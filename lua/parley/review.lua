-- Extracted from arubertoson/nvim: lua/aru/workspace/review.lua.
---Parley's frozen navigation and editor lifecycle; connected review ownership lives in Pi.
local M = { status = "" }
local api = vim.api
local snapshot = require("parley.snapshot")
local composer = require("parley.composer")
local inline = require("parley.inline")
local gutter = require("parley.gutter")
local peek = require("parley.comparison")
local mode_help = require("parley.help")
local source = require("parley.source")
local thread = require("parley.thread")

---@class ParleyReviewPiece
---@field file ParleyReviewFile
---@field side 'old'|'new'
---@field first integer
---@field last integer
---@field old_first integer
---@field old_count integer
---@field new_first integer
---@field new_count integer
---@field seen boolean
---@field view table?

---@class ParleyReviewSession
---@field id integer
---@field root string
---@field vcs string
---@field pieces ParleyReviewPiece[]
---@field files ParleyReviewFile[] Original frozen sources, separate from supplemental evidence.
---@field buffer_maps table<integer, table[]> Original mappings retained until workspace detach.
---@field projections table<ParleyReviewFile, table<string, integer[][]>> Active-buffer diff cache.
---@field evidence table<string, integer>? Supplemental source IDs to navigation pieces.
---@field index integer
---@field win integer
---@field inline ParleyReviewInline
---@field gutter ParleyReviewGutter
---@field peek ParleyReviewPeek
---@field peek_piece ParleyReviewPiece? Revealed only until the source leaves this hunk.
---@field peek_target ParleyReviewPeekTarget?
---@field peek_anchor integer? Source row above which the excerpt is displayed.
---@field presentation ParleyReviewComposer.Presentation
---@field prompt table? Identity of a review-owned decision picker temporarily borrowing focus.
---@field stale boolean
---@field group integer
---@field snapshots table<string, integer>
---@field selected integer? Saved note ID, or recovery draft; edits keep committed identity.
---@field selection_cursor integer[]? Cursor at selection, cleared by ordinary movement.
---@field restoring_maps boolean?
---@field deletion ParleyReviewDeletion? Session-owned inline confirmation and temporary mappings.
---@field thread { root: integer, key: integer|string, buf: integer, win: integer, scrolloff: integer, saved_maps: table[] }? Contextual message navigation.
---@field status_prefix string? Cached progress, independent of spinner frames.
---@field activity_label string? Fixed-height inline turn status.
---@field activity_waiting boolean?
---@field activity_frame integer?
---@field activity_timer uv.uv_timer_t? Owned only while waiting for an agent turn.

---@class ParleyReviewDeletion
---@field id integer Exact saved note identity; never inferred from overlapping targets.
---@field buf integer
---@field saved_maps table[]

---@type ParleyReviewSession?
local session
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function stop_activity(s)
    if not s.activity_timer then return end
    s.activity_timer:stop()
    s.activity_timer:close()
    s.activity_timer = nil
end

local function refresh_activity(s)
    local phase = not s.stale and s.remote and s.remote.activity and s.remote.activity()
    s.activity_waiting = not not phase
    s.activity_label = phase and (frames[s.activity_frame or 1] .. " " .. phase)
        or (s.remote and s.remote.status())
    M.status = (s.status_prefix or "") .. (s.activity_label and (" · " .. s.activity_label) or "")
    if not phase then
        stop_activity(s)
    elseif not s.activity_timer then
        local timer = vim.uv.new_timer()
        s.activity_timer = timer
        timer:start(
            120,
            120,
            vim.schedule_wrap(function()
                if session ~= s or s.activity_timer ~= timer then return end
                if not api.nvim_win_is_valid(s.win) then
                    stop_activity(s)
                    return
                end
                s.activity_frame = (s.activity_frame or 1) % #frames + 1
                refresh_activity(s)
                inline.animate(s.inline, s.activity_label)
                api.nvim_exec_autocmds("User", {
                    pattern = "ParleyReviewChanged",
                    data = { status = M.status },
                })
            end)
        )
    end
end

local function pieces_for(files)
    local pieces = {}
    for _, file in ipairs(files) do
        local hunks =
            vim.text.diff(file.old, file.new, { result_type = "indices", algorithm = "histogram" })
        -- Keep metadata-only files (empty files, modes, renames) in the queue too.
        if #hunks == 0 then hunks = { { 1, 0, 1, 0 } } end
        for _, hunk in ipairs(hunks) do
            local side = (hunk[4] == 0 and hunk[2] > 0 or file.deleted) and "old" or "new"
            local first = math.max(1, side == "old" and hunk[1] or hunk[3])
            local count = side == "old" and hunk[2] or hunk[4]
            pieces[#pieces + 1] = {
                file = file,
                side = side,
                first = first,
                last = first + math.max(1, count) - 1,
                old_first = hunk[1],
                old_count = hunk[2],
                new_first = hunk[3],
                new_count = hunk[4],
                seen = false,
            }
        end
    end
    return pieces
end

local bindings = {
    { "n", "]c", function() M.move(1) end, "Next review piece" },
    { "n", "[c", function() M.move(-1) end, "Previous review piece" },
    { "n", "c", function() M.comment("line") end, "Comment on line" },
    { "x", "c", function() M.comment("range") end, "Comment on selection" },
    { "n", "C", function() M.comment("hunk") end, "Comment on review hunk" },
    { "n", "<CR>", function() M.enter_thread() end, "Enter discussion thread" },
    { "n", "<C-n>", function() M.move_note(1) end, "Next review note" },
    { "n", "<C-p>", function() M.move_note(-1) end, "Previous review note" },
    { "n", "<Space>", function() M.peek() end, "Toggle current hunk comparison" },
    { "n", "<leader>rq", function() M.stop() end, "Exit review mode" },
    { "n", "<leader>rd", function() M.delete_note() end, "Delete selected review note" },
    {
        "n",
        "<leader>rs",
        function() require("parley").submit() end,
        "Submit explicit review turn",
    },
    { "n", "<leader>rr", function() M.reply() end, "Reply to selected review note" },
    { "n", "<leader>?", function() M.help() end, "Show review hotkeys" },
    { "n", "<F1>", function() M.help() end, "Show review hotkeys" },
    { "x", "<F1>", function() M.help() end, "Show review hotkeys" },
}

