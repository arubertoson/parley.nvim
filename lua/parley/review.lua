-- Extracted from arubertoson/nvim: lua/aru/workspace/review.lua.
---Parley's frozen navigation and editor lifecycle; connected review ownership lives in Pi.
local M = { status = "" }
local api = vim.api
local snapshot = require("parley.snapshot")
local composer = require("parley.composer")
local inline = require("parley.inline")
local peek = require("parley.comparison")
local mode_help = require("parley.help")

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
---@field index integer
---@field win integer
---@field original_buf integer
---@field original_view table
---@field inline ParleyReviewInline
---@field peek ParleyReviewPeek
---@field peek_piece ParleyReviewPiece? Revealed only until the source leaves this hunk.
---@field peek_target ParleyReviewPeekTarget?
---@field peek_anchor integer? Source row above which the excerpt is displayed.
---@field presentation ParleyReviewComposer.Presentation
---@field stale boolean
---@field group integer
---@field snapshots table<string, integer>
---@field mapped_buf integer?
---@field saved_maps table[]
---@field selected integer? Saved note ID, or recovery draft; edits keep committed identity.
---@field selection_cursor integer[]? Cursor at selection, cleared by ordinary movement.
---@field restoring_maps boolean?
---@field deletion ParleyReviewDeletion? Session-owned inline confirmation and temporary mappings.

---@class ParleyReviewDeletion
---@field id integer Exact saved note identity; never inferred from overlapping targets.
---@field buf integer
---@field saved_maps table[]

---@type ParleyReviewSession?
local session
local request = 0
local serial = 0

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
    { "n", "<CR>", function() M.edit_note() end, "Edit inline note at cursor" },
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
    cancel_deletion(s)
    if not s.mapped_buf then return end
    local buf, saved = s.mapped_buf, s.saved_maps
    s.mapped_buf, s.saved_maps = nil, {}
    s.restoring_maps = true
    if api.nvim_buf_is_valid(buf) then
        api.nvim_buf_call(buf, function()
            for i, binding in ipairs(bindings) do
                vim.keymap.del(binding[1], binding[2], { buffer = buf })
                if saved[i].buffer == 1 then vim.fn.mapset(binding[1], false, saved[i]) end
            end
        end)
    end
    s.restoring_maps = false
end

local function map_source(s)
    if session ~= s or s.restoring_maps or api.nvim_get_current_win() ~= s.win then return end
    local buf = api.nvim_get_current_buf()
    local already_mapped = s.mapped_buf == buf
    if not already_mapped then unmap(s) end
    -- Only the selected piece's source is owned by review mode.
    local piece = s.pieces[s.index]
    local name = api.nvim_buf_get_name(buf)
    if s.remote then
        if s.snapshots[piece.side .. ":" .. piece.file.path] ~= buf then return end
    elseif piece.side == "new" then
        if name ~= vim.fs.joinpath(s.root, piece.file.path) then return end
    elseif s.snapshots[piece.file.path] ~= buf then
        return
    end
    s.mapped_buf = buf
    for i, binding in ipairs(bindings) do
        -- BufEnter may follow WinEnter and reinstall VCSigns' ]c/[c mappings.
        -- Reassert review ownership, but capture the original mappings only once.
        if not already_mapped then
            s.saved_maps[i] = vim.fn.maparg(binding[2], binding[1], false, true)
        end
        vim.keymap.set(
            binding[1],
            binding[2],
            binding[3],
            { buffer = buf, desc = binding[4], nowait = true }
        )
    end
end

local function source_matches(s, piece, buf)
    local text = piece.side == "old" and piece.file.old or piece.file.new
    local owned = s.remote and s.snapshots[piece.side .. ":" .. piece.file.path] == buf
        or piece.side == "old" and s.snapshots[piece.file.path] == buf
        or piece.side == "new"
            and api.nvim_buf_get_name(buf) == vim.fs.joinpath(s.root, piece.file.path)
    if s.remote and not s.snapshots[piece.side .. ":" .. piece.file.path] then return false end
    return owned
        and vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), snapshot.lines(text))
end

