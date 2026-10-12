-- Extracted from arubertoson/nvim: lua/aru/workspace/review_style.lua.
---Shared presentation for active and inactive review notes.
local M = {}
local api = vim.api

---Themes may omit GUI colors, especially with transparent backgrounds.
local function blend(base, tint, amount)
    if not base or not tint then return base end
    local color = 0
    for _, shift in ipairs({ 16, 8, 0 }) do
        local a = math.floor(base / 2 ^ shift) % 256
        local b = math.floor(tint / 2 ^ shift) % 256
        color = color + math.floor(a + (b - a) * amount + 0.5) * 2 ^ shift
    end
    return color
end

function M.refresh()
    local normal = api.nvim_get_hl(0, { name = "Normal", link = false })
    local comment = api.nvim_get_hl(0, { name = "Comment", link = false })
    local hint = api.nvim_get_hl(0, { name = "LspInlayHint", link = false })
    -- Match VCSigns' diff backgrounds and gutter colors when available; otherwise
    -- use Neovim's theme-defined diff and added/removed colors.
    for _, side in ipairs({ { "Add", "Added" }, { "Delete", "Removed" } }) do
        local diff_name = vim.fn.hlexists("VcsignsDiff" .. side[1]) == 1
                and "VcsignsDiff" .. side[1]
            or "Diff" .. side[1]
        local sign_name = vim.fn.hlexists("Sign" .. side[1]) == 1 and "Sign" .. side[1]
            or vim.fn.hlexists("diff" .. side[2]) == 1 and "diff" .. side[2]
            or side[2]
        local diff = api.nvim_get_hl(0, { name = diff_name, link = false })
        local sign = api.nvim_get_hl(0, { name = sign_name, link = false })
        api.nvim_set_hl(0, "ParleyReviewDiff" .. side[1], {
            fg = sign.fg or diff.fg or normal.fg,
            bg = diff.bg,
        })
    end
    api.nvim_set_hl(0, "ParleyReviewDiffHeader", { fg = comment.fg })
    local background = blend(normal.bg, normal.fg, 0.025)
    local foreground = blend(hint.fg or comment.fg, background, 0.12)
    api.nvim_set_hl(0, "ParleyReviewNote", { fg = foreground, bg = background, italic = true })
    local error_color = api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
    api.nvim_set_hl(0, "ParleyReviewNoteDelete", {
        fg = error_color.fg,
        bg = background,
        italic = true,
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

api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("ParleyReviewNoteColors", { clear = true }),
    callback = M.refresh,
})

---@param target ParleyReviewComposer.Target
function M.label(target)
    if target.scope == "hunk" then return ("Hunk · %d–%d"):format(target.first, target.last) end
    if target.scope == "range" then return ("Lines %d–%d"):format(target.first, target.last) end
    return ("Line %d"):format(target.first)
end

---Display-column indentation shared by notes and their editor.
function M.indent(win, first)
    return api.nvim_win_call(win, function()
        local textoff = vim.fn.getwininfo(win)[1].textoff
        local indentation = vim.fn.indent(first) + 4 - vim.fn.winsaveview().leftcol
        return math.min(api.nvim_win_get_width(win) - 1, math.max(textoff, textoff + indentation))
    end)
end

---Wrap display text without splitting UTF-8 or wide characters.
function M.wrap(text, width)
    text = text:gsub("\t", "    ")
    local lines, line = {}, ""
    for i = 0, vim.fn.strchars(text) - 1 do
        local char = vim.fn.strcharpart(text, i, 1)
        if line ~= "" and vim.fn.strdisplaywidth(line .. char) > width then
            lines[#lines + 1], line = line, ""
        end
        line = line .. char
    end
    lines[#lines + 1] = line
    return lines
end

return M
