-- Extracted from arubertoson/nvim: lua/aru/workspace/review_inline.lua.
---Bounded thread cards in display space; no source text or extra windows.
local M = {}
local api = vim.api
local style = require("parley.style")
local thread = require("parley.thread")
local ns = api.nvim_create_namespace("parley.notes")
M.namespace = ns

---@class ParleyReviewInline
---@field win integer
---@field buf integer?
---@field reservation ParleyReviewInlineReservation? Only the active card is replaced by composer room.
---@field focus integer? Note navigation reveals this exact card at a shared boundary.
---@field message integer|string? Message selected in contextual thread navigation.
---@field message_offset integer? Wrapped display rows skipped in a long selected message.
---@field activity { text: string, notes: table<string, boolean> }? Pending submitted note IDs, never a cursor row.
---@field marks table<integer, integer>
---@field rows ParleyReviewInlineRow[]
---@field cards table<integer|string, table>? Render variants, bounded to currently displayed messages.

---@class ParleyReviewInlineRow
---@field row integer One-based source row after which display space is reserved.
---@field lines ParleyReviewVirtualLine[]
---@field focus { first: integer, count: integer }? Selected card's display-space extent.
---@field activity { index: integer, first: integer, phase: string? }[]? Fixed-height reply/conclusion spinners.

---@class ParleyReviewInlineReservation: ParleyReviewInlineRow
---@field buf integer Source buffer owning the shared room.
---@field id integer Composer identity, including a new reply draft.
---@field offset integer? Display rows preceding the composer room.
---@field thread integer|string? Selected message owning an auxiliary conclusion editor.

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
    inline.buf, inline.rows, inline.marks, inline.focus, inline.cards = nil, {}, {}, nil, nil
end

