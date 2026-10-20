---Explicit review pairing over the existing socket. Startup/require acquire nothing.
---Only ReviewStart discovers an offer; subsequent reconnects retain its workspace
---and Pi session. Presentation/history survive disconnects, never migrate sessions.
local client = require("parley.client")
local workspace = require("parley.workspace")
local M = {}
local api = vim.api
local actions = { attach = "bridge-attach", detach = "bridge-detach", ping = "bridge-ping" }

---@alias ParleyBridge.State 'idle'|'connecting'|'connected'|'unavailable'|'rebind-required'

---@class ParleyBridge.Endpoint: ParleyClient.Endpoint
---@field instanceId string
---@field sessionId string

---@class ParleyBridge.Identity
---@field version 1
---@field workspace string
---@field editorId string
---@field instanceId string
---@field sessionId string
---@field nonce string

---@class ParleyBridge.RoundTrip
---@field requestId string
---@field result ParleyBridge.Identity

---@alias ParleyBridge.PingCallback fun(result: ParleyBridge.RoundTrip?, err: string?)

---@class ParleyBridge.Status
---@field state ParleyBridge.State
---@field running boolean Reconnects enabled only after an explicit successful start.
---@field connected boolean Cached socket state, not a live probe.
---@field error? string
---@field workspace? string Retained across navigation/disconnects.
---@field editor_id string
---@field binding? ParleyBridge.Endpoint Last socket-verified binding.
---@field last_result? ParleyBridge.RoundTrip

local editor_id = client.id()
---@type ParleyClient?
local pipe
---@type ParleyClient?
local connecting
---@type ParleyClient?
local releasing
---@type uv.uv_timer_t?
local timer
---@type integer?
local group
---@type string?
local root
---@type ParleyBridge.Endpoint?
local binding
---@type ParleyBridge.Endpoint? Unacknowledged attach may have claimed the editor slot.
local candidate
local generation = 0
local busy, stopped = false, true
---@type { state: ParleyBridge.State, error?: string, last_result?: ParleyBridge.RoundTrip }
local status = { state = "idle" }

---Cached, independent snapshot. No filesystem reads, requests or resource creation.
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

local function report(state, err)
    if status.state == state and status.error == err then
        return
    end
    status.state, status.error = state, err
    api.nvim_exec_autocmds("User", { pattern = "ParleyBridgeChanged", data = M.status() })
    if err then
        vim.notify("Parley: " .. err, vim.log.levels.WARN)
    end
end

local function matches(identity, endpoint, nonce)
    return type(identity) == "table"
        and identity.version == 1
        and identity.workspace == endpoint.workspace
        and identity.editorId == editor_id
        and identity.instanceId == endpoint.instanceId
        and identity.sessionId == endpoint.sessionId
        and identity.nonce == nonce
end

local function payload(endpoint)
    return {
        instanceId = endpoint.instanceId,
        sessionId = endpoint.sessionId,
        editorId = editor_id,
        nonce = client.id(),
    }
end

---One attempt to release exactly our slot, including uncertain attach delivery.
---This is cleanup, not discovery, review activation or a reconnect loop. Its pipe
---and request timers end on acknowledgment/failure; failure never retargets it.
local function release(endpoint, owner)
    if not endpoint then
        if owner then
            owner.close()
        end
        return
    end
    local function send(connection)
        releasing = connection
        local p = payload(endpoint)
        local submitted, failure = pcall(
            connection.request,
            actions.detach,
            nil,
            p,
            function(identity, err)
                connection.close()
                if releasing == connection then
                    releasing = nil
                end
                if not err and not matches(identity, endpoint, p.nonce) then
                    err = "Pi detach identity mismatch"
                end
                if err then
                    vim.notify(
                        "Parley: editor release was not confirmed: "
                            .. err
                            .. ". Start/stop this editor again when the same Pi offer is available.",
                        vim.log.levels.WARN
                    )
                end
            end,
            endpoint.workspace
        )
        if not submitted then
            if releasing == connection then
                releasing = nil
            end
            pcall(connection.close)
            error(failure, 0)
        end
    end
    if owner and not owner.closed then
        send(owner)
    else
        local connection
        connection = client.connect(endpoint.socket, function(connected, err)
            if not connected then
                if releasing == connection then
                    releasing = nil
                end
                vim.notify(
                    "Parley: could not release the disconnected Pi attachment: " .. tostring(err),
                    vim.log.levels.WARN
                )
                return
            end
            send(connected)
        end)
        releasing = connection
    end
end