local thread_bindings = {
    { "<C-n>", function() M.move_message(1) end, "Next thread message" },
    { "<C-p>", function() M.move_message(-1) end, "Previous thread message" },
    { "y", function() M.yank_message() end, "Yank selected message text" },
    { "e", function() M.edit_message() end, "Edit selected human message" },
    { "r", function() M.reply_message() end, "Reply to selected message" },
    { "E", function() M.copy_message() end, "Copy agent message into a reply draft" },
    { "gc", function() M.conclude() end, "Conclude thread" },
    { "<CR>", function() M.edit_message(true) end, "Edit human message / reply to agent" },
    { "<C-d>", function() M.scroll_message(1) end, "Scroll selected message down" },
    { "<C-u>", function() M.scroll_message(-1) end, "Scroll selected message up" },
    { "q", function() M.leave_thread() end, "Leave thread navigation" },
    { "<Esc>", function() M.leave_thread() end, "Leave thread navigation" },
    { "<C-c>", function() M.leave_thread() end, "Leave thread navigation" },
}

-- Thread navigation owns focus; source motions must not accidentally leave it.
-- These use the same capture/restoration lifecycle as the other thread mappings.
for _, key in ipairs({ "h", "j", "k", "l", "gj", "gk", "<Left>", "<Down>", "<Up>", "<Right>" }) do
    thread_bindings[#thread_bindings + 1] = { key, "<Nop>", "Source movement disabled in thread" }
end

local function map_thread(s)
    if not s.thread or api.nvim_get_current_buf() ~= s.thread.buf then return end
    for _, binding in ipairs(thread_bindings) do
        vim.keymap.set("n", binding[1], binding[2], {
            buffer = s.thread.buf,
            nowait = true,
            desc = binding[3],
        })
    end
end

local function cancel_thread(s)
    local active = s.thread
    if not active then return end
    s.thread = nil
    s.inline.message, s.inline.message_offset, s.inline.focus = nil, nil, nil
    mode_help.close()
    if
        api.nvim_win_is_valid(active.win)
        and api.nvim_get_option_value("scrolloff", { win = active.win, scope = "local" }) == 0
    then
        api.nvim_set_option_value(
            "scrolloff",
            active.scrolloff,
            { win = active.win, scope = "local" }
        )
    end
    if api.nvim_buf_is_valid(active.buf) then
        s.restoring_maps = true
        api.nvim_buf_call(active.buf, function()
            for i, binding in ipairs(thread_bindings) do
                vim.keymap.del("n", binding[1], { buffer = active.buf })
                if active.saved_maps[i].buffer == 1 then
                    vim.fn.mapset("n", false, active.saved_maps[i])
                end
            end
        end)
        s.restoring_maps = false
    end
end

local cancel_keys = { "<Esc>", "<C-c>" }

local function cancel_deletion(s)
    local pending = s.deletion
    if not pending then return end
    s.deletion = nil
    if api.nvim_buf_is_valid(pending.buf) then
        s.restoring_maps = true
        api.nvim_buf_call(pending.buf, function()
            for i, key in ipairs(cancel_keys) do
                vim.keymap.del("n", key, { buffer = pending.buf })
                if pending.saved_maps[i].buffer == 1 then
                    vim.fn.mapset("n", false, pending.saved_maps[i])
                end
            end
        end)
        s.restoring_maps = false
    end
end

local function unmap(s)
    if session == s then return end -- Navigation never removes workspace review controls.
    s.restoring_maps = true
    for buf, saved in pairs(s.buffer_maps) do
        if api.nvim_buf_is_valid(buf) then
            api.nvim_buf_call(buf, function()
                for i, binding in ipairs(bindings) do
                    vim.keymap.del(binding[1], binding[2], { buffer = buf })
                    if saved[i].buffer == 1 then vim.fn.mapset(binding[1], false, saved[i]) end
                end
            end)
        end
    end
    s.buffer_maps = {}
    s.restoring_maps = false
end

local function map_source(s)
    if session ~= s or s.restoring_maps then return end
    local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    local path = source.path(s.root, buf)
    if api.nvim_win_get_config(win).relative ~= "" or not path then return end
    if vim.b[buf].parley_snapshot and vim.b[buf].parley_session ~= s.id then return end
    if win ~= s.win or buf ~= s.view_buf then
        s.capture_generation = (s.capture_generation or 0) + 1
        cancel_deletion(s)
        inline.clear(s.inline)
        cancel_thread(s)
        gutter.clear(s.gutter)
        peek.clear(s.peek)
        s.peek_piece, s.peek_target, s.peek_anchor = nil, nil, nil
        s.selected, s.selection_cursor = nil, nil
        s.win, s.view_buf = win, buf
        s.inline.win, s.peek.win = win, win
        api.nvim__ns_set(inline.namespace, { wins = { win } })
        gutter.rebind(win)
        api.nvim__ns_set(s.peek.ns, { wins = { win } })
    end
    source.select(s, buf)
    local saved = s.buffer_maps[buf]
    if not saved then
        saved = {}
        s.buffer_maps[buf] = saved
        for i, binding in ipairs(bindings) do
            saved[i] = vim.fn.maparg(binding[2], binding[1], false, true)
        end
    end
    for _, binding in ipairs(bindings) do
        vim.keymap.set(
            binding[1],
            binding[2],
            binding[3],
            { buffer = buf, desc = binding[4], nowait = true }
        )
    end
    map_thread(s)
end

local function source_matches(s, piece, buf)
    local text = piece.side == "old" and piece.file.old or piece.file.new
    local owned = source.path(s.root, buf) == piece.file.path
        and (
            not vim.b[buf].parley_snapshot
            or vim.b[buf].parley_side == piece.side
                and vim.b[buf].parley_source_id == piece.file.source_id
        )
    return owned
        and vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), snapshot.lines(text))
end

