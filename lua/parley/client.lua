---Versioned NDJSON client. Each instance owns its pipe, request timers and acknowledgements.
---No resources are acquired by require(); callbacks run on Neovim's main loop.
local uv = vim.uv
local M = {}

---A decoded table, not a validated application result. The request's handler
---owns validation of its fields; the transport only validates the envelope.
---@alias ParleyClient.Result table<string|integer, unknown>
---@alias ParleyClient.ResultCallback fun(result: ParleyClient.Result?, err: string?)
---@alias ParleyClient.ConnectCallback fun(client: ParleyClient?, err: string?)
---@alias ParleyClient.RequestHandler fun(request: ParleyClient.Request, respond: ParleyClient.ResultCallback)

---Only the header is validated before dispatch. Payloads remain untrusted.
---@class ParleyClient.Request
---@field version 1
---@field requestId string
---@field action string
---@field payload? unknown
---@field reviewId? unknown
---@field workspace? unknown

---Discovery validates workspace, protocol version and socket path only.
---Runtime/session identity must still be checked by attach over the socket.
---@class ParleyClient.Endpoint
---@field version 1
---@field workspace string
---@field socket string
---@field instanceId? unknown
---@field sessionId? unknown
---@field pid? unknown

---@class ParleyClient.Success
---@field version 1
---@field requestId string
---@field ok true
---@field result ParleyClient.Result Fields remain untrusted application data.

---@class ParleyClient.Failure
---@field version 1
---@field requestId string
---@field ok false
---@field error string

---@alias ParleyClient.Response ParleyClient.Success|ParleyClient.Failure

---@class ParleyClient.Pending
---@field callback ParleyClient.ResultCallback
---@field timer uv.uv_timer_t Owned until result, timeout or client closure.

local serial = 0

---@return string
function M.state_directory()
    return vim.env.PARLEY_STATE_DIR
        or vim.fs.joinpath(vim.env.XDG_STATE_HOME or vim.fn.expand("~/.local/state"), "parley")
end

---@param cwd string
---@return string? root Canonical workspace, or nil on failure.
---@return string? err
function M.workspace(cwd)
    local dir = uv.fs_realpath(cwd)
    if not dir then return nil, "Cannot resolve workspace" end
    while true do
        if
            uv.fs_lstat(vim.fs.joinpath(dir, ".jj")) or uv.fs_lstat(vim.fs.joinpath(dir, ".git"))
        then
            return dir
        end
        local parent = vim.fs.dirname(dir)
        if parent == dir then return nil, "Not in a jj or Git workspace" end
        dir = parent
    end
end

---@return string
function M.id()
    serial = serial + 1
    -- Fixed decimal avoids scientific-notation punctuation rejected by protocol identifiers.
    return ("nvim-%d-%.0f-%d"):format(uv.os_getpid(), uv.hrtime(), serial)
end

---@param request_id string
---@param result ParleyClient.Result?
---@param handler_err string?
---@return string? encoded
---@return string? err
local function encode_response(request_id, result, handler_err)
    ---@type ParleyClient.Response
    local envelope
    if result ~= nil then
        envelope = { version = 1, requestId = request_id, ok = true, result = result }
    else
        envelope = {
            version = 1,
            requestId = request_id,
            ok = false,
            error = handler_err or "Unsupported Pi request",
        }
    end
    local encoded, data = pcall(vim.json.encode, envelope)
    if not encoded then
        -- Serialization failed before delivery. Send a correlated failure, not the bad result.
        envelope = {
            version = 1,
            requestId = request_id,
            ok = false,
            error = "Editor result encoding failed: " .. tostring(data),
        }
        encoded, data = pcall(vim.json.encode, envelope)
    end
    if not encoded then return nil, tostring(data) end
    return data .. "\n"
end

