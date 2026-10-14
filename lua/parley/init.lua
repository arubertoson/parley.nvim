---Public editor actions. Requiring Parley acquires no resources.
---Workspace activation is independent of the retained frozen-review implementation.
---ParleyReviewStarted/Stopped carry { window: integer? }; ParleyReviewChanged
---carries { status: string }. Configuration owns layout and statusline rendering.
local workspace = require("parley.workspace")
local M = {}

function M.start()
    local activated, err = require("parley.bridge").activate()
    if not activated then
        vim.notify("Parley: " .. (err or "Activation failed"), vim.log.levels.WARN)
    end
end

function M.stop()
    if workspace.is_active() then
        workspace.stop()
        return
    end
    local connected = package.loaded["parley.connected"]
    if connected then
        connected.stop()
        return
    end
    local review = package.loaded["parley.review"]
    if review then review.stop() end
end

-- Retained evidence actions are deliberate opt-ins, never activation dependencies.
-- Until workspace interaction is implemented, do not route its actions into a
-- different conversation or create a legacy composer behind the user's back.
local function legacy_action(module, action, ...)
    if workspace.is_active() then
        vim.notify(
            "Parley workspace mode currently supports activation and stop only",
            vim.log.levels.WARN
        )
        return
    end
    return require(module)[action](...)
end

---@param step integer
function M.move(step) legacy_action("parley.review", "move", step) end
---@param step integer
function M.move_note(step) legacy_action("parley.review", "move_note", step) end
---@param scope 'line'|'range'|'hunk'
function M.comment(scope) legacy_action("parley.review", "comment", scope) end

function M.edit_note() legacy_action("parley.review", "edit_note") end
function M.peek() legacy_action("parley.review", "peek") end
function M.full_diff() legacy_action("parley.review", "full_diff") end
function M.delete_note() legacy_action("parley.review", "delete_note") end
function M.help() legacy_action("parley.review", "help") end
function M.reply() legacy_action("parley.review", "reply") end
function M.conclude() legacy_action("parley.review", "conclude") end
function M.reopen() legacy_action("parley.review", "reopen") end

function M.open_offer() legacy_action("parley.connected", "open_offer") end
function M.dismiss_offer() legacy_action("parley.connected", "dismiss_offer") end
function M.submit() legacy_action("parley.connected", "submit") end
function M.save() legacy_action("parley.connected", "save") end
function M.scope() legacy_action("parley.connected", "scope") end
function M.close() legacy_action("parley.connected", "close") end
function M.collect() legacy_action("parley.connected", "collect") end
function M.finish() legacy_action("parley.connected", "finish") end
function M.conclusions() legacy_action("parley.connected", "conclusions") end

---Cached presentation only; no discovery, capture or activation.
---@return string Empty while inactive.
function M.status()
    if workspace.is_active() then return workspace.status end
    local review = package.loaded["parley.review"]
    return review and review.status or ""
end

---Borrow the active source window identity; navigation may replace it.
---@return integer? Absent without a valid source window.
function M.active_window()
    if workspace.is_active() then return workspace.active_window() end
    local review = package.loaded["parley.review"]
    return review and review.active_window() or nil
end

return M