local function file_notes(s)
    local buf, items = api.nvim_win_get_buf(s.win), {}
    s.outdated = 0
    local path = source.path(s.root, buf)
    for _, item in ipairs(composer.review_items(s.id)) do
        local target = item.note.target
        local owner, anchor = target.review, target.anchor or target
        if owner.path == path then
            local file = s.pieces[owner.piece].file
            local first, last = source.project(s, file, owner.side, buf, anchor.first, anchor.last)
            if
                first
                and last <= api.nvim_buf_line_count(buf)
                and vim.deep_equal(
                    api.nvim_buf_get_lines(buf, first - 1, last, false),
                    anchor.context
                )
            then
                target.path = api.nvim_buf_get_name(buf)
                target.first, target.last = first, last
                target.outdated = false
                items[#items + 1] = item
            else
                s.outdated = s.outdated + 1
                target.outdated = true
            end
        end
    end
    return items
end

local function identity(item) return (item.note.comment or item.note).id end

local function selected_item(s)
    for _, item in ipairs(composer.review_items(s.id)) do
        if identity(item) == s.selected then return item end
    end
end

local function selected_message(s)
    if not s.thread then return end
    for _, message in ipairs(thread.messages(composer.review_items(s.id))) do
        if message.key == s.thread.key then return message end
    end
end

local function clear_peek(s)
    s.peek_piece, s.peek_target, s.peek_anchor = nil, nil, nil
    peek.clear(s.peek)
end

local function deletion_matches(s)
    local pending = s.deletion
    return pending
        and api.nvim_get_current_win() == s.win
        and api.nvim_win_get_buf(s.win) == pending.buf
        and s.selected == pending.id
        and vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win))
end

local function update_inline(s, items)
    items = s.stale and {} or items or file_notes(s)
    if s.thread then
        local message, visible = selected_message(s), false
        for _, item in ipairs(items) do
            if message and identity(item) == identity(message.item) then visible = true end
        end
        if visible then
            s.thread.root = message.root
        else
            cancel_thread(s)
        end
    end
    if s.deletion and not deletion_matches(s) then cancel_deletion(s) end
    local buf = api.nvim_win_get_buf(s.win)
    if s.peek_piece then
        -- The editor has already locked its boundary before borrowing room.
        local row = api.nvim_win_get_cursor(s.win)[1]
        if s.stale or row < s.peek_piece.first or row > s.peek_piece.last then clear_peek(s) end
    end
    s.inline.activity = not s.stale
            and s.activity_waiting
            and s.remote.pending
            and {
                text = s.activity_label,
                notes = s.remote.pending(),
            }
        or nil
    inline.update(s.inline, buf, items, s.selected, s.deletion and s.deletion.id)
    peek.update(s.peek, buf, s.peek_piece, s.peek_target, s.peek_anchor)
end

local function progress(s)
    local remaining, notes, drafts = 0, 0, 0
    for _, piece in ipairs(s.pieces) do
        if not piece.seen then remaining = remaining + 1 end
    end
    for _, item in ipairs(composer.review_items(s.id)) do
        if item.state ~= "draft" then notes = notes + 1 end
        if item.state ~= "saved" then drafts = drafts + 1 end
    end
    local piece = s.pieces[s.index]
    if not api.nvim_win_is_valid(s.win) then return end
    local buf = api.nvim_win_get_buf(s.win)
    s.stale = not source.path(s.root, buf)
    if s.stale or source.path(s.root, buf) ~= piece.file.path or piece.file.source_id then
        gutter.clear(s.gutter)
    else
        local side = vim.b[buf].parley_side or "new"
        gutter.update(
            s.gutter,
            buf,
            piece.file,
            side,
            function(row) return source.project(s, piece.file, side, buf, row, row) end,
            s.remote and s.remote.in_stage and not s.remote.in_stage(piece.file.path),
            s.remote and s.remote.scope_ranges and s.remote.scope_ranges(piece.file.path, side)
        )
    end
    if s.remote then file_notes(s) end
    s.status_prefix = ("Review %d/%d · %d unseen · %d notes%s%s%s"):format(
        s.index,
        #s.pieces,
        remaining,
        notes,
        drafts > 0 and (" · %d drafts"):format(drafts) or "",
        piece.side == "old" and " · OLD" or "",
        s.stale and " · STALE"
            or (s.outdated and s.outdated > 0 and (" · %d outdated"):format(s.outdated) or "")
    )
    if s.remote and s.remote.scope then
        s.status_prefix = s.status_prefix .. " · " .. s.remote.scope(source.path(s.root, buf))
    end
    refresh_activity(s)
    update_inline(s)
    api.nvim_exec_autocmds(
        "User",
        { pattern = "ParleyReviewChanged", data = { status = M.status } }
    )
end

local function remember(s)
    if not api.nvim_win_is_valid(s.win) then return end
    local piece = s.pieces[s.index]
    if source_matches(s, piece, api.nvim_win_get_buf(s.win)) then
        piece.view = api.nvim_win_call(s.win, vim.fn.winsaveview)
    end
end

local function frozen_buffer(s, file, side)
    local key = side .. ":" .. (file.source_id or file.path)
    local existing = s.snapshots[key]
    if existing and api.nvim_buf_is_valid(existing) then return existing end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(
        buf,
        ("parley://%d/%s/%s/%s"):format(
            s.id,
            side,
            file.source_id or "original",
            side == "old" and file.old_path or file.path
        )
    )
    vim.bo[buf].bufhidden = "hide"
    vim.b[buf].parley_oldside = side == "old"
    vim.b[buf].parley_snapshot = true
    vim.b[buf].parley_session = s.id
    vim.b[buf].parley_root = s.root
    vim.b[buf].parley_path = file.path
    vim.b[buf].parley_side = side
    vim.b[buf].parley_source_id = file.source_id
    api.nvim_buf_set_lines(buf, 0, -1, false, snapshot.lines(file[side]))
    vim.bo[buf].filetype = vim.filetype.match({ filename = file.old_path }) or ""
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    s.snapshots[key] = buf
    return buf
end

