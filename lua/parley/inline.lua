-- Adapted from legacy/lua/parley/inline.lua and its shared card presentation.
-- Original provenance: arubertoson/nvim, lua/aru/workspace/review_inline.lua.
---Window-local human-note cards. The workspace supplies validated placements;
---this module owns display marks only, never source anchors, drafts or history.
local style = require("parley.composer.style")
local M = {}
local api = vim.api

---@class ParleyInline.Item
---@field note ParleyComposer.Draft Borrowed editor-owned text.
---@field first integer Validated live source range.
---@field last integer

---@class ParleyInline.Reservation
---@field id integer Note whose card is replaced by editor room.
---@field row integer
---@field lines ParleyNoteLine[]
---@field offset integer Display rows preceding the editor room.

---@class ParleyInline.Row
---@field row integer One-based source boundary.
---@field lines ParleyNoteLine[]
---@field focus_first? integer One-based display row of the selected card.
---@field focus_count? integer

---@class ParleyInline.View
---@field window integer
---@field namespace integer Scoped to this window only.
---@field buffer? integer
---@field items ParleyInline.Item[] Borrowed until the next update.
---@field selected? integer
---@field reservation? ParleyInline.Reservation
---@field rows ParleyInline.Row[]
---@field marks table<integer, integer>

---@return ParleyInline.View
function M.open(window)
    local namespace = api.nvim_create_namespace("parley.notes.window." .. window)
    api.nvim__ns_set(namespace, { wins = { window } })
    return { window = window, namespace = namespace, items = {}, rows = {}, marks = {} }
end

---@param view ParleyInline.View
function M.clear(view)
    if view.buffer and api.nvim_buf_is_loaded(view.buffer) then
        api.nvim_buf_clear_namespace(view.buffer, view.namespace, 0, -1)
    end
    view.buffer = nil
    view.reservation = nil
    view.items, view.rows, view.marks = {}, {}, {}
end

