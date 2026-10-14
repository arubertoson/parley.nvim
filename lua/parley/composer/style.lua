-- Adapted from legacy/lua/parley/style.lua, originally extracted from
-- arubertoson/nvim: lua/aru/workspace/review_style.lua.
---Shared human-card presentation. The composer refreshes its own theme; callers
---drawing inactive cards own their theme lifecycle. Requiring installs no hooks.
local M = {}
local api = vim.api

local function blend(base, tint, amount)
    if not base or not tint then
        return base
    end

    local color = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
        local original = math.floor(base / 2 ^ shift) % 256
        local target = math.floor(tint / 2 ^ shift) % 256
        color = color + math.floor(original + (target - original) * amount + 0.5) * 2 ^ shift
    end
    return color
end

function M.refresh()
    local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
    local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
    local hint = api.nvim_get_hl(0, { name = "LspInlayHint", link = false })
    local human = api.nvim_get_hl(0, { name = "DiagnosticHint", link = false })

    local background = blend(normal.bg, normal.fg, 0.025)
    local foreground = blend(hint.fg or comment.fg, background, 0.12)
    api.nvim_set_hl(0, "ParleyReviewNote", {
        fg = foreground,
        bg = background,
        italic = true,
    })
    api.nvim_set_hl(0, "ParleyReviewHumanMarker", {
        fg = human.fg or normal.fg,
        bg = background,
    })
    api.nvim_set_hl(0, "ParleyReviewNoteHeading", {
        fg = blend(foreground, background, 0.55),
        bg = background,
        italic = true,
    })
    api.nvim_set_hl(0, "ParleyReviewNoteActive", {
        fg = blend(foreground, normal.fg, 0.25),
        bg = background,
        italic = true,
    })
end

---Use source indentation without changing source-window options.
---@return integer indent, integer width, integer padding
function M.layout(window, first)
    local available = api.nvim_win_get_width(window)
    local padding = math.min(3, math.floor((available - 1) / 2))
    local indent = api.nvim_win_call(window, function()
        local gutter = vim.fn.getwininfo(window)[1].textoff
        local indentation = vim.fn.indent(first) + 4 - vim.fn.winsaveview().leftcol
        return math.max(gutter, gutter + indentation)
    end)

    indent = math.min(available - padding - 1, math.max(padding, indent))
    return indent, math.min(100, available - indent - padding), padding
end

---@param first integer
---@param last integer
---@return string
function M.label(first, last)
    if first == last then
        return ("Line %d"):format(first)
    end
    return ("Lines %d–%d"):format(first, last)
end

---@alias ParleyNoteLine string[][] Dense { text, highlight } chunks.

---Three-column card padding, human role bar, and full-width background.
---@param chunks string[][] Text only, without padding.
---@param active? boolean
---@return ParleyNoteLine
function M.card_line(indent, width, padding, chunks, active)
    local body = active and "ParleyReviewNoteActive" or "ParleyReviewNote"
    local line = { { string.rep(" ", indent - padding), "Normal" } }
    if padding > 0 then
        line[#line + 1] = { "▎" .. string.rep(" ", padding - 1), "ParleyReviewHumanMarker" }
    end

    local used = 0
    for _, chunk in ipairs(chunks) do
        line[#line + 1] = chunk
        used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    line[#line + 1] = { string.rep(" ", math.max(0, width + padding - used)), body }
    return line
end

---Wrap at whitespace; split only tokens wider than the panel, at UTF-8 boundaries.
---@return string[]
function M.wrap(text, width)
    text = text:gsub("\t", "    ")
    local lines, line = {}, ""
    local function oversized(value)
        for index = 0, vim.fn.strchars(value) - 1 do
            local char = vim.fn.strcharpart(value, index, 1)
            if line ~= "" and vim.fn.strdisplaywidth(line .. char) > width then
                lines[#lines + 1], line = line, ""
            end
            line = line .. char
        end
    end

    for gap, word in text:gmatch("(%s*)(%S+)") do
        if line ~= "" and vim.fn.strdisplaywidth(line .. gap .. word) > width then
            lines[#lines + 1], line, gap = line, "", ""
        end
        local value = gap .. word
        if vim.fn.strdisplaywidth(line .. value) <= width then
            line = line .. value
        else
            if gap ~= "" then
                oversized(gap)
                if line ~= "" then
                    lines[#lines + 1], line = line, ""
                end
            end
            oversized(word)
        end
    end
    if #lines == 0 and line == "" then
        oversized(text)
    end
    lines[#lines + 1] = line
    return lines
end

return M