local function visit(s, index, initial)
    cancel_thread(s)
    cancel_deletion(s)
    composer.close(false)
    if not initial then remember(s) end
    unmap(s)
    inline.clear(s.inline)
    gutter.clear(s.gutter)
    s.index = index
    if s.peek_piece ~= s.pieces[index] then clear_peek(s) end
    s.selected, s.selection_cursor = nil, nil
    local piece = s.pieces[index]
    api.nvim_set_current_win(s.win)
    local buf
    if piece.side == "old" or piece.file.deleted then
        buf = frozen_buffer(s, piece.file, piece.side)
    else
        buf = vim.fn.bufadd(vim.fs.joinpath(s.root, piece.file.path))
        vim.fn.bufload(buf)
    end
    api.nvim_win_set_buf(s.win, buf)
    piece.seen = true
    api.nvim_win_call(s.win, function()
        if piece.view then
            vim.fn.winrestview(piece.view)
        else
            local ranges = s.remote
                and s.remote.scope_ranges
                and s.remote.scope_ranges(piece.file.path, piece.side)
            local row = ranges and ranges[1] and ranges[1][1] or piece.first
            local first = source.project(s, piece.file, piece.side, buf, row, row)
            api.nvim_win_set_cursor(
                s.win,
                { math.min(first or row, api.nvim_buf_line_count(buf)), 0 }
            )
            vim.cmd("normal! zvzz")
        end
    end)
    map_source(s)
    progress(s)
end

function M.move(step)
    local s = session
    if not s then return end
    if s.remote then map_source(s) end
    if not api.nvim_win_is_valid(s.win) then return end
    if s.deletion then
        cancel_deletion(s)
        update_inline(s)
    end
    local index = s.index + step
    if s.remote and s.remote.in_stage then
        while
            index >= 1
            and index <= #s.pieces
            and not s.remote.in_stage(s.pieces[index].file.path)
        do
            index = index + step
        end
    end
    if index < 1 or index > #s.pieces then
        vim.notify("End of current review piece/queue", vim.log.levels.INFO)
        return
    end
    visit(s, index)
end

local function selected_source()
    local s = session
    if not s then return end
    map_source(s)
    if api.nvim_get_current_win() == s.win and source.path(s.root, api.nvim_get_current_buf()) then
        return s, s.pieces[s.index]
    end
    vim.notify("Review actions require an ordinary file in this workspace", vim.log.levels.WARN)
end

---Resolve cursor ownership without moving the frozen navigation queue.
local function cursor_piece(s, row)
    local buf = api.nvim_win_get_buf(s.win)
    local path = source.path(s.root, buf)
    local side = vim.b[buf].parley_side or "new"
    for index, piece in ipairs(s.pieces) do
        if
            piece.file.path == path
            and piece.side == side
            and not piece.file.source_id
            and source.project(s, piece.file, side, buf, piece.first, piece.last)
        then
            local first, last = source.project(s, piece.file, side, buf, piece.first, piece.last)
            if row >= first and row <= last then return piece, index, first, last end
        end
    end
end

local function select_item(s, item, items)
    if s.peek_piece == s.pieces[item.note.target.review.piece] then
        s.peek_target = item.note.target
    end
    s.selected = identity(item)
    s.selection_cursor = api.nvim_win_get_cursor(s.win)
    update_inline(s, items)
end

local function reveal_item(s, item)
    local target = item.note.target
    visit(s, target.review.piece)
    if s.stale then
        -- Keep identity for discard/delete, but never claim a valid source placement.
        s.selected = identity(item)
        s.selection_cursor = api.nvim_win_get_cursor(s.win)
        vim.notify(
            "Stale note (original target retained):\n" .. table.concat(item.note.lines, "\n"),
            vim.log.levels.WARN
        )
        return
    end
    if s.remote then
        local visible = false
        for _, candidate in ipairs(file_notes(s)) do
            if identity(candidate) == identity(item) then visible = true end
        end
        if not visible then
            vim.notify(
                "Outdated placement; showing immutable original evidence",
                vim.log.levels.INFO
            )
            local piece = s.pieces[target.review.piece]
            local buf = frozen_buffer(s, piece.file, target.review.side)
            api.nvim_win_set_buf(s.win, buf)
            map_source(s)
            progress(s)
            file_notes(s)
        end
    end
    api.nvim_win_set_cursor(s.win, { target.last, 0 })
    api.nvim_win_call(s.win, function() vim.cmd("normal! zvzt") end)
    s.inline.focus = identity(item)
    select_item(s, item)
end

