---Disposable thread presentation above a borrowed human composer.
---The host owns messages, exact reply parents, source placement and draft buffers.
---A retained State owns only selection/folding/reading positions; updates never
---select incoming messages, enter a draft, move focus or scroll the source.
local composer = require("parley.composer")
local keys = require("parley.composer.keymaps")
local style = require("parley.composer.style")
local thread = require("parley.thread")
local M = {}
local api = vim.api
local heading_namespace

---@class ParleyDiscussion.Draft: ParleyComposer.Draft
---@field entry_id string Stable presentation identity, distinct from committed message IDs.
---@field created_at integer
---@field parent_id? string Fixed by the host when this separate human draft is created.
---@field replaces_id? string Committed human message copied into this draft, never edited in place.
---@field accepted? ParleyThread.Message Last accepted capture from this buffer; later edits stay local.

---@class ParleyDiscussion.Response: ParleyThread.Message
---@field state string Request activity label; this entry is never persisted or a reply parent.

---@class ParleyDiscussion.State
---@field selected_id? string
---@field collapsed? boolean
---@field seen_count? integer Presentation only, not a delivery/read acknowledgement.
---@field positions? table<string, table> Native reading views, keyed by history/draft entry identity.

---@class ParleyDiscussion.Keymaps
---@field next_message? ParleyKeymapKeys
---@field previous_message? ParleyKeymapKeys
---@field toggle? ParleyKeymapKeys
---@field reply? ParleyKeymapKeys
---@field edit? ParleyKeymapKeys
---@field close? ParleyKeymapKeys
---@field resolve? ParleyKeymapKeys
---@field reopen? ParleyKeymapKeys
---@field delete? ParleyKeymapKeys

---@class ParleyDiscussion.Options
---@field source_win integer
---@field first integer Host-validated, unchanged live placement.
---@field last integer
---@field source_label string
---@field room ParleyComposer.Room Borrowed placement; discussion never imports its host.
---@field state? ParleyDiscussion.State Retained and mutated; contains no canonical text.
---@field message_id? string Explicit history/draft entry target; absent resumes retained selection.
---@field enter? boolean Focus the reader unless false; false prepares direct composing.
---@field keymaps? ParleyDiscussion.Keymaps|false
---@field composer_keymaps? ParleyComposer.Keymaps|false
---@field reply fun(parent_id: string?): ParleyDiscussion.Draft Return a retained draft with this exact parent.
---@field edit? fun(message_id: string): ParleyDiscussion.Draft Copy/resume a human revision draft.
---@field draft fun(editing?: boolean): ParleyDiscussion.Draft? Visible draft, or retained edit buffer when editing=true.
---@field response? fun(): ParleyDiscussion.Response? Transient request-correlated agent slot.
---@field changed fun() Refresh host cards after releasing room.
---@field thread_action? fun(action: 'resolve'|'reopen'|'delete') Host-owned active-thread action.

---@class ParleyDiscussion.Reader
---@field buffer integer Disposable display only.
---@field window integer
---@field height integer Display rows, excluding outer padding.
---@field rendered? string[]
---@field rendered_id? string

---@class ParleyDiscussion.View: ParleyDiscussion.Reader
---@field thread ParleyThread Borrowed; the host changes active history through parley.thread.
---@field options ParleyDiscussion.Options
---@field state ParleyDiscussion.State
---@field parent? ParleyDiscussion.Reader Independently scrollable exact-parent context.
---@field group? integer Present after setup begins.
---@field source_buf integer
---@field source_tick integer
---@field source_view table
---@field closed boolean
---@field composing boolean
---@field draft? ParleyDiscussion.Draft
---@field response? ParleyDiscussion.Response Last rendered slot; used only to replace the selected waiting entry.
---@field editor? ParleyComposer.Editor Borrowed presentation identity, never a draft owner.
---@field render_mode? 'expanded'|'collapsed'
---@field pending boolean
---@field refreshing boolean
---@field emphasized? boolean Last attachment/focus emphasis, not remembered selection.

local defaults = {
    next_message = "<C-n>",
    previous_message = "<C-p>",
    toggle = "za",
    reply = "r",
    edit = { "e", "<CR>" },
    close = { "q", "<Esc>" },
    resolve = "<leader>tr",
    reopen = "<leader>tR",
    delete = "<leader>td",
}

---@param overrides? ParleyDiscussion.Keymaps|false
---@return table<string, string[]>
function M.resolve_keymaps(overrides)
    return keys.resolve(defaults, overrides)
