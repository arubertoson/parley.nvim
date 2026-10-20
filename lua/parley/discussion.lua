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
---@field draft fun(): ParleyDiscussion.Draft? Current visible editable entry, owned by the host, not committed history.
---@field changed fun() Refresh host cards after releasing room.

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
---@field group integer
---@field source_buf integer
---@field source_tick integer
---@field source_view table
---@field closed boolean
---@field composing boolean
---@field draft? ParleyDiscussion.Draft
---@field draft_room? ParleyNoteLine[]
---@field render_mode? 'expanded'|'collapsed'
---@field pending boolean
---@field refreshing boolean

local defaults = {
    next_message = "<C-n>",
    previous_message = "<C-p>",
    toggle = "za",
    reply = "r",
    edit = { "e", "<CR>" },
    close = "<Esc>",
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
local function get_entry(data, options, id)
    local draft = options.draft()
    if draft and id == draft.entry_id then
        if not api.nvim_buf_is_loaded(draft.buffer) then
            return nil, draft
        end
        return {
            id = draft.entry_id,
            parent_id = draft.parent_id,
            role = "human",
            author = "You",
            origin = "editor/draft",
            created_at = draft.created_at,
            lines = api.nvim_buf_get_lines(draft.buffer, 0, -1, false),
        },
            draft
    end
    return id and thread.get(data, id) or nil
end

local function entry_ids(data, options)
    local ids = {}
    for _, message in ipairs(data.messages) do
        ids[#ids + 1] = message.id
    end
    local draft = options.draft()
    if draft then
        ids[#ids + 1] = draft.entry_id
    end
    return ids
end

local function selected_message(view)
    if view.composing and view.draft then
        local id = view.draft.replaces_id or view.draft.parent_id
        return id and thread.get(view.thread, id) or nil
    end
    return get_entry(view.thread, view.options, view.state.selected_id)
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
    if view.render_mode == "expanded" then
        remember_reader(view, view)
    end
    remember_reader(view, view.parent)
end

local function close_reader(reader)
    if not reader then
        return
    end
    if
        api.nvim_win_is_valid(reader.window)
        and api.nvim_win_get_buf(reader.window) == reader.buffer
    then
        api.nvim_win_close(reader.window, true)
    end
    if api.nvim_buf_is_valid(reader.buffer) then
        api.nvim_buf_delete(reader.buffer, { force = true })
    end
end

---Idempotent teardown. Retained state and all host-owned buffers survive.
---@param view ParleyDiscussion.View? Nil is safe after an incompatible open.
---@param restore? boolean Explicit exit may return to the unchanged source view.
function M.close(view, restore)
    if not view or view.closed then
        return
    end
    remember_position(view)
    local focused = api.nvim_get_current_win() == view.window
        or (view.parent and api.nvim_get_current_win() == view.parent.window)
    view.closed = true
    api.nvim_del_augroup_by_id(view.group)
    if view.composing and composer.owns_source_window(view.options.source_win) then
        composer.close(false)
    end
    view.options.room.release()
    close_reader(view.parent)
    close_reader(view)
    view.options.changed()
    if
        restore
        and focused
        and source_available(view)
        and api.nvim_get_current_win() == view.options.source_win
    then
        vim.fn.winrestview(view.source_view)
    end
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
    local body = parent and "ParleyReviewNote" or "ParleyReviewNoteActive"
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
    api.nvim_buf_set_lines(reader.buffer, 0, -1, false, lines)
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
local function render_parent(view, width)
    local message = selected_message(view)
    local parent = message and message.parent_id and thread.get(view.thread, message.parent_id)
    local reader = view.parent
    if not parent or (view.state.collapsed and not view.composing) then
        reader.rendered_id = nil
        api.nvim_win_set_config(reader.window, { hide = true })
        return
    end
    local role = parent.role == "agent" and "Agent" or "You"
    local lines = {
        style.heading(parent, "parent", view.options.first, view.options.last, width, role),
    }
    for _, line in ipairs(parent.lines) do
        lines[#lines + 1] = line
    end
    render_lines(reader, lines, "ParleyDiscussionParentHeading")
    reader.rendered_id = parent.id
    return parent
end

local function render(view, width)
    local message, draft = selected_message(view)
    local ids = entry_ids(view.thread, view.options)
    local count, index = #ids, 0
    for position, id in ipairs(ids) do
        if message and id == message.id then
            index = position
            break
        end
    end
    local label = message and message.role == "agent" and "Agent" or "You"
    local heading = style.heading(
        message or {},
        (draft and "draft · %d/%d" or "read-only · %d/%d"):format(index, count),
        view.options.first,
        view.options.last,
        width,
        label
    )
    local lines = { heading }
    if view.composing or not view.state.collapsed then
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

-- The full parent and selected reader share a bounded source-window budget.
-- Short cards lend unused room to the other; long cards scroll independently.
-- Composing keeps the selected reader expanded at the same bounded height,
-- with its reading position intact; the reply uses the remaining viewport.
-- These are display budgets, never truncation of canonical text or draft text.
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
    local indent, width, padding = style.layout(options.source_win)
    api.nvim_win_set_config(view.window, { width = width })
    api.nvim_win_set_config(view.parent.window, { width = width })
    local parent = render_parent(view, width)
    render(view, width)
    configure_window(view)
    configure_window(view.parent, true)
    -- Two padding rows per card and one neutral row between cards.
    local maximum = math.max(parent and 4 or 2, math.floor(height / 2) - (parent and 5 or 2))
    local function text_height(reader)
        return math.min(
            maximum,
            api.nvim_win_text_height(reader.window, {
                start_row = 0,
                end_row = api.nvim_buf_line_count(reader.buffer) - 1,
                max_height = maximum,
            }).all
        )
    end
    local desired = text_height(view)
    view.height = desired
    if parent then
        view.height = math.min(desired, math.ceil(maximum / 2))
        view.parent.height = math.min(text_height(view.parent), maximum - view.height)
        view.height = math.min(desired, maximum - view.parent.height)
    end
    local message = selected_message(view)
    local role = message and message.role or "human"
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
        for _ = 1, view.height + 2 do
            room[#room + 1] = style.card_line(indent, width, padding, {}, true, role)
        end
        if view.composing then
            -- Separate the immutable reader from the editable reply card.
            room[#room + 1] = { { "", "Normal" } }
        end
        for _, line in ipairs(view.draft_room or {}) do
            room[#room + 1] = line
        end
        return options.room.reserve(options.last, room) + (parent and view.parent.height + 3 or 0)
    end
    local preceding = reserve()
    local config
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
        local below = options.last < api.nvim_buf_line_count(view.source_buf) and 1 or 0
        local row = source_row()
        if reveal and (not row or row + view.height + 2 + below > height) then
            vim.cmd("normal! zt")
            row = source_row()
        end
        while row and view.height > height - row - 2 - below do
            local overflow = row + view.height + 2 + below - height
            if view.height > 2 then
                view.height = math.max(2, view.height - overflow)
            elseif parent and view.parent.height > 2 then
                view.parent.height = math.max(2, view.parent.height - overflow)
            else
                return
            end
            preceding = reserve()
            row = source_row()
        end
        if row then
            config = {
                relative = "win",
                win = options.source_win,
                row = row + 1,
                col = indent,
                width = width,
                height = view.height,
                hide = false,
                border = "none",
            }
        end
    end)
    if config then
        api.nvim_win_set_config(view.window, config)
        if parent then
            api.nvim_win_set_config(
                view.parent.window,
                vim.tbl_extend("force", config, {
                    row = config.row - view.parent.height - 3,
                    height = view.parent.height,
                    focusable = not view.composing,
                })
            )
        end
        for _, reader in ipairs({ view, view.parent }) do
            if reader.rendered_id and (reader ~= view or view.render_mode == "expanded") then
                api.nvim_win_call(reader.window, function()
                    vim.fn.winrestview(
                        view.state.positions[reader.rendered_id]
                            or { lnum = 1, col = 0, topline = 1, topfill = 0 }
                    )
                end)
            end
        end
        return preceding
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
    remember_position(view)
    view.refreshing = true
    local ok, result = pcall(layout, view, false)
    view.refreshing = false
    if not ok or result == nil then
        M.close(view, false)
        if not ok then
            error(result, 0)
        end
        return
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
    local ids = entry_ids(view.thread, view.options)
    if ids[#ids] == id then
        view.state.seen_count = #view.thread.messages
    end
    -- Don't save the previous message's cursor under the newly selected ID.
    view.refreshing = true
    local ok, result = pcall(layout, view, false)
    view.refreshing = false
    if not ok or result == nil then
        M.close(view, false)
        if not ok then
            error(result, 0)
        end
        return false
    end
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
    -- Folding has already captured the full reading view; don't replace it
    -- with the two-row collapsed view when expanding again.
    M.update(view)
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
    assert(view.options.draft() == draft, "Parley: composer must borrow the host's current draft")
    if not api.nvim_buf_is_loaded(draft.buffer) then
        vim.notify("Parley: retained draft was deleted externally", vim.log.levels.WARN)
        return false
    end
    remember_position(view)
    view.draft, view.composing = draft, true
    M.update(view)
    if view.closed then
        return false
    end
    api.nvim_set_current_win(view.options.source_win)
    if not display_available(view) or api.nvim_get_current_win() ~= view.options.source_win then
        view.composing = false
        M.update(view)
        return false
    end
    local opened, failure = pcall(composer.show, draft, {
        source_win = view.options.source_win,
        first = view.options.first,
        last = view.options.last,
        source_label = view.options.source_label,
        keymaps = view.options.composer_keymaps,
        draft_label = draft.replaces_id and "editing revision" or "editing reply",
        enter = true,
        room = {
            namespace = view.options.room.namespace,
            reserve = function(_, lines)
                view.draft_room = lines
                -- This layout is entered by the composer, not M.update. Guard
                -- our option/window hooks too, so the two views cannot keep
                -- scheduling each other after a healthy refresh.
                local refreshing = view.refreshing
                view.refreshing = true
                local ok, preceding = pcall(layout, view, false)
                view.refreshing = refreshing
                if not ok then
                    error(preceding, 0)
                end
                assert(preceding ~= nil, "Parley: discussion placement is no longer available")
                -- Include both reader padding rows and the neutral separator.
                return preceding + view.height + 3
            end,
            release = function()
                view.draft_room = nil
            end,
        },
        changed = function()
            view.composing = false
            view.state.selected_id = draft.entry_id
            view.state.collapsed = false
            view.state.positions[draft.entry_id] = view.state.positions[draft.entry_id]
                or { lnum = 1, col = 0, topline = 1, topfill = 0 }
            if not view.closed then
                M.update(view)
            end
        end,
        closed = function(restore)
            if
                restore
                and display_available(view)
                and api.nvim_get_current_win() == view.options.source_win
            then
                api.nvim_set_current_win(view.window)
                configure_window(view)
            end
        end,
        navigate = function(step)
            -- The composer has already retained the draft and restored this
            -- reader. Navigate its entries, never another source attachment.
            if display_available(view) and api.nvim_get_current_win() == view.window then
                M.move(view, step)
            end
        end,
    })
    if not opened then
        view.composing, view.draft_room = false, nil
        M.update(view)
        error(failure, 0)
    end
    return view.composing and composer.owns_source_window(view.options.source_win)
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
    assert(draft.replaces_id == message.id, "Parley: revision draft has a different target")
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
        group = api.nvim_create_augroup("ParleyDiscussion" .. buffer, { clear = true }),
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
        style.refresh()
        view.parent = create_reader(options.source_win)
        for _, display in ipairs({ view, view.parent }) do
            vim.bo[display.buffer].bufhidden = "wipe"
            vim.bo[display.buffer].swapfile = false
            vim.bo[display.buffer].undofile = false
            vim.bo[display.buffer].filetype = "markdown"
            vim.bo[display.buffer].readonly = true
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
        for _, name in ipairs({
            "next_message",
            "previous_message",
            "toggle",
            "reply",
            "edit",
            "close",
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
        api.nvim_create_autocmd({
            "WinEnter",
            "BufEnter",
            "WinClosed",
            "BufWipeout",
            "WinResized",
            "VimResized",
            "TextChanged",
            "TextChangedI",
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
        api.nvim_create_autocmd("WinScrolled", {
            group = view.group,
            callback = function(event)
                if event.match == tostring(options.source_win) then
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
        M.close(view, false)
        error(failure, 0)
    end
    return view
end

return M