local function card(heading, text, indent, width, padding, agent, deleting, selected, conclusion)
    local body = conclusion and "ParleyReviewConclusion"
        or selected and "ParleyReviewMessageSelected"
        or (agent and "ParleyReviewAgent" or "ParleyReviewNote")
    local title = conclusion and "ParleyReviewConclusionHeading"
        or selected and "ParleyReviewMessageSelectedHeading"
        or (agent and "ParleyReviewAgentHeading" or "ParleyReviewNoteHeading")
    local lines = {}
    local function row(value, highlight, prefix_bytes)
        local chunks = {}
        if prefix_bytes and prefix_bytes > 0 then
            chunks[#chunks + 1] = { value:sub(1, prefix_bytes), "ParleyReviewNoteDelete" }
            value = value:sub(prefix_bytes + 1)
        end
        chunks[#chunks + 1] = { value, highlight }
        lines[#lines + 1] =
            style.card_line(indent, width, padding, chunks, agent, selected, conclusion)
    end
    row("", body)
    local remaining = deleting and #"Delete note?" or 0
    for _, line in ipairs(style.wrap(heading, width)) do
        local prefix_bytes = math.min(remaining, #line)
        row(line, title, prefix_bytes)
        remaining = remaining - prefix_bytes
    end
    for _, value in ipairs(text) do
        for _, line in ipairs(style.wrap(value, width)) do
            row(line, body)
        end
    end
    row("", body)
    return lines
end

-- Cards are immutable render values. Cache both selection variants so moving
-- through an expanded history does not repeatedly wrap every unchanged message.
local function cached_card(
    cache,
    key,
    heading,
    text,
    indent,
    width,
    padding,
    agent,
    deleting,
    selected,
    conclusion
)
    local variants = cache.previous[key] or {}
    local slot = selected and "selected" or "ordinary"
    local input = { heading, text, indent, width, padding, agent, deleting, selected, conclusion }
    local entry = variants[slot]
    if not entry or not vim.deep_equal(entry.input, input) then
        entry = {
            input = vim.deepcopy(input),
            lines = card(
                heading,
                text,
                indent,
                width,
                padding,
                agent,
                deleting,
                selected,
                conclusion
            ),
        }
        variants[slot] = entry
    end
    cache.current[key] = variants
    return entry.lines
end

local function identity(item) return (item.note.comment or item.note).id end

local function notice(inline, row, text, agent)
    local indent, width, padding = style.layout(inline.win, row)
    return style.card_line(indent, width, padding, {
        {
            style.wrap(text, width)[1],
            agent and "ParleyReviewAgentHeading" or "ParleyReviewNoteHeading",
        },
    }, agent)
end

local function conclusion_indicator(inline, row, frame, phase)
    local indent, width, padding = style.layout(inline.win, row)
    return style.card_line(indent, width, padding, {
        { style.wrap(frame .. " " .. phase, width)[1], "ParleyReviewConclusionHeading" },
    }, nil, false, true)
end

-- Folding is presentation-only. Keep complete relationships and pending memberships;
-- inactive threads show the latest message from each author, or their current conclusion.
local function thread_display(inline, messages, selected, deleting, reservation)
    local groups = {}
    for _, message in ipairs(messages) do
        local group = groups[message.root] or {}
        groups[message.root] = group
        local note = message.item.note.comment or message.item.note
        local id = identity(message.item)
        group.last = message
        if not message.conclusion then
            group[thread.is_agent(message) and "agent" or "human"] = message
        end
        group.conclusion = note.conclusion or group.conclusion
        group.pending = group.pending or message.conclusion_turn ~= nil
        group.selected = group.selected or id == selected
        if id == inline.focus then group.focus_row = message.item.note.target.last end
        group.expanded = group.expanded
            or message.key == inline.message
            or id == deleting
            or reservation and (id == reservation.id or message.key == reservation.thread)
    end
    return groups
end

local function conclusion_card(message, group, indent, width, padding)
    local conclusion, preview = group.conclusion, {}
    for _, line in ipairs(vim.split(conclusion.summary, "\n", { plain = true })) do
        if line:match("%S") and line ~= "Summary:" then
            for _, wrapped in ipairs(style.wrap(line, width)) do
                preview[#preview + 1] = wrapped
            end
        end
    end
    if #preview > 3 then preview = { preview[1], preview[2], preview[3], "…" } end
    preview[#preview + 1] = "Enter to expand · summary, not implementation status"
    local heading = "thread concluded"
        .. (conclusion.decision and (" · " .. conclusion.decision) or "")
        .. " · "
        .. style.label(message.item.note.target)
        .. (conclusion.generated and " · Pi-generated" or "")
        .. (group.selected and " · selected thread" or "")
    return card(heading, preview, indent, width, padding, nil, nil, false, true)
end

---Render explicit reply relationships, including human follow-ups to agent replies.
---A reservation replaces one card, never the other notes sharing its source row.
local function thread_area(inline, buf, messages, groups, selected, deleting, row, cache)
    local reservation = inline.reservation
    if reservation and (reservation.row ~= row or reservation.buf ~= buf) then
        reservation = nil
    end
    local lines, rendered, revealed = {}, {}, {}
    local focused_offset, focused_count
    local height = api.nvim_win_get_height(inline.win)
        - (vim.wo[inline.win].winbar ~= "" and 1 or 0)
    local anchor_height = api.nvim_win_text_height(inline.win, {
        start_row = row - 1,
        start_vcol = 0,
        end_row = row - 1,
        max_height = height,
    }).all
    local layouts = {}
    local function layout(first)
        if not layouts[first] then layouts[first] = { style.layout(inline.win, first) } end
        return unpack(layouts[first])
    end
    local activity = inline.activity
    local indicators = {}
    local function append(area)
        if #lines > 0 then lines[#lines + 1] = { { "", "Normal" } } end
        for _, line in ipairs(area) do
            lines[#lines + 1] = line
        end
    end
    for _, message in ipairs(messages) do
        local item, id = message.item, message.key
        local note = item.note.comment or item.note
        local agent = thread.is_agent(message)
        local active = inline.message == id
        local indent, width, padding = layout(item.note.target.first)
        local group = groups[message.root]
        local concluded = not group.expanded
            and not group.pending
            and group.conclusion
            and group.conclusion.state == "concluded"
        local visible = group.expanded
            or (concluded and group.last == message)
            or (
                not concluded
                and (message.conclusion or group.human == message or group.agent == message)
            )
        if not visible and not message.reply and id == inline.focus then
            focused_offset, revealed[message.root] = #lines, true
        elseif
            visible
            and (
                active
                or not inline.message and group.focus_row == row and not revealed[message.root]
            )
        then
            focused_offset, revealed[message.root] = #lines, true
        end
        if not message.reply and not message.conclusion then rendered[id] = true end
        if visible and concluded then
            append(conclusion_card(message, group, indent, width, padding))
        elseif
            visible
            and reservation
            and not message.reply
            and not message.conclusion
            and reservation.id == id
        then
            if #lines > 0 then lines[#lines + 1] = { { "", "Normal" } } end
            reservation.offset = #lines
            for _, line in ipairs(reservation.lines) do
                lines[#lines + 1] = line
            end
        elseif visible then
            local conclusion = message.conclusion
            local heading = conclusion
                    and ("Conclusion · " .. (conclusion.decision or conclusion.state) .. " · " .. conclusion.id .. " · not implementation status")
                or message.reply and ("agent · " .. message.reply.id)
                or (agent and ("agent finding · " .. note.remote_id) or "human")
            if conclusion and (conclusion.generated or message.conclusion_turn) then
                heading = heading .. " · Pi-generated"
            end
            if not message.reply and not conclusion then
                heading = heading .. " · " .. style.label(item.note.target)
                if note.reply_to then heading = heading .. " · reply to " .. note.reply_to end
                if item.state ~= "saved" then heading = heading .. " · " .. item.state end
            end
            if note.conclusion and not conclusion then
                heading = heading
                    .. " · thread "
                    .. note.conclusion.state
                    .. (note.conclusion.decision and (" · " .. note.conclusion.decision) or "")
            end
            if active then
                heading = heading .. " · selected message"
            elseif not inline.message and group.selected then
                heading = heading .. (id == selected and " · selected" or " · selected thread")
            end
            if id == deleting then heading = "Delete note? Enter confirm · Esc/Ctrl+C cancel" end
            local text = thread.lines(message)
            local area
            local turn = message.conclusion_turn
            if turn and (turn.status == "queued" or turn.status == "running") then
                area = card(heading, {}, indent, width, padding, nil, nil, active, true)
                local phase = turn.status == "queued" and "Queued · waiting for Pi"
                    or "Generating conclusion"
                local frame = activity and activity.text:match("^%S+") or "⠋"
                local indicator =
                    conclusion_indicator(inline, item.note.target.first, frame, phase)
                table.insert(area, #area, indicator)
                indicators[indicator] = { first = item.note.target.first, phase = phase }
            else
                area = cached_card(
                    cache,
                    id,
                    heading,
                    text,
                    indent,
                    width,
                    padding,
                    agent,
                    id == deleting,
                    active,
                    conclusion ~= nil
                )
            end
            if active and not reservation then
                -- A source cursor cannot enter virtual lines. Page long selected messages
                -- in display space while preserving the complete text for yank/reply.
                local room = math.max(1, height - anchor_height - 3)
                local offset = math.min(inline.message_offset or 0, math.max(0, #area - room))
                inline.message_offset = offset
                local visible = {}
                for i = offset + 1, math.min(#area, offset + room) do
                    visible[#visible + 1] = area[i]
                end
                visible[#visible + 1] = notice(
                    inline,
                    row,
                    ("Ctrl+N/P messages · Enter edit/reply · gc conclude · y copy · E draft · Esc exit%s"):format(
                        #area > room and " · Ctrl+D/U scroll" or ""
                    )
                )
                area = visible
            end
            if active then
                focused_offset = #lines + (#lines > 0 and 1 or 0)
                focused_count = #area
            end
            append(area)
        end
        for _, owner in ipairs(message.tails or {}) do
            local parent = owner.note.comment or owner.note
            if activity and parent.remote_id and activity.notes[parent.remote_id] then
                -- Reserve the next agent message as its own card, after earlier discussion.
                -- Only the spinner row is animated; card geometry and composer room stay fixed.
                local first = owner.note.target.first
                local left, columns, pad = layout(first)
                local area = card("agent · pending reply", {}, left, columns, pad, true)
                local indicator = notice(inline, first, activity.text, true)
                table.insert(area, #area, indicator)
                indicators[indicator] = { first = first }
                append(area)
            end
        end
    end
    if reservation and not rendered[reservation.id] then
        reservation.offset = #lines
        for _, line in ipairs(reservation.lines) do
            lines[#lines + 1] = line
        end
    end
    if
        not reservation
        and focused_offset
        and (
            inline.message and #lines > height - anchor_height
            or focused_offset > math.max(0, height - 6)
        )
    then
        -- Multiple cards can share one source boundary. Navigation must show
        -- the selected card, not strand it below a tall preceding conversation.
        local visible = focused_offset > 0
                and {
                    notice(
                        inline,
                        row,
                        inline.message and "Earlier messages · Ctrl+P to navigate"
                            or "Earlier thread · move cursor to show"
                    ),
                }
            or {}
        for i = focused_offset + 1, #lines do
            visible[#visible + 1] = lines[i]
        end
        lines = visible
        focused_offset = focused_offset > 0 and 1 or 0
    end
    if reservation then
        -- Cursor anchoring cannot scroll into filler below EOF. While editing,
        -- keep a labeled tail preview above the room; closure restores all text.
        local available = math.max(0, height - #reservation.lines - 2)
        local preceding = reservation.offset or 0
        if preceding > available then
            local visible = {}
            if available > 0 then
                visible[1] = notice(inline, row, "Earlier thread · close composer to read")
            end
            local keep = math.max(0, available - 1)
            for i = preceding - keep + 1, #lines do
                visible[#visible + 1] = lines[i]
            end
            lines = visible
            reservation.offset = available
        end
    end
    local visible = {}
    for index, line in ipairs(lines) do
        if indicators[line] then
            visible[#visible + 1] = {
                index = index,
                first = indicators[line].first,
                phase = indicators[line].phase,
            }
        end
    end
    local focus = focused_count and { first = focused_offset + 1, count = focused_count } or nil
    return lines, visible, focus
end

---@param inline ParleyReviewInline
---@param buf integer
---@param items ParleyReviewComposer.Item[] Only notes whose original source still matches.
---@param selected integer? Exact note identity, including overlapping targets.
---@param deleting integer? Pending confirmation replaces only this note's metadata.
function M.update(inline, buf, items, selected, deleting)
    local cache = { previous = inline.cards or {}, current = {} }
    local by_row = {}
    if inline.focus ~= selected then inline.focus = nil end
    local messages = thread.messages(items)
    local reservation = inline.reservation
    local groups = thread_display(
        inline,
        messages,
        selected,
        deleting,
        reservation and reservation.buf == buf and reservation or nil
    )
    for _, message in ipairs(messages) do
        local row = message.item.note.target.last
        by_row[row] = by_row[row] or {}
        table.insert(by_row[row], message)
    end
    if reservation and reservation.buf == buf then
        by_row[reservation.row] = by_row[reservation.row] or {}
    end
    local rows = {}
    for row, notes in pairs(by_row) do
        local lines, activity, focus =
            thread_area(inline, buf, notes, groups, selected, deleting, row, cache)
        if #lines > 0 then
            rows[#rows + 1] = { row = row, lines = lines, activity = activity, focus = focus }
        end
    end
    table.sort(rows, function(a, b) return a.row < b.row end)
    if inline.buf == buf and vim.deep_equal(inline.rows, rows) then
        inline.cards = cache.current
        return
    end
    local previous = {}
    if inline.buf == buf then
        for _, row in ipairs(inline.rows) do
            previous[row.row] = row
        end
    else
        M.clear(inline)
    end
    inline.buf, inline.rows, inline.cards = buf, rows, cache.current
    local marks = {}
    for _, row in ipairs(rows) do
        -- Swap inactive text and editing room in place, never through zero height.
        if vim.deep_equal(previous[row.row], row) then
            marks[row.row] = inline.marks[row.row]
        else
            marks[row.row] = api.nvim_buf_set_extmark(buf, ns, row.row - 1, 0, {
                id = inline.marks[row.row],
                virt_lines = row.lines,
                virt_lines_leftcol = true,
                priority = 100,
            })
        end
    end
    for row, mark in pairs(inline.marks) do
        if not marks[row] then api.nvim_buf_del_extmark(buf, ns, mark) end
    end
    inline.marks = marks
end

---Explicit navigation only; incoming replies and spinner updates never move the view.
function M.reveal(inline)
    if not inline.message or inline.reservation or not api.nvim_win_is_valid(inline.win) then
        return
    end
    for _, row in ipairs(inline.rows) do
        if row.focus then
            api.nvim_win_call(inline.win, function()
                local view = vim.fn.winsaveview()
                local height = api.nvim_win_get_height(inline.win)
                    - (vim.wo[inline.win].winbar ~= "" and 1 or 0)
                local preceding = height + 1
                if view.topline <= row.row then
                    preceding = api.nvim_win_text_height(inline.win, {
                        start_row = view.topline - 1,
                        start_vcol = view.skipcol,
                        end_row = row.row - 1,
                        max_height = height + 1,
                    }).all + view.topfill
                end
                if preceding + row.focus.first - 1 + row.focus.count <= height then return end
                -- Direct view placement, not a cursor-centric scrolling command.
                -- In thread mode scrolloff is temporarily zero, so the card's
                -- reserved room remains usable instead of recentering the cursor.
                vim.fn.winrestview({ topline = row.row, topfill = 0, skipcol = 0 })
            end)
            return
        end
    end
end

---Animate only pending-card spinners, without rewrapping cards or moving composer room.
function M.animate(inline, text)
    if not inline.activity or not inline.buf or not api.nvim_buf_is_valid(inline.buf) then
        return
    end
    inline.activity.text = text
    for _, row in ipairs(inline.rows) do
        if #row.activity > 0 then
            for _, indicator in ipairs(row.activity) do
                row.lines[indicator.index] = indicator.phase
                        and conclusion_indicator(
                            inline,
                            indicator.first,
                            text:match("^%S+"),
                            indicator.phase
                        )
                    or notice(inline, indicator.first, text, true)
            end
            api.nvim_buf_set_extmark(inline.buf, ns, row.row - 1, 0, {
                id = inline.marks[row.row],
                virt_lines = row.lines,
                virt_lines_leftcol = true,
                priority = 100,
            })
        end
    end
end

return M