local function card(view, item, budget)
    local indent, width, padding = style.layout(view.window)
    local selected = item.note.id == view.selected
    local text = api.nvim_buf_get_lines(item.note.buffer, 0, -1, false)
    local state = "draft"
    if item.note.saved_lines then
        state = vim.deep_equal(text, item.note.saved_lines) and "saved" or "unsaved edits"
    end

    local heading = style.heading(item.note, state, item.first, item.last, width)
    local lines = {
        style.card_line(indent, width, padding, {}, selected),
        style.card_line(indent, width, padding, {
            { heading, "ParleyReviewNoteHeading" },
        }, selected),
    }

    local body = selected and "ParleyReviewNoteActive" or "ParleyReviewNote"
    for _, value in ipairs(text) do
        for _, wrapped in ipairs(style.wrap(value, width)) do
            if #lines >= budget - 1 then
                lines[#lines] =
                    style.card_line(indent, width, padding, { { "…", body } }, selected)
                lines[#lines + 1] = style.card_line(indent, width, padding, {}, selected)
                return lines
            end
            lines[#lines + 1] =
                style.card_line(indent, width, padding, { { wrapped, body } }, selected)
        end
    end
    lines[#lines + 1] = style.card_line(indent, width, padding, {}, selected)
    return lines
end

local function render_row(view, row, items)
    local height = api.nvim_win_get_height(view.window)
        - (vim.wo[view.window].winbar ~= "" and 1 or 0)
    local anchor_height = api.nvim_win_text_height(view.window, {
        start_row = row - 1,
        start_vcol = 0,
        end_row = row - 1,
        max_height = height,
    }).all
    local budget = math.max(3, height - anchor_height - 1)
    local lines = {}
    local focus_first, focus_count
    local reservation = view.reservation

    for _, item in ipairs(items) do
        if #lines > 0 then
            lines[#lines + 1] = { { "", "Normal" } }
        end

        local area
        if reservation and reservation.id == item.note.id then
            area = reservation.lines
            reservation.offset = #lines
        else
            area =
                card(view, item, item.note.id == view.selected and budget or math.min(8, budget))
        end
        if item.note.id == view.selected then
            focus_first, focus_count = #lines + 1, #area
        end
        for _, line in ipairs(area) do
            lines[#lines + 1] = line
        end
    end

    -- Notes sharing a boundary remain separate. Explicit selection must not leave
    -- its card/editor stranded underneath earlier cards, including below EOF.
    if focus_first and focus_count and focus_first + focus_count - 1 > budget then
        local visible = {}
        if focus_first > 1 and focus_count < budget then
            local indent, width, padding = style.layout(view.window)
            visible[1] = style.card_line(indent, width, padding, {
                { "Earlier notes", "ParleyReviewNoteHeading" },
            })
        end
        local offset = #visible
        for index = focus_first, math.min(#lines, focus_first + budget - offset - 1) do
            visible[#visible + 1] = lines[index]
        end
        lines = visible
        focus_first = offset + 1
        if reservation and reservation.row == row then
            reservation.offset = offset
        end
    end

    return { row = row, lines = lines, focus_first = focus_first, focus_count = focus_count }
end

---Replace cards/room in place; do not clear through zero height or scroll the view.
---@param view ParleyInline.View
---@param buffer integer
---@param items ParleyInline.Item[] Only unchanged, currently placed notes.
---@param selected? integer
function M.update(view, buffer, items, selected)
    if view.buffer ~= buffer then
        M.clear(view)
    end
    view.buffer, view.items, view.selected = buffer, items, selected

    local grouped = {}
    if api.nvim_win_get_width(view.window) >= 24 and api.nvim_win_get_height(view.window) >= 8 then
        for _, item in ipairs(items) do
            if
                api.nvim_buf_is_loaded(item.note.buffer)
                and item.last <= api.nvim_buf_line_count(buffer)
            then
                grouped[item.last] = grouped[item.last] or {}
                table.insert(grouped[item.last], item)
            end
        end
    end

    local rows = {}
    for row, notes in pairs(grouped) do
        rows[#rows + 1] = render_row(view, row, notes)
    end
    table.sort(rows, function(left, right)
        return left.row < right.row
    end)
    if vim.deep_equal(view.rows, rows) then
        return
    end

    local previous = {}
    for _, row in ipairs(view.rows) do
        previous[row.row] = row
    end
    local marks = {}
    for _, row in ipairs(rows) do
        if vim.deep_equal(previous[row.row], row) then
            marks[row.row] = view.marks[row.row]
        else
            marks[row.row] = api.nvim_buf_set_extmark(buffer, view.namespace, row.row - 1, 0, {
                id = view.marks[row.row],
                virt_lines = row.lines,
                virt_lines_leftcol = true,
                priority = 100,
            })
        end
    end
    for row, mark in pairs(view.marks) do
        if not marks[row] then
            api.nvim_buf_del_extmark(buffer, view.namespace, mark)
        end
    end
    view.rows, view.marks = rows, marks
end

---Borrow editor room until release. Return the rows preceding that room.
---@param view ParleyInline.View
---@param id integer
---@param row integer
---@param lines ParleyNoteLine[]
---@return integer
function M.reserve(view, id, row, lines)
    view.reservation = { id = id, row = row, lines = lines, offset = 0 }
    M.update(view, assert(view.buffer), view.items, view.selected)
    return view.reservation.offset
end

---The workspace must validate placements and update after releasing a room.
function M.release(view)
    view.reservation = nil
end

---Explicit navigation only. Background rendering never moves the source view.
function M.reveal(view)
    for _, row in ipairs(view.rows) do
        if row.focus_first and row.focus_count then
            api.nvim_win_call(view.window, function()
                api.nvim_win_set_cursor(view.window, { row.row, 0 })
                vim.cmd("normal! zv")
                local position = vim.fn.winsaveview()
                local height = api.nvim_win_get_height(view.window)
                    - (vim.wo[view.window].winbar ~= "" and 1 or 0)
                local preceding = height + 1
                if position.topline <= row.row then
                    preceding = api.nvim_win_text_height(view.window, {
                        start_row = position.topline - 1,
                        start_vcol = position.skipcol,
                        end_row = row.row - 1,
                        max_height = height + 1,
                    }).all + position.topfill
                end
                if preceding + row.focus_first - 1 + row.focus_count > height then
                    vim.cmd("normal! zt")
                end
            end)
            return
        end
    end
end

return M