---Navigate the frozen queue's target order, including unfinished edits.
function M.move_note(step)
    local s = session
    if not s then return end
    cancel_thread(s)
    if s.remote then map_source(s) end
    if not api.nvim_win_is_valid(s.win) or api.nvim_get_current_win() ~= s.win then return end
    if s.deletion then
        cancel_deletion(s)
        update_inline(s)
    end
    if s.remote then file_notes(s) end
    local items = composer.review_items(s.id)
    local scope_order = { line = 1, range = 2, hunk = 3 }
    local ordered = {}
    for index, item in ipairs(items) do
        ordered[#ordered + 1] = { item = item, order = index }
    end
    table.sort(ordered, function(a, b)
        local x, y = a.item.note.target, b.item.note.target
        if x.review.piece ~= y.review.piece then return x.review.piece < y.review.piece end
        local a_anchor, b_anchor = x.anchor or x, y.anchor or y
        if a_anchor.last ~= b_anchor.last then return a_anchor.last < b_anchor.last end
        if a_anchor.first ~= b_anchor.first then return a_anchor.first < b_anchor.first end
        if x.scope ~= y.scope then return scope_order[x.scope] < scope_order[y.scope] end
        return a.order < b.order
    end)
    local current
    for index, entry in ipairs(ordered) do
        if identity(entry.item) == s.selected then current = index end
    end
    local next_index
    if current then
        next_index = current + step
    else
        local row = api.nvim_win_get_cursor(s.win)[1]
        for index, entry in ipairs(ordered) do
            local target = entry.item.note.target
            if step > 0 then
                if
                    target.review.piece > s.index
                    or (target.review.piece == s.index and (target.last >= row or target.outdated))
                then
                    next_index = index
                    break
                end
            elseif
                target.review.piece < s.index
                or (target.review.piece == s.index and (target.last <= row or target.outdated))
            then
                next_index = index
            end
        end
    end
    local entry = next_index and ordered[next_index]
    if not entry then
        vim.notify("End of review notes", vim.log.levels.INFO)
        return
    end
    reveal_item(s, entry.item)
end

---Selection belongs to a message, not its anchor or the last reply in a thread.
local function focus_message(s, message, root)
    local items, visible = file_notes(s), false
    for _, item in ipairs(items) do
        if identity(item) == identity(message.item) then visible = true end
    end
    if not visible then
        reveal_item(s, message.item)
        items = file_notes(s)
    end
    if s.stale then return end
    cancel_deletion(s)
    local entering = not s.thread
    if entering then
        local active = {
            root = root,
            key = message.key,
            buf = api.nvim_win_get_buf(s.win),
            win = s.win,
            scrolloff = api.nvim_get_option_value("scrolloff", { win = s.win, scope = "local" }),
            saved_maps = {},
        }
        api.nvim_buf_call(active.buf, function()
            for i, binding in ipairs(thread_bindings) do
                active.saved_maps[i] = vim.fn.maparg(binding[1], "n", false, true)
            end
        end)
        s.thread = active
        -- Cursor context must not push the discussion below the viewport. Restore
        -- the exact local/inherited setting when contextual navigation ends.
        api.nvim_set_option_value("scrolloff", 0, { win = s.win, scope = "local" })
    end
    s.thread.key = message.key
    s.inline.message, s.inline.message_offset = message.key, 0
    api.nvim_win_set_cursor(s.win, { message.item.note.target.last, 0 })
    api.nvim_win_call(s.win, function() vim.cmd("normal! zv") end)
    select_item(s, message.item, items)
    inline.reveal(s.inline)
    if entering then map_thread(s) end
end

function M.enter_thread()
    if session and session.deletion then
        M.edit_note() -- Enter still confirms the existing inline deletion prompt.
        return
    end
    local s = selected_source()
    if not s then return end
    if s.thread then
        M.edit_message(true)
        return
    end
    local item = selected_item(s)
    if not item then
        local row = api.nvim_win_get_cursor(s.win)[1]
        for _, candidate in ipairs(file_notes(s)) do
            local target = candidate.note.target
            if row >= target.first and row <= target.last then
                item = candidate
                break
            end
        end
    end
    if not item then
        vim.notify("Select a note with Ctrl+N/P, then enter its thread", vim.log.levels.INFO)
        return
    end
    local messages, root = thread.messages(composer.review_items(s.id)), nil
    for _, message in ipairs(messages) do
        if message.key == identity(item) then
            root = message.root
            break
        end
    end
    -- Enter at the tail, whether the latest message is human or agent-authored.
    for index = #messages, 1, -1 do
        if messages[index].root == root then
            focus_message(s, messages[index], root)
            return
        end
    end
end

function M.leave_thread()
    local s = session
    if not s or not s.thread then return end
    cancel_thread(s)
    if api.nvim_win_is_valid(s.win) then update_inline(s) end
end

function M.move_message(step)
    local s = session
    if not s or not s.thread or api.nvim_get_current_win() ~= s.win then return end
    local messages, current = {}, nil
    for _, message in ipairs(thread.messages(composer.review_items(s.id))) do
        if message.root == s.thread.root then
            messages[#messages + 1] = message
            if message.key == s.thread.key then current = #messages end
        end
    end
    local next_message = current and messages[current + step * vim.v.count1]
    if not next_message then
        vim.notify("End of thread messages", vim.log.levels.INFO)
        return
    end
    focus_message(s, next_message, s.thread.root)
end

function M.scroll_message(step)
    local s = session
    if not s or not s.thread or api.nvim_get_current_win() ~= s.win then return end
    s.inline.message_offset = math.max(
        0,
        (s.inline.message_offset or 0)
            + step * math.max(1, math.floor(api.nvim_win_get_height(s.win) / 2)) * vim.v.count1
    )
    update_inline(s)
    inline.reveal(s.inline)
end

local function message_action()
    local s = session
    if not s or not s.thread or api.nvim_get_current_win() ~= s.win then return end
    if not vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win)) then
        M.leave_thread()
        return
    end
    local message = selected_message(s)
    if not message then
        M.leave_thread()
        return
    end
    return s, message
end

function M.yank_message()
    local _, message = message_action()
    if not message then return end
    local lines, register = thread.lines(message), vim.v.register
    vim.fn.setreg(register, lines, "V")
    if register ~= '"' and register ~= "_" then vim.fn.setreg('"', lines, "V") end
    vim.notify("Review message copied", vim.log.levels.INFO)
end

function M.edit_message(reply_to_agent)
    local s, message = message_action()
    if not message then return end
    if message.conclusion then
        if message.conclusion.state == "concluded" then
            M.conclude(message.conclusion.id) -- Edit this record; viewing/editing requests no model work.
        else
            vim.notify(
                message.conclusion_turn
                        and "Conclusion generation is pending or failed; gc to retry explicitly"
                    or "Reopening history is read-only; gc requests a new conclusion",
                vim.log.levels.INFO
            )
        end
        return
    end
    if thread.is_agent(message) then
        if reply_to_agent then
            M.reply_message()
        else
            vim.notify("Agent messages are immutable; E copies into a draft", vim.log.levels.INFO)
        end
        return
    end
    composer.open_item(message.item, s.presentation)
end

local function compose_message(copy)
    local s, message = message_action()
    if not message then return end
    if message.conclusion then
        vim.notify("Select a discussion message with Ctrl+P before replying", vim.log.levels.INFO)
        return
    end
    if copy and not thread.is_agent(message) then
        vim.notify("Use e to edit a human message", vim.log.levels.INFO)
        return
    end
    local note = message.item.note
    local parent = message.reply and message.reply.id or note.remote_id
    if message.item.state ~= "saved" or not parent or not s.remote then
        vim.notify("Save the message in a connected review before replying", vim.log.levels.INFO)
        return
    end
    -- A copied agent message is a new human draft explicitly replying to its origin.
    -- Neither copying nor opening the composer submits anything to Pi.
    composer.reply(note, parent, s.presentation, copy and thread.lines(message) or nil)
end

function M.reply_message() compose_message(false) end
function M.copy_message() compose_message(true) end

