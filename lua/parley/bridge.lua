---Passive workspace bridge. Plugin startup owns its timer/pipe; require acquires nothing.
---Binding survives disconnects and Pi reloads, but never follows a changed Pi session.
---Explicit activation is dispatched to workspace.lua; transport owns no model policy.
local client = require("parley.client")
local M = {}

local actions = {
    attach = "bridge-attach",
    ping = "bridge-ping",
    activate = "workspace-activate",
}

---@alias ParleyBridge.State 'waiting'|'connecting'|'connected'|'unavailable'|'rebind-required'

---A discovery record whose runtime/session strings were checked before attach.
---It becomes a binding only after the socket returns the matching identity.
---@class ParleyBridge.Endpoint: ParleyClient.Endpoint
---@field instanceId string
---@field sessionId string

---@class ParleyBridge.Identity
---@field version 1
---@field workspace string
---@field editorId string
---@field instanceId string
---@field sessionId string
---@field pid? unknown Not part of identity verification; debug metadata from Pi.
---@field nonce? unknown Checked separately for ping results.

---@class ParleyBridge.PingIdentity: ParleyBridge.Identity
---@field nonce string

---Outbound result fields; incoming action-specific fields remain untrusted.
---@class ParleyBridge.Result: ParleyBridge.PingIdentity
---@field active? true

---@class ParleyBridge.Payload
---@field instanceId string
---@field sessionId string
---@field editorId string
---@field label string? Sent only at attach.
---@field nonce string? Sent only at ping.

---@class ParleyBridge.RoundTrip
---@field requestId string
---@field result ParleyBridge.PingIdentity

---@alias ParleyBridge.PingCallback fun(result: ParleyBridge.RoundTrip?, err: string?)

---@class ParleyBridge.Activity
---@field state ParleyBridge.State
---@field error string?
---@field last_result ParleyBridge.RoundTrip?

---@class ParleyBridge.Status: ParleyBridge.Activity
---@field running boolean Whether plugin-owned polling is active.
---@field connected boolean Whether the verified local pipe is still open; not a live probe.
---@field workspace string? Canonical root, retained across navigation/disconnects.
---@field editor_id string Identity of this loaded editor bridge.
---@field binding ParleyBridge.Endpoint? Last verified binding, retained when unavailable.

local editor_id = client.id()
---@type ParleyClient?
local pipe
---@type ParleyClient?
local connecting
---@type uv.uv_timer_t?
local timer
---@type string?
local root
---@type ParleyBridge.Endpoint?
local binding
local generation = 0
local busy, stopped = false, false
---@type ParleyBridge.Activity
local status = { state = "waiting" }

---@param state ParleyBridge.State
---@param err string?
local function report(state, err)
    if status.state == state and status.error == err then return end
    status.state, status.error = state, err
    vim.api.nvim_exec_autocmds("User", {
        pattern = "ParleyBridgeChanged",
        data = M.status(),
    })
    if err then vim.notify("Parley bridge: " .. err, vim.log.levels.WARN) end
end

---Return an independent deep copy; mutating it never changes bridge state.
---This reads cached state only and acquires no resources.
---@return ParleyBridge.Status
function M.status()
    return vim.deepcopy({
        state = status.state,
        running = timer ~= nil and not stopped,
        connected = status.state == "connected" and pipe ~= nil and not pipe.closed,
        error = status.error,
        workspace = root,
        editor_id = editor_id,
        binding = binding,
        last_result = status.last_result,
    })
end

---Check untrusted wire identity before treating it as an application record.
---@param identity unknown
---@param endpoint ParleyBridge.Endpoint
---@return boolean
local function matches(identity, endpoint)
    return type(identity) == "table"
        and identity.version == 1
        and identity.workspace == root
        and identity.editorId == editor_id
        and identity.instanceId == endpoint.instanceId
        and identity.sessionId == endpoint.sessionId
end

---@param endpoint ParleyBridge.Endpoint
---@return ParleyBridge.Payload
local function payload(endpoint)
    return {
        instanceId = endpoint.instanceId,
        sessionId = endpoint.sessionId,
        editorId = editor_id,
    }
