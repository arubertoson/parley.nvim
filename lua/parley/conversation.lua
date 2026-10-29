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
-- Capture handles own private copies; exporting a payload never lends out draft
-- buffers or mutable history. Unused handles can be collected by their caller.
local captures = setmetatable({}, { __mode = "k" })

local function fresh_id(kind)
    serial = serial + 1
    return ("parley-%s-%d-%.0f-%d"):format(kind, vim.uv.os_getpid(), vim.uv.hrtime(), serial)
end

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
---@field pending? ParleyDiscussion.Draft Only this retained editable entry is currently presented.
---@field state ParleyDiscussion.State Retained reading state, not canonical history.
---@field response? ParleyDiscussion.Response Transient exact-request slot, never committed history.
---@field resolved? boolean Editor-local submission filter; history and drafts survive.
---@field deleted? boolean Retained locally, excluded from presentation and submission.

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
---@field thread_action? fun(action: 'resolve'|'reopen'|'delete') Operate on the active thread in the host.
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
    local history = thread.new(seed.id or fresh_id("conversation"))
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

-- Accepted text keeps its buffer and undo tree, but is not another draft entry.
local function visible_draft(data)
    local draft = data.pending
    if
        draft
        and draft.accepted
        and api.nvim_buf_is_loaded(draft.buffer)
        and vim.deep_equal(
            api.nvim_buf_get_lines(draft.buffer, 0, -1, false),
            draft.accepted.lines
        )
    then
        return nil
    end
    return draft
end