local function file_notes(s)
    local piece, items = s.pieces[s.index], {}
    for _, item in ipairs(composer.review_items(s.id)) do
        local owner = item.note.target.review
        if owner.path == piece.file.path and owner.side == piece.side then
            items[#items + 1] = item
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
        and source_matches(s, s.pieces[s.index], pending.buf)
end

local function update_inline(s)
    if s.deletion and not deletion_matches(s) then cancel_deletion(s) end
    local buf = api.nvim_win_get_buf(s.win)
    if s.peek_piece then
        local row = api.nvim_win_get_cursor(s.win)[1]
        if s.stale or row < s.peek_piece.first or row > s.peek_piece.last then clear_peek(s) end
    end
    inline.update(
        s.inline,
        buf,
        s.stale and {} or file_notes(s),
        s.selected,
        s.deletion and s.deletion.id
    )
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
    s.stale = not source_matches(s, piece, api.nvim_win_get_buf(s.win))
    M.status = ("Review %d/%d · %d unseen · %d notes%s%s%s%s"):format(
        s.index,
        #s.pieces,
        remaining,
        notes,
        drafts > 0 and (" · %d drafts"):format(drafts) or "",
        piece.side == "old" and " · OLD" or "",
        s.stale and " · STALE" or "",
        s.remote and (" · " .. s.remote.status()) or ""
    )
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
    local key = s.remote and (side .. ":" .. file.path) or file.path
    local existing = s.snapshots[key]
    if existing and api.nvim_buf_is_valid(existing) then return existing end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(
        buf,
        ("parley://%d/%s/%s"):format(s.id, side, side == "old" and file.old_path or file.path)
    )
    vim.bo[buf].bufhidden = "hide"
    vim.b[buf].parley_oldside = side == "old"
    vim.b[buf].parley_snapshot = true
    api.nvim_buf_set_lines(buf, 0, -1, false, snapshot.lines(file[side]))
    vim.bo[buf].filetype = vim.filetype.match({ filename = file.old_path }) or ""
    vim.bo[buf].modified = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    s.snapshots[key] = buf
    return buf
end

local function visit(s, index, initial)
    cancel_deletion(s)
    composer.close(false)
    if not initial then remember(s) end
    unmap(s)
    inline.clear(s.inline)
    s.index = index
    if s.peek_piece ~= s.pieces[index] then clear_peek(s) end
    s.selected, s.selection_cursor = nil, nil
    local piece = s.pieces[index]
    api.nvim_set_current_win(s.win)
    local buf
    if s.remote or piece.side == "old" then
        buf = frozen_buffer(s, piece.file, piece.side)
    else
        buf = vim.fn.bufadd(vim.fs.joinpath(s.root, piece.file.path))
        vim.fn.bufload(buf)
    end
    api.nvim_win_set_buf(s.win, buf)
    piece.seen = true
    if not source_matches(s, piece, buf) then
        progress(s)
        vim.notify(
            "Frozen review target changed: " .. piece.file.path .. "; comments disabled",
            vim.log.levels.WARN
        )
        map_source(s)
        return
    end
    api.nvim_win_call(s.win, function()
        if piece.view then
            vim.fn.winrestview(piece.view)
        else
            api.nvim_win_set_cursor(s.win, { piece.first, 0 })
            vim.cmd("normal! zvzz")
        end
    end)
    map_source(s)
    progress(s)
end

function M.move(step)
    local s = session
    if not s then return end
    if not api.nvim_win_is_valid(s.win) then
        M.stop()
        return
    end
    if s.deletion then
        cancel_deletion(s)
        update_inline(s)
    end
    local index = s.index + step
    if index < 1 or index > #s.pieces then
        vim.notify("End of review queue", vim.log.levels.INFO)
        return
    end
    visit(s, index)
end

local function selected_source()
    local s = session
    if not s then return end
    if
        api.nvim_get_current_win() ~= s.win
        or not source_matches(s, s.pieces[s.index], api.nvim_get_current_buf())
    then
        vim.notify("Return to the unchanged selected review piece", vim.log.levels.WARN)
        return
    end
    return s, s.pieces[s.index]
end

---Resolve cursor ownership without moving the frozen navigation queue.
local function cursor_piece(s, row)
    local source = s.pieces[s.index]
    for index, piece in ipairs(s.pieces) do
        if
            piece.file == source.file
            and piece.side == source.side
            and row >= piece.first
            and row <= piece.last
        then
            return piece, index
        end
    end
end

local function select_item(s, item)
    if s.peek_piece == s.pieces[item.note.target.review.piece] then
        s.peek_target = item.note.target
    end
    s.selected = identity(item)
    s.selection_cursor = api.nvim_win_get_cursor(s.win)
    update_inline(s)
end

---Navigate the frozen queue's target order, including unfinished edits.
function M.move_note(step)
    local s = session
    if not s or api.nvim_get_current_win() ~= s.win then return end
    if s.deletion then
        cancel_deletion(s)
        update_inline(s)
    end
    local items = composer.review_items(s.id)
    local scope_order = { line = 1, range = 2, hunk = 3 }
    local ordered = {}
    for index, item in ipairs(items) do
        ordered[#ordered + 1] = { item = item, order = index }
    end
    table.sort(ordered, function(a, b)
        local x, y = a.item.note.target, b.item.note.target
        if x.review.piece ~= y.review.piece then return x.review.piece < y.review.piece end
        if x.first ~= y.first then return x.first < y.first end
        if x.last ~= y.last then return x.last < y.last end
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
                    or (target.review.piece == s.index and target.first >= row)
                then
                    next_index = index
                    break
                end
            elseif
                target.review.piece < s.index
                or (target.review.piece == s.index and target.first <= row)
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
    local item, target = entry.item, entry.item.note.target
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
    api.nvim_win_set_cursor(s.win, { target.first, 0 })
    api.nvim_win_call(s.win, function() vim.cmd("normal! zv") end)
    select_item(s, item)
end

function M.comment(scope)
    local s = selected_source()
    if not s then return end
    local piece, index = cursor_piece(s, api.nvim_win_get_cursor(s.win)[1])
    if not piece then
        vim.notify("Comment target must be inside a review piece", vim.log.levels.INFO)
        return
    end
    local first, last
    if scope == "hunk" then
        first, last = piece.first, piece.last
    elseif scope == "range" then
        first, last = vim.fn.line("v"), vim.fn.line(".")
        if first > last then
            first, last = last, first
        end
        local escape = api.nvim_replace_termcodes("<Esc>", true, false, true)
        api.nvim_feedkeys(escape, "nx", false)
    else
        first = api.nvim_win_get_cursor(s.win)[1]
        last = first
    end
    if first < piece.first or last > piece.last then
        vim.notify("Comment target must be inside one review piece", vim.log.levels.INFO)
        return
    end
    piece.seen = true
    progress(s)
    composer.open(
        first,
        last,
        scope,
        { session = s.id, piece = index, path = piece.file.path, side = piece.side },
        s.presentation
    )
end

function M.edit_note()
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
        composer.open_item(selected, s.presentation)
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
        composer.open_item(item, s.presentation)
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
    local item = selected_item(s)
    if not item then
        vim.notify("Select a note with Ctrl+N/P before deleting", vim.log.levels.INFO)
        return
    end
    if item.state == "draft" then
        vim.notify("This is a new draft; discard it instead", vim.log.levels.INFO)
        return
    end
    if
        not vim.deep_equal(s.selection_cursor, api.nvim_win_get_cursor(s.win))
        or not source_matches(s, s.pieces[s.index], api.nvim_get_current_buf())
    then
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
    local hotkeys = {}
    for _, binding in ipairs(bindings) do
        local description = binding[4]
        if s.deletion and binding[2] == "<CR>" then
            description = "Confirm selected note deletion"
        end
        hotkeys[#hotkeys + 1] = { mode = binding[1], key = binding[2], description = description }
    end
    if s.deletion then
        for _, key in ipairs(cancel_keys) do
            hotkeys[#hotkeys + 1] = { mode = "n", key = key, description = "Cancel note deletion" }
        end
    end
    mode_help.toggle("Review hotkeys", hotkeys)
end

function M.stop()
    request = request + 1
    mode_help.close()
    local s = session
    if not s then return end
    cancel_deletion(s)
    composer.close(false)
    session = nil
    api.nvim_del_augroup_by_id(s.group)
    unmap(s)
    inline.clear(s.inline)
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
    if api.nvim_win_is_valid(s.win) then
        if api.nvim_buf_is_valid(s.original_buf) then
            api.nvim_win_set_buf(s.win, s.original_buf)
            api.nvim_set_current_win(s.win)
            api.nvim_win_call(s.win, function() vim.fn.winrestview(s.original_view) end)
        end
    end
    for _, buf in pairs(s.snapshots) do
        if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
    end
    if s.remote then s.remote.stop(s) end
    vim.notify("Review exited; local notes retained", vim.log.levels.INFO)
end

---Without a supplied snapshot this internal entry point retains the standalone prototype loop.
---The public start action uses Pi discovery and passes an owned frozen record.
function M.start(frozen, remote)
    if session then
        vim.notify("Already in review mode", vim.log.levels.INFO)
        return
    end
    local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    if api.nvim_win_get_config(win).relative ~= "" or vim.bo[buf].buftype ~= "" then
        vim.notify("Start review from an ordinary source window", vim.log.levels.WARN)
        return
    end
    request = request + 1
    local current_request = request
    local cwd = vim.uv.cwd()
    local function begin(result, err)
        if
            request ~= current_request
            or vim.uv.cwd() ~= cwd
            or not api.nvim_win_is_valid(win)
            or api.nvim_get_current_win() ~= win
            or api.nvim_win_get_buf(win) ~= buf
        then
            return
        end
        if not result then
            vim.notify(err, vim.log.levels.ERROR)
            return
        end
        local pieces = pieces_for(result.files)
        if #pieces == 0 then
            vim.notify("No changed files", vim.log.levels.INFO)
            return
        end
        serial = serial + 1
        local s = {
            id = remote and remote.local_id or serial,
            remote = remote,
            root = result.root,
            vcs = result.vcs,
            pieces = pieces,
            index = 1,
            win = win,
            original_buf = buf,
            original_view = api.nvim_win_call(win, vim.fn.winsaveview),
            inline = inline.open(win),
            peek = peek.open(win),
            stale = false,
            snapshots = {},
            saved_maps = {},
            group = api.nvim_create_augroup("ParleyReview", { clear = true }),
        }
        session = s
        s.presentation = {
            namespace = inline.namespace,
            reserve = function(target, lines)
                if s.peek_piece == s.pieces[target.review.piece] then
                    s.peek_target, s.peek_anchor = target, target.last
                end
                s.inline.reservation =
                    { buf = api.nvim_win_get_buf(s.win), row = target.last, lines = lines }
                update_inline(s)
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
                    unmap(s)
                    if pending then update_inline(s) end
                end
            end,
        })
        api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
            group = s.group,
            callback = function()
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
                    s.selected, s.selection_cursor = nil, nil
                end
                if moved_selection or s.peek_piece then update_inline(s) end
            end,
        })
        api.nvim_create_autocmd("ModeChanged", {
            group = s.group,
            pattern = "n:*",
            callback = function()
                if s.deletion then
                    cancel_deletion(s)
                    update_inline(s)
                end
            end,
        })
        api.nvim_create_autocmd("WinClosed", {
            group = s.group,
            callback = function(args)
                local closed = tonumber(args.match)
                if closed == s.win then
                    vim.schedule(function()
                        if session == s then M.stop() end
                    end)
                end
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
        if remote then remote.start(s) end
        visit(s, 1, true)
    end
    if frozen then
        begin(frozen)
    else
        snapshot.collect(cwd, begin)
    end
end

---Refresh replies/status without replacing human edits or their undo buffers.
function M.refresh()
    if session and api.nvim_win_is_valid(session.win) then progress(session) end
end

function M.reply()
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
    local choices = { { id = note.remote_id, text = table.concat(note.lines, "\n") } }
    for _, reply in ipairs(note.replies or {}) do
        choices[#choices + 1] = reply
    end
    vim.ui.select(choices, {
        prompt = "Reply to:",
        format_item = function(reply) return reply.text end,
    }, function(reply)
        if not reply or session ~= s or not selected_item(s) then return end
        composer.reply(note, reply.id, s.presentation)
    end)
end

---Borrow the active source window identity; nil means review is inactive.
---@return integer?
function M.active_window() return session and session.win end

return M
