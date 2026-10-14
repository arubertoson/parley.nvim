---Passive diagnostics for :checkhealth parley. Requiring this module acquires nothing.
---Checks read filesystem advertisements and cached bridge state, never connect or rebind.
local M = {}

---@return boolean Whether discovery can run on this host.
local function check_runtime()
    local health = vim.health
    local available = true
    if vim.fn.has("win32") == 1 then
        health.error("Parley requires a Unix-socket host")
        available = false
    end
    local uv = vim.uv
    if
        not (
            uv
            and uv.new_pipe
            and uv.new_timer
            and uv.fs_stat
            and uv.fs_realpath
            and uv.fs_lstat
            and uv.fs_scandir
            and uv.fs_scandir_next
        )
    then
        health.error("Bridge requires vim.uv pipe, timer and filesystem APIs", {
            "Use a Neovim build with these APIs; checkhealth does not provide compatibility shims.",
        })
        available = false
    end
    if
        not (
            vim.fs
            and vim.fs.joinpath
            and vim.fs.dirname
            and vim.json
            and vim.json.encode
            and vim.json.decode
        )
    then
        health.error("Bridge requires vim.fs path helpers and vim.json")
        available = false
    end
    if not vim.api.nvim__ns_set then
        health.error("Composer requires Neovim's experimental nvim__ns_set API", {
            "Use a Neovim build that provides window-scoped namespaces.",
        })
    else
        health.ok("Window-scoped namespaces are available")
    end
    if available then health.ok("Unix-socket bridge APIs are available") end
    return available
end

---@param snapshot ParleyBridge.Status?
local function report_bridge(snapshot)
    if not snapshot then
        vim.health.warn("Passive bridge has not been loaded", {
            "Ensure Parley's plugin entry point is enabled. Health reporting does not activate it.",
        })
        return
    end
    vim.health.info("Editor identity: " .. snapshot.editor_id)
    vim.health.info("Cached bridge state: " .. snapshot.state)
    if not snapshot.running then
        vim.health.warn("Passive bridge is not running", {
            "Check plugin loading or restart Neovim after updating Parley.",
        })
    elseif snapshot.error then
        vim.health.warn(snapshot.error)
    elseif not snapshot.connected then
        vim.health.warn(
            "Bridge is not attached; existing background discovery may still be pending"
        )
    end
    if snapshot.binding then
        vim.health.info("Bound runtime: " .. snapshot.binding.instanceId)
        vim.health.info("Bound Pi session: " .. snapshot.binding.sessionId)
    end
end

---@param endpoint ParleyClient.Endpoint Discovery checked protocol, workspace and socket path.
---@param snapshot ParleyBridge.Status?
local function report_endpoint(endpoint, snapshot)
    local health = vim.health
    health.info("Advertised workspace: " .. endpoint.workspace)
    health.info("Advertised protocol: " .. endpoint.version)
    health.info("Advertised socket: " .. endpoint.socket)

    local instance_id, session_id = endpoint.instanceId, endpoint.sessionId
    if type(instance_id) ~= "string" or type(session_id) ~= "string" or session_id == "" then
        health.error("Pi advertisement has no usable runtime/session identity", {
            "Reload Parley in the existing interactive Pi runtime for this workspace.",
        })
        return
    end
    health.info("Advertised runtime: " .. instance_id)
    health.info("Advertised Pi session: " .. session_id)

    local binding = snapshot and snapshot.binding
    local matches_binding = false
    if binding then
        if binding.sessionId ~= session_id then
            health.warn("Advertised Pi session differs from the retained binding", {
                ":ParleyBind explicitly binds the advertised session; health never rebinds it.",
            })
        elseif binding.instanceId ~= instance_id or binding.socket ~= endpoint.socket then
            health.warn("Pi runtime/socket changed within the bound session", {
                "The existing bridge can reconnect to the same session; health does not attempt it.",
            })
        elseif binding.workspace ~= endpoint.workspace then
            health.error("Advertisement differs from the bound workspace; no binding changed")
        else
            matches_binding = true
        end
    else
        health.info("No verified binding yet; an advertisement alone does not verify a connection")
    end

    local socket, err = vim.uv.fs_stat(endpoint.socket)
    if not socket then
        health.warn("Advertised socket is unavailable: " .. tostring(err), {
            "Check the existing Pi runtime and reload Parley there if needed. No stale records were removed.",
        })
    elseif socket.type ~= "socket" then
        health.error("Advertised endpoint is not a Unix socket")
    elseif matches_binding and snapshot and snapshot.running and snapshot.connected then
        health.ok("Advertisement matches the cached verified connection (not live-probed)")
    else
        health.info("Socket exists; reachability and attach identity were not live-probed")
    end
end

function M.check()
    local health = vim.health
    health.start("Parley")
    health.info(
        "Passive report: no socket requests, review activation, session changes or model work"
    )
    if not check_runtime() then return end

    local client = require("parley.client")
    -- Do not load/activate the bridge merely to report its status.
    local bridge = package.loaded["parley.bridge"]
    ---@type ParleyBridge.Status?
    local snapshot = bridge and bridge.status()
    report_bridge(snapshot)

    -- Navigation or a changed cwd must not retarget a retained workspace attachment.
    local workspace = snapshot and snapshot.workspace
    if not workspace then
        local err
        workspace, err = client.workspace(vim.fn.getcwd())
        if not workspace then
            health.warn(err or "No workspace found", {
                "Run health in a jj or Git workspace. :ParleyBind is the explicit binding action.",
            })
            return
        end
    end
    health.info("Diagnostic workspace: " .. workspace)
    health.info("Discovery directory: " .. vim.fs.joinpath(client.state_directory(), "endpoints"))

    -- Endpoint discovery is a synchronous read with a callback, not a connection attempt.
    client.endpoints(workspace, function(endpoints, err)
        if not endpoints then
            health.warn(err or "No Pi advertisement found", {
                "Check that Parley is loaded in the existing interactive Pi runtime for this workspace.",
            })
        elseif #endpoints ~= 1 then
            health.error("Multiple Pi workspace owners are advertised; no endpoint selected")
        else
            report_endpoint(endpoints[1], snapshot)
        end
    end)
end

return M