---@param data ParleyConversation
---@return ParleyInline.Preview? preview Nil uses the initial local-note card.
function M.preview(data)
    local draft = visible_draft(data)
    if data.response and not draft then
        return data.response
    end
    if data.resolved then
        local latest = data.thread.messages[#data.thread.messages]
        return {
            buffer = not latest and data.note.buffer or nil,
            lines = latest and latest.lines or nil,
            role = latest and latest.role or "human",
            state = "resolved",
            created_at = latest and latest.created_at or data.note.created_at,
        }
    end
    if #data.thread.messages == 0 then
        return
    end
    if draft then
        return {
            buffer = draft.buffer,
            role = "human",
            state = ("draft · %d entries"):format(#data.thread.messages + 1),
            created_at = draft.created_at,
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
        if not item.conversation.deleted then
            cards[#cards + 1] = {
                note = item.conversation.note,
                preview = M.preview(item.conversation),
                first = item.first,
                last = item.last,
            }
        end
    end
    local selection = source.state.selected
    inline.update(source.view, source.buffer, cards, selection and selection.note.id)
end

---Activity arrivals refresh an existing reader only. General source/layout
---refresh must not feed reader geometry changes back into another layout pass.
---@param source ParleyConversation.Source
function M.update_reply(source)
    local presentation = source.presentation
    if
        available(source)
        and presentation
        and presentation.reader
        and not presentation.reader.composing
    then
        discussion.update(presentation.reader)
    end
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

---Return only the currently focused thread, never a remembered selection from
---another window or a source range that no longer contains the cursor.
---@return ParleyConversation?
function M.active()
    local window, buffer = api.nvim_get_current_win(), api.nvim_get_current_buf()
    local function reading(display)
        return display and display.window == window and display.buffer == buffer
    end
    local function composing(editor)
        return editor and editor.window == window and editor.note.buffer == buffer
    end
    local presentation = current
    if presentation and not presentation.data.deleted then
        local reader = presentation.reader
        if
            composing(presentation.editor)
            or reader
                and not reader.closed
                and (reading(reader) or reading(reader.parent) or composing(reader.editor))
        then
            return presentation.data
        end
    end
    local source = sources[window]
    if source and focused(source) then
        local data = source.state.selected
        local item = data and not data.deleted and find_item(source, data)
        local line = api.nvim_win_get_cursor(window)[1]
        if item and line >= item.first and line <= item.last then
            return data
        end
    end
end

---Release only this deleted thread's views. All retained text and source
---attachments belong to the host and remain available for inspection.
---@param data ParleyConversation
function M.hide(data)
    for _, source in pairs(sources) do
        if source.state.selected == data then
            source.state.selected = nil
        end
        if source.presentation and source.presentation.data == data then
            M.close(source, true)
        end
        M.refresh(source)
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
    if data.deleted or not focused(source) then
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
                thread_action = source.options.thread_action,
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
            local draft = visible_draft(data)
            local message_id = entry ~= "resume"
                    and (draft and draft.entry_id or (data.response and data.response.id) or latest.id)
                or nil
            local continue_draft = entry == "reply" or (entry == "read" and draft ~= nil)
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
                thread_action = source.options.thread_action,
                reply = function(parent_id)
                    return reply_draft(data, parent_id)
                end,
                edit = function(id)
                    return revision_draft(data, id)
                end,
                draft = function(editing)
                    return editing and data.pending or visible_draft(data)
                end,
                response = function()
                    return data.response
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
        if not item.conversation.deleted and item.first == first and item.last == last then
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
    if
        selected
        and not selected.conversation.deleted
        and line >= selected.first
        and line <= selected.last
    then
        return M.show(source, selected.conversation, entry or "read")
    end
    for index = #source.items, 1, -1 do
        local item = source.items[index]
        if not item.conversation.deleted and line >= item.first and line <= item.last then
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
    local items = {}
    for _, item in ipairs(source.items) do
        if not item.conversation.deleted then
            items[#items + 1] = item
        end
    end
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

---@class ParleyConversation.Capture
---@field conversation_id string
---@field base_version integer
---@field base_tip_id? string
---@field message ParleyThread.Message Fresh submitted identity, never a draft entry ID.
---@field version integer
---@field supersedes string[] Exact active suffix removed by accepting this prose.
---@field replaces_id? string

---Capture only the current eligible entry (or the initial note before entry).
---The returned handle is read-only; its private snapshot is independent of later
---edits. Empty/unchanged prose returns nil without error. Older retained drafts
---are not implicitly selected, retargeted or submitted alongside the current one.
---@param data ParleyConversation
---@param author string
---@param origin string
---@return ParleyConversation.Capture? capture
---@return string? failure
function M.capture(data, author, origin)
    if data.deleted or data.resolved then
        return
    end
    local draft = data.pending or data.note
    if not api.nvim_buf_is_loaded(draft.buffer) then
        return nil, "retained draft buffer is unavailable; it was not recreated"
    end
    local lines = api.nvim_buf_get_lines(draft.buffer, 0, -1, false)
    if not table.concat(lines, "\n"):find("%S") then
        return
    end
    local accepted = draft.accepted
    if accepted and vim.deep_equal(lines, accepted.lines) then
        return
    end
    local history = data.thread
    local replaces_id = accepted and accepted.id or draft.replaces_id
    if replaces_id then
        local replaced = thread.get(history, replaces_id)
        if not replaced or replaced.role ~= "human" or replaced.parent_id ~= draft.parent_id then
            return nil, "draft revision target is no longer active; exact parent retained"
        end
        if not accepted and vim.deep_equal(lines, replaced.lines) then
            return
        end
    end
    local parent_index = 0
    if draft.parent_id then
        for index, message in ipairs(history.messages) do
            if message.id == draft.parent_id then
                parent_index = index
                break
            end
        end
        if parent_index == 0 then
            return nil, "draft parent is no longer active; exact parent retained"
        end
    end
    local supersedes = {}
    for index = parent_index + 1, #history.messages do
        supersedes[#supersedes + 1] = history.messages[index].id
    end
    if replaces_id and supersedes[1] ~= replaces_id then
        return nil, "draft revision does not replace the exact active suffix"
    end
    local message = {
        id = fresh_id("message"),
        parent_id = draft.parent_id,
        role = "human",
        author = author,
        origin = origin,
        created_at = os.time(),
        lines = lines,
    }
    -- Validate all immutable fields without changing the live conversation.
    local staged = {
        id = history.id,
        version = history.version,
        messages = history.messages,
        superseded = vim.list_extend({}, history.superseded),
    }
    local valid, failure = thread.rewind(staged, draft.parent_id, message, history.version)
    if not valid then
        return nil, failure
    end
    local tip = history.messages[#history.messages]
    local capture = {
        conversation_id = history.id,
        base_version = history.version,
        base_tip_id = tip and tip.id,
        message = message,
        version = history.version + 1,
        supersedes = supersedes,
        replaces_id = replaces_id,
    }
    captures[capture] = { data = data, draft = draft, snapshot = vim.deepcopy(capture) }
    return capture
end

---Only the trusted caller at durable request acceptance may invoke this. All
---captures are preflighted before publishing any history; failure changes none.
---No callbacks/UI work occurs in the commit phase. In particular, acceptance
---never writes, clears, closes or replaces a draft buffer, even after more edits.
---@param batch ParleyConversation.Capture[] Original handles, not decoded JSON.
---@return true? accepted
---@return string? failure
function M.accept(batch)
    local plans, seen = {}, {}
    for _, capture in ipairs(batch) do
        local saved = captures[capture]
        if not saved or not vim.deep_equal(capture, saved.snapshot) then
            return nil, "submission capture is unknown, changed or already accepted"
        end
        local data, snapshot = saved.data, saved.snapshot
        if data.deleted then
            return nil,
                "conversation was deleted after capture; evidence retained without application"
        end
        if seen[snapshot.conversation_id] then
            return nil, "submission captures more than one draft for a conversation"
        end
        seen[snapshot.conversation_id] = true
        local history = data.thread
        local tip = history.messages[#history.messages]
        if
            history.id ~= snapshot.conversation_id
            or history.version ~= snapshot.base_version
            or (tip and tip.id) ~= snapshot.base_tip_id
        then
            return nil, "conversation changed after capture; accepted evidence was not retargeted"
        end
        local staged = {
            id = history.id,
            version = history.version,
            messages = history.messages,
            superseded = vim.list_extend({}, history.superseded),
        }
        local valid, failure = thread.rewind(
            staged,
            snapshot.message.parent_id,
            snapshot.message,
            snapshot.base_version
        )
        if not valid then
            return nil, failure
        end
        plans[#plans + 1] = {
            capture = capture,
            saved = saved,
            staged = staged,
            accepted = vim.deepcopy(snapshot.message),
        }
    end
    for _, plan in ipairs(plans) do
        local data, draft = plan.saved.data, plan.saved.draft
        local snapshot, staged = plan.saved.snapshot, plan.staged
        data.thread.messages = staged.messages
        data.thread.superseded = staged.superseded
        data.thread.version = staged.version
        draft.accepted = plan.accepted
        -- Editing the accepted human message resumes this very buffer/undo tree.
        -- Its parent never moves, including when post-capture edits already exist.
        data.revisions[snapshot.message.id] = draft
        captures[plan.capture] = nil
    end
    return true
end

---Atomically receive a compatible append-only batch without presentation work.
---The host may refresh later; no draft, selection, geometry or hook changes here.
---Preflight uses a private thread copy, including superseded-ID provenance.
---@param data ParleyConversation
---@param messages ParleyThread.Message[]
---@param expected_version integer
---@param expected_tip_id? string
---@return true? success
---@return string? failure
function M.receive_batch(data, messages, expected_version, expected_tip_id)
    if data.deleted then
        return nil, "conversation is deleted; incoming evidence was not applied"
    end
    if type(messages) ~= "table" or not vim.islist(messages) or #messages == 0 then
        return nil, "incoming messages must be a nonempty dense array"
    end
    local history = data.thread
    local tip = history.messages[#history.messages]
    if history.version ~= expected_version or (tip and tip.id or nil) ~= expected_tip_id then
        return nil, "conversation no longer has the exact submitted version/tip"
    end
    local proposed = vim.deepcopy(history)
    for _, message in ipairs(messages) do
        if type(message) ~= "table" then
            return nil, "message must be a table"
        end
        for _, draft in ipairs(data.drafts) do
            if message.id == draft.entry_id then
                return nil, "message id belongs to an editable draft"
            end
        end
        local appended, failure = thread.append(proposed, message)
        if not appended then
            return nil, failure
        end
    end
    history.messages, history.version = proposed.messages, proposed.version
    return true
end

---Receive one explicitly supplied committed record. No discovery, model work,
---draft commitment, automatic selection or reply-target migration occurs here.
---@param data ParleyConversation
---@param message ParleyThread.Message
---@return true? success
---@return string? failure
function M.receive(data, message)
    if data.deleted then
        return nil, "conversation is deleted; incoming evidence was not applied"
    end
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
            if options.thread_action then
                for _, name in ipairs({ "resolve", "reopen", "delete" }) do
                    actions[#actions + 1] = {
                        name = name,
                        mode = "n",
                        run = function()
                            options.thread_action(name)
                        end,
                    }
                end
            end
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