end

local function source_available(view)
    return api.nvim_win_is_valid(view.options.source_win)
        and api.nvim_win_get_buf(view.options.source_win) == view.source_buf
        and api.nvim_buf_get_changedtick(view.source_buf) == view.source_tick
        and view.options.last <= api.nvim_buf_line_count(view.source_buf)
end

local function display_available(view)
    return not view.closed
        and source_available(view)
        and api.nvim_win_is_valid(view.window)
        and api.nvim_win_get_buf(view.window) == view.buffer
        and view.parent ~= nil
        and api.nvim_win_is_valid(view.parent.window)
        and api.nvim_win_get_buf(view.parent.window) == view.parent.buffer
end

-- Draft entries are presentation snapshots read from the host's canonical
-- buffer. They never enter immutable history merely by being shown or saved.
---@param data ParleyThread
---@param options ParleyDiscussion.Options
---@param id? string
---@return ParleyThread.Message? message
---@return ParleyDiscussion.Draft? draft
local function get_entry(data, options, id, composing)
    local response = options.response and options.response()
    if response and response.id == id then
        return response
    end
    local draft = options.draft(composing)
    if draft and id == draft.entry_id then
        return {
            id = draft.entry_id,
            parent_id = draft.parent_id,
            role = "human",
            author = "You",
            origin = "editor/draft",
            created_at = draft.created_at,
            lines = api.nvim_buf_is_loaded(draft.buffer)
                    and api.nvim_buf_get_lines(draft.buffer, 0, -1, false)
                or { "Draft buffer unavailable" },
        },
            draft
    end
    return id and thread.get(data, id) or nil
end

