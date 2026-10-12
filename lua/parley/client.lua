---Versioned NDJSON client. Each instance owns its pipe, request timers and acknowledgements.
---No resources are acquired by require(); callbacks run on Neovim's main loop.
local M = {}
local uv = vim.uv
local serial = 0

function M.state_directory()
    return vim.env.PARLEY_STATE_DIR
        or vim.fs.joinpath(vim.env.XDG_STATE_HOME or vim.fn.expand("~/.local/state"), "parley")
end

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

function M.id()
    serial = serial + 1
    return ("nvim-%d-%s-%d"):format(uv.os_getpid(), tostring(uv.hrtime()), serial)
end

function M.connect(socket, callback)
    local pipe = uv.new_pipe(false)
    local client = { pending = {}, closed = false }
    local buffer = ""
    function client.close(reason)
        if client.closed then return end
        client.closed = true
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
    function client.request(action, review_id, payload, done, workspace)
        if client.closed then
            done(nil, "Pi connection is closed")
            return
        end
        local id = M.id()
        local timer = uv.new_timer()
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
    end
    pipe:connect(socket, function(err)
        if err then
            client.close()
            vim.schedule(function() callback(nil, "Cannot connect to Pi: " .. err) end)
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
                local ok, response = pcall(vim.json.decode, line)
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
        end)
        vim.schedule(function() callback(client) end)
    end)
    return client
end

---Discover only live reviews in the canonical workspace. Stale sockets are never deleted by Neovim.
function M.discover(cwd, callback)
    local root, err = M.workspace(cwd)
    if not root then
        callback(nil, err)
        return
    end
    local directory = vim.fs.joinpath(M.state_directory(), "endpoints")
    local scan, scan_err, code = uv.fs_scandir(directory)
    if not scan then
        callback(nil, code == "ENOENT" and "Run /review in Pi first" or scan_err)
        return
    end
    local endpoints = {}
    while true do
        local name = uv.fs_scandir_next(scan)
        if not name then break end
        if name:match("%.json$") then
            local ok, descriptor = pcall(
                function()
                    return vim.json.decode(
                        table.concat(vim.fn.readfile(vim.fs.joinpath(directory, name)), "\n")
                    )
                end
            )
            if not ok then
                callback(nil, "Invalid Pi discovery record: " .. name)
                return
            end
            if descriptor.workspace == root and descriptor.version == 1 and descriptor.socket then
                endpoints[#endpoints + 1] = descriptor
            end
        end
    end
    if #endpoints == 0 then
        callback(nil, "Run /review in Pi for this workspace first")
        return
    end
    local reviews, errors, remaining = {}, {}, #endpoints
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
                            item.endpoint = endpoint
                            reviews[#reviews + 1] = item
                        end
                    end
                end
                finish()
            end, root)
        end)
    end
end

return M