---Unpublish this transport lifetime before callbacks can start a replacement.
---All mandatory cleanup runs even if an operation/hook throws.
local function disconnect()
    generation = generation + 1
    stopped, busy = true, false
    local owner, pending, endpoint = pipe, connecting, candidate or binding
    local old_timer, old_group = timer, group
    pipe, connecting, candidate, binding, timer, group = nil, nil, nil, nil, nil, nil
    local failed, failure
    local function finish(action)
        local ok, err = pcall(action)
        if not ok and not failed then
            failed, failure = true, err
        end
    end
    finish(function()
        if old_timer then
            old_timer:stop()
            old_timer:close()
        end
    end)
    finish(function()
        if old_group then
            api.nvim_del_augroup_by_id(old_group)
        end
    end)
    finish(function()
        if pending then
            pending.close()
        end
    end)
    finish(function()
        release(endpoint, owner)
    end)
    if failed then
        error(failure, 0)
    end
end

---ReviewStop releases the editor slot, not Pi leadership or local history/drafts.
function M.stop()
    local closed, failure = pcall(disconnect)
    root, status.last_result = nil, nil
    local token = generation
    local detached, err = pcall(workspace.stop)
    local reported, report_err = pcall(function()
        if generation == token then
            report("idle")
        end
    end)
    if not closed then
        error(failure, 0)
    end
    if not detached then
        error(err, 0)
    end
    if not reported then
        error(report_err, 0)
    end
end

---@param workspace_root string
---@return ParleyBridge.Endpoint? endpoint
---@return string? failure
local function endpoint_for(workspace_root)
    local result, failure
    -- Discovery is currently a synchronous filesystem read with a callback.
    client.endpoints(workspace_root, function(endpoints, err)
        if not endpoints then
            failure = (err or "No review offer")
                .. "; run /review in the leading Pi, then :ReviewStart"
        elseif #endpoints ~= 1 then
            failure = "Ambiguous Pi workspace owners; no connection made"
        else
            local endpoint = endpoints[1]
            if
                type(endpoint.instanceId) ~= "string"
                or endpoint.instanceId == ""
                or type(endpoint.sessionId) ~= "string"
                or endpoint.sessionId == ""
            then
                failure =
                    "Pi offer has no runtime/session identity; run /review in the updated Pi extension"
            else
                ---@cast endpoint ParleyBridge.Endpoint
                result = endpoint
            end
        end
    end)
    return result, failure
end

---Verify a candidate bidirectionally. The temporary endpoint is accepted only on
---this exact connecting socket/generation, never installed as a binding early.
local function attach(endpoint, token, done)
    local connection
    connection = client.connect(endpoint.socket, function(owner, err)
        if stopped or generation ~= token then
            if owner then
                owner.close()
            end
            return
        end
        connecting = nil
        if not owner then
            done(nil, err)
            return
        end
        pipe = owner
        owner.on_disconnect = function(reason)
            if stopped or generation ~= token or pipe ~= owner then
                return
            end
            busy = false
            report("unavailable", reason or "Pi disconnected; retaining the bound session")
        end
        candidate = endpoint
        local p = payload(endpoint)
        p.label = "Neovim PID " .. vim.uv.os_getpid() .. " · " .. endpoint.workspace:sub(1, 200)
        owner.request(actions.attach, nil, p, function(identity, attach_err)
            if stopped or generation ~= token or pipe ~= owner then
                return
            end
            if not identity or not matches(identity, endpoint, p.nonce) then
                done(nil, attach_err or "Pi attach identity mismatch")
                return
            end
            binding, candidate = endpoint, nil
            done(owner)
        end, endpoint.workspace)
    end, function(message, respond)
        local p = message.payload
        if
            stopped
            or generation ~= token
            or pipe ~= connection
            or message.workspace ~= endpoint.workspace
            or message.action ~= actions.ping
            or type(p) ~= "table"
            or type(p.nonce) ~= "string"
            or p.nonce ~= message.requestId
            or not matches(p, endpoint, message.requestId)
        then
            respond(nil, "Pi request does not match this review pairing")
            return
        end
        respond({
            version = 1,
            workspace = endpoint.workspace,
            editorId = editor_id,
            instanceId = endpoint.instanceId,
            sessionId = endpoint.sessionId,
            nonce = p.nonce,
        })
    end)
    connecting = connection
end

---Model-free round trip on an already verified socket. Never changes binding.
---@param done ParleyBridge.PingCallback
function M.ping(done)
    local owner, endpoint, token = pipe, binding, generation
    if not owner or owner.closed or not endpoint then
        done(nil, "Review is not connected")
        return
    end
    local p = payload(endpoint)
    local request_id
    request_id = owner.request(actions.ping, nil, p, function(identity, err)
        if generation ~= token or pipe ~= owner then
            return
        end
        if identity and not matches(identity, endpoint, p.nonce) then
            identity, err = nil, "Pi ping identity mismatch"
            owner.close(err)
        end
        if identity then
            ---@cast identity ParleyBridge.Identity
            ---@cast request_id string
            status.last_result = { requestId = request_id, result = identity }
        end
        done(identity and { requestId = request_id, result = identity } or nil, err)
    end, endpoint.workspace)
