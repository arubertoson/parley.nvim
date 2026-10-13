-- Extracted from arubertoson/nvim: lua/aru/workspace/review_composer.lua.
---Parley's in-memory reserved-space composer.
---Explicit closure commits or cancels. Context interruptions retain locked recovery drafts.
---Hidden editor buffers own each note's in-memory undo history until note deletion.
---Requires Neovim's experimental window-scoped namespace API.
local M = {}
---@type ParleyReviewComposer.Draft[] Saved in-memory notes; mutated only by composer actions.
M.comments = {}
---Read-only agent findings live separately from human notes and never enter saves.
M.findings = {}
local api = vim.api
local style = require("parley.style")
local mode_help = require("parley.help")
local ns = api.nvim_create_namespace("parley.composer")
local display_ns = api.nvim_create_namespace("parley.composer.display")
local display_options = {
    "wrap",
    "linebreak",
    "foldenable",
    "foldmethod",
    "foldlevel",
    "winbar",
    "number",
    "numberwidth",
    "signcolumn",
    "statuscolumn",
    "breakindent",
    "showbreak",
    "conceallevel",
}

---@class ParleyReviewComposer.Owner
---@field session integer Frozen review session identity, not a Neovim handle.
---@field piece integer Index into that session's frozen navigation queue.
---@field path string Repository-relative path.
---@field side 'old'|'new'
---@field source_id string? Explicit immutable supplemental evidence identity.

---@class ParleyReviewComposer.Anchor
---@field first integer Immutable frozen-source coordinate, never editor placement.
---@field last integer
---@field context string[]

---@alias ParleyReviewVirtualLine string[][] Dense { text, highlight } chunks.

---@class ParleyReviewComposer.Target
---@field path string
---@field first integer
---@field last integer
---@field scope 'line'|'range'|'hunk'
---@field context string[]
---@field review ParleyReviewComposer.Owner? Absent for standalone composition.
---@field anchor ParleyReviewComposer.Anchor? Durable coordinates; other fields describe editor placement.
---@field outdated boolean? No conservative placement in the current workspace buffer.

---@class ParleyReviewComposer.Draft
---@field id integer
---@field target ParleyReviewComposer.Target
---@field lines string[]
---@field cursor integer[]
---@field comment ParleyReviewComposer.Draft? Borrowed committed note being edited; saved notes have no parent.
---@field remote_id string? Stable durable note identity, assigned by the connection owner.
---@field reply_to string? Explicit durable note/reply parent.
---@field replies { id: string, replyTo: string, text: string }[]? Acknowledged agent replies.
---@field author 'agent'? Explicit origin for immutable initial findings.

---@class ParleyReviewComposer.Item
---@field note ParleyReviewComposer.Draft
---@field state 'saved'|'draft'|'editing'

---@class ParleyReviewComposer.Presentation
---@field namespace integer
---@field reserve fun(target: ParleyReviewComposer.Target, lines: ParleyReviewVirtualLine[], draft: ParleyReviewComposer.Draft): integer? Display rows before the editor room.
---@field release fun()
---@field select fun(items: string[], options: table, done: fun(choice: string?))? Review-owned focus borrowing.
---@field concluded fun(id: string)? Select a conclusion after an explicit acknowledged save.

---@class ParleyReviewComposer.Session
---@field draft ParleyReviewComposer.Draft
---@field source_buf integer
---@field source_win integer
---@field source_view table
---@field buf integer
---@field win integer
---@field mark integer
---@field group integer
---@field rows integer
---@field refreshing boolean
---@field resize_pending boolean
---@field closing boolean
---@field display table Source context captured after the last composer layout.
---@field presentation ParleyReviewComposer.Presentation? Review owns the shared note/editor room.

---@type ParleyReviewComposer.Session?
local session
---@type ParleyReviewComposer.Draft[]
local drafts = {}
---@type ParleyReviewComposer.Draft?
local last_draft
local serial = 0

---@class ParleyReviewComposer.Editor
---@field buf integer Hidden editor buffer, owned for the note's lifetime.
---@field committed integer Undo sequence at the last accepted text (zero for a new note).

---@type table<integer, ParleyReviewComposer.Editor>
local editors = {}

---@param note ParleyReviewComposer.Draft
---@return integer
local function editor_id(note) return (note.comment or note).id end

local function release_editor(note)
    local id = editor_id(note)
    local editor = editors[id]
    if not editor then return end -- A target may be rejected before any editor is created.
    editors[id] = nil
    if api.nvim_buf_is_valid(editor.buf) then api.nvim_buf_delete(editor.buf, { force = true }) end
