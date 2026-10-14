---Editor-owned workspace review mode. Activation changes only local mode/status.
---No frozen record, capture, renderer, model runner or secondary connection is needed.
---The attachment survives navigation, window closure and bridge disconnects. Stop
---removes mode hooks only; it never touches buffers, undo, composer or saved drafts.
local M = {}
local api = vim.api

---@class ParleyWorkspace.Binding
---@field workspace string Canonical workspace root.
---@field sessionId string Pi conversation identity; runtime reloads may reconnect.

---@class ParleyWorkspace.Active: ParleyWorkspace.Binding
---@field group integer Workspace-owned lifecycle hooks.
---@field window? integer Most recently visited ordinary workspace source window.

---@type ParleyWorkspace.Active?
local active
M.status = ""

local function source_window(root, win)
    win = win or api.nvim_get_current_win()
    if not api.nvim_win_is_valid(win) then return end
    local buf = api.nvim_win_get_buf(win)
    if api.nvim_win_get_config(win).relative ~= "" or vim.bo[buf].buftype ~= "" then return end
    if vim.b[buf].parley_snapshot then return end
    local name = vim.fs.normalize(api.nvim_buf_get_name(buf))
    local prefix = root .. "/"
    if name:sub(1, #prefix) ~= prefix then return end
    local path = name:sub(#prefix + 1)
    if path == "" or path:match("^%.git/") or path:match("^%.jj/") then return end
    return win
end

local function changed()
    api.nvim_exec_autocmds("User", {
        pattern = "ParleyReviewChanged",
        data = { status = M.status },
    })
end

---Borrow the current attachment's source window, if it is still valid.
function M.active_window()
    local win = active and active.window
    if active and win then return source_window(active.workspace, win) end
end

function M.is_active() return active ~= nil end

---The caller verifies the bridge identity before dispatch. Copy only workspace
---and conversation identity; a new runtime in the same session is not migration.
---@param binding ParleyWorkspace.Binding
---@return boolean activated
---@return string? err
function M.activate(binding)
    if active then
        if active.workspace == binding.workspace and active.sessionId == binding.sessionId then
            return true
        end
        return false,
            "Another workspace/Pi session is active; stop it explicitly before activating"
    end
    local review, composer = package.loaded["parley.review"], package.loaded["parley.composer"]
    local connected = package.loaded["parley.connected"]
    if
        (review and review.is_active())
        or (composer and composer.is_open())
        or (connected and connected.is_busy())
    then
        return false, "An existing review or composer is active; no conversation or draft replaced"
    end
    local win = source_window(binding.workspace)
    if vim.fn.mode() ~= "n" or not win then
        return false,
            "Neovim is busy; activation requires an ordinary workspace source window in normal mode"
    end
    local group = api.nvim_create_augroup("ParleyWorkspace", { clear = true })
    active = {
        workspace = binding.workspace,
        sessionId = binding.sessionId,
        group = group,
        window = win,
    }
    api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        group = group,
        callback = function()
            if not active then return end
            local source = source_window(active.workspace)
            if source then active.window = source end
        end,
    })
    M.status = "Workspace review"
    changed()
    api.nvim_exec_autocmds("User", { pattern = "ParleyReviewStarted", data = { window = win } })
    return true
end

---Idempotent detach; bridge binding and all local draft/undo contents are untouched.
function M.stop()
    if not active then return end
    local previous = active
    active = nil
    api.nvim_del_augroup_by_id(previous.group)
    M.status = ""
    changed()
    api.nvim_exec_autocmds(
        "User",
        { pattern = "ParleyReviewStopped", data = { window = previous.window } }
    )
end

return M
