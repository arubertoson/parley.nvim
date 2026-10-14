-- Extracted from arubertoson/nvim: lua/aru/workspace/review_style.lua.
---Shared presentation for review signs, comparisons and notes.
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
    -- Independent, theme-aware defaults; no other sign plugin needs to be loaded.
    for _, sign in ipairs({ { "Add", "Added" }, { "Change", "Changed" }, { "Delete", "Removed" } }) do
        api.nvim_set_hl(0, "ParleyReviewSign" .. sign[1], { default = true, link = sign[2] })
    end
    api.nvim_set_hl(0, "ParleyReviewSignOutside", { default = true, link = "Comment" })
    for _, side in ipairs({ { "Add", "Added" }, { "Delete", "Removed" } }) do
        local diff = api.nvim_get_hl(0, { name = "Diff" .. side[1], link = false })
        local sign = api.nvim_get_hl(0, { name = "ParleyReviewSign" .. side[1], link = false })
        api.nvim_set_hl(0, "ParleyReviewDiff" .. side[1], {
            fg = sign.fg or diff.fg or normal.fg,
            bg = diff.bg,
        })
    end
    api.nvim_set_hl(0, "ParleyReviewDiffHeader", { fg = comment.fg })
    local background = blend(normal.bg, normal.fg, 0.025)
    local foreground = blend(hint.fg or comment.fg, background, 0.12)
    api.nvim_set_hl(0, "ParleyReviewNote", { fg = foreground, bg = background, italic = true })
    local agent_background = blend(normal.bg, normal.fg, 0.045)
    local agent_foreground = blend(foreground, normal.fg, 0.12)
    local human_color = api.nvim_get_hl(0, { name = "DiagnosticHint", link = false })
    local agent_color = api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })
    api.nvim_set_hl(0, "ParleyReviewHumanMarker", {
        fg = human_color.fg or normal.fg,
        bg = background,
    })
    api.nvim_set_hl(0, "ParleyReviewAgentMarker", {
        fg = agent_color.fg or agent_foreground,
        bg = agent_background,
    })
    api.nvim_set_hl(0, "ParleyReviewAgent", {
        fg = agent_foreground,
        bg = agent_background,
        italic = true,
    })
    api.nvim_set_hl(0, "ParleyReviewAgentHeading", {
        fg = blend(agent_foreground, agent_background, 0.4),
        bg = agent_background,
        italic = true,
    })
    -- A recorded decision is neither a human/agent message nor a green "fixed" status.
    local violet = 0x9B8BAF
    local conclusion_background = blend(normal.bg, violet, 0.045)
    api.nvim_set_hl(0, "ParleyReviewConclusion", {
        fg = foreground or normal.fg,
        bg = conclusion_background,
    })
    api.nvim_set_hl(0, "ParleyReviewConclusionHeading", {
        fg = blend(violet, normal.fg, 0.2),
        bg = conclusion_background,
    })
    api.nvim_set_hl(0, "ParleyReviewConclusionMarker", {
        fg = violet,
        bg = conclusion_background,
    })
    local error_color = api.nvim_get_hl(0, { name = "DiagnosticError", link = false })
    local selected_background = blend(normal.bg, agent_color.fg or normal.fg, 0.12)
    api.nvim_set_hl(0, "ParleyReviewMessageSelected", {
        fg = normal.fg or agent_foreground,
        bg = selected_background,
    })
    api.nvim_set_hl(0, "ParleyReviewMessageSelectedHeading", {
        fg = agent_color.fg or normal.fg,
        bg = selected_background,
        bold = true,
    })
    api.nvim_set_hl(0, "ParleyReviewMessageSelectedMarker", {
        fg = agent_color.fg or normal.fg,
        bg = selected_background,
        bold = true,
    })
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

---Bound text separately from the card's three-column horizontal padding.
---@return integer indent, integer width, integer padding
function M.layout(win, first)
    local available = api.nvim_win_get_width(win)
    local padding = math.min(3, math.floor((available - 1) / 2))
    local indent = math.min(available - padding - 1, math.max(padding, M.indent(win, first)))
    return indent, math.min(100, available - indent - padding), padding
end

---Shared card chrome; chunks contain only text, never padding or identity state.
---@param agent boolean? nil for a neutral thread/status notice.
---@param selected boolean? Contextual message highlight, independent of composer focus.
---@param conclusion boolean? Separate decision-card chrome, independent of authorship.
---@return ParleyReviewVirtualLine
function M.card_line(indent, width, padding, chunks, agent, selected, conclusion)
    local body = conclusion and "ParleyReviewConclusion"
        or selected and "ParleyReviewMessageSelected"
        or (agent and "ParleyReviewAgent" or "ParleyReviewNote")
    local marker = conclusion and "ParleyReviewConclusionMarker"
        or selected and "ParleyReviewMessageSelectedMarker"
        or (agent and "ParleyReviewAgentMarker" or "ParleyReviewHumanMarker")
    local line = { { string.rep(" ", indent - padding), "Normal" } }
    if padding > 0 then
        line[#line + 1] = agent == nil and not conclusion and { string.rep(" ", padding), body }
            or { "▎" .. string.rep(" ", padding - 1), marker }
    end
    local used = 0
    for _, chunk in ipairs(chunks) do
        line[#line + 1] = chunk
        used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    line[#line + 1] = { string.rep(" ", math.max(0, width + padding - used)), body }
    return line
end

---Wrap at whitespace; only a token wider than the panel needs a UTF-8-safe split.
function M.wrap(text, width)
    text = text:gsub("\t", "    ")
    local lines, line = {}, ""
    local function oversized(value)
        for i = 0, vim.fn.strchars(value) - 1 do
            local char = vim.fn.strcharpart(value, i, 1)
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
    if #lines == 0 and line == "" then oversized(text) end
    lines[#lines + 1] = line
    return lines
end

return M