end

local function sync_undo(buf)
    -- Neovim documents this assignment as closing the current undo block,
    -- including an Insert-mode block, without changing the option's value.
    vim.bo[buf].undolevels = vim.bo[buf].undolevels
end

local function history_label(s)
    local tree = vim.fn.undotree(s.buf)
    local position = 1 -- The text before the oldest retained undo block.
    for index, entry in ipairs(tree.entries) do
        if entry.seq == tree.seq_cur then position = index + 1 end
    end
    local saved = s.draft.comment and tree.seq_cur == editors[editor_id(s.draft)].committed
    return ("history %d/%d · %s"):format(
        position,
        #tree.entries + 1,
        saved and "saved" or "unsaved"
    )
end

---Native undo has no pruning operation. Rebuild only the accepted ancestry,
---in the same owned buffer, so neither redo nor alternate-branch commands can
---resurrect discarded future text. Ordinary latest-version commits do no work.
local function prune_history(buf)
    local tree = vim.fn.undotree(buf)
    local branched = false
    for _, entry in ipairs(tree.entries) do
        if entry.alt then
            branched = true
            break
        end
    end
    if tree.seq_cur == tree.seq_last and not branched then return end
    api.nvim_buf_call(buf, function()
        local states = { api.nvim_buf_get_lines(buf, 0, -1, false) }
        for _ = 1, #tree.entries do
            local seq = vim.fn.undotree().seq_cur
            vim.cmd("silent undo")
            if vim.fn.undotree().seq_cur == seq then break end -- Oldest retained state.
            states[#states + 1] = api.nvim_buf_get_lines(buf, 0, -1, false)
        end
        local levels = vim.bo[buf].undolevels
        vim.bo[buf].undolevels = -1
        api.nvim_buf_set_lines(buf, 0, -1, false, states[#states])
        sync_undo(buf)
        vim.bo[buf].undolevels = levels
        for index = #states - 1, 1, -1 do
            if not vim.deep_equal(states[index], states[index + 1]) then
                api.nvim_buf_set_lines(buf, 0, -1, false, states[index])
                sync_undo(buf)
            end
        end
    end)
end

local function next_id()
    serial = serial + 1
    return serial
end

---Project this session's notes and unfinished edits without duplicating saved notes.
---@param id integer
---@return ParleyReviewComposer.Item[]
function M.review_items(id)
    local items = {}
    for _, note in ipairs(M.comments) do
        local owner = note.target.review
        if owner and owner.session == id then
            local item = { note = note, state = "saved" }
            for _, draft in ipairs(drafts) do
                if draft.comment == note then item = { note = draft, state = "editing" } end
            end
            items[#items + 1] = item
        end
    end
    for _, note in ipairs(M.findings) do
        if note.target.review.session == id then
            items[#items + 1] = { note = note, state = "saved" }
        end
    end
    for _, draft in ipairs(drafts) do
        local owner = draft.target.review
        if owner and owner.session == id and not draft.comment and not draft.auxiliary_key then
            items[#items + 1] = { note = draft, state = "draft" }
        end
    end
    return items
end

local function remove_draft(note)
    for index, draft in ipairs(drafts) do
        if draft == note then
            table.remove(drafts, index)
            break
        end
    end
    last_draft = drafts[#drafts]
end

local function empty(note) return table.concat(note.lines, "\n"):match("^%s*$") ~= nil end

local function source_available(s)
    return api.nvim_buf_is_valid(s.source_buf)
        and api.nvim_win_is_valid(s.source_win)
        and api.nvim_win_get_buf(s.source_win) == s.source_buf
end

local function save_draft(s)
    if api.nvim_buf_is_valid(s.buf) then
        s.draft.lines = api.nvim_buf_get_lines(s.buf, 0, -1, false)
        if api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf then
            s.draft.cursor = api.nvim_win_get_cursor(s.win)
        end
    end
end

---Internal interruption boundary: preserve unfinished text at its original target.
---Explicit editor exits use commit or cancel instead.
---@param restore boolean? Restore the source viewport only for an explicit return.
function M.close(restore)
    local s = session
    if not s then return end
    mode_help.close()
    session = nil
    save_draft(s)
    local drop = not s.draft.comment and empty(s.draft)
    if drop then remove_draft(s.draft) end
    api.nvim_del_augroup_by_id(s.group)
    if api.nvim_get_current_win() == s.win then vim.cmd.stopinsert() end
    if restore and source_available(s) then
        api.nvim_win_call(s.source_win, function() vim.fn.winrestview(s.source_view) end)
    end
    if s.presentation then s.presentation.release() end
    if api.nvim_buf_is_valid(s.source_buf) then
        api.nvim_buf_clear_namespace(s.source_buf, ns, 0, -1)
    end
    -- Replace the room with inactive text before closing the float fires focus
    -- autocommands, which may redraw the screen (e.g. statusline refreshes).
    api.nvim_exec_autocmds("User", {
        pattern = "ParleyReviewNotesChanged",
        data = {
            note = (s.draft.comment or s.draft).id,
            target = s.draft.target,
            auxiliary = s.draft.auxiliary_key ~= nil,
        },
    })
    if api.nvim_win_is_valid(s.win) and api.nvim_win_get_buf(s.win) == s.buf then
        api.nvim_win_close(s.win, true)
    end
    if drop then release_editor(s.draft) end
    if restore and source_available(s) then api.nvim_set_current_win(s.source_win) end
end

local function target_unchanged(s)
    return s.draft.target.last <= api.nvim_buf_line_count(s.source_buf)
        and vim.deep_equal(
            api.nvim_buf_get_lines(
                s.source_buf,
                s.draft.target.first - 1,
                s.draft.target.last,
                false
            ),
            s.draft.target.context
        )
end

-- Unlike screenpos(), these queries observe folds, wrapping, and virtual lines
-- before a redraw. The fingerprint is bounded by the viewport, not file size.
local function display_signature(s)
    if not source_available(s) or s.draft.target.last > api.nvim_buf_line_count(s.source_buf) then
        return nil
    end
    return api.nvim_win_call(s.source_win, function()
        local view = vim.fn.winsaveview()
        local last = s.draft.target.last
        local height = api.nvim_win_get_height(s.source_win)
        local options = {}
        for _, name in ipairs(display_options) do
            options[name] = vim.wo[s.source_win][name]
        end
        local before, after = -1, -1
        if view.topline <= last then
            before = api.nvim_win_text_height(s.source_win, {
                start_row = view.topline - 1,
                end_row = last - 1,
                max_height = height + 1,
            }).all
            local opts = { start_row = view.topline - 1, max_height = height + 1 }
            if last < api.nvim_buf_line_count(s.source_buf) then
                opts.end_row, opts.end_vcol = last, 0
            end
            after = api.nvim_win_text_height(s.source_win, opts).all
        end
        return {
            tick = api.nvim_buf_get_changedtick(s.source_buf),
            cursor = api.nvim_win_get_cursor(s.source_win),
            position = api.nvim_win_get_position(s.source_win),
            width = api.nvim_win_get_width(s.source_win),
            height = height,
            options = options,
            topline = view.topline,
            topfill = view.topfill,
            leftcol = view.leftcol,
            skipcol = view.skipcol,
            fold = vim.fn.foldclosed(last),
            before = before,
            after = after,
        }
    end)
end

local function geometry(s, reveal)
    local target = s.draft.target
    -- Do not cover virtual diff text or other plugins' display-space editors.
    for _, mark in
        ipairs(
            api.nvim_buf_get_extmarks(
                s.source_buf,
                -1,
                { target.last - 1, 0 },
                { target.last - 1, -1 },
                { details = true }
            )
        )
    do
        if
            mark[4].ns_id ~= ns
            and (not s.presentation or mark[4].ns_id ~= s.presentation.namespace)
            and mark[4].virt_lines
            and not mark[4].virt_lines_above
        then
            return nil
        end
    end
    local winbar_rows = vim.wo[s.source_win].winbar ~= "" and 1 or 0
    local height = api.nvim_win_get_height(s.source_win) - winbar_rows
    local width = api.nvim_win_get_width(s.source_win)
    if height < 8 or width < 24 then return nil end
    local indent, content_width, padding = style.layout(s.source_win, target.first)
    local label = s.draft.label or style.label(target)
    local heading = style.wrap(label .. " · editing · " .. history_label(s), content_width)
    local max_content_height = height - #heading - 4
    if max_content_height < 1 then return nil end
    -- Let Neovim measure its word wrapping; character-width estimates undercount it.
    api.nvim_win_set_config(s.win, { width = content_width })
    local content_rows = api.nvim_win_text_height(s.win, {
        start_row = 0,
        end_row = api.nvim_buf_line_count(s.buf) - 1,
        max_height = 7,
    }).all
    local content_height = math.min(math.max(1, content_rows), 6, max_content_height)
    s.rows = content_height + #heading + 2 -- Top margin, metadata, editor, bottom margin.
    local blanks = {}
    for _ = 1, s.rows do
        blanks[#blanks + 1] = style.card_line(indent, content_width, padding, {}, false)
    end
    for i, text in ipairs(heading) do
        blanks[i + 1] = style.card_line(
            indent,
            content_width,
            padding,
            { { text, "ParleyReviewNoteHeading" } },
            false
        )
    end
    local preceding = 0
    if s.presentation then
        preceding = s.presentation.reserve(target, blanks, s.draft) or 0
    else
        api.nvim_buf_set_extmark(s.source_buf, ns, target.last - 1, 0, {
            id = s.mark,
            virt_lines = blanks,
            virt_lines_leftcol = true,
            priority = 200,
        })
    end
    local config
    api.nvim_win_call(s.source_win, function()
        if reveal then
            api.nvim_win_set_cursor(s.source_win, { target.last, 0 })
            vim.cmd("normal! zv")
        elseif vim.fn.foldclosed(target.last) ~= -1 then
            return
        end
        local function space()
            local view = vim.fn.winsaveview()
            if view.topline > target.last then return nil end
            -- Measure layout without drawing an intermediate blank reservation.
            -- Filler above topline is only partially visible (topfill), while
            -- skipcol excludes any wrapped rows scrolled off the top.
            -- An explicit end_row excludes our reservation below the target.
            local row = api.nvim_win_text_height(s.source_win, {
                start_row = view.topline - 1,
                start_vcol = view.skipcol,
                end_row = target.last - 1,
                max_height = height + 1,
            }).all + view.topfill + preceding
            -- Keep room for at least one display row below, except at EOF.
            local below = target.last < api.nvim_buf_line_count(s.source_buf) and 1 or 0
            if row + s.rows + below > height then return nil end
            return row
        end
        local row = space()
        if not row and reveal then
            api.nvim_win_set_cursor(s.source_win, { target.last, 0 })
            vim.cmd("normal! zt")
            row = space()
        end
        if not row then return end
        config = {
            relative = "win",
            win = s.source_win,
            row = row + #heading + 1,
            col = indent,
            width = content_width,
            height = content_height,
            style = "minimal",
            border = "none",
            zindex = 60,
            hide = false,
        }
    end)
    return config
end

local function refresh(s, reveal)
    if session ~= s or s.refreshing then return end
    if not source_available(s) or not api.nvim_buf_is_valid(s.buf) then
        M.close(false)
        return
    end
    if not target_unchanged(s) then
        M.close(false)
        vim.notify("Review draft retained: source target changed", vim.log.levels.WARN)
        return
    end
    s.refreshing = true
    local config = geometry(s, reveal)
    s.refreshing = false
    if not config then
        M.close(false)
        vim.notify(
            "Review draft retained: no unobscured display space; resume at its target",
            vim.log.levels.INFO
        )
        return
    end
    api.nvim_win_set_config(s.win, config)
    s.display = display_signature(s)
end

---An explicit review-owned display action may reflow its own room. External
---source/view changes still invalidate the composer rather than realigning it.
function M.change_display(change)
    local s = session
    if not s then
        change()
        return
    end
    if s.closing or not vim.deep_equal(s.display, display_signature(s)) then
        M.close(false)
        return
    end
    s.refreshing = true
    change()
    s.refreshing = false
    refresh(s, true)
end

local function schedule_close(s)
    if s.closing then return end
    s.closing = true
    save_draft(s)
    if api.nvim_win_is_valid(s.win) then api.nvim_win_set_config(s.win, { hide = true }) end
    vim.schedule(function()
        if session == s then M.close(false) end
    end)
end

-- Only edits to the draft may resize the composer. Source changes never trigger
-- realignment: hide now, then close outside the redraw/autocommand callback.
local function invalidate_display()
    local s = session
    if not s or s.refreshing or s.closing then return end
    if not vim.deep_equal(s.display, display_signature(s)) then schedule_close(s) end
end

local function schedule_resize(s)
    if s.resize_pending or s.closing then return end
    s.resize_pending = true
    vim.schedule(function()
        s.resize_pending = false
        if session ~= s or s.closing then return end
        if not vim.deep_equal(s.display, display_signature(s)) then
            schedule_close(s)
        else
            refresh(s, false)
        end
    end)
end

api.nvim_set_decoration_provider(display_ns, {
    on_start = invalidate_display,
    on_win = function(_, win)
        if session and win == session.source_win then invalidate_display() end
        return false
    end,
})

local function commit()
    local s = assert(session)
    if s.saving or s.draft.saving then return end
    if s.closing or not vim.deep_equal(s.display, display_signature(s)) then
        M.close(false)
        vim.notify("Review draft retained: source context changed", vim.log.levels.WARN)
        return
    end
    save_draft(s)
    if empty(s.draft) then
        if not s.draft.comment then
            M.close(true)
            return
        end
        vim.notify(
            "Empty text does not delete a saved note; cancel or use confirmed deletion",
            vim.log.levels.INFO
        )
        return
    end
    if s.draft.on_save then
        s.saving = true
        s.draft.saving = true
        vim.bo[s.buf].modifiable = false
        local lines = vim.deepcopy(s.draft.lines)
        s.draft.on_save(lines, function(ok, err)
            s.saving = false
            s.draft.saving = false
            if api.nvim_buf_is_valid(s.buf) then vim.bo[s.buf].modifiable = true end
            if not ok then
                vim.notify(
                    "Parley conclusion draft retained: " .. tostring(err),
                    vim.log.levels.WARN
                )
                return
            end
            remove_draft(s.draft)
            if session == s then M.close(true) end
            release_editor(s.draft)
            vim.notify(
                "Parley conclusion saved; no implementation authorized",
                vim.log.levels.INFO
            )
        end)
        return
    end
    sync_undo(s.buf)
    s.refreshing = true
    prune_history(s.buf)
    s.refreshing = false
    editors[editor_id(s.draft)].committed = vim.fn.undotree(s.buf).seq_cur
    vim.bo[s.buf].modified = false
    if s.draft.comment then
        s.draft.comment.lines = vim.deepcopy(s.draft.lines)
        s.draft.comment.cursor = vim.deepcopy(s.draft.cursor)
    else
        M.comments[#M.comments + 1] = s.draft
    end
    remove_draft(s.draft)
    M.close(true)
    vim.notify("Comment saved in memory (Parley)", vim.log.levels.INFO)
end

local function move_history(command)
    local s = assert(session)
    if s.closing or not vim.deep_equal(s.display, display_signature(s)) then
        M.close(false)
        return
    end
    sync_undo(s.buf)
    vim.cmd("silent " .. command)
    refresh(s, false) -- Update the dim history position even when text height is unchanged.
end

---Borrow the locked draft; its owned editor survives closure for native history.
---@param draft ParleyReviewComposer.Draft
---@param presentation ParleyReviewComposer.Presentation?
local function open_draft(draft, presentation)
    if draft.saving then
        vim.notify("Parley conclusion is awaiting acknowledgement", vim.log.levels.INFO)
        return
    end
    local source_win = api.nvim_get_current_win()
    local source_buf = api.nvim_get_current_buf()
    if
        api.nvim_win_get_config(source_win).relative ~= ""
        or (
            vim.bo[source_buf].buftype ~= ""
            and not vim.b[source_buf].parley_snapshot
            and not vim.b[source_buf].parley_oldside
        )
    then
        vim.notify("Open the composer from an ordinary source window", vim.log.levels.WARN)
        return
    end
    if api.nvim_buf_get_name(source_buf) ~= draft.target.path then
        vim.notify(
            "Resume from the original source buffer: " .. draft.target.path,
            vim.log.levels.WARN
        )
        return
    end
    if
        draft.target.last > api.nvim_buf_line_count(source_buf)
        or not vim.deep_equal(
            api.nvim_buf_get_lines(source_buf, draft.target.first - 1, draft.target.last, false),
            draft.target.context
        )
    then
        vim.notify(
            "Draft retained but target changed; Parley does not relocate targets",
            vim.log.levels.WARN
        )
        return
    end
    if session then M.close(false) end
    assert(api.nvim__ns_set, "Parley composer requires Neovim's experimental nvim__ns_set API")
    api.nvim__ns_set(ns, { wins = { source_win } })
    local source_view = vim.fn.winsaveview()
    local editor = editors[editor_id(draft)]
    if not editor then
        local buf = api.nvim_create_buf(false, true)
        api.nvim_buf_set_name(buf, vim.fn.tempname() .. "-Parley Composer.txt")
        -- Unwritten prose outside the workspace can use prose LSPs, but must not
        -- enlist Markdown renderers whose queued work can outlive this editor.
        vim.bo[buf].buftype = ""
        vim.bo[buf].bufhidden = "hide"
        vim.bo[buf].undofile = false -- This history is deliberately in memory only.
        -- Establish the initial text as the history baseline, not an empty no-op edit.
        local levels = vim.bo[buf].undolevels
        vim.bo[buf].undolevels = -1
        api.nvim_buf_set_lines(buf, 0, -1, false, draft.lines)
        sync_undo(buf)
        vim.bo[buf].undolevels = levels
        editor = {
            buf = buf,
            committed = api.nvim_buf_call(buf, function() return vim.fn.undotree().seq_cur end),
        }
        editors[editor_id(draft)] = editor
        vim.bo[buf].filetype = "text"
        vim.bo[buf].syntax = ""
        vim.treesitter.stop(buf) -- Keep the same plain italic presentation as saved notes.
    end
    local buf = editor.buf
    assert(
        api.nvim_buf_is_valid(buf),
        "Review editor and its undo history were removed externally"
    )
    -- Create the float hidden; never display it before a reservation exists.
    local win = api.nvim_open_win(buf, false, {
        relative = "win",
        win = source_win,
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        style = "minimal",
        hide = true,
    })
    local s = {
        draft = draft,
        presentation = presentation,
        source_buf = source_buf,
        source_win = source_win,
        source_view = source_view,
        buf = buf,
        win = win,
        mark = api.nvim_buf_set_extmark(source_buf, ns, draft.target.last - 1, 0, {}),
        group = api.nvim_create_augroup("ParleyReviewComposer", { clear = true }),
        rows = 0,
        refreshing = false,
        resize_pending = false,
        closing = false,
    }
    s.display = display_signature(s)
    session = s
    last_draft = draft
    vim.wo[win].wrap = true
    style.refresh()
    vim.wo[win].linebreak = true
    vim.wo[win].spell = true
    vim.wo[win].winhighlight =
        "Normal:ParleyReviewNoteActive,NormalFloat:ParleyReviewNoteActive,EndOfBuffer:ParleyReviewNoteActive"
    api.nvim_create_autocmd({
        "TextChanged",
        "TextChangedI",
        "TextChangedP",
        "VimResized",
        "WinResized",
        "WinScrolled",
    }, {
        group = s.group,
        callback = function(args)
            if s.refreshing or session ~= s then return end
            if args.buf == s.buf and args.event:match("^TextChanged") then
                schedule_resize(s)
            else
                invalidate_display()
            end
        end,
    })
    api.nvim_create_autocmd({ "BufWinLeave", "BufWipeout", "WinClosed", "WinLeave" }, {
        group = s.group,
        callback = function(args)
            if args.event == "WinClosed" then
                if tonumber(args.match) == s.source_win or tonumber(args.match) == s.win then
                    M.close(false)
                end
            elseif args.event == "WinLeave" then
                if api.nvim_get_current_win() == s.win then schedule_close(s) end
            elseif args.buf == s.source_buf or args.buf == s.buf then
                save_draft(s)
                vim.schedule(function()
                    if
                        session == s
                        and (
                            not source_available(s)
                            or not api.nvim_win_is_valid(s.win)
                            or api.nvim_win_get_buf(s.win) ~= s.buf
                        )
                    then
                        M.close(false)
                    end
                end)
            end
        end,
    })
    api.nvim_create_autocmd("OptionSet", {
        group = s.group,
        pattern = display_options,
        callback = invalidate_display,
    })
    vim.keymap.set({ "n", "i" }, "<CR>", commit, { buffer = buf, desc = "Save review comment" })
    for _, key in ipairs({ "<C-j>", "<C-CR>" }) do
        vim.keymap.set("i", key, "<CR>", { buffer = buf, desc = "New line in review comment" })
    end
    vim.keymap.set(
        { "n", "i" },
        "<C-c>",
        function() M.discard(assert(M.current_item())) end,
        { buffer = buf, desc = "Cancel comment edits and close" }
    )
    vim.keymap.set("n", "q", commit, { buffer = buf, desc = "Commit comment and close" })
    for key, command in pairs({ ["<C-p>"] = "undo", ["<C-n>"] = "redo" }) do
        local opts = {
            buffer = buf,
            desc = command == "undo" and "Previous comment edit" or "Next comment edit",
        }
        vim.keymap.set({ "n", "i" }, key, function() move_history(command) end, opts)
    end
    if presentation then
        vim.keymap.set(
            "n",
            "<Space>",
            function() require("parley.review").peek() end,
            { buffer = buf, desc = "Toggle current hunk comparison" }
        )
        vim.keymap.set(
            "n",
            "<leader>rq",
            function() require("parley.review").stop() end,
            { buffer = buf, desc = "Exit review mode" }
        )
    end
    local function help()
        local hotkeys = {}
        for _, mode in ipairs({ "n", "i" }) do
            for _, mapping in ipairs(api.nvim_buf_get_keymap(buf, mode)) do
                if mapping.desc then
                    hotkeys[#hotkeys + 1] =
                        { mode = mode, key = mapping.lhs, description = mapping.desc }
                end
            end
        end
        table.sort(hotkeys, function(a, b)
            if a.key ~= b.key then return a.key < b.key end
            return a.mode < b.mode
        end)
        mode_help.toggle("Comment hotkeys", hotkeys)
    end
    vim.keymap.set({ "n", "i" }, "<F1>", help, { buffer = buf, desc = "Show comment hotkeys" })
    vim.keymap.set("n", "<leader>?", help, { buffer = buf, desc = "Show comment hotkeys" })
    refresh(s, true)
    if session ~= s then return end
    api.nvim_win_set_config(win, { hide = false })
    api.nvim_set_current_win(win)
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].statuscolumn = ""
    vim.wo[win].signcolumn = "no"
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(buf), 0 })
    vim.cmd("startinsert!")
end

---Open at a locked line/range/hunk target in the current source buffer.
---@param first integer
---@param last integer
---@param scope 'line'|'range'|'hunk'
---@param review ParleyReviewComposer.Owner? Frozen review-piece identity.
---@param presentation ParleyReviewComposer.Presentation? Borrowed room owned by review mode.
---@param anchor ParleyReviewComposer.Anchor? Captured before opening; never changed by projection.
function M.open(first, last, scope, review, presentation, anchor)
    local buf = api.nvim_get_current_buf()
    assert(
        first >= 1 and last >= first and last <= api.nvim_buf_line_count(buf),
        "Invalid composer range"
    )
    if
        api.nvim_win_get_config(0).relative ~= ""
        or (
            vim.bo[buf].buftype ~= ""
            and not vim.b[buf].parley_snapshot
            and not vim.b[buf].parley_oldside
        )
    then
        vim.notify("Open the composer from an ordinary source window", vim.log.levels.WARN)
        return
    end
    assert(scope == "line" or scope == "range" or scope == "hunk", "Invalid composer scope")
    local target = {
        path = api.nvim_buf_get_name(buf),
        first = first,
        last = last,
        scope = scope,
        context = api.nvim_buf_get_lines(buf, first - 1, last, false),
        review = review,
        anchor = anchor and vim.deepcopy(anchor),
    }
    for _, draft in ipairs(drafts) do
        if vim.deep_equal(draft.target, target) then
            open_draft(draft, presentation)
            return
        end
    end
    for _, comment in ipairs(M.comments) do
        if vim.deep_equal(comment.target, target) then
            M.edit(comment, presentation)
            return
        end
    end
    local draft = { id = next_id(), target = target, lines = { "" }, cursor = { 1, 0 } }
    drafts[#drafts + 1] = draft
    open_draft(draft, presentation)
end

---Edit a committed note without changing its locked target or duplicating it.
---@param comment ParleyReviewComposer.Draft Borrowed saved note; must have no parent comment.
---@param presentation ParleyReviewComposer.Presentation?
function M.edit(comment, presentation)
    if comment.author == "agent" then
        vim.notify("Agent finding is read-only; use reply to discuss it", vim.log.levels.INFO)
        return
    end
    for _, draft in ipairs(drafts) do
        if draft.comment == comment then
            draft.target = vim.deepcopy(comment.target)
            open_draft(draft, presentation)
            return
        end
    end
    local draft = {
        id = next_id(),
        target = vim.deepcopy(comment.target),
        lines = vim.deepcopy(comment.lines),
        cursor = { 1, 0 },
        comment = comment,
    }
    drafts[#drafts + 1] = draft
    open_draft(draft, presentation)
end

---@param item ParleyReviewComposer.Item
---@param presentation ParleyReviewComposer.Presentation?
function M.open_item(item, presentation)
    if item.state == "saved" then
        M.edit(item.note, presentation)
    else
        open_draft(item.note, presentation)
    end
end

---Restore saved wire notes using new local identities; buffers/undo remain editor-owned.
function M.restore_review(notes)
    for _, note in ipairs(notes) do
        note.id = next_id()
        note.cursor = { 1, 0 }
        local collection = note.author == "agent" and M.findings or M.comments
        collection[#collection + 1] = note
    end
end

---A reply is a distinct note with an explicit parent, even at an identical target.
---@param lines string[]? Optional copied text; owned by the new human draft, never the original agent message.
function M.reply(note, parent, presentation, lines)
    local draft = {
        id = next_id(),
        target = vim.deepcopy(note.target),
        lines = lines and vim.deepcopy(lines) or { "" },
        cursor = { 1, 0 },
        reply_to = parent,
    }
    drafts[#drafts + 1] = draft
    open_draft(draft, presentation)
end

---The composer owns this source's display while its editor is open, including
---the focus transition into the float. Querying ownership never captures text.
function M.owns_source_window(win)
    return session ~= nil
        and not session.closing
        and session.source_win == win
        and source_available(session)
end

---A passive lifecycle query; never reads or saves the composer text.
function M.is_open() return session ~= nil and not session.closing end

---The active editor is an action boundary; read its current text before acting.
---@return ParleyReviewComposer.Item? Absent when the composer is closed.
function M.current_item()
    if not session then return end
    save_draft(session)
    return { note = session.draft, state = session.draft.comment and "editing" or "draft" }
end

---@param item ParleyReviewComposer.Item
function M.discard(item)
    if item.state == "saved" then
        vim.notify("Selected note has no draft to discard", vim.log.levels.INFO)
        return
    end
    local draft = item.note
    local editor = editors[editor_id(draft)]
    if editor and api.nvim_buf_is_valid(editor.buf) then
        sync_undo(editor.buf)
        api.nvim_buf_call(editor.buf, function() vim.cmd("undo " .. editor.committed) end)
        draft.lines = api.nvim_buf_get_lines(editor.buf, 0, -1, false)
        vim.bo[editor.buf].modified = false
    end
    -- Restore inactive saved text before the float closes and focus redraws.
    remove_draft(draft)
    if session and session.draft == draft then
        M.close(true)
    else
        api.nvim_exec_autocmds("User", {
            pattern = "ParleyReviewNotesChanged",
            data = {
                note = editor_id(draft),
                target = draft.target,
                auxiliary = draft.auxiliary_key ~= nil,
            },
        })
    end
    if not draft.comment then release_editor(draft) end
end

---Only called after explicit confirmation by the review UI.
---@param item ParleyReviewComposer.Item Borrowed saved note or unfinished edit of one.
function M.delete(item)
    local comment = item.note.comment or (item.state == "saved" and item.note)
    assert(comment, "Discard new drafts rather than deleting a saved note")
    if comment.author == "agent" then
        vim.notify("Agent findings cannot be deleted", vim.log.levels.INFO)
        return
    end
    if session and (session.draft == item.note or session.draft.comment == comment) then
        M.close(true)
    end
    for index, note in ipairs(M.comments) do
        if note == comment then
            table.remove(M.comments, index)
            break
        end
    end
    for index = #drafts, 1, -1 do
        if drafts[index].comment == comment then remove_draft(drafts[index]) end
    end
    release_editor(comment)
    api.nvim_exec_autocmds("User", { pattern = "ParleyReviewNotesChanged" })
end

---Open a retained auxiliary summary in the same reserved-space editor, never as a human note.
---The connection owns acknowledgement; failed saves keep the draft and undo buffer.
function M.auxiliary(key, target, lines, label, presentation, on_save)
    for _, draft in ipairs(drafts) do
        if draft.auxiliary_key == key then
            draft.target = vim.deepcopy(target)
            draft.label, draft.on_save = label, on_save
            open_draft(draft, presentation)
            return
        end
    end
    local draft = {
        id = next_id(),
        target = vim.deepcopy(target),
        lines = vim.deepcopy(lines),
        cursor = { 1, 0 },
        auxiliary_key = key,
        label = label,
        on_save = on_save,
    }
    drafts[#drafts + 1] = draft
    open_draft(draft, presentation)
end

---Resume without replacing retained edits or their original save/provenance callback.
function M.resume_auxiliary(key, presentation)
    for _, draft in ipairs(drafts) do
        if draft.auxiliary_key == key then
            open_draft(draft, presentation)
            return true
        end
    end
    return false
end

function M.has_drafts(id)
    for _, draft in ipairs(drafts) do
        if draft.target.review and draft.target.review.session == id then return true end
    end
    return false
end

function M.resume()
    if not last_draft then
        vim.notify("No review draft", vim.log.levels.INFO)
        return
    end
    open_draft(last_draft)
end

return M
