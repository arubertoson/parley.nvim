---Local conversation ownership and source actions, independent of Pi/binding.
---Callers supply conversation data and validated source placements. This module
---retains drafts/native undo and coordinates the existing presentation modules;
---closing an attachment releases UI only, never history or draft buffers.
local composer = require("parley.composer")
local config = require("parley.config")
local discussion = require("parley.discussion")
local inline = require("parley.inline")
local keys = require("parley.composer.keymaps")
local style = require("parley.composer.style")
local thread = require("parley.thread")
local M = {}
local api = vim.api
local serial = 0

---@class ParleyConversation.Seed
---@field id? string
---@field messages? ParleyThread.Message[] Copied/validated in append order.
---@field lines? string[] Initial editable text, not a submitted human message.
---@field parent_id? string Exact parent for the initial reply draft.
---@field created_at? integer Initial draft creation time; defaults to now.

---@class ParleyConversation
---@field thread ParleyThread Canonical immutable committed history.
---@field note ParleyDiscussion.Draft Stable initial draft/source-card identity.
---@field drafts ParleyDiscussion.Draft[] All retained buffers, including older replies/revisions.
---@field replies table<string, ParleyDiscussion.Draft> Exact committed parent to reply draft.
---@field revisions table<string, ParleyDiscussion.Draft> Submitted human ID to copied draft.
---@field pending? ParleyDiscussion.Draft Only this unsent entry is currently presented.
---@field state ParleyDiscussion.State Retained reading state, not canonical history.

---@class ParleyConversation.Item
---@field conversation ParleyConversation
---@field first integer Validated live source range.
---@field last integer

---@class ParleyConversation.SourceOptions
---@field window integer
---@field label string Display identity of this source, not a filesystem lookup.
---@field items ParleyConversation.Item[] Borrowed; newly created notes are appended here.
---@field state? { selected: ParleyConversation? } Retained source selection.
---@field keymaps? ParleyConfig.Resolved Activation-time choices; defaults to configured keys.
---@field source_maps? boolean False when the workspace owns its visited-buffer maps.
---@field enabled? fun(): boolean Explicit-entry permission; never gates cleanup.
---@field created? fun(data: ParleyConversation, first: integer, last: integer) Associate a new note with caller-owned source anchors.
---@field selected? fun(data: ParleyConversation) Update caller-owned cross-file selection.
---@field navigate? fun(step: integer) Cross-file navigation belongs to the workspace.
---@field changed? fun() Host notification, after local presentation is refreshed.

---@class ParleyConversation.Source
---@field options ParleyConversation.SourceOptions
---@field window integer
---@field buffer integer
---@field items ParleyConversation.Item[] Validated placements only; unplaced data stays with its caller.
---@field state { selected: ParleyConversation? }
---@field keys ParleyConfig.Resolved
---@field view ParleyInline.View
---@field bindings table[]
---@field group? integer
---@field closed boolean
---@field presentation? ParleyConversation.Presentation

---@class ParleyConversation.Presentation
---@field source ParleyConversation.Source
---@field data ParleyConversation
---@field reader? ParleyDiscussion.View
---@field editor? ParleyComposer.Editor

---@type table<integer, ParleyConversation.Source>
local sources = {}
---@type ParleyConversation.Presentation?
local current