local function conclusion_action(action, editing_id)
    local s = selected_source()
    if not s or not s.remote then return end
    local message = selected_message(s)
    local item = message and message.item or selected_item(s)
    local note = item and (item.note.comment or item.note)
    if not note or item.state ~= "saved" or not note.remote_id then
        vim.notify(
            "Select a saved thread with Ctrl+N/P before concluding or reopening",
            vim.log.levels.INFO
        )
        return
    end
    local navigation, selected, key = s.thread, s.selected, message and message.key
    s.remote[action](
        message and message.reply and message.reply.id or note.remote_id,
        item.note.target,
        s.presentation,
        function()
            return s.thread == navigation
                and s.selected == selected
                and (not navigation or navigation.key == key)
        end,
        editing_id
    )
end

function M.conclude(editing_id) conclusion_action("conclude", editing_id) end
function M.reopen() conclusion_action("reopen") end

function M.comment(scope)
    local s = selected_source()
    if not s then return end
    local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
    local first, last = api.nvim_win_get_cursor(win)[1], api.nvim_win_get_cursor(win)[1]
    if scope == "range" then
        first, last = vim.fn.line("v"), vim.fn.line(".")
        if first > last then
            first, last = last, first
        end
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    elseif scope == "hunk" then
        local piece, _, a, b = cursor_piece(s, first)
        if piece then
            first, last = a, b
        else
            scope = "line"
        end
    end
    s.capture_generation = (s.capture_generation or 0) + 1
    local generation = s.capture_generation
    local owner, anchor = source.anchor(s, buf, first, last)
    if owner then
        composer.open(first, last, scope, owner, s.presentation, anchor)
        return
    end
    if vim.b[buf].parley_snapshot then
        vim.notify("Selection has no valid frozen text anchor", vim.log.levels.WARN)
        return
    end
    local payload = {
        path = source.path(s.root, buf),
        text = source.text(buf),
        fileformat = vim.bo[buf].fileformat,
        modified = vim.bo[buf].modified,
    }
    if #payload.text > 1024 * 1024 or payload.text == "" then
        vim.notify("Supporting buffer must contain text and fit within 1 MiB", vim.log.levels.WARN)
        return
    end
    local tick = api.nvim_buf_get_changedtick(buf)
    local cursor = api.nvim_win_get_cursor(win)
    vim.notify(
        "Capturing this buffer as immutable review evidence; no agent work started",
        vim.log.levels.INFO
    )
    s.remote.capture(payload, function(record, err)
        if session ~= s or s.capture_generation ~= generation then return end
        if not record then
            vim.notify("Parley capture failed: " .. err, vim.log.levels.WARN)
            return
        end
        source.sync(s, record)
        if
            api.nvim_get_current_win() ~= win
            or api.nvim_get_current_buf() ~= buf
            or not api.nvim_buf_is_valid(buf)
            or api.nvim_buf_get_changedtick(buf) ~= tick
            or not vim.deep_equal(api.nvim_win_get_cursor(win), cursor)
        then
            vim.notify(
                "Evidence captured; return to the intended selection and compose again",
                vim.log.levels.INFO
            )
            return
        end
        for _, evidence in ipairs(record.evidence or {}) do
            if
                evidence.path == payload.path
                and evidence.text == payload.text
                and evidence.fileformat == payload.fileformat
                and evidence.modified == payload.modified
            then
                local index = s.evidence[evidence.id]
                local context = api.nvim_buf_get_lines(buf, first - 1, last, false)
                composer.open(
                    first,
                    last,
                    scope,
                    {
                        session = s.id,
                        piece = index,
                        path = payload.path,
                        side = "new",
                        source_id = evidence.id,
                    },
                    s.presentation,
                    {
                        first = first,
                        last = last,
                        context = context,
                    }
                )
                return
            end
        end
        vim.notify("Capture acknowledgement omitted the requested evidence", vim.log.levels.WARN)
    end)
end