---Return a caller-owned client immediately, including while connecting.
---The scheduled callback receives it only after connection succeeds. Results
---and incoming requests run on the main loop; closed-request failure is immediate.
---Payloads are encoded at submission, not retained; callbacks live until settlement.
---Incoming handlers respond once, synchronously or after application-owned work completes.
---Result tables are handed to the application and not retained by the transport.
---Handle-allocation failure raises; socket connection failure uses the callback.
---@param socket string Unix socket path from discovery.
---@param callback ParleyClient.ConnectCallback
---@param on_request ParleyClient.RequestHandler? Application-owned named-request handler.
---@return ParleyClient client Caller must close it, even when cancelling connection.
function M.connect(socket, callback, on_request)
    ---@type uv.uv_pipe_t
    local pipe = assert(uv.new_pipe(false))
    ---The caller owns closure. Pending callbacks receive at most one result/error.
    ---@class ParleyClient
    ---@field pending table<string, ParleyClient.Pending> Transport-owned; callers must not mutate.
    ---@field closed boolean
    ---@field on_disconnect fun(reason: string?)? Called on the main loop after closure.
    ---@field close fun(reason?: string) Idempotently close pipe/timers and fail pending requests.
    ---@field request fun(action: string, review_id: string?, payload: table<string, unknown>?, done: ParleyClient.ResultCallback, workspace?: string): string? Request ID, absent if already closed.
    local client = { pending = {}, closed = false }
    local buffer = ""
    ---@type uv.uv_timer_t
    local connect_timer = assert(uv.new_timer())
    local connect_completed = false
    ---@param owner ParleyClient?
    ---@param err string?
    local function complete_connect(owner, err)
        if connect_completed then return end
        connect_completed = true
        connect_timer:stop()
        connect_timer:close()
        vim.schedule(function() callback(owner, err) end)
    end
    ---@param reason string?
    function client.close(reason)
        if client.closed then return end
        client.closed = true
        complete_connect(nil, reason or "Pi connection cancelled")
        pipe:read_stop()
        if not pipe:is_closing() then pipe:close() end
        for id, entry in pairs(client.pending) do
            client.pending[id] = nil
            entry.timer:stop()
            entry.timer:close()
            vim.schedule(function() entry.callback(nil, reason or "Detached from Pi") end)
        end
        if client.on_disconnect then vim.schedule(function() client.on_disconnect(reason) end) end
    end
    ---@param action string
    ---@param review_id string?
    ---@param payload table<string, unknown>?
    ---@param done ParleyClient.ResultCallback
    ---@param workspace string?
    ---@return string? request_id Absent if the client is already closed.
    function client.request(action, review_id, payload, done, workspace)
        if client.closed then
            done(nil, "Pi connection is closed")
            return
        end
        local id = M.id()
        ---@type uv.uv_timer_t
        local timer = assert(uv.new_timer())
        client.pending[id] = { callback = done, timer = timer }
        timer:start(
            10000,
            0,
            function()
                client.close(
                    "Pi acknowledgement timed out; delivery is unknown. Reattach before retrying."
                )
            end
        )
        local message = {
            version = 1,
            requestId = id,
            action = action,
            reviewId = review_id,
            payload = payload,
            workspace = workspace,
        }
        pipe:write(vim.json.encode(message) .. "\n", function(err)
            if err then client.close("Pi write failed: " .. err) end
        end)
        return id
    end
    local function response_written(err)
        if err then client.close("Editor result write failed: " .. err) end
    end

    ---@param request ParleyClient.Request Header validated; payload remains untrusted.
    ---@param handler ParleyClient.RequestHandler
    local function handle_request(request, handler)
        if client.closed then return end
        local responded = false
        local function respond(result, handler_err)
            if responded or client.closed then return end
            local data, encode_err = encode_response(request.requestId, result, handler_err)
            if not data then
                client.close(
                    "Editor response encoding failed: "
                        .. (encode_err or "unknown serialization error")
                )
                return
            end
            -- Once writing starts, delivery can be uncertain. Never retry this response.
            responded = true
            local written, write_request, write_err =
                pcall(pipe.write, pipe, data, response_written)
            if not written then
                client.close("Editor result write failed: " .. tostring(write_request))
            elseif not write_request then
                client.close(
                    "Editor result write failed: " .. (write_err or "write was not queued")
                )
            end
        end
        -- Protect invocation only; the handler owns failures in its later asynchronous work.
        -- respond() protects encoding and writing regardless of when the handler calls it.
        local handled, handler_err = pcall(handler, request, respond)
        if not handled then
            if responded then
                client.close(
                    "Editor request handler failed after responding: " .. tostring(handler_err)
                )
            else
                respond(nil, tostring(handler_err))
            end
        end
    end

    connect_timer:start(10000, 0, function() client.close("Pi socket connection timed out") end)
    pipe:connect(socket, function(err)
        if client.closed then
            complete_connect(nil, "Pi connection cancelled")
            return
        end
        if err then
            client.close("Cannot connect to Pi: " .. err)
            return
        end
        pipe:read_start(function(read_err, chunk)
            if read_err or not chunk then
                client.close(read_err or "Pi disconnected; local notes retained")
                return
            end
            buffer = buffer .. chunk
            if #buffer > 64 * 1024 * 1024 then
                client.close("Oversized Pi response")
                return
            end
            while true do
                local boundary = buffer:find("\n", 1, true)
                if not boundary then break end
                local line = buffer:sub(1, boundary - 1)
                buffer = buffer:sub(boundary + 1)
                ---@type boolean, unknown
                local ok, response = pcall(vim.json.decode, line)
                if ok and type(response) == "table" and type(response.action) == "string" then
                    if
                        response.version ~= 1
                        or type(response.requestId) ~= "string"
                        or not on_request
                    then
                        client.close("Unexpected Pi request")
                        return
                    end
                    -- Header validation above does not validate the application payload.
                    ---@cast response ParleyClient.Request
                    vim.schedule(function() handle_request(response, on_request) end)
                else
                    if
                        not ok
                        or type(response) ~= "table"
                        or response.version ~= 1
                        or type(response.ok) ~= "boolean"
                        or type(response.requestId) ~= "string"
                        or (response.ok and type(response.result) ~= "table")
                        or (not response.ok and type(response.error) ~= "string")
                    then
                        client.close("Invalid Parley acknowledgement")
                        return
                    end
                    ---@cast response ParleyClient.Response
                    local entry = client.pending[response.requestId]
                    if not entry then
                        client.close("Unmatched Parley acknowledgement")
                        return
                    end
                    client.pending[response.requestId] = nil
                    entry.timer:stop()
                    entry.timer:close()
                    vim.schedule(function()
                        if response.ok then
                            entry.callback(response.result)
                        else
                            entry.callback(nil, response.error or "Pi rejected request")
                        end
                    end)
                end
            end
        end)
        complete_connect(client)
    end)
    return client