local function entry_ids(data, options, composing)
    local ids = {}
    for _, message in ipairs(data.messages) do
        ids[#ids + 1] = message.id
    end
    local response = options.response and options.response()
    if response then
        ids[#ids + 1] = response.id
    end
    local draft = options.draft(composing)
    if draft then
        ids[#ids + 1] = draft.entry_id
    end
    return ids
end

-- One projection for both reading and editing: the selected entry and only its
-- exact parent. A revision's replaces_id is identity, never alternate context.
local function projection(view)
    local response = view.options.response and view.options.response()
    local previous = view.response
    view.response = response
    -- Replace only a selected transient slot, never select an arriving reply
    -- while the user is reading another entry or editing local prose.
    if
        previous
        and not response
        and view.state.selected_id == previous.id
        and not view.composing
    then
        view.state.selected_id = previous.parent_id
        for _, message in ipairs(view.thread.messages) do
            if message.role == "agent" and message.parent_id == previous.parent_id then
                view.state.selected_id = message.id
                break
            end
        end
    end
    local pending = view.options.draft(true)
    if
        pending
        and pending.accepted
        and not view.composing
        and not view.options.draft()
        and view.state.selected_id == pending.entry_id
    then
        view.state.selected_id = pending.accepted.id
        view.state.positions[pending.accepted.id] = view.state.positions[pending.accepted.id]
            or view.state.positions[pending.entry_id]
    end
    local selected, draft =
        get_entry(view.thread, view.options, view.state.selected_id, view.composing)
    local parent = selected and selected.parent_id and thread.get(view.thread, selected.parent_id)
    if view.state.collapsed and not view.composing then
        parent = nil
    end
    local ids = entry_ids(view.thread, view.options, view.composing)
    local index = 0
    for position, id in ipairs(ids) do
        if selected and id == selected.id then
            index = position
            break
        end
    end
    return { selected = selected, draft = draft, parent = parent, index = index, count = #ids }
end

local function remember_reader(view, reader)
    if
        reader
        and reader.rendered_id
        and api.nvim_win_is_valid(reader.window)
        and api.nvim_win_get_buf(reader.window) == reader.buffer
    then
        view.state.positions[reader.rendered_id] =
            api.nvim_win_call(reader.window, vim.fn.winsaveview)
    end
end

local function remember_position(view)
    if not view.composing and view.render_mode == "expanded" then
        remember_reader(view, view)
    end
    remember_reader(view, view.parent)
end

local function close_reader(reader)
    if not reader then
        return
    end
    local closed, failure = pcall(function()
        if
            api.nvim_win_is_valid(reader.window)
            and api.nvim_win_get_buf(reader.window) == reader.buffer
        then
            api.nvim_win_close(reader.window, true)
        end
    end)
    local deleted, err = pcall(function()
        if api.nvim_buf_is_valid(reader.buffer) then
            api.nvim_buf_delete(reader.buffer, { force = true })
        end
    end)
    if not closed then
        error(failure, 0)
    end
    if not deleted then
        error(err, 0)
    end
end

---Idempotent teardown. Retained state and all host-owned buffers survive.
---@param view ParleyDiscussion.View? Nil is safe after an incompatible open.
---@param restore? boolean Explicit exit may return to the unchanged source view.
function M.close(view, restore)
    if not view or view.closed then
        return
    end
    local focused = api.nvim_get_current_win() == view.window
        or (view.parent and api.nvim_get_current_win() == view.parent.window)
    view.closed = true
    local failed, failure
    local function finish(action)
        local ok, err = pcall(action)
        if not ok and not failed then
            failed, failure = true, err
        end
    end
    finish(function()
        if view.group then
            api.nvim_del_augroup_by_id(view.group)
        end
    end)
    finish(function()
        remember_position(view)
    end)
    if view.editor then
        finish(function()
            composer.close(false, view.editor)
        end)
    end
    finish(view.options.room.release)
    finish(function()
        close_reader(view.parent)
    end)
    finish(function()
        close_reader(view)
    end)
    finish(view.options.changed)
    if
        restore
        and focused
        and source_available(view)
        and api.nvim_get_current_win() == view.options.source_win
    then
        finish(function()
            vim.fn.winrestview(view.source_view)
        end)
    end
    if failed then
        error(failure, 0)
    end
end

local function attachment_active(view)
    local focused = api.nvim_get_current_win()
    if focused == view.options.source_win then
        local line = api.nvim_win_get_cursor(focused)[1]
        return line >= view.options.first and line <= view.options.last
    end
    return focused == view.window
        or (view.parent and focused == view.parent.window)
        or (view.editor and focused == view.editor.window)
        or false
end

local function configure_window(reader, parent)
    local window = reader.window
    vim.wo[window].number = false
    vim.wo[window].relativenumber = false
    vim.wo[window].signcolumn = "no"
    vim.wo[window].statuscolumn = ""
    vim.wo[window].foldcolumn = "0"
    vim.wo[window].foldenable = false
    vim.wo[window].wrap = true
    vim.wo[window].linebreak = true
    local active = not parent and attachment_active(reader)
    local body = active and "ParleyReviewNoteActive" or "ParleyReviewNote"
    vim.wo[window].winhighlight = ("Normal:%s,NormalFloat:%s,EndOfBuffer:%s"):format(
        body,
        body,
        body
    )
end

local function render_lines(reader, lines, heading_highlight)
    if vim.deep_equal(reader.rendered, lines) then
        return
    end
    vim.bo[reader.buffer].modifiable = true
    local heading_only = reader.rendered and #reader.rendered == #lines
    if heading_only then
        for index = 2, #lines do
            if reader.rendered[index] ~= lines[index] then
                heading_only = false
                break
            end
        end
    end
    -- Incoming history changes the count/index heading, not the selected body.
    -- Replacing the whole buffer here would reset a reader's cursor/scroll.
    api.nvim_buf_set_lines(
        reader.buffer,
        0,
        heading_only and 1 or -1,
        false,
        heading_only and { lines[1] } or lines
    )
    vim.bo[reader.buffer].modifiable = false
    vim.bo[reader.buffer].modified = false
    reader.rendered = lines
    api.nvim_buf_clear_namespace(reader.buffer, heading_namespace, 0, -1)
    api.nvim_buf_set_extmark(reader.buffer, heading_namespace, 0, 0, {
        end_col = #lines[1],
        hl_group = heading_highlight,
        hl_eol = true,
    })
end

-- Context is a full native reader, not a shortened virtual-text preview.
-- Both readers use the same line coordinates so selecting a parent, replying,
-- and returning to a draft can reuse that message's retained reading view.
local function render_parent(view, width, resolved)
    local parent = resolved.parent
    local reader = view.parent
    if not parent then
        reader.rendered_id = nil
        api.nvim_win_set_config(reader.window, { hide = true })
        return
    end
    local role = parent.role == "agent" and "Agent" or "You"
    local lines = {
        style.heading(parent, "parent", view.options.first, view.options.last, width, role),
        "",
    }
    for _, line in ipairs(parent.lines) do
        lines[#lines + 1] = line
    end
    render_lines(reader, lines, "ParleyDiscussionParentHeading")
    reader.rendered_id = parent.id
    return parent
end

local function render(view, width, resolved)
    local message, draft = resolved.selected, resolved.draft
    local label = message and message.role == "agent" and "Agent" or "You"
    local heading = style.heading(
        message or {},
        message and message.state
            or (draft and "draft · %d/%d" or "read-only · %d/%d"):format(
                resolved.index,
                resolved.count
            ),
        view.options.first,
        view.options.last,
        width,
        label
    )
    local lines = { heading }
    if view.composing or not view.state.collapsed then
        lines[#lines + 1] = ""
        if message then
            for _, line in ipairs(message.lines) do
                lines[#lines + 1] = line
            end
        else
            lines[#lines + 1] = "No messages yet"
        end
    end
    render_lines(view, lines, "ParleyReviewNoteHeading")
    view.render_mode = not view.composing and view.state.collapsed and "collapsed" or "expanded"
    view.rendered_id = message and message.id or nil
end

-- Resolve once, measure the two slots, allocate the viewport, reserve source
-- room, then apply geometry. The borrowed composer never calls this layout.
local function layout(view, reveal)
    local options = view.options
    local height = api.nvim_win_get_height(options.source_win)
        - (vim.wo[options.source_win].winbar ~= "" and 1 or 0)
    if height < 10 or api.nvim_win_get_width(options.source_win) < 24 then
        return
    end
    for _, mark in
        ipairs(
            api.nvim_buf_get_extmarks(
                view.source_buf,
                -1,
                { options.last - 1, 0 },
                { options.last - 1, -1 },
                { details = true }
            )
        )
    do
        local details = mark[4]
        if
            details
            and details.ns_id ~= options.room.namespace
            and details.virt_lines
            and not details.virt_lines_above
        then
            return
        end
    end

    local resolved = projection(view)
    local active = attachment_active(view)
    view.emphasized = active
    local indent, width, padding = style.layout(options.source_win)
    api.nvim_win_set_config(view.window, { width = width })
    api.nvim_win_set_config(view.parent.window, { width = width })
    render_parent(view, width, resolved)
    render(view, width, resolved)
    configure_window(view)
    configure_window(view.parent, true)

    local parent = resolved.parent
    local below = options.last < api.nvim_buf_line_count(view.source_buf) and 1 or 0
    local overhead = (view.composing and 4 or 2) + (parent and 3 or 0)
    local body_minimum = view.composing and 1 or math.min(3, #view.rendered)
    local parent_minimum = parent and math.min(3, #view.parent.rendered) or 0
    local minimum = body_minimum + parent_minimum
    local budget = (view.composing and height - 1 - below or math.floor(height / 2)) - overhead
    if budget < minimum then
        return
    end
    local function text_height(reader)
        return math.max(
            1,
            math.min(
                budget,
                api.nvim_win_text_height(reader.window, {
                    start_row = 0,
                    end_row = api.nvim_buf_line_count(reader.buffer) - 1,
                    max_height = budget,
                }).all
            )
        )
    end
    local desired
    if view.composing then
        desired = composer.measure(view.editor, width, budget)
    else
        desired = text_height(view)
    end
    if not desired then
        return
    end
    local parent_desired = parent and text_height(view.parent) or 0
    local function allocate()
        local parent_height = parent
                and math.min(
                    parent_desired,
                    math.max(parent_minimum, math.floor(budget / 3)),
                    budget - body_minimum
                )
            or 0
        view.height = math.min(desired, budget - parent_height)
        view.parent.height = parent and math.min(parent_desired, budget - view.height) or 0
    end
    allocate()

    local function reserve()
        local room = {}
        if parent then
            for _ = 1, view.parent.height + 2 do
                local line = style.card_line(indent, width, padding, {}, false, parent.role)
                for _, chunk in ipairs(line) do
                    if chunk[2] == "ParleyReviewHumanMarker" then
                        chunk[2] = "ParleyDiscussionParentHumanMarker"
                    elseif chunk[2] == "ParleyDiscussionAgentMarker" then
                        chunk[2] = "ParleyDiscussionParentAgentMarker"
                    end
                end
                room[#room + 1] = line
            end
            room[#room + 1] = { { "", "Normal" } }
        end
        local role = resolved.selected and resolved.selected.role or "human"
        local first = #room + 1
        for _ = 1, view.height + (view.composing and 4 or 2) do
            room[#room + 1] = style.card_line(indent, width, padding, {}, active, role)
        end
        if view.composing then
            room[first + 1] = style.card_line(indent, width, padding, {
                { view.rendered[1], "ParleyReviewNoteHeading" },
            }, active, role)
        end
        return options.room.reserve(options.last, room)
    end
    local preceding = reserve()
    local row
    api.nvim_win_call(options.source_win, function()
        if reveal then
            api.nvim_win_set_cursor(options.source_win, { options.last, 0 })
            vim.cmd("normal! zv")
        elseif vim.fn.foldclosed(options.last) ~= -1 then
            return
        end
        local function source_row()
            local position = vim.fn.winsaveview()
            if position.topline > options.last then
                return
            end
            return api.nvim_win_text_height(options.source_win, {
                start_row = position.topline - 1,
                start_vcol = position.skipcol,
                end_row = options.last - 1,
                max_height = height + 1,
            }).all + position.topfill + preceding
        end
        row = source_row()
        local function room_height()
            return view.height + view.parent.height + overhead
        end
        if reveal and (not row or row + room_height() + below > height) then
            vim.cmd("normal! zt")
            row = source_row()
        end
        while row and row + room_height() + below > height do
            local remaining = budget - (row + room_height() + below - height)
            if remaining < minimum then
                row = nil
                return
            end
            budget = remaining
            allocate()
            preceding = reserve()
            row = source_row()
        end
    end)
    if not row then
        return
    end

    local config = {
        relative = "win",
        win = options.source_win,
        row = row + (parent and view.parent.height + 3 or 0) + 1,
        col = indent,
        width = width,
        height = view.height,
        hide = false,
        border = "none",
    }
    api.nvim_win_set_config(view.window, view.composing and { hide = true } or config)
    if parent then
        api.nvim_win_set_config(
            view.parent.window,
            vim.tbl_extend("force", config, {
                row = row + 1,
                height = view.parent.height,
                focusable = true,
            })
        )
    end
    if view.composing then
        composer.place(
            view.editor,
            vim.tbl_extend("force", config, { row = config.row + 2 }),
            active
        )
    end
    return true
end

-- Headers are display chrome, not a reading/cursor target. A collapsed card
-- contains only its heading; expanded messages and parent context start below it.
---@param reader ParleyDiscussion.Reader
local function keep_cursor_in_body(reader)
    local cursor = api.nvim_win_get_cursor(reader.window)
    if cursor[1] < 3 and api.nvim_buf_line_count(reader.buffer) >= 3 then
        api.nvim_win_set_cursor(reader.window, { 3, 0 })
    end
end

-- Navigation restoration belongs to explicit transitions, never geometry.
local function restore_position(view)
    for _, reader in ipairs({ view, view.parent }) do
        if
            reader.rendered_id
            and (reader ~= view or (not view.composing and not view.state.collapsed))
        then
            api.nvim_win_call(reader.window, function()
                vim.fn.winrestview(
                    view.state.positions[reader.rendered_id]
                        or { lnum = 3, col = 0, topline = 1, topfill = 0 }
                )
                keep_cursor_in_body(reader)
            end)
        end
    end
end

---Refresh borrowed data without changing selection, focus, reading view or draft.
---@param view ParleyDiscussion.View
function M.update(view)
    if view.closed or view.refreshing then
        return
    end
    if not display_available(view) then
        M.close(view, false)
        return
    end
    view.refreshing = true
    local ok, result = pcall(layout, view, false)
    view.refreshing = false
    if not ok or result == nil then
        if not ok then
            pcall(M.close, view, false)
            error(result, 0)
        end
        M.close(view, false)
    end
end

---Explicit message selection; selecting never creates or retargets a draft.
---@param view ParleyDiscussion.View
---@param id string
---@return boolean
function M.select(view, id)
    if view.closed or view.composing or not get_entry(view.thread, view.options, id) then
        return false
    end
    if not display_available(view) then
        M.close(view, false)
        return false
    end
    remember_position(view)
    view.state.selected_id = id
    view.state.collapsed = false
    local ids = entry_ids(view.thread, view.options)
    if ids[#ids] == id then
        view.state.seen_count = #view.thread.messages
    end
    -- Don't save the previous message's cursor under the newly selected ID.
    view.refreshing = true
    local ok, result = pcall(layout, view, false)
    view.refreshing = false
    if not ok or result == nil then
        if not ok then
            pcall(M.close, view, false)
            error(result, 0)
        end
        M.close(view, false)
        return false
    end
    restore_position(view)
    return true
end

---@param view ParleyDiscussion.View
---@param step integer
function M.move(view, step)
    local ids = entry_ids(view.thread, view.options)
    if not view.state.selected_id and #ids > 0 then
        local index = step > 0 and 1 or #ids
        M.select(view, ids[index])
        return
    end
    for index, id in ipairs(ids) do
        if id == view.state.selected_id then
            local target = ids[index + step]
            if target then
                M.select(view, target)
            end
            return
        end
    end
end

---@param view ParleyDiscussion.View
function M.toggle(view)
    if view.closed or view.composing then
        return
    end
    remember_position(view)
    view.state.collapsed = not view.state.collapsed
    -- Folding captures the outgoing view; geometry never restores it.
    M.update(view)
    if not view.closed then
        restore_position(view)
    end
end

-- The composer borrows the same host buffer on every entry. Save/close selects
-- its editable draft entry; neither operation creates immutable history.
---@param view ParleyDiscussion.View
---@param draft ParleyDiscussion.Draft
---@return boolean started
local function compose(view, draft)
    assert(
        not thread.get(view.thread, draft.entry_id),
        "Parley: draft entry ID conflicts with history"
    )
    assert(
        view.options.draft(true) == draft,
        "Parley: composer must borrow the host's current draft"
    )
    if not api.nvim_buf_is_loaded(draft.buffer) then
        vim.notify("Parley: retained draft was deleted externally", vim.log.levels.WARN)
        return false
    end

    remember_position(view)
    view.state.selected_id = draft.entry_id
    view.state.collapsed = false
    view.draft, view.composing = draft, true
    view.refreshing = true
    local opened, failure = pcall(function()
        api.nvim_set_current_win(view.options.source_win)
        if
            not display_available(view)
            or api.nvim_get_current_win() ~= view.options.source_win
        then
            return
        end
        local editor
        editor = composer.show(draft, {
            source_win = view.options.source_win,
            first = view.options.first,
            last = view.options.last,
            source_label = view.options.source_label,
            keymaps = view.options.composer_keymaps,
            thread_action = view.options.thread_action,
            managed = true,
            changed = function()
                if view.closed or view.draft ~= draft then
                    return
                end
                view.composing, view.editor = false, nil
                M.update(view)
                if not view.closed then
                    restore_position(view)
                end
            end,
            closed = function(restore, destination)
                if destination == "source" then
                    M.close(view, restore)
                    return
                end
                if
                    restore
                    and display_available(view)
                    and api.nvim_get_current_win() == view.options.source_win
                then
                    api.nvim_set_current_win(view.window)
                    if display_available(view) and api.nvim_get_current_win() == view.window then
                        configure_window(view)
                    end
                end
            end,
            navigate = function(step)
                if display_available(view) and api.nvim_get_current_win() == view.window then
                    M.move(view, step)
                end
            end,
        })
        view.editor = editor
        if view.closed then
            if editor then
                composer.close(false, editor)
            end
            return
        end
        assert(editor, "Parley: composer was interrupted while opening")
        assert(layout(view, true), "Parley: no unobscured discussion space at its source")
        restore_position(view)
        if not composer.enter(editor) then
            composer.close(false, editor)
        end
    end)
    view.refreshing = false
    if not opened then
        -- Cleanup cannot replace the original opening failure.
        if view.editor then
            pcall(composer.close, false, view.editor)
        end
        view.composing, view.editor = false, nil
        if not view.closed then
            pcall(M.update, view)
        end
        error(failure, 0)
    end
    if not view.editor then
        view.composing = false
        if not view.closed then
            M.update(view)
        end
    end
    return not view.closed and view.composing
end

---Reply to committed history or resume the selected draft. A draft cannot
---become its own reply parent; navigating never retargets an existing buffer.
---@param view ParleyDiscussion.View? Nil is safe after an incompatible open.
---@return boolean started
function M.reply(view)
    if not view or not display_available(view) or view.composing then
        return false
    end
    local message, existing = get_entry(view.thread, view.options, view.state.selected_id)
    if existing then
        return compose(view, existing)
    end
    if #view.thread.messages > 0 and not message then
        vim.notify("Parley: select an active message before replying", vim.log.levels.INFO)
        return false
    end
    if message and message.origin == "request/activity" then
        vim.notify(
            "Parley: this reply is pending; select a committed message to compose a follow-up",
            vim.log.levels.INFO
        )
        return false
    end
    local draft = view.options.reply(view.state.selected_id)
    assert(draft.parent_id == view.state.selected_id, "Parley: reply draft has a different parent")
    assert(not draft.replaces_id, "Parley: reply draft cannot replace a submitted message")
    return compose(view, draft)
end

---Editing submitted human text always borrows a separate host-owned draft.
---@param view ParleyDiscussion.View
---@return boolean started
function M.edit(view)
    if not display_available(view) or view.composing then
        return false
    end
    local message, existing = get_entry(view.thread, view.options, view.state.selected_id)
    if existing then
        return compose(view, existing)
    end
    if not message or message.role ~= "human" then
        vim.notify("Parley: select a draft or human message to edit", vim.log.levels.INFO)
        return false
    end
    if not view.options.edit then
        return false
    end
    local draft = view.options.edit(message.id)
    assert(
        draft.replaces_id == message.id or (draft.accepted and draft.accepted.id == message.id),
        "Parley: revision draft has a different target"
    )
    assert(draft.parent_id == message.parent_id, "Parley: revision draft has a different parent")
    return compose(view, draft)
end

local function schedule_update(view)
    if view.closed or view.pending or view.refreshing then
        return
    end
    view.pending = true
    vim.schedule(function()
        view.pending = false
        if view.closed then
            return
        end
        local focused = api.nvim_get_current_win()
        local own_draft = view.composing
            and view.draft
            and api.nvim_win_get_buf(focused) == view.draft.buffer
        if
            focused ~= view.window
            and focused ~= view.parent.window
            and focused ~= view.options.source_win
            and not own_draft
        then
            M.close(view, false)
        else
            M.update(view)
        end
    end)
end

---@param source_win integer
---@return ParleyDiscussion.Reader
local function create_reader(source_win)
    local buffer = api.nvim_create_buf(false, true)
    local created, window = pcall(api.nvim_open_win, buffer, false, {
        relative = "win",
        win = source_win,
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        style = "minimal",
        border = "none",
        hide = true,
        focusable = true,
        noautocmd = true,
        zindex = 55,
    })
    if not created then
        api.nvim_buf_delete(buffer, { force = true })
        error(window, 0)
    end
    return { buffer = buffer, window = window, height = 2 }
end

---An explicit message_id takes precedence over retained selection. Otherwise
---resume State, initially defaulting to the current draft or latest message. enter=false
---prepares the same reader/room without focusing it, for direct reply entry.
---The returned view must be closed by its host on detach. Options/data are
---borrowed until close; save/close never commits the host's draft into history.
---@param data ParleyThread
---@param options ParleyDiscussion.Options
---@return ParleyDiscussion.View? view Nil when an older cached host cannot supply draft lookup.
function M.open(data, options)
    -- Presentation-only reload can pair this module with an older cached host.
    -- Refuse before allocating or mutating state; never guess at its drafts.
    if options.draft == nil then
        vim.notify(
            "Parley: cached host lacks draft lookup; discussion was not opened. Start a fresh Neovim session after preserving any drafts you need.",
            vim.log.levels.WARN
        )
        return nil
    end
    assert(type(options.draft) == "function", "Parley: discussion requires a host draft lookup")
    local bindings = M.resolve_keymaps(options.keymaps)
    if options.message_id ~= nil then
        assert(
            get_entry(data, options, options.message_id),
            "Parley: discussion entry message does not exist"
        )
    end
    local state = options.state or {}
    state.positions = state.positions or {}
    state.seen_count = state.seen_count or #data.messages
    if options.message_id ~= nil then
        state.selected_id = options.message_id
        state.collapsed = false
    elseif not state.selected_id or not get_entry(data, options, state.selected_id) then
        local ids = entry_ids(data, options)
        state.selected_id = ids[#ids]
    end
    local source_buffer = api.nvim_win_get_buf(options.source_win)
    local source_view = api.nvim_win_call(options.source_win, vim.fn.winsaveview)
    heading_namespace = heading_namespace or api.nvim_create_namespace("parley.discussion.heading")
    local reader = create_reader(options.source_win)
    local buffer, window = reader.buffer, reader.window
    local view = {
        thread = data,
        options = options,
        state = state,
        buffer = buffer,
        window = window,
        source_buf = source_buffer,
        source_tick = api.nvim_buf_get_changedtick(source_buffer),
        source_view = source_view,
        closed = false,
        composing = false,
        height = 2,
        pending = false,
        refreshing = true,
    }
    local initialized, failure = pcall(function()
        view.group = api.nvim_create_augroup("ParleyDiscussion" .. buffer, { clear = true })
        style.refresh()
        view.parent = create_reader(options.source_win)
        for _, display in ipairs({ view, view.parent }) do
            vim.bo[display.buffer].bufhidden = "wipe"
            vim.bo[display.buffer].swapfile = false
            vim.bo[display.buffer].undofile = false
            vim.bo[display.buffer].filetype = "markdown"
            -- Nonmodifiable guards user edits without readonly warnings on renders.
            vim.bo[display.buffer].readonly = false
        end
        local actions = {
            next_message = function()
                M.move(view, 1)
            end,
            previous_message = function()
                M.move(view, -1)
            end,
            toggle = function()
                M.toggle(view)
            end,
            reply = function()
                M.reply(view)
            end,
            edit = function()
                M.edit(view)
            end,
            close = function()
                M.close(view, true)
            end,
        }
        if options.thread_action then
            for _, name in ipairs({ "resolve", "reopen", "delete" }) do
                actions[name] = function()
                    options.thread_action(name)
                end
            end
        end
        for _, name in ipairs({
            "next_message",
            "previous_message",
            "toggle",
            "reply",
            "edit",
            "close",
            "resolve",
            "reopen",
            "delete",
        }) do
            for _, key in ipairs(actions[name] and bindings[name] or {}) do
                vim.keymap.set(
                    "n",
                    key,
                    actions[name],
                    { buffer = buffer, desc = "Parley discussion: " .. name }
                )
                vim.keymap.set("n", key, function()
                    if not display_available(view) then
                        return
                    end
                    if name == "resolve" or name == "reopen" or name == "delete" then
                        actions[name]()
                        return
                    end
                    local id = view.parent.rendered_id
                    if not id then
                        return
                    end
                    -- Parent scrolling is native. Message actions explicitly
                    -- select that parent in the primary reader before acting.
                    remember_position(view)
                    api.nvim_set_current_win(view.window)
                    configure_window(view)
                    if name == "close" or M.select(view, id) then
                        actions[name]()
                    end
                end, {
                    buffer = view.parent.buffer,
                    desc = "Parley parent: " .. name,
                })
            end
        end
        assert(layout(view, true) ~= nil, "Parley: no unobscured discussion space at its source")
        restore_position(view)
        api.nvim_create_autocmd({
            "WinEnter",
            "BufEnter",
            "WinClosed",
            "BufWipeout",
            "WinResized",
            "VimResized",
            "TextChanged",
            "TextChangedI",
            "TextChangedP",
            "ModeChanged",
        }, {
            group = view.group,
            callback = function()
                schedule_update(view)
            end,
        })
        for _, display in ipairs({ view, view.parent }) do
            api.nvim_create_autocmd("BufWinLeave", {
                group = view.group,
                buffer = display.buffer,
                callback = function()
                    remember_position(view)
                end,
            })
        end
        api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
            group = view.group,
            callback = function()
                local focused = api.nvim_get_current_win()
                if focused == view.window then
                    keep_cursor_in_body(view)
                elseif focused == view.parent.window then
                    keep_cursor_in_body(view.parent)
                end
                if attachment_active(view) ~= view.emphasized then
                    schedule_update(view)
                end
            end,
        })
        api.nvim_create_autocmd("WinScrolled", {
            group = view.group,
            callback = function(event)
                if
                    event.match == tostring(view.window)
                    or event.match == tostring(view.parent.window)
                then
                    remember_position(view)
                elseif event.match == tostring(options.source_win) then
                    schedule_update(view)
                end
            end,
        })
        api.nvim_create_autocmd("ColorScheme", {
            group = view.group,
            callback = function()
                style.refresh()
                schedule_update(view)
            end,
        })
        api.nvim_create_autocmd("OptionSet", {
            group = view.group,
            callback = function()
                schedule_update(view)
            end,
        })
        if options.enter ~= false then
            api.nvim_set_current_win(window)
            configure_window(view)
        end
    end)
    view.refreshing = false
    if not initialized then
        pcall(M.close, view, false)
        error(failure, 0)
    end
    return view
end

return M
