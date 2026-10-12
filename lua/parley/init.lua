---Parley's public actions. Requiring this module creates no editor resources.
---The review module owns the active editor session and its frozen navigation state.
---User events: ParleyReviewStarted/Stopped carry { window: integer };
---ParleyReviewChanged carries { status: string }, already cached for rendering.
local M = {}

function M.start() require("parley.connected").start() end

function M.stop()
    local connected = package.loaded["parley.connected"]
    if connected then
        connected.stop()
        return
    end
    local review = package.loaded["parley.review"]
    if review then review.stop() end
end

---@param step integer
function M.move(step) require("parley.review").move(step) end

---@param step integer
function M.move_note(step) require("parley.review").move_note(step) end

---@param scope 'line'|'range'|'hunk'
function M.comment(scope) require("parley.review").comment(scope) end

function M.edit_note() require("parley.review").edit_note() end
function M.peek() require("parley.review").peek() end
function M.full_diff() require("parley.review").full_diff() end
function M.delete_note() require("parley.review").delete_note() end
function M.help() require("parley.review").help() end

function M.submit() require("parley.connected").submit() end
function M.save() require("parley.connected").save() end
function M.close() require("parley.connected").close() end
function M.reply() require("parley.review").reply() end

---Return cached progress only; never load review, scan files or create resources.
---@return string Empty while review is inactive.
function M.status()
    local review = package.loaded["parley.review"]
    if not review then return "" end
    return review.status
end

---Borrow the active source window identity, valid only until review stops.
---@return integer? Absent while review is inactive.
function M.active_window()
    local review = package.loaded["parley.review"]
    if not review then return nil end
    return review.active_window()
end

return M