end

local function tick()
    if stopped or busy or releasing or not binding then
        return
    end
    local token, retained = generation, binding
    if pipe and not pipe.closed then
        local owner = pipe
        busy = true
        M.ping(function(_, err)
            if stopped or generation ~= token or pipe ~= owner then
                return
            end
            busy = false
            if err then
                owner.close(err)
                report("unavailable", err)
            else
                report("connected")
            end
        end)
        return
    end
    local endpoint, err = endpoint_for(retained.workspace)
    if not endpoint then
        report("unavailable", err)
        return
    end
    if endpoint.sessionId ~= retained.sessionId then
        if timer then
            timer:stop()
            timer:close()
            timer = nil
        end
        stopped = true
        report(
            "rebind-required",
            "Pi session changed; run /review there, then :ReviewStop and :ReviewStart here"
        )
        return
    end
    busy = true
    attach(endpoint, token, function(owner, failure)
        busy = false
        if owner then
            report("connected")
        else
            if pipe then
                pipe.close()
            end
            report("unavailable", failure)
        end
    end)
end

local function reject(reason)
    if binding then
        vim.notify("Parley: " .. reason, vim.log.levels.WARN)
    else
        report("unavailable", reason)
    end
end

---Discover once, verify, then activate only if the original source is still
---focused/available. No offer means an immediate failure, not background waiting.
function M.activate()
    if busy or releasing then
        vim.notify("Parley: pairing or editor release is still in progress", vim.log.levels.WARN)
        return
    end
    local workspace_root, failure = client.workspace(vim.fn.getcwd())
    if not workspace_root then
        reject(failure)
        return
    end
    local endpoint, err = endpoint_for(workspace_root)
    if not endpoint then
        reject(err)
        return
    end
    if
        binding
        and (binding.workspace ~= endpoint.workspace or binding.sessionId ~= endpoint.sessionId)
    then
        reject(":ReviewStop before pairing another workspace/Pi session")
        return
    end
    local selected = { workspace = endpoint.workspace, sessionId = endpoint.sessionId }
    local ready, reason = workspace.can_activate(selected)
    if not ready then
        reject(reason)
        return
    end
    if binding and pipe and not pipe.closed then
        -- An existing verified pairing cannot be silently replaced by discovery.
        local activated, activate_err = workspace.activate({
            workspace = binding.workspace,
            sessionId = binding.sessionId,
        })
        if not activated then
            report("unavailable", activate_err)
        end
        return
    end
    local window, buffer = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local retained, already_active = binding, workspace.is_active()
    generation = generation + 1
    local token = generation
    stopped, busy, root = false, true, workspace_root
    local started, start_err = pcall(function()
        group = group or api.nvim_create_augroup("ParleyBridge", { clear = true })
        api.nvim_clear_autocmds({ group = group })
        api.nvim_create_autocmd("VimLeavePre", { group = group, once = true, callback = M.stop })
        report("connecting")
        if stopped or generation ~= token then
            return
        end
        attach(endpoint, token, function(owner, attach_err)
            busy = false
            if not owner then
                if retained and timer then
                    if pipe then
                        pipe.close()
                    end
                else
                    disconnect()
                end
                report("unavailable", attach_err)
                return
            end
            local activated, activate_err
            local completed, activation_failure = pcall(function()
                if
                    not already_active
                    and (
                        not api.nvim_win_is_valid(window)
                        or api.nvim_get_current_win() ~= window
                        or api.nvim_win_get_buf(window) ~= buffer
                    )
                then
                    activated, activate_err =
                        false, "Source focus changed during pairing; no review activated"
                    return
                end
                if not already_active then
                    local available, unavailable = workspace.can_activate(selected)
                    if not available then
                        activated, activate_err = false, unavailable
                        return
                    end
                end
                activated, activate_err = workspace.activate(selected)
                if stopped or generation ~= token or not activated then
                    return
                end
                if not timer then
                    timer = assert(vim.uv.new_timer())
                    timer:start(5000, 5000, vim.schedule_wrap(tick))
                end
                report("connected")
            end)
            if stopped or generation ~= token then
                if not completed then
                    error(activation_failure, 0)
                end
                return
            end
            if not completed or not activated then
                pcall(M.stop)
                if not completed then
                    error(activation_failure, 0)
                end
                report("unavailable", activate_err)
            end
        end)
    end)
    if not started then
        if generation == token then
            pcall(disconnect)
        end
        error(start_err, 0)
    end
end

return M