local function create_draft(data, lines)
    repeat
        serial = serial + 1
    until not thread.get(data.thread, "parley-draft-" .. serial)
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buffer, ("parley://draft/%d.md"):format(serial))
    vim.b[buffer].parley_composer = true
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undofile = false
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines or { "" })
    local draft = {
        id = serial,
        entry_id = "parley-draft-" .. serial,
        buffer = buffer,
        created_at = os.time(),
    }
    data.drafts[#data.drafts + 1] = draft
    return draft
end

---Build an isolated local conversation. No window, binding or transport needed.
---The caller retains this object across attachment/detachment; buffers are never
---recreated on entry, and incoming messages never commit its editable text.
---@param seed? ParleyConversation.Seed
---@return ParleyConversation
function M.new(seed)
    seed = seed or {}
    local history = thread.new(seed.id or ("conversation-" .. (serial + 1)))
    for _, message in ipairs(seed.messages or {}) do
        local appended, failure = thread.append(history, message)
        assert(appended, failure)
    end
    if seed.parent_id then
        assert(thread.get(history, seed.parent_id), "Parley: draft parent is not active history")
    end
    local data = { thread = history, drafts = {}, replies = {}, revisions = {}, state = {} }
    data.note = create_draft(data, seed.lines)
    data.note.parent_id = seed.parent_id
    data.note.created_at = seed.created_at or data.note.created_at
    if seed.parent_id then
        data.replies[seed.parent_id] = data.note
    end
    return data
end

local function reply_draft(data, parent_id)
    if parent_id == nil then
        assert(data.note.parent_id == nil, "Parley: initial comment has a reply parent")
        data.pending = data.note
    else
        assert(thread.get(data.thread, parent_id), "Parley: reply parent is not active history")
        local draft = data.replies[parent_id]
        if not draft then
            draft = create_draft(data)
            draft.parent_id = parent_id
            data.replies[parent_id] = draft
        end
        data.pending = draft
    end
    return data.pending
end

local function revision_draft(data, id)
    local message = assert(thread.get(data.thread, id))
    assert(message.role == "human", "Parley: only human messages can be revised")
    local draft = data.revisions[id]
    if not draft then
        draft = create_draft(data, message.lines)
        draft.parent_id = message.parent_id
        draft.replaces_id = id
        data.revisions[id] = draft
    end
    data.pending = draft
    return draft
end

---@param data ParleyConversation
---@return ParleyInline.Preview? preview Nil uses the initial local-note card.
function M.preview(data)
    if #data.thread.messages == 0 then
        return
    end
    if data.pending then
        return {
            buffer = data.pending.buffer,
            role = "human",
            state = ("draft · %d entries"):format(#data.thread.messages + 1),
            created_at = data.pending.created_at,
        }
    end
    local latest = data.thread.messages[#data.thread.messages]
    return {
        lines = latest.lines,
        role = latest.role,
        state = ("%d messages"):format(#data.thread.messages),
        created_at = latest.created_at,
    }
end

local function available(source)
    return not source.closed
        and sources[source.window] == source
        and api.nvim_win_is_valid(source.window)
        and api.nvim_win_get_buf(source.window) == source.buffer
end

local function focused(source)
    return available(source)
        and api.nvim_get_current_win() == source.window
        and (source.options.enabled == nil or source.options.enabled())
end

local function ready_to_show(source)
    if not focused(source) or current ~= nil then
        return false
    end
    -- Teardown hooks can open a composer at a different source without moving
    -- focus. Do not let a subsequent show reclaim that replacement either.
    for _, window in ipairs(api.nvim_list_wins()) do
        if composer.owns_source_window(window) then
            return false
        end
    end
    return true
end

local function find_item(source, data)
    for _, item in ipairs(source.items) do
        if item.conversation == data then
            return item
        end
    end
end

---Refresh only supplied placements. Never discover files, select, focus or scroll.
---@param source ParleyConversation.Source
---@param items? ParleyConversation.Item[] Revalidated by the source owner.
---@param selected? ParleyConversation
function M.refresh(source, items, selected)
    if not available(source) then
        return
    end
    if items then
        source.items = items
    end
    if selected then
        source.state.selected = selected
    end
    local cards = {}
    for _, item in ipairs(source.items) do
        cards[#cards + 1] = {
            note = item.conversation.note,
            preview = M.preview(item.conversation),
            first = item.first,
            last = item.last,
        }
    end
    local selection = source.state.selected
    inline.update(source.view, source.buffer, cards, selection and selection.note.id)
end

local function changed(source)
    M.refresh(source)
    if source.options.changed then
        source.options.changed()
    end
end

---Release this exact presentation before callbacks can open a replacement.
---@param source ParleyConversation.Source
---@param restore? boolean
function M.close(source, restore)
    local presentation = source.presentation
    if not presentation then
        return
    end
    source.presentation = nil
    if current == presentation then
        current = nil
    end
    local reader, editor = presentation.reader, presentation.editor
    local closed, failure = pcall(function()
        if reader then
            discussion.close(reader, restore)
        end
    end)
    local released, err = pcall(function()
        if editor then
            composer.close(restore, editor)
        end
    end)
    if not closed then
        error(failure, 0)
    end
    if not released then
        error(err, 0)
    end
end

---Enter the previewed entry, explicitly reply, resume retained reading state, or
---only reveal the source card (nil). This is the same action for every caller.
---@param source ParleyConversation.Source
---@param data ParleyConversation
---@param entry? 'read'|'reply'|'resume'
---@param label? string Original identity for an explicitly unplaced local note.
---@return boolean opened
function M.show(source, data, entry, label)
    if not focused(source) then
        return false
    end
    if current then
        M.close(current.source, false)
    end
    if not ready_to_show(source) then
        return false
    end
    source.state.selected = data
    M.refresh(source)
    if not ready_to_show(source) then
        return false
    end
    local item = find_item(source, data)
    if item then
        inline.reveal(source.view)
    end
    if not ready_to_show(source) then
        return false
    end
    if source.options.selected then
        source.options.selected(data)
    end
    changed(source)
    if not ready_to_show(source) then
        return false
    end
    item = find_item(source, data)
    if not entry and item then
        return true
    end
    if #data.thread.messages > 0 and not item then
        vim.notify(
            "Parley: conversation source is unplaced; history and drafts retained",
            vim.log.levels.WARN
        )
        return false
    end

    local presentation = { source = source, data = data }
    source.presentation, current = presentation, presentation
    local room_owner = {}
    local room = item
            and {
                namespace = source.view.namespace,
                reserve = function(row, lines)
                    return inline.reserve(source.view, data.note.id, row, lines, room_owner)
                end,
                release = function()
                    inline.release(source.view, room_owner)
                end,
            }
        or nil
    local source_label = label
        or (source.options.label .. ":" .. (item and item.first or "unplaced"))
    local opened, failure = pcall(function()
        if #data.thread.messages == 0 then
            data.pending = data.note
            local editor = composer.show(data.note, {
                source_win = source.window,
                source_label = source_label,
                first = item and item.first,
                last = item and item.last,
                keymaps = source.keys.composer,
                enter = entry ~= nil,
                room = room,
                navigate = function(step)
                    M.move(source, step)
                end,
                changed = function()
                    changed(source)
                end,
            })
            presentation.editor = editor
            if source.presentation ~= presentation then
                if editor then
                    composer.close(false, editor)
                end
                return
            end
        else
            local latest = data.thread.messages[#data.thread.messages]
            local message_id = entry ~= "resume"
                    and (data.pending and data.pending.entry_id or latest.id)
                or nil
            local continue_draft = entry == "reply" or (entry == "read" and data.pending ~= nil)
            local reader = discussion.open(data.thread, {
                source_win = source.window,
                source_label = source_label,
                first = assert(item).first,
                last = item.last,
                room = assert(room),
                state = data.state,
                message_id = message_id,
                enter = not continue_draft,
                keymaps = source.keys.discussion,
                composer_keymaps = source.keys.composer,
                reply = function(parent_id)
                    return reply_draft(data, parent_id)
                end,
                edit = function(id)
                    return revision_draft(data, id)
                end,
                draft = function()
                    return data.pending
                end,
                changed = function()
                    changed(source)
                end,
            })
            presentation.reader = reader
            if source.presentation ~= presentation then
                discussion.close(reader, false)
                return
            end
            if reader and continue_draft and not discussion.reply(reader) then
                M.close(source, false)
            end
        end
    end)
    if not opened then
        if source.presentation == presentation then
            pcall(M.close, source, false)
        end
        error(failure, 0)
    end
    return source.presentation == presentation
        and (presentation.reader ~= nil or presentation.editor ~= nil)
end

---Associate supplied data with an already validated source range. The source
---owner captures anchors here, not in the fixture or conversation implementation.
---@param source ParleyConversation.Source
---@param data ParleyConversation
---@param first integer
---@param last integer
function M.add(source, data, first, last)
    assert(available(source), "Parley: source attachment is unavailable")
    assert(
        first >= 1 and last >= first and last <= api.nvim_buf_line_count(source.buffer),
        "Parley: invalid source range"
    )
    if source.options.created then
        source.options.created(data, first, last)
    end
    source.items[#source.items + 1] = { conversation = data, first = first, last = last }
end

---@param source ParleyConversation.Source
---@param range? boolean Native Visual selection; otherwise the cursor line.
---@return ParleyConversation? data
function M.comment(source, range)
    if not focused(source) then
        return
    end
    local first = api.nvim_win_get_cursor(source.window)[1]
    local last = first
    if range then
        first, last = math.min(vim.fn.line("v"), first), math.max(vim.fn.line("v"), first)
        vim.cmd("normal! " .. api.nvim_replace_termcodes("<Esc>", true, false, true))
    end
    if not focused(source) then
        return
    end
    for index = #source.items, 1, -1 do
        local item = source.items[index]
        if item.first == first and item.last == last then
            M.show(source, item.conversation, "read")
            return item.conversation
        end
    end
    local data = M.new()
    M.add(source, data, first, last)
    M.show(source, data, "read")
    return data
end

---@param source ParleyConversation.Source
---@param create? boolean
---@param entry? 'read'|'reply'
function M.edit(source, create, entry)
    if not focused(source) then
        return
    end
    local line = api.nvim_win_get_cursor(source.window)[1]
    local selected = source.state.selected and find_item(source, source.state.selected)
    if selected and line >= selected.first and line <= selected.last then
        return M.show(source, selected.conversation, entry or "read")
    end
    for index = #source.items, 1, -1 do
        local item = source.items[index]
        if line >= item.first and line <= item.last then
            return M.show(source, item.conversation, entry or "read")
        end
    end
    if create then
        M.comment(source)
    else
        vim.notify("Parley: no note at the cursor; c creates a draft", vim.log.levels.INFO)
    end
end

---@param source ParleyConversation.Source
---@param step integer
function M.move(source, step)
    if not focused(source) then
        return
    end
    if source.options.navigate then
        source.options.navigate(step)
        return
    end
    local items = vim.list_extend({}, source.items)
    table.sort(items, function(left, right)
        if left.first ~= right.first then
            return left.first < right.first
        end
        return left.conversation.note.id < right.conversation.note.id
    end)
    for index, item in ipairs(items) do
        if item.conversation == source.state.selected then
            M.show(source, items[(index - 1 + step) % #items + 1].conversation)
            return
        end
    end
    if #items > 0 then
        M.show(source, items[step > 0 and 1 or #items].conversation)
    end
end

---Receive one explicitly supplied committed record. No discovery, model work,
---draft commitment, automatic selection or reply-target migration occurs here.
---@param data ParleyConversation
---@param message ParleyThread.Message
---@return true? success
---@return string? failure
function M.receive(data, message)
    if type(message) ~= "table" then
        return nil, "message must be a table"
    end
    for _, draft in ipairs(data.drafts) do
        if message.id == draft.entry_id then
            return nil, "message id belongs to an editable draft"
        end
    end
    local appended, failure = thread.append(data.thread, message)
    if not appended then
        return nil, failure
    end
    local presentation = current
    if presentation and presentation.data == data and presentation.reader then
        discussion.update(presentation.reader)
    end
    for _, source in pairs(sources) do
        if find_item(source, data) then
            changed(source)
        end
    end
    return true
end

---Detach only this source lifetime. Mandatory cleanup survives notification/hook
---errors and cannot close a replacement presentation opened by those hooks.
---@param source ParleyConversation.Source?
function M.detach(source)
    if not source or source.closed then
        return
    end
    source.closed = true
    if sources[source.window] == source then
        sources[source.window] = nil
    end
    local failed, failure
    local function finish(action)
        local ok, err = pcall(action)
        if not ok and not failed then
            failed, failure = true, err
        end
    end
    finish(function()
        if source.group then
            api.nvim_del_augroup_by_id(source.group)
        end
    end)
    finish(function()
        if api.nvim_buf_is_loaded(source.buffer) then
            api.nvim_buf_call(source.buffer, function()
                for _, binding in ipairs(source.bindings) do
                    local mapping = vim.fn.maparg(binding.key, binding.mode, false, true)
                    if mapping.buffer == 1 and mapping.callback == binding.action then
                        vim.keymap.del(binding.mode, binding.key, { buffer = source.buffer })
                        if binding.original.buffer == 1 then
                            vim.fn.mapset(binding.mode, false, binding.original)
                        end
                    end
                end
            end)
        end
    end)
    finish(function()
        inline.clear(source.view)
    end)
    finish(function()
        M.close(source, false)
    end)
    if failed then
        error(failure, 0)
    end
end

---Attach a supplied local scenario to one source window. Scratch fixtures and
---workspace files use this same API; workspace validation remains outside it.
---@param options ParleyConversation.SourceOptions
---@return ParleyConversation.Source
function M.attach(options)
    local previous = sources[options.window]
    if previous then
        M.detach(previous)
        assert(not sources[options.window], "Parley: source replaced during detach")
    end
    local source = {
        options = options,
        window = options.window,
        buffer = api.nvim_win_get_buf(options.window),
        items = options.items,
        state = options.state or {},
        keys = options.keymaps or config.get(),
        view = inline.open(options.window),
        bindings = {},
        closed = false,
    }
    sources[source.window] = source
    local initialized, failure = pcall(function()
        style.refresh()
        if options.source_maps ~= false then
            local actions = {
                {
                    name = "comment",
                    mode = "n",
                    run = function()
                        M.comment(source)
                    end,
                },
                {
                    name = "comment",
                    mode = "x",
                    run = function()
                        M.comment(source, true)
                    end,
                },
                {
                    name = "edit",
                    mode = "n",
                    run = function()
                        M.edit(source, true)
                    end,
                },
                {
                    name = "edit",
                    mode = "x",
                    run = function()
                        M.comment(source, true)
                    end,
                },
                {
                    name = "enter",
                    mode = "n",
                    run = function()
                        M.edit(source)
                    end,
                },
                {
                    name = "reply",
                    mode = "n",
                    run = function()
                        M.edit(source, false, "reply")
                    end,
                },
                {
                    name = "next",
                    mode = "n",
                    run = function()
                        M.move(source, 1)
                    end,
                },
                {
                    name = "previous",
                    mode = "n",
                    run = function()
                        M.move(source, -1)
                    end,
                },
            }
            api.nvim_buf_call(source.buffer, function()
                for _, action in ipairs(actions) do
                    for _, configured_key in ipairs(source.keys.review[action.name]) do
                        local key = keys.concrete(configured_key)
                        source.bindings[#source.bindings + 1] = {
                            key = key,
                            mode = action.mode,
                            action = action.run,
                            original = vim.fn.maparg(key, action.mode, false, true),
                        }
                    end
                end
            end)
            for _, binding in ipairs(source.bindings) do
                vim.keymap.set(binding.mode, binding.key, binding.action, {
                    buffer = source.buffer,
                    desc = "Parley: local conversation action",
                })
            end
        end
        source.group =
            api.nvim_create_augroup("ParleyConversationSource" .. source.window, { clear = true })
        api.nvim_create_autocmd({ "BufWinLeave", "WinClosed" }, {
            group = source.group,
            callback = function()
                vim.schedule(function()
                    if not source.closed and not available(source) then
                        M.detach(source)
                    end
                end)
            end,
        })
        api.nvim_create_autocmd({ "WinResized", "VimResized", "ColorScheme" }, {
            group = source.group,
            callback = function(event)
                if event.event == "ColorScheme" then
                    style.refresh()
                end
                if not composer.owns_source_window(source.window) then
                    M.refresh(source)
                end
            end,
        })
        M.refresh(source)
    end)
    if not initialized then
        pcall(M.detach, source)
        error(failure, 0)
    end
    return source
end

return M
