---Passive diagnostics for :checkhealth parley. Requiring this module acquires nothing.
---Only host capabilities and cached bridge state; no discovery, probes or binding.
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
        health.ok("Window-scoped composer namespaces are available")
    end
    if available then
        health.ok("Unix-socket bridge APIs are available")
    end
    return available
end

---@param snapshot ParleyBridge.Status?
local function report_bridge(snapshot)
    if not snapshot then
        vim.health.info("No review pairing requested; run /review in Pi, then :ReviewStart here")
        return
    end
    vim.health.info("Editor identity: " .. snapshot.editor_id)
    vim.health.info("Cached bridge state: " .. snapshot.state)
    if not snapshot.running then
        vim.health.info("Background reconnect is disabled until an explicit review start succeeds")
    end
    if snapshot.error then
        vim.health.warn(snapshot.error)
    elseif not snapshot.connected and snapshot.state ~= "idle" then
        vim.health.warn("Review is not connected; run /review in Pi, then :ReviewStart here")
    end
    if snapshot.binding then
        vim.health.info("Bound workspace: " .. snapshot.binding.workspace)
        vim.health.info("Bound runtime: " .. snapshot.binding.instanceId)
        vim.health.info("Bound Pi session: " .. snapshot.binding.sessionId)
        vim.health.info(
            "Bound socket: " .. snapshot.binding.socket .. " (cached; not live-probed)"
        )
    end
end

function M.check()
    local health = vim.health
    health.start("Parley")
    health.info(
        "Passive report: no socket requests, review activation, session changes or model work"
    )
    if not check_runtime() then
        return
    end

    -- Do not load the bridge or read discovery records merely to report status.
    local bridge = package.loaded["parley.bridge"]
    ---@type ParleyBridge.Status?
    local snapshot = bridge and bridge.status()
    report_bridge(snapshot)
end

return M
