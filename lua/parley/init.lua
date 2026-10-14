---Public workspace actions. Requiring Parley acquires no resources.
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

function M.stop() workspace.stop() end

---Cached presentation only; no discovery, capture or activation.
---@return string Empty while inactive.
function M.status() return workspace.status end

---Borrow the active source window identity; navigation may replace it.
---@return integer? Absent without a valid source window.
function M.active_window() return workspace.active_window() end

return M