end

---@param endpoint ParleyBridge.Endpoint
---@param nonce string
---@return ParleyBridge.Result
local function response_identity(endpoint, nonce)
    return {
        version = 1,
        workspace = endpoint.workspace,
        editorId = editor_id,
        instanceId = endpoint.instanceId,
        sessionId = endpoint.sessionId,
        nonce = nonce,
    }
end

---@param p ParleyBridge.PingIdentity Verified identity and correlated nonce.
---@param endpoint ParleyBridge.Endpoint
---@param respond ParleyClient.ResultCallback
local function handle_ping(p, endpoint, respond) respond(response_identity(endpoint, p.nonce)) end

---@param p ParleyBridge.PingIdentity Verified identity and correlated nonce.
---@param endpoint ParleyBridge.Endpoint
---@param respond ParleyClient.ResultCallback
local function handle_activate(p, endpoint, respond)
    if stopped or not pipe or pipe.closed or status.state ~= "connected" then
        respond(nil, "Bridge is not connected; no review activated")
        return
    end
    local activated, err = require("parley.workspace").activate(endpoint)
    if not activated then
        respond(nil, err)
        return
    end
    local result = response_identity(endpoint, p.nonce)
    result.active = true
    respond(result)
end

---@type table<string, fun(p: ParleyBridge.PingIdentity, endpoint: ParleyBridge.Endpoint, respond: ParleyClient.ResultCallback)>
local handlers = {
    [actions.ping] = handle_ping,
    [actions.activate] = handle_activate,
}

---@param message ParleyClient.Request Header validated by the transport; payload untrusted.
---@param respond ParleyClient.ResultCallback
local function incoming(message, respond)
    local endpoint = binding
    local p = message.payload
    if not endpoint or not matches(p, endpoint) then
        respond(nil, "Pi request identity does not match the attached bridge")
        return
    end
    ---@cast p ParleyBridge.Identity
    if type(p.nonce) ~= "string" or p.nonce ~= message.requestId then
        respond(nil, "Pi request identity does not match the attached bridge")
        return
    end
    ---@cast p ParleyBridge.PingIdentity
    local handler = handlers[message.action]
    if not handler then
        respond(nil, "Unsupported Pi presentation request")
        return
    end
    handler(p, endpoint, respond)
end

---Editor-initiated activation uses the same verified binding, without another pipe.
---@return boolean activated
---@return string? err
function M.activate()
    if stopped or not pipe or pipe.closed or status.state ~= "connected" or not binding then
        return false, "No matching connected Pi session; check :checkhealth parley"
    end
    return require("parley.workspace").activate(binding)
end

---Submit a model-free request. The callback borrows the verified result also
---cached as last_result; treat it as read-only. status() deep-copies that cache.
---Disconnected failure is immediate; other settlement is scheduled.
---When omitted, the callback displays the result/error without changing focus.
---@param done ParleyBridge.PingCallback?
function M.ping(done)
    done = done
        or function(result, err)
            vim.notify(
                err or ("Parley bridge round trip: " .. vim.json.encode(result)),
                err and vim.log.levels.ERROR or vim.log.levels.INFO
            )
        end
    if not pipe or pipe.closed or status.state ~= "connected" then
        done(nil, status.error or "Parley bridge is not connected")
        return
    end
    local owner, endpoint = pipe, binding
    -- Connected is published only after a verified binding has been installed.
    ---@cast endpoint ParleyBridge.Endpoint
    local p = payload(endpoint)
    p.nonce = client.id()
    ---@type string?
    local request_id
    request_id = owner.request(actions.ping, nil, p, function(result, err)
        if owner ~= pipe then
            done(nil, "Bridge binding changed during request")
            return
        end
        if result and (not matches(result, endpoint) or result.nonce ~= p.nonce) then
            result, err = nil, "Pi result identity mismatch"
            owner.close(err)
        end
        if result then
            -- Both identity and nonce were checked above; a successful request has an ID.
            ---@cast result ParleyBridge.PingIdentity
            ---@cast request_id string
            status.last_result = { requestId = request_id, result = result }
        end
        done(result and { requestId = request_id, result = result } or nil, err)
    end, root)
