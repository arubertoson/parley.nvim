---Public workspace actions. Requiring Parley acquires no resources.
---ParleyReviewStarted/Stopped carry { window: integer? }; ParleyReviewChanged
---carries { status: string }. Configuration owns layout and statusline rendering.
local config = require("parley.config")
local workspace = require("parley.workspace")
local M = {}

---Optional; defaults work without setup. Configure before entering review mode.
---Each call replaces prior options; omitted actions use their default keys.
---@param options? ParleyConfig.Options
function M.setup(options)
    if workspace.is_active() then
        error("Parley: stop review mode before changing configuration", 2)
    end
    config.configure(options)
end

function M.start()
    require("parley.bridge").activate()
end

function M.start_implementation()
    require("parley.bridge").activate("parley")
end

function M.turn()
    require("parley.interaction").submit("ask", nil, "parley")
end

function M.finish_implementation()
    require("parley.interaction").done(nil, "parley")
end

function M.resolve_note(resolved)
    workspace.resolve_note(resolved)
end

function M.stop()
    require("parley.bridge").stop()
end

function M.done(review_id)
    require("parley.interaction").done(review_id)
end

function M.ask()
    require("parley.interaction").submit("ask")
end

---@param instructions string
function M.investigate(instructions)
    require("parley.interaction").submit("investigate", instructions)
end

---Cached transport/acceptance state and host-reported acknowledged-request activity.
---User ParleyRequestChanged carries a copy for statuslines/widgets; reads perform no I/O.
---@return ParleyInteraction.Status
function M.request_status()
    return require("parley.interaction").status()
end

---@param scope? 'line'|'range'
function M.comment(scope)
    workspace.comment(scope or "line")
end

function M.edit_note()
    workspace.edit_note()
end

---@param step integer
function M.move_note(step)
    workspace.move_note(step)
end

---Cached presentation only; no discovery, capture or activation.
---@return string Empty while inactive.
function M.status()
    return workspace.status
end

---Borrow the active source window identity; navigation may replace it.
---@return integer? Absent without a valid source window.
function M.active_window()
    return workspace.active_window()
end

return M