end

---Discovery reads advertisements only. Attach must verify them over the socket.
---Stale sockets/leases are never deleted by Neovim.
---Return newly decoded advertisements; callers may retain/mutate their own copies.
---@param cwd string
---@param callback fun(endpoints: ParleyClient.Endpoint[]?, err: string?, root: string?)
function M.endpoints(cwd, callback)
    local root, err = M.workspace(cwd)
    if not root then
        callback(nil, err)
        return
    end
    local directory = vim.fs.joinpath(M.state_directory(), "endpoints")
    local scan, scan_err, code = uv.fs_scandir(directory)
    if not scan then
        callback(nil, code == "ENOENT" and "Waiting for Pi in this workspace" or scan_err)
        return
    end
    ---@type ParleyClient.Endpoint[]
    local endpoints = {}
    while true do
        local name = uv.fs_scandir_next(scan)
        if not name then break end
        if name:match("%.json$") then
            ---@type boolean, unknown
            local ok, descriptor = pcall(
                function()
                    return vim.json.decode(
                        table.concat(vim.fn.readfile(vim.fs.joinpath(directory, name)), "\n")
                    )
                end
            )
            if not ok or type(descriptor) ~= "table" then
                callback(nil, "Invalid Pi discovery record: " .. name)
                return
            end
            if descriptor.workspace == root then
                if
                    descriptor.version ~= 1
                    or type(descriptor.socket) ~= "string"
                    or descriptor.socket:sub(1, 1) ~= "/"
                then
                    callback(nil, "Incomplete or unsupported Pi discovery record: " .. name)
                    return
                end
                ---@cast descriptor ParleyClient.Endpoint
                endpoints[#endpoints + 1] = descriptor
            end
        end
    end
    if #endpoints == 0 then
        callback(nil, "Waiting for Pi in this workspace")
        return
    end
    callback(endpoints, nil, root)
end

---@class ParleyClient.ReviewListing
---@field id unknown
---@field status 'open'
---@field endpoint ParleyClient.Endpoint Assigned locally, not trusted from Pi.
---@field [string] unknown Other review fields are validated by the review handler.

---Legacy review discovery remains an explicit list request, not bridge activation.
---@param cwd string
---@param callback fun(reviews: ParleyClient.ReviewListing[]?, err: string?)
function M.discover(cwd, callback)
    M.endpoints(cwd, function(endpoints, err, root)
        if not endpoints then
            callback(nil, err)
            return
        end
        ---@type ParleyClient.ReviewListing[]
        local reviews = {}
        ---@type string[]
        local errors = {}
        local remaining = #endpoints
        for _, endpoint in ipairs(endpoints) do
            M.connect(endpoint.socket, function(client, connect_err)
                local function finish()
                    remaining = remaining - 1
                    if remaining == 0 then
                        if #errors > 0 then
                            callback(nil, table.concat(errors, "\n"))
                        else
                            callback(reviews)
                        end
                    end
                end
                if not client then
                    errors[#errors + 1] = connect_err
                    finish()
                    return
                end
                client.request("list", nil, nil, function(items, list_err)
                    client.close()
                    if list_err then
                        errors[#errors + 1] = list_err
                    elseif type(items) ~= "table" then
                        errors[#errors + 1] = "Invalid Pi review list"
                    else
                        for _, item in ipairs(items) do
                            if item.status == "open" then
                                -- Only the open status is selected here, not the review schema.
                                ---@cast item ParleyClient.ReviewListing
                                item.endpoint = endpoint
                                reviews[#reviews + 1] = item
                            end
                        end
                    end
                    finish()
                end, root)
            end)
        end
    end)
end

return M