end

local function tick()
    if stopped or busy then return end
    -- Navigating buffers/windows does not retarget an existing workspace binding.
    root = root or client.workspace(vim.fn.getcwd())
    if not root then
        report("waiting", "Not in a workspace; :ParleyBind after changing directory")
        return
    end
    if pipe and not pipe.closed then
        local owner, token = pipe, generation
        busy = true
        M.ping(function(_, err)
            if stopped or generation ~= token or pipe ~= owner then return end
            busy = false
            if err then
                report("unavailable", err)
                owner.close(err)
            end
        end)
        return
    end
    local token = generation
    busy = true
    client.endpoints(root, function(endpoints, err)
        if stopped or generation ~= token then return end
        if not endpoints then
            busy = false
            report("waiting", err)
            return
        end
        if #endpoints ~= 1 then
            busy = false
            report("unavailable", "Ambiguous Pi workspace owners; no connection made")
            return
        end
        local endpoint = endpoints[1]
        if
            type(endpoint.instanceId) ~= "string"
            or type(endpoint.sessionId) ~= "string"
            or endpoint.sessionId == ""
        then
            busy = false
            report("unavailable", "Pi advertisement has no runtime/session identity; reload Pi")
            return
        end
        ---@cast endpoint ParleyBridge.Endpoint
        if binding and binding.sessionId ~= endpoint.sessionId then
            busy = false
            report(
                "rebind-required",
                "Pi session changed; :ParleyBind explicitly binds the advertised session"
            )
            return
        end
        if status.state == "waiting" then report("connecting") end
        connecting = client.connect(endpoint.socket, function(owner, connect_err)
            if stopped or generation ~= token then
                if owner then owner.close() end
                return
            end
            connecting = nil
            if not owner then
                busy = false
                report("unavailable", connect_err)
                return
            end
            pipe = owner
            owner.on_disconnect = function(reason)
                if stopped or owner ~= pipe then return end
                busy = false
                report("unavailable", reason or "Pi disconnected; waiting for the bound session")
            end
            local p = payload(endpoint)
            p.label = "Neovim PID " .. vim.uv.os_getpid() .. " · " .. root:sub(1, 200)
            owner.request(actions.attach, nil, p, function(identity, attach_err)
                if stopped or generation ~= token or pipe ~= owner then
                    owner.close()
                    return
                end
                busy = false
                if not identity or not matches(identity, endpoint) then
                    local failure = attach_err or "Pi attach identity mismatch"
                    owner.close(failure)
                    report("unavailable", failure)
                    return
                end
                binding = endpoint
                report("connected")
            end, root)
        end, incoming)
    end)
end

---Explicitly forget only the transport binding. Never migrate conversation/drafts.
function M.bind()
    generation = generation + 1
    local old_pipe, old_connecting = pipe, connecting
    pipe, connecting, binding, root = nil, nil, nil, nil
    busy = false
    if old_pipe then old_pipe.close() end
    if old_connecting then old_connecting.close() end
    status.last_result = nil
    tick()
end

---Idempotently release the plugin-owned timer and all connecting/connected pipes.
---The last binding remains cached; starting again does not authorize rebinding.
function M.stop()
    if stopped then return end
    stopped = true
    generation = generation + 1
    if timer then
        timer:stop()
        timer:close()
        timer = nil
    end
    if pipe then pipe.close() end
    if connecting then connecting.close() end
    pipe, connecting = nil, nil
end

---Plugin activation owns this singleton until stop()/VimLeavePre. Repeated starts
---are harmless; requiring the module alone never starts discovery or connection.
function M.start()
    if timer then return end
    stopped = false
    timer = assert(vim.uv.new_timer())
    timer:start(0, 5000, vim.schedule_wrap(tick))
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("ParleyBridge", { clear = true }),
        once = true,
        callback = M.stop,
    })
end

return M
