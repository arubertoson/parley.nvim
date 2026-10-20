-- Adapted from legacy/lua/parley/style.lua, originally extracted from
-- arubertoson/nvim: lua/aru/workspace/review_style.lua.
---Shared card presentation. The composer refreshes its own theme; callers
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
    local agent = api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false })

    local background = blend(normal.bg, normal.fg, 0.025)
    local foreground = blend(hint.fg or comment.fg, background, 0.12)
    -- Both roles inherit the original muted note style. Selection alone
    -- brings out the text; authorship is carried by labels and role bars.
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
        fg = blend(foreground, normal.fg, 0.85),
        bg = background,
        italic = true,
    })
    api.nvim_set_hl(0, "ParleyDiscussionAgentMarker", {
        fg = agent.fg or normal.fg,
        bg = background,
    })

    -- Parent headings/markers yield to the selected message; its body stays
    -- muted like any other unselected card.
    api.nvim_set_hl(0, "ParleyDiscussionParentHeading", {
        fg = blend(foreground, background, 0.65),
        bg = background,
        italic = true,
    })
    api.nvim_set_hl(0, "ParleyDiscussionParentHumanMarker", {
        fg = blend(human.fg or normal.fg, foreground, 0.6),
        bg = background,
    })
    api.nvim_set_hl(0, "ParleyDiscussionParentAgentMarker", {
        fg = blend(agent.fg or normal.fg, foreground, 0.6),
        bg = background,
    })

    -- The small help annotation is darker than the prose, with quiet labels
    -- and slightly clearer keys; neither should compete with the editor text.
    local help_background = blend(normal.bg, 0, 0.2)
    api.nvim_set_hl(0, "ParleyComposerHelp", {
        fg = blend(normal.fg, help_background, 0.58),
        bg = help_background,
        italic = false,
    })
    api.nvim_set_hl(0, "ParleyComposerHelpKey", {
        fg = blend(normal.fg, help_background, 0.4),
        bg = help_background,
        bold = false,
        italic = false,
    })
end

---Fixed gutter-aware rail, independent of source indentation/horizontal scroll.
---@return integer indent, integer width, integer padding
function M.layout(window)
    local available = api.nvim_win_get_width(window)
    local padding = math.min(3, math.floor((available - 1) / 2))
    local gutter = vim.fn.getwininfo(window)[1].textoff
    local indent = math.min(available - padding - 1, math.max(padding, gutter + 4))
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

---Three-column card padding, role bar, and full-width background.
---@param chunks string[][] Text only, without padding.
---@param active? boolean
---@param role? 'human'|'agent'
---@return ParleyNoteLine
function M.card_line(indent, width, padding, chunks, active, role)
    local body = active and "ParleyReviewNoteActive" or "ParleyReviewNote"
    local marker = role == "agent" and "ParleyDiscussionAgentMarker" or "ParleyReviewHumanMarker"
    local line = { { string.rep(" ", indent - padding), "Normal" } }
    if padding > 0 then
        line[#line + 1] = { "▎" .. string.rep(" ", padding - 1), marker }
    end

    local used = 0
    for _, chunk in ipairs(chunks) do
        line[#line + 1] = chunk
        used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    line[#line + 1] = { string.rep(" ", math.max(0, width + padding - used)), body }
    return line
end

---Keep the composer's lower edge behind a compact annotation, without a role bar.
---@param chunks ParleyNoteLine Already fitted to the editor width.
---@return ParleyNoteLine
function M.footer_line(indent, width, padding, chunks)
    local line = {
        { string.rep(" ", indent - padding), "Normal" },
        { string.rep(" ", padding), "ParleyReviewNoteActive" },
    }
    local used = 0
    for _, chunk in ipairs(chunks) do
        line[#line + 1] = chunk
        used = used + vim.fn.strdisplaywidth(chunk[1])
    end
    line[#line + 1] = {
        string.rep(" ", math.max(0, width + padding - used)),
        "ParleyReviewNoteActive",
    }
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

---One-row card heading: role/state left, creation date/source range right.
---Unknown dates stay absent. Metadata yields space before the role/state does.
---@param note { created_at?: integer }
---@param state string
---@param first integer
---@param last integer
---@param width integer
---@param role_label? string Defaults to You.
---@return string
function M.heading(note, state, first, last, width, role_label)
    local left = (role_label or "You") .. " · " .. state
    local left_width = vim.fn.strdisplaywidth(left)
    if left_width > width then
        return M.wrap(left, width)[1]
    end

    local right = M.label(first, last)
    if note.created_at then
        for _, format in ipairs({ "%Y-%m-%d %H:%M", "%Y-%m-%d" }) do
            -- An otherwise valid timestamp can exceed this host's date range.
            -- Optional display metadata must not make a discussion unopenable.
            local valid, date = pcall(os.date, format, note.created_at)
            if valid then
                local dated = date .. " · " .. right
                if left_width + 1 + vim.fn.strdisplaywidth(dated) <= width then
                    right = dated
                    break
                end
            end
        end
    end
    if left_width + 1 + vim.fn.strdisplaywidth(right) > width then
        right = first == last and ("L%d"):format(first) or ("L%d–%d"):format(first, last)
    end
    if left_width + 1 + vim.fn.strdisplaywidth(right) > width then
        right = ""
    end
    return left .. string.rep(" ", width - left_width - vim.fn.strdisplaywidth(right)) .. right
end

return M
