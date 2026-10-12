-- Extracted from arubertoson/nvim: lua/aru/workspace/review_inline.lua.
---Muted, indented notes in display space; no source text or extra windows.
local M = {}
local api = vim.api
local style = require("parley.style")
local ns = api.nvim_create_namespace("parley.notes")
M.namespace = ns

---@class ParleyReviewInline
---@field win integer
---@field buf integer?
---@field reservation ParleyReviewInlineReservation? Composer room replaces the inactive note in the same extmark.
---@field marks table<integer, integer>
---@field rows ParleyReviewInlineRow[]

---@class ParleyReviewInlineRow
---@field row integer One-based source row after which display space is reserved.
---@field lines ParleyReviewVirtualLine[]

---@class ParleyReviewInlineReservation: ParleyReviewInlineRow
---@field buf integer Source buffer owning the shared room.

---@param win integer
---@return ParleyReviewInline
function M.open(win)
    assert(api.nvim__ns_set, "Inline review requires Neovim's experimental nvim__ns_set API")
    api.nvim__ns_set(ns, { wins = { win } })
    style.refresh()
    return { win = win, rows = {}, marks = {} }
end

function M.clear(inline)
    if inline.buf and api.nvim_buf_is_valid(inline.buf) then
        api.nvim_buf_clear_namespace(inline.buf, ns, 0, -1)
    end
    inline.buf, inline.rows, inline.marks = nil, {}, {}
end

local function note_area(item, width, indent, selected, deleting)
    local content_width = width - indent
    local scope = style.label(item.note.target)
    if item.state ~= "saved" then scope = scope .. " · " .. item.state end
    if selected then scope = scope .. " · selected" end
    local delete_label = "Delete note?"
    if deleting then scope = delete_label .. " Enter confirm · Esc/Ctrl+C cancel" end
    local lines = {}
    local function row(text, highlight, prefix_bytes)
        local padding = string.rep(" ", math.max(0, content_width - vim.fn.strdisplaywidth(text)))
        local chunks = { { string.rep(" ", indent), "ParleyReviewNote" } }
        if prefix_bytes and prefix_bytes > 0 then
            chunks[#chunks + 1] = { text:sub(1, prefix_bytes), "ParleyReviewNoteDelete" }
            text = text:sub(prefix_bytes + 1)
        end
        chunks[#chunks + 1] = { text .. padding, highlight }
        lines[#lines + 1] = chunks
    end
    row("", "ParleyReviewNote")
    local remaining = deleting and #delete_label or 0
    for _, line in ipairs(style.wrap(scope, content_width)) do
        local prefix_bytes = math.min(remaining, #line)
        row(line, "ParleyReviewNoteHeading", prefix_bytes)
        remaining = remaining - prefix_bytes
    end
    for _, text in ipairs(item.note.lines) do
        for _, line in ipairs(style.wrap(text, content_width)) do
            row(line, "ParleyReviewNote")
        end
    end
    local note = item.note.comment or item.note
    if note.reply_to then row("reply to " .. note.reply_to, "ParleyReviewNoteHeading") end
    for _, reply in ipairs(note.replies or {}) do
        row("agent · " .. reply.id, "ParleyReviewNoteHeading")
        for _, text in ipairs(vim.split(reply.text, "\n", { plain = true })) do
            for _, line in ipairs(style.wrap(text, content_width)) do
                row(line, "ParleyReviewNote")
            end
        end
    end
    lines[#lines + 1] = { { string.rep(" ", width), "ParleyReviewNote" } }
    return lines
end

---@param inline ParleyReviewInline
---@param buf integer
---@param items ParleyReviewComposer.Item[] Only notes whose original source still matches.
---@param selected integer? Exact note identity, including overlapping targets.
---@param deleting integer? Pending confirmation replaces only this note's metadata.
function M.update(inline, buf, items, selected, deleting)
    local width = api.nvim_win_get_width(inline.win)
    local by_row = {}
    for _, item in ipairs(items) do
        local row = item.note.target.last
        if not inline.reservation or row ~= inline.reservation.row then
            local lines = by_row[row] or {}
            local indent = style.indent(inline.win, item.note.target.first)
            local id = (item.note.comment or item.note).id
            for _, line in ipairs(note_area(item, width, indent, id == selected, id == deleting)) do
                lines[#lines + 1] = line
            end
            by_row[row] = lines
        end
    end
    if inline.reservation and inline.reservation.buf == buf then
        by_row[inline.reservation.row] = inline.reservation.lines
    end
    local rows = {}
    for row, lines in pairs(by_row) do
        rows[#rows + 1] = { row = row, lines = lines }
    end
    table.sort(rows, function(a, b) return a.row < b.row end)
    if inline.buf == buf and vim.deep_equal(inline.rows, rows) then return end
    if inline.buf ~= buf then M.clear(inline) end
    inline.buf, inline.rows = buf, rows
    local marks = {}
    for _, row in ipairs(rows) do
        -- Swap inactive text and editing room in place, never through zero height.
        marks[row.row] = api.nvim_buf_set_extmark(buf, ns, row.row - 1, 0, {
            id = inline.marks[row.row],
            virt_lines = row.lines,
            virt_lines_leftcol = true,
            priority = 100,
        })
    end
    for row, mark in pairs(inline.marks) do
        if not marks[row] then api.nvim_buf_del_extmark(buf, ns, mark) end
    end
    inline.marks = marks
end

return M