function M.edit_note()
    if session and session.thread then
        M.edit_message(true)
        return
    end
    local pending_session = session
    if pending_session and pending_session.deletion then
        local id = pending_session.deletion.id
        local confirmed = deletion_matches(pending_session)
        cancel_deletion(pending_session)
        if confirmed then
            -- Revalidate the original identity, not whichever overlap is now nearest.
            for _, item in ipairs(composer.review_items(pending_session.id)) do
                if identity(item) == id and item.state ~= "draft" then
                    composer.delete(item)
                    return
                end
            end
        end
        progress(pending_session)
        return
    end
    local s = selected_source()
    if not s then return end
    local buf, index = api.nvim_get_current_buf(), s.index
    local cursor, choices = api.nvim_win_get_cursor(s.win)[1], {}
    local selected = selected_item(s)
    if selected and vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win)) then
        if selected.note.author == "agent" then
            M.reply()
        else
            composer.open_item(selected, s.presentation)
        end
        return
    end
    for _, item in ipairs(file_notes(s)) do
        local target = item.note.target
        if cursor >= target.first and cursor <= target.last then choices[#choices + 1] = item end
    end
    local function edit(item)
        -- A picker can complete after the source or review context has changed.
        if
            session ~= s
            or api.nvim_get_current_win() ~= s.win
            or api.nvim_get_current_buf() ~= buf
            or s.index ~= index
        then
            return
        end
        if not selected_source() then return end
        -- The picker may outlive deletion, cancellation, or an edit handoff.
        -- Resolve its identity against live notes instead of reopening stale state.
        local id, live = identity(item), nil
        for _, candidate in ipairs(composer.review_items(s.id)) do
            if identity(candidate) == id then
                live = candidate
                break
            end
        end
        if not live then return end
        item = live
        remember(s)
        s.index = item.note.target.review.piece
        s.pieces[s.index].seen = true
        progress(s)
        select_item(s, item)
        if item.note.author == "agent" then
            M.reply()
        else
            composer.open_item(item, s.presentation)
        end
    end
    if #choices == 0 then
        vim.notify("No note at cursor; c/C adds one", vim.log.levels.INFO)
    elseif #choices == 1 then
        edit(choices[1])
    else
        vim.ui.select(choices, {
            prompt = "Notes at cursor",
            format_item = function(item)
                return ("[%s] %s"):format(
                    item.note.target.scope,
                    table.concat(item.note.lines, " ")
                )
            end,
        }, function(item)
            if item then edit(item) end
        end)
    end
end

local function action_item()
    local s = session
    if not s then return end
    local active = composer.current_item()
    if active and active.note.target.review and active.note.target.review.session == s.id then
        return s, active
    end
    if api.nvim_get_current_win() == s.win then return s, selected_item(s) end
end

function M.peek()
    local s, item = action_item()
    if not s or not source_matches(s, s.pieces[s.index], api.nvim_win_get_buf(s.win)) then
        return
    end
    local row = api.nvim_win_get_cursor(s.win)[1]
    local piece = cursor_piece(s, row)
    if not piece then return end
    composer.change_display(function()
        if s.peek_piece == piece then
            clear_peek(s)
        else
            s.peek_piece = piece
            s.peek_anchor = row
            if item and s.pieces[item.note.target.review.piece] == piece then
                s.peek_target = item.note.target
            else
                s.peek_target = { first = row, last = row, scope = "line" }
            end
        end
        update_inline(s)
        peek.reveal(s.peek)
    end)
end

function M.full_diff()
    local s = session
    if not s then return end
    composer.close(true)
    peek.full(s.pieces[s.index])
end

function M.discard()
    local _, item = action_item()
    if item then composer.discard(item) end
end

function M.delete_note()
    local s = session
    if not s or api.nvim_get_current_win() ~= s.win then return end
    if s.thread and type(s.thread.key) == "string" then
        local message = selected_message(s)
        vim.notify(
            message
                    and message.conclusion
                    and "Conclusion history cannot be deleted; edit or reopen it"
                or "Agent replies are read-only; reply or copy into a draft",
            vim.log.levels.INFO
        )
        return
    end
    cancel_thread(s)
    local item = selected_item(s)
    if not item then
        vim.notify("Select a note with Ctrl+N/P before deleting", vim.log.levels.INFO)
        return
    end
    if item.note.author == "agent" then
        vim.notify("Agent findings are read-only; reply to discuss them", vim.log.levels.INFO)
        return
    end
    if item.state == "draft" then
        vim.notify("This is a new draft; discard it instead", vim.log.levels.INFO)
        return
    end
    if not vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win)) then
        vim.notify("Return to the unchanged selected note before deleting", vim.log.levels.INFO)
        return
    end
    cancel_deletion(s)
    local pending = { id = identity(item), buf = api.nvim_get_current_buf(), saved_maps = {} }
    s.deletion = pending
    for i, key in ipairs(cancel_keys) do
        pending.saved_maps[i] = vim.fn.maparg(key, "n", false, true)
        vim.keymap.set("n", key, function()
            cancel_deletion(s)
            update_inline(s)
        end, { buffer = pending.buf, nowait = true, desc = "Cancel note deletion" })
    end
    update_inline(s)
end

