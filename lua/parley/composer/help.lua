-- Recovered from legacy/lua/parley/help.lua; presentation only.
-- Extracted from arubertoson/nvim: lua/aru/interface/mode_help.lua.
---Transient, non-focusing mode hotkeys. Neovim owns preview-buffer/event cleanup.
---One help popup at a time; callers close it when their mode ends.
local M = {}
local api = vim.api
---@type integer? Last preview handle; Neovim may close it on interaction.
local win

---@class ParleyHotkey
---@field mode string n, i, or x; displayed beside each binding.
---@field key string Neovim key notation, including <leader> when appropriate.
---@field description string

function M.close()
    local previous = win
    win = nil
    if previous and api.nvim_win_is_valid(previous) then
        api.nvim_win_close(previous, true)
    end
end

---Borrow the hotkeys for this invocation; never enter the popup or change mode.
---@param title string
---@param bindings ParleyHotkey[]
function M.toggle(title, bindings)
    if win and api.nvim_win_is_valid(win) then
        M.close()
        return
    end
    local rows, grouped = {}, {}
    for _, binding in ipairs(bindings) do
        local key = binding.key:gsub("<leader>", function()
            return vim.g.mapleader or "\\"
        end)
        local identity = key .. "\0" .. binding.description
        local row = grouped[identity]
        if row then
            row.mode = row.mode .. "/" .. binding.mode
        else
            row = { mode = binding.mode, key = key, description = binding.description }
            grouped[identity] = row
            rows[#rows + 1] = row
        end
    end
    local lines = { "n normal · i insert · x selection" }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = ("%-3s %-12s %s"):format(row.mode, row.key, row.description)
    end
    lines[#lines + 1] = "Repeat help to hide · move/type to dismiss"
    local width = 0
    for _, line in ipairs(lines) do
        width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    -- A non-focusing popup cannot scroll. Show the complete list in messages
    -- instead of silently clipping hotkeys in a cramped terminal.
    if width > vim.o.columns - 4 or #lines > vim.o.lines - 4 then
        vim.notify(title .. "\n" .. table.concat(lines, "\n"))
        return
    end
    local _, preview = vim.lsp.util.open_floating_preview(lines, "", {
        focus = false,
        focusable = false,
        -- Composer windows can be one row tall; do not size against their cursor.
        relative = "editor",
        offset_x = math.floor((vim.o.columns - width - 2) / 2),
        offset_y = math.floor((vim.o.lines - #lines - 2) / 2) - 1,
        border = "rounded",
        title = " " .. title .. " ",
        width = width,
        height = #lines,
        wrap = false,
        zindex = 80,
        close_events = {
            "CursorMoved",
            "CursorMovedI",
            "InsertCharPre",
            "ModeChanged",
            "WinLeave",
            "VimResized",
        },
    })
    win = preview
end

return M