function M.help()
    local s = session
    if not s or api.nvim_get_current_win() ~= s.win then return end
    local hotkeys, overrides = {}, {}
    if s.thread then
        for _, binding in ipairs(thread_bindings) do
            overrides[binding[1]] = true
        end
    end
    for _, binding in ipairs(bindings) do
        local description = binding[4]
        if s.deletion and binding[2] == "<CR>" then
            description = "Confirm selected note deletion"
        end
        if binding[1] ~= "n" or not overrides[binding[2]] then
            hotkeys[#hotkeys + 1] =
                { mode = binding[1], key = binding[2], description = description }
        end
    end
    if s.thread then
        for _, binding in ipairs(thread_bindings) do
            hotkeys[#hotkeys + 1] = { mode = "n", key = binding[1], description = binding[3] }
        end
    end
    if s.deletion then
        for _, key in ipairs(cancel_keys) do
            hotkeys[#hotkeys + 1] = { mode = "n", key = key, description = "Cancel note deletion" }
        end
    end
    mode_help.toggle(s.thread and "Thread hotkeys" or "Review hotkeys", hotkeys)
end

function M.stop()
    mode_help.close()
    local s = session
    if not s then return end
    cancel_deletion(s)
    cancel_thread(s)
    composer.close(false)
    session = nil
    api.nvim_del_augroup_by_id(s.group)
    stop_activity(s)
    unmap(s)
    inline.clear(s.inline)
    gutter.clear(s.gutter)
    M.status = ""
    peek.clear(s.peek)
    api.nvim_exec_autocmds(
        "User",
        { pattern = "ParleyReviewChanged", data = { status = M.status } }
    )
    api.nvim_exec_autocmds("User", {
        pattern = "ParleyReviewStopped",
        data = { window = s.win },
    })
    for _, buf in pairs(s.snapshots) do
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
    end
    if s.remote then s.remote.stop(s) end
    vim.notify("Review exited; local notes retained", vim.log.levels.INFO)
end

---Attach Pi-owned frozen evidence; no editor-side VCS capture or refresh.
---A no-argument call retains the recovery entry point through connected discovery.
function M.start(frozen, remote)
    if not frozen then
        require("parley.connected").start()
        return
    end
    if not remote then
        vim.notify("Frozen review requires a Pi connection; use :ReviewStart", vim.log.levels.WARN)
        return
    end
    if session then
        vim.notify("Already in review mode", vim.log.levels.INFO)
        return
    end
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    if api.nvim_win_get_config(win).relative ~= "" or vim.bo[buf].buftype ~= "" then
        vim.notify("Start review from an ordinary source window", vim.log.levels.WARN)
        return
    end
    local pieces = pieces_for(frozen.files)
    if #pieces == 0 then
        vim.notify("No changed files", vim.log.levels.INFO)
        return
    end
    local s = {
        id = remote.local_id,
        remote = remote,
        root = frozen.root,
        vcs = frozen.vcs,
        pieces = pieces,
        files = frozen.files,
        index = 1,
        win = win,
        inline = inline.open(win),
        gutter = gutter.open(win),
        peek = peek.open(win),
        stale = false,
        snapshots = {},
        buffer_maps = {},
        projections = {},
        group = api.nvim_create_augroup("ParleyReview", { clear = true }),
    }
    session = s
    s.presentation = {
        namespace = inline.namespace,
        select = function(items, options, done)
            -- A UI picker borrows focus, just like the composer. Keep the exact thread
            -- until its callback has returned and the picker has closed its window.
            local token = {}
            s.prompt = token
            local ok, err = pcall(vim.ui.select, items, options, function(choice)
                vim.schedule(function()
                    if session ~= s or s.prompt ~= token then return end
                    s.prompt = nil
                    done(choice)
                end)
            end)
            if not ok then
                s.prompt = nil
                error(err)
            end
        end,
        concluded = function(id)
            -- Only explicit, acknowledged saves select the new tail. Polling never does.
            if session ~= s or api.nvim_get_current_win() ~= s.win then return end
            for _, message in ipairs(thread.messages(composer.review_items(s.id))) do
                if message.conclusion and message.conclusion.id == id then
                    focus_message(s, message, message.root)
                    return
                end
            end
        end,
        reserve = function(target, lines, draft)
            if s.peek_piece == s.pieces[target.review.piece] then
                s.peek_target, s.peek_anchor = target, target.last
            end
            s.inline.reservation = {
                buf = api.nvim_win_get_buf(s.win),
                row = target.last,
                lines = lines,
                id = identity({ note = draft }),
                thread = draft.auxiliary_key and (s.thread and s.thread.key or s.selected) or nil,
            }
            update_inline(s)
            return s.inline.reservation.offset or 0
        end,
        release = function() s.inline.reservation = nil end,
    }
    api.nvim_exec_autocmds("User", {
        pattern = "ParleyReviewStarted",
        data = { window = win },
    })
    api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
        group = s.group,
        callback = function()
            if api.nvim_get_current_win() == s.win then
                local pending = s.deletion ~= nil
                -- Entering the reserved editor is not leaving its thread. Cancelling
                -- here changes scrolloff/cards during focus transfer and invalidates
                -- the composer before it can accept input.
                if s.prompt or composer.owns_source_window(s.win) then return end
                local navigating = s.thread ~= nil
                cancel_thread(s)
                cancel_deletion(s)
                if pending or navigating then update_inline(s) end
            end
        end,
    })
    api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        group = s.group,
        callback = function()
            if session ~= s or s.restoring_maps then return end
            map_source(s)
            if api.nvim_get_current_win() == s.win then
                progress(s)
            elseif s.peek_piece then
                -- Editing this hunk's note is still part of the same visit.
                local item = composer.current_item()
                local owner = item and item.note.target.review
                if not owner or owner.session ~= s.id then clear_peek(s) end
            end
        end,
    })
    api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        group = s.group,
        callback = function(args)
            if api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == args.buf then
                progress(s)
            end
        end,
    })
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = s.group,
        callback = function()
            if api.nvim_get_current_win() ~= s.win then return end
            local moved_selection = s.selected
                and not vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win))
            if moved_selection then
                cancel_thread(s)
                s.selected, s.selection_cursor = nil, nil
            end
            if moved_selection or s.peek_piece then update_inline(s) end
        end,
    })
    api.nvim_create_autocmd("ModeChanged", {
        group = s.group,
        pattern = "n:*",
        callback = function()
            if api.nvim_get_current_win() ~= s.win then return end
            if s.prompt then return end
            if s.thread or s.deletion then
                cancel_thread(s)
                cancel_deletion(s)
                update_inline(s)
            end
        end,
    })
    api.nvim_create_autocmd("WinClosed", {
        group = s.group,
        callback = function(args)
            local closed = tonumber(args.match)
            if closed == s.win then cancel_thread(s) end
        end,
    })
    api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
        group = s.group,
        callback = function()
            if api.nvim_win_is_valid(s.win) then update_inline(s) end
        end,
    })
    api.nvim_create_autocmd("OptionSet", {
        group = s.group,
        pattern = { "number", "relativenumber", "numberwidth", "signcolumn", "statuscolumn" },
        callback = function()
            if api.nvim_win_is_valid(s.win) then update_inline(s) end
        end,
    })
    api.nvim_create_autocmd("User", {
        group = s.group,
        pattern = "ParleyReviewNotesChanged",
        callback = function(event)
            if not api.nvim_win_is_valid(s.win) then return end
            local data = event.data
            if data and data.auxiliary then
                progress(s)
                return
            end
            cancel_deletion(s)
            if data and data.target.review and data.target.review.session == s.id then
                s.selected = data.note
                s.selection_cursor = api.nvim_win_get_cursor(s.win)
            end
            if not selected_item(s) then
                s.selected, s.selection_cursor = nil, nil
            end
            if s.remote then s.remote.changed(s) end
            progress(s)
        end,
    })
    remote.start(s)
    local first = 1
    if remote.in_stage then
        for index, piece in ipairs(s.pieces) do
            if remote.in_stage(piece.file.path) then
                first = index
                break
            end
        end
    end
    visit(s, first, true)
end

---Refresh replies/status without replacing human edits or their undo buffers.
function M.refresh()
    local s = session
    if not s or not api.nvim_win_is_valid(s.win) then return end
    progress(s)
end

function M.reply()
    if session and session.thread then
        M.reply_message()
        return
    end
    local s = session
    if not s or not s.remote then return end
    local item = selected_item(s)
    if not item or item.state ~= "saved" then
        vim.notify("Select a saved note before replying", vim.log.levels.WARN)
        return
    end
    local note = item.note
    if not note.remote_id then
        vim.notify("Save the note before replying", vim.log.levels.WARN)
        return
    end
    if not selected_source() then return end
    if not vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win)) then
        vim.notify("Return to the selected note before replying", vim.log.levels.WARN)
        return
    end
    -- The common reply action continues the latest agent response without a picker.
    -- Its exact durable parent is retained even when display metadata is omitted.
    local replies = note.replies or {}
    local parent = #replies > 0 and replies[#replies].id or note.remote_id
    composer.reply(note, parent, s.presentation)
end

---Attachment is workspace-owned; closing its latest display window does not detach it.
function M.is_active() return session ~= nil end
---Borrow the active source window identity; nil means review is inactive.
---@return integer?
function M.active_window() return session and session.win end

return M
