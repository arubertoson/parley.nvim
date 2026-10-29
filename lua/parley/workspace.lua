---Editor-local notes and navigation, bound to one verified workspace/Pi session.
---Hidden prose buffers own text/native undo. Source extmarks and original selected
---lines establish conservative placement, not frozen evidence or submission state.
---Detach/disconnect retain notes in this Neovim process; there is no restart store.
local config = require("parley.config")
local composer = require("parley.composer")
local conversation = require("parley.conversation")
local keys = require("parley.composer.keymaps")
local style = require("parley.composer.style")
local M = {}
local api = vim.api
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@class ParleyWorkspace.Binding
---@field workspace string Canonical workspace root.
---@field sessionId string Pi conversation identity, independent of runtime reloads.
---@field editorId? string Paired editor identity; required for submission provenance.

---@class ParleyWorkspace.Note: ParleyDiscussion.Draft
---@field conversation ParleyConversation Shared conversation data; source metadata stays here.
---@field path string Original workspace-relative source path.
---@field source_buf? integer
---@field namespace? integer Retained, invisible source anchors.
---@field anchor? integer
---@field observation? table Immutable imported source observation, not current placement.
---@field first integer Original line, identifying an unplaced note.
---@field context string[] Original selected lines, never refreshed on reopen.
---@field observed_at integer Original editor observation, not submission time.
---@field source_tick integer Original source-buffer version, including unsaved edits.
---@field source_editor_id? string Paired editor which made the original observation.

---@class ParleyWorkspace.Drafts
---@field notes ParleyWorkspace.Note[] Creation order, not navigation order.
---@field selected? ParleyWorkspace.Note
---@field review_id? string Durable review owner; nil until first explicit request.
---@field workflow? 'review'|'parley' Immutable authority for this draft owner.

---@class ParleyWorkspace.Keymap
---@field mode string
---@field key string
---@field action fun()
---@field description string

---@class ParleyWorkspace.Active: ParleyWorkspace.Binding
---@field group integer
---@field window? integer Last visited workspace source window.
---@field drafts ParleyWorkspace.Drafts Borrowed from the conversation cache.
---@field keymaps ParleyConfig.Resolved Read-only configuration snapshot.
---@field bindings ParleyWorkspace.Keymap[] Keys installed for this activation.
---@field reply_activity? { saved: table, responses: table<ParleyConversation, ParleyDiscussion.Response>, frame: integer, timer?: uv.uv_timer_t } One accepted request's transient UI.
---@field maps table<integer, table[]> Original mapping overrides by visited file buffer.
---@field views table<integer, ParleyConversation.Source> Owned source attachments.
---@field selection? { window: integer, buffer: integer, line: integer }
---@field refresh_pending? boolean
---@field selection_allowed? boolean Only explicit :Parley start can select another review.

---@class ParleyWorkspace.Source
---@field review ParleyWorkspace.Active
---@field window integer
---@field buffer integer
---@field path string

---@type ParleyWorkspace.Active?
local active
---@type table<string, table<string, ParleyWorkspace.Drafts>>
local conversations = {}
---@type table<string, table<string, table<string, ParleyWorkspace.Drafts>>>
local review_drafts = {}
---@type table<table, table>
local requests = setmetatable({}, { __mode = "k" })
---@type integer?
local anchors
local place_imported
M.status = ""

---@param window integer
---@return integer? buffer
local function ordinary_file_buffer(window)
    if not api.nvim_win_is_valid(window) then
        return
    end

    local configuration = api.nvim_win_get_config(window)
    if configuration.relative ~= "" then
        return
    end

    local buffer = api.nvim_win_get_buf(window)
    if vim.bo[buffer].buftype ~= "" or vim.b[buffer].parley_composer then
        return
    end

    return buffer
end

---@param root string
---@param window? integer
---@return integer? buffer
---@return string? relative_path
local function workspace_source(root, window)
    local buffer = ordinary_file_buffer(window or api.nvim_get_current_win())
    if not buffer then
        return
    end

    local filename = vim.fs.normalize(api.nvim_buf_get_name(buffer))
    local workspace_prefix = root .. "/"
    if filename:sub(1, #workspace_prefix) ~= workspace_prefix then
        return
    end

    local relative_path = filename:sub(#workspace_prefix + 1)
    local repository_metadata = relative_path:match("^%.git/") or relative_path:match("^%.jj/")
    if relative_path == "" or repository_metadata then
        return
    end

    return buffer, relative_path
end

---Extmarks track movement, not permission to attach a note to changed text.
local function placement(review, note)
    if not note.source_buf or not api.nvim_buf_is_loaded(note.source_buf) then
        return
    end

    local filename = vim.fs.normalize(api.nvim_buf_get_name(note.source_buf))
    if filename ~= review.workspace .. "/" .. note.path then
        return
    end
    if not note.namespace or not note.anchor then
        return
    end

    local mark = api.nvim_buf_get_extmark_by_id(
        note.source_buf,
        note.namespace,
        note.anchor,
        { details = true }
    )
    local details = mark[3]
    if not details or details.invalid or details.end_col ~= 0 then
        return
    end

    local first, last = mark[1] + 1, details.end_row
    if not last or last < first or last > api.nvim_buf_line_count(note.source_buf) then
        return
    end

    local lines = api.nvim_buf_get_lines(note.source_buf, first - 1, last, false)
    if not vim.deep_equal(lines, note.context) then
        return
    end

    return first, last
end

local function placed_items(review, buffer)
    local items = {}
    for _, note in ipairs(review.drafts.notes) do
        if not note.conversation.deleted and note.source_buf == buffer then
            local first, last = placement(review, note)
            if first and last then
                items[#items + 1] = {
                    conversation = note.conversation,
                    first = first,
                    last = last,
                }
            end
        end
    end
    return items
end

local function cache_status()
    local review = active
    M.status = ""
    if review then
        local count = 0
        for _, note in ipairs(review.drafts.notes) do
            if not note.conversation.deleted then
                count = count + 1
            end
        end
        M.status = ("Workspace review · %d notes"):format(count)
        if review.drafts.workflow == "parley" then
            M.status = ("Parley implementation · %d notes"):format(count)
        end
        if review.reply_activity then
            M.status = spinner_frames[review.reply_activity.frame] .. " " .. M.status
        end
        local note = review.drafts.selected
        if note then
            local first = placement(review, note)
            local path = note.path:gsub("[%c]", "?")
            local position = (" · %s:%d"):format(path, first or note.first)
            M.status = M.status .. position .. (first and "" or " · unplaced")
        end
    end
end

local function changed()
    cache_status()
    api.nvim_exec_autocmds(
        "User",
        { pattern = "ParleyReviewChanged", data = { status = M.status } }
    )
end

function M.active_window()
    local review = active
    if review and review.window and workspace_source(review.workspace, review.window) then
        return review.window
    end
end

function M.is_active()
    return active ~= nil
end

---@return ParleyWorkspace.Source?
local function current_source()
    local review = active
    if not review then
        vim.notify("Parley: activate workspace review first", vim.log.levels.WARN)
        return
    end

    local window = api.nvim_get_current_win()
    if not ordinary_file_buffer(window) then
        vim.notify("Parley: note actions require an ordinary file window", vim.log.levels.WARN)
        return
    end

    local buffer, path = workspace_source(review.workspace, window)
    if not buffer or not path then
        vim.notify(
            "Parley: this file is outside the active workspace's source scope",
            vim.log.levels.WARN
        )
        return
    end

    -- An explicit source action can now place an imported observation which was
    -- previously unloaded/unsaved. Still no relocation or source opening.
    for _, note in ipairs(review.drafts.notes) do
        place_imported(review, note, buffer)
    end
    -- Explicit entry cannot rely on a scheduled TextChanged refresh having run.
    local view = review.views[window]
    if view then
        local selected = review.drafts.selected
        conversation.refresh(
            view,
            placed_items(review, buffer),
            selected and selected.conversation
        )
    end

    return { review = review, window = window, buffer = buffer, path = path }
end

local function refresh_sources(review)
    if active ~= review then
        return
    end

    local selected = review.drafts.selected
    for window, view in pairs(review.views) do
        local buffer = workspace_source(review.workspace, window)
        if view.closed or not buffer or view.buffer ~= buffer then
            review.views[window] = nil
            conversation.detach(view)
        elseif not composer.owns_source_window(window) then
            conversation.refresh(
                view,
                placed_items(review, buffer),
                selected and selected.conversation
            )
        end
    end
end

local function schedule_refresh(review)
    if active ~= review or review.refresh_pending then
        return
    end
    review.refresh_pending = true
    vim.schedule(function()
        review.refresh_pending = false
        if active == review then
            refresh_sources(review)
            changed()
        end
    end)
end

local function selected_position(review, window)
    review.selection = {
        window = window,
        buffer = api.nvim_win_get_buf(window),
        line = api.nvim_win_get_cursor(window)[1],
    }
end

local function show(review, note, window, enter)
    local view = review.views[window]
    if active ~= review or not view or api.nvim_get_current_win() ~= window then
        return
    end
    conversation.refresh(view, placed_items(review, view.buffer))
    conversation.show(
        view,
        note.conversation,
        enter and "read" or nil,
        ("%s:%d"):format(note.path:gsub("[%c]", "?"), note.first)
    )
    if active == review and api.nvim_win_is_valid(window) then
        selected_position(review, window)
    end
end

-- Source identity and conservative anchors belong to the workspace, not the
-- shared conversation API. Creation is explicit and never discovers evidence.
local function associate(review, window, data, first, last)
    assert(active == review, "Parley: workspace changed while creating a note")
    local buffer, path = workspace_source(review.workspace, window)
    assert(buffer and path, "Parley: note source is outside the workspace")
    anchors = anchors or api.nvim_create_namespace("parley.anchors")
    local anchor = api.nvim_buf_set_extmark(buffer, anchors, first - 1, 0, {
        end_row = last,
        end_col = 0,
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
    })
    local note = data.note
    note.conversation = data
    note.path, note.source_buf = path, buffer
    note.namespace, note.anchor = anchors, anchor
    note.first = first
    note.context = api.nvim_buf_get_lines(buffer, first - 1, last, false)
    note.observed_at = os.time()
    note.source_tick = api.nvim_buf_get_changedtick(buffer)
    note.source_editor_id = review.editorId
    review.drafts.notes[#review.drafts.notes + 1] = note
end

---Explicit local composition only: no source discovery, captures or submitted turns.
---@param scope 'line'|'range'
---@return ParleyConversation? data
function M.comment(scope)
    local source = current_source()
    if not source then
        return
    end
    local view = source.review.views[source.window]
    if view then
        return conversation.comment(view, scope == "range")
    end
end

---Associate explicitly supplied conversation data with the current validated
---workspace source. This local API does not connect, execute, select or submit.
---@param seed ParleyConversation.Seed
---@param first integer
---@param last integer
---@return ParleyConversation? data
function M.add_conversation(seed, first, last)
    local source = current_source()
    if not source then
        return
    end
    local view = source.review.views[source.window]
    if not view then
        return
    end
    local data = conversation.new(seed)
    conversation.add(view, data, first, last)
    refresh_sources(source.review)
    changed()
    return data
end

local function identifier(value)
    return type(value) == "string"
        and #value >= 1
        and #value <= 128
        and value:match("^[A-Za-z0-9_-]+$") ~= nil
end

-- Missing/deleted sources retain evidence, not a guessed new association.
local function source_contained(root, path)
    if type(path) ~= "string" or path == "" then
        return nil, "invalid workspace-relative source path"
    end
    if
        path:find("[\\%c]")
        or path:sub(1, 1) == "/"
        or path:match("^%a:")
        or path:sub(-1) == "/"
        or path:find("//", 1, true)
    then
        return nil, "invalid workspace-relative source path"
    end
    for part in path:gmatch("[^/]+") do
        if part == "." or part == ".." or part == ".git" or part == ".jj" then
            return nil, "invalid workspace-relative source path"
        end
    end
    local filename = root .. "/" .. path
    while true do
        local resolved, failure, code = vim.uv.fs_realpath(filename)
        if resolved then
            if resolved ~= root and resolved:sub(1, #root + 1) ~= root .. "/" then
                return nil, "source resolves outside the workspace"
            end
            local relative = resolved:sub(#root + 2)
            for part in relative:gmatch("[^/]+") do
                if part == ".git" or part == ".jj" then
                    return nil, "source resolves into repository metadata"
                end
            end
            return true
        end
        if code ~= "ENOENT" then
            return nil, "cannot validate source containment: " .. tostring(failure)
        end
        -- Deleted files can retain their observation. Unresolvable symlinks
        -- cannot be treated as deleted ordinary files or silently followed.
        local stat, stat_failure, stat_code = vim.uv.fs_lstat(filename)
        if stat or stat_code ~= "ENOENT" then
            return nil, "cannot validate missing source: " .. tostring(stat_failure or failure)
        end
        filename = vim.fs.dirname(filename)
        if not filename or #filename < #root then
            return nil, "cannot validate workspace source containment"
        end
    end
end

local function capture_anchor(review, note, editor_id)
    local contained, failure = source_contained(review.workspace, note.path)
    if not contained then
        return nil, failure
    end
    if note.observation then
        -- A disk observation does not become an editor observation on reply.
        return vim.deepcopy(note.observation)
    end
    if not note.observed_at or not note.source_tick or not note.source_editor_id then
        return nil, "original source observation is unavailable; draft retained"
    end
    if note.source_editor_id ~= editor_id then
        return nil, "source observation belongs to a different editor; draft retained"
    end
    return {
        path = note.path,
        side = "workspace",
        first = note.first,
        last = note.first + #note.context - 1,
        lines = vim.list_extend({}, note.context),
        observedAt = note.observed_at,
        source = {
            kind = "editor",
            editorId = note.source_editor_id,
            bufferId = note.source_buf,
            changedTick = note.source_tick,
        },
    }
end

-- A disk-origin finding may acquire an anchor only in an already loaded,
-- unmodified buffer, at its original coordinates. Never load a source here.
-- Compare disk and buffer independently: an unsaved buffer is not disk evidence.
place_imported = function(review, note, buffer)
    local observed = note.observation
    if active ~= review then
        return
    end
    if
        (note.source_buf and api.nvim_buf_is_valid(note.source_buf))
        or not observed
        or observed.side ~= "workspace"
        or observed.source.kind ~= "disk"
        or not api.nvim_buf_is_loaded(buffer)
        or vim.bo[buffer].buftype ~= ""
        or vim.bo[buffer].modified
        or api.nvim_buf_get_name(buffer) ~= review.workspace .. "/" .. note.path
        or not source_contained(review.workspace, note.path)
    then
        return
    end
    local filename = vim.uv.fs_realpath(review.workspace .. "/" .. note.path)
    if not filename then
        return
    end
    local before = vim.uv.fs_lstat(filename)
    if not before or before.type ~= "file" or before.size > 1024 * 1024 then
        return
    end
    local fd = vim.uv.fs_open(filename, "r", 0)
    if not fd then
        return
    end
    local checked, unchanged = pcall(function()
        local opened = vim.uv.fs_fstat(fd)
        if
            not opened
            or opened.type ~= "file"
            or opened.dev ~= before.dev
            or opened.ino ~= before.ino
            or opened.size ~= before.size
        then
            return false
        end
        local bytes = vim.uv.fs_read(fd, before.size + 1, 0)
        local after = vim.uv.fs_fstat(fd)
        local named = vim.uv.fs_stat(review.workspace .. "/" .. note.path)
        if
            not bytes
            or #bytes ~= before.size
            or not after
            or not named
            or opened.dev ~= after.dev
            or opened.ino ~= after.ino
            or opened.size ~= after.size
            or not vim.deep_equal(opened.mtime, after.mtime)
            or not vim.deep_equal(opened.ctime, after.ctime)
            or named.dev ~= after.dev
            or named.ino ~= after.ino
            or named.size ~= after.size
            or not vim.deep_equal(named.mtime, after.mtime)
            or not source_contained(review.workspace, note.path)
        then
            return false
        end
        local disk = vim.split(bytes, "\n", { plain = true })
        if disk[#disk] == "" then
            table.remove(disk)
        end
        if observed.last > #disk or observed.last > api.nvim_buf_line_count(buffer) then
            return false
        end
        for index, line in ipairs(observed.lines) do
            if disk[observed.first + index - 1] ~= line then
                return false
            end
        end
        return vim.deep_equal(
            api.nvim_buf_get_lines(buffer, observed.first - 1, observed.last, false),
            observed.lines
        )
    end)
    local closed = vim.uv.fs_close(fd)
    if not checked or not unchanged or not closed then
        return
    end
    anchors = anchors or api.nvim_create_namespace("parley.anchors")
    -- A wiped buffer has lost its anchors. Reopening may establish a new one
    -- only after the same disk and buffer observation checks above.
    local mark = api.nvim_buf_set_extmark(buffer, anchors, observed.first - 1, 0, {
        end_row = observed.last,
        end_col = 0,
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
    })
    note.source_buf, note.namespace, note.anchor = buffer, anchors, mark
end

local function fields(value, names)
    if type(value) ~= "table" or vim.islist(value) then
        return false
    end
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    for _, name in ipairs(names) do
        if value[name] == nil then
            return false
        end
    end
    return count == #names
end

local function integer(value, minimum)
    return type(value) == "number"
        and value >= minimum
        and value <= 9007199254740991
        and value % 1 == 0
end

local function lines(value)
    if type(value) ~= "table" or not vim.islist(value) or #value == 0 then
        return false
    end
    for _, line in ipairs(value) do
        if type(line) ~= "string" or line:find("\n", 1, true) then
            return false
        end
    end
    return true
end

local function valid_observation(anchor)
    if
        not fields(anchor, { "path", "side", "first", "last", "lines", "observedAt", "source" })
        or (anchor.side ~= "workspace" and anchor.side ~= "base")
        or not integer(anchor.first, 1)
        or not integer(anchor.last, anchor.first)
        or not integer(anchor.observedAt, 0)
        or not lines(anchor.lines)
        or #anchor.lines ~= anchor.last - anchor.first + 1
    then
        return false
    end
    local source = anchor.source
    if fields(source, { "kind" }) and source.kind == "disk" then
        return anchor.side == "workspace"
    end
    if fields(source, { "kind", "commit" }) and source.kind == "commit" then
        return anchor.side == "base"
            and type(source.commit) == "string"
            and source.commit:find("%S") ~= nil
    end
    return fields(source, { "kind", "editorId", "bufferId", "changedTick" })
        and source.kind == "editor"
        and anchor.side == "workspace"
        and identifier(source.editorId)
        and integer(source.bufferId, 1)
        and integer(source.changedTick, 0)
end

local function publication_conflict(review, incoming)
    for _, note in ipairs(review.drafts.notes) do
        local history = note.conversation.thread
        if incoming[history.id] then
            return "publication identity belongs to an existing conversation"
        end
        local histories = { history.messages }
        for _, suffix in ipairs(history.superseded) do
            histories[#histories + 1] = suffix.messages
        end
        for _, messages in ipairs(histories) do
            for _, message in ipairs(messages) do
                if incoming[message.id] then
                    return "publication identity already exists in local history"
                end
            end
        end
        for _, draft in ipairs(note.conversation.drafts) do
            if incoming[draft.entry_id] then
                return "publication identity belongs to an editable draft"
            end
        end
    end
end

---Import a completed publication batch against a private accepted capture.
---This is a background data path: no focused-source API, file opening, selection,
---draft mutation or explicit presentation callbacks. All shapes/relations
---are preflighted before mutation. Compatible groups apply independently; each
---group returns an explicit application fact for the transport host to persist.
---The one-shot handle is consumed even if a native allocation subsequently fails.
---@param capture table Original accepted handle, never a decoded replacement.
---@param groups table[] Wire projections of published conversations/messages.
---@return table[]? receipts Local facts, not durable acknowledgments.
---@return string? failure
function M.import_results(capture, groups)
    local saved = requests[capture]
    if
        not saved
        or not saved.accepted
        or saved.imported
        or not vim.deep_equal(capture, saved.snapshot)
    then
        return nil, "missing, changed or already consumed accepted result owner"
    end
    if type(groups) ~= "table" or not vim.islist(groups) then
        return nil, "result conversations must be an array"
    end
    local review = saved.review
    local plans, ids = {}, {}
    for _, group in ipairs(groups) do
        if
            not fields(group, { "id", "anchor", "new", "baseVersion", "baseTipId", "messages" })
            or not identifier(group.id)
            or ids[group.id]
            or type(group.new) ~= "boolean"
            or not integer(group.baseVersion, 0)
            or not valid_observation(group.anchor)
            or (group.baseTipId ~= vim.NIL and not identifier(group.baseTipId))
            or type(group.messages) ~= "table"
            or not vim.islist(group.messages)
            or #group.messages == 0
        then
            return nil, "invalid/duplicate result conversation or source observation"
        end
        ids[group.id] = true
        local submitted
        for _, item in ipairs(saved.accepted.submissions) do
            if item.conversationId == group.id then
                submitted = item
            end
        end
        if group.new then
            if
                submitted
                or group.baseVersion ~= 0
                or group.baseTipId ~= vim.NIL
                or group.anchor.side ~= "workspace"
                or group.anchor.source.kind ~= "disk"
            then
                return nil,
                    "finding must have a new identity and an observed workspace disk anchor"
            end
        else
            local captured
            for _, item in ipairs(saved.snapshot.conversations) do
                if item.id == group.id then
                    captured = item
                end
            end
            if
                not submitted
                or not captured
                or group.baseVersion ~= submitted.version
                or group.baseTipId ~= submitted.tipId
                or not vim.deep_equal(group.anchor, captured.anchor)
            then
                return nil, "reply does not identify the exact submitted conversation/anchor"
            end
        end
        local plan = { group = group, messages = {}, messageIds = {}, incoming = {} }
        if group.new then
            plan.incoming[group.id] = true
        end
        local parent = group.baseTipId
        for index, message in ipairs(group.messages) do
            if
                not fields(message, {
                    "id",
                    "parentId",
                    "role",
                    "author",
                    "origin",
                    "createdAt",
                    "lines",
                    "version",
                })
                or not identifier(message.id)
                or ids[message.id]
                or message.role ~= "agent"
                or message.parentId ~= parent
                or message.version ~= group.baseVersion + index
                or not integer(message.version, 1)
                or type(message.author) ~= "string"
                or not message.author:find("%S")
                or type(message.origin) ~= "string"
                or not message.origin:find("%S")
                or not integer(message.createdAt, 0)
                or not lines(message.lines)
                or not table.concat(message.lines, "\n"):find("%S")
            then
                return nil,
                    "invalid/duplicate publication identity, provenance or parent/version chain"
            end
            ids[message.id] = true
            plan.incoming[message.id] = true
            parent = message.id
            plan.messages[#plan.messages + 1] = {
                id = message.id,
                parent_id = message.parentId ~= vim.NIL and message.parentId or nil,
                role = message.role,
                author = message.author,
                origin = message.origin,
                created_at = message.createdAt,
                lines = vim.deepcopy(message.lines),
            }
            plan.messageIds[#plan.messageIds + 1] = message.id
        end
        -- Path/containment failures are incompatible evidence, not permission to
        -- attach elsewhere. Keep validating the remaining groups before applying.
        local contained, failure = source_contained(review.workspace, group.anchor.path)
        plan.failure = not contained and failure or nil
        plans[#plans + 1] = plan
    end
    saved.imported = true
    local receipts = {}
    for _, plan in ipairs(plans) do
        local group = plan.group
        local failure = saved.incompatible
            or plan.failure
            or publication_conflict(review, plan.incoming)
        local data, note
        if active ~= review then
            failure = "accepted workspace lifetime is no longer active; no retargeting"
        end
        for _, candidate in ipairs(review.drafts.notes) do
            if candidate.conversation.thread.id == group.id then
                note, data = candidate, candidate.conversation
            end
        end
        if not group.new then
            local baseline = saved.baselines[group.id]
            if
                data and data.deleted
                or not baseline
                or data ~= baseline.data
                or not vim.deep_equal(data.thread, baseline.history)
            then
                failure =
                    "conversation differs from exact accepted history; reply was not retargeted"
            end
        end
        if not failure then
            local ok, imported, import_failure = pcall(function()
                if group.new then
                    data = conversation.new({ id = group.id, messages = plan.messages })
                    if active ~= review then
                        error("workspace lifetime changed while allocating the finding", 0)
                    end
                    -- Native buffer allocation may invoke user hooks. Do not
                    -- overwrite identities/resources those hooks just acquired.
                    local conflict = publication_conflict(review, plan.incoming)
                    if conflict then
                        error(conflict, 0)
                    end
                    note = data.note
                    ---@cast note ParleyWorkspace.Note
                    note.conversation, note.path = data, group.anchor.path
                    note.first, note.context = group.anchor.first, vim.deepcopy(group.anchor.lines)
                    note.observation = vim.deepcopy(group.anchor)
                    review.drafts.notes[#review.drafts.notes + 1] = note
                    return true
                end
                return conversation.receive_batch(
                    data,
                    plan.messages,
                    group.baseVersion,
                    group.baseTipId
                )
            end)
            if not ok or not imported then
                failure = tostring(ok and import_failure or imported)
            end
        end
        local placed
        if not failure then
            -- Placement is secondary to history application. A native placement
            -- failure must not falsely label already appended prose incompatible.
            for _, buffer in ipairs(api.nvim_list_bufs()) do
                local ok = pcall(place_imported, review, note, buffer)
                if not ok then
                    break
                end
            end
            local ok, first = pcall(placement, review, note)
            placed = ok and first ~= nil
        end
        receipts[#receipts + 1] = {
            messageIds = plan.messageIds,
            status = failure and "incompatible" or "applied",
            placement = failure and vim.NIL or (placed and "placed" or "unplaced"),
            detail = failure and tostring(failure):sub(1, 1024)
                or (
                    not placed
                        and "History retained unplaced: source is unloaded, changed, unsaved or not safely verifiable"
                    or vim.NIL
                ),
        }
    end
    saved.pending = false
    cache_status()
    return receipts
end

local function clear_reply_activity(review)
    local owner = review.reply_activity
    review.reply_activity = nil
    local failure
    if owner and owner.timer then
        local stopped, stop_error = pcall(owner.timer.stop, owner.timer)
        local closed, close_error = pcall(owner.timer.close, owner.timer)
        failure = not stopped and stop_error or not closed and close_error or nil
    end
    for data, response in pairs(owner and owner.responses or {}) do
        if data.response == response then
            data.response = nil
        end
    end
    if owner and active == review then
        changed()
    end
    if failure then
        error(failure, 0)
    end
end

local function advance_reply_frame(owner)
    owner.frame = owner.frame % #spinner_frames + 1
    for _, response in pairs(owner.responses) do
        response.lines = { spinner_frames[owner.frame] }
    end
end

---Track each capture from upload through response delivery for deletion checks.
---Only accepted requests get UI slots. An owned 80 ms timer animates glyphs;
---it never polls Pi or changes durable evidence.
function M.request_activity(capture, phase, activity)
    local saved = requests[capture]
    if not saved then
        return
    end
    saved.pending = phase ~= nil
    local review = saved.review
    local labels = {
        accepted = activity == "working" and "Agent working"
            or activity == "starting" and "Agent starting"
            or activity == "settling" and "Agent settling"
            or "Accepted; awaiting agent",
        downloading = "Receiving results",
        applying = "Applying results / recording receipts",
    }
    local owner = review.reply_activity
    if owner and owner.saved ~= saved then
        return
    end
    if
        active ~= review
        or not labels[phase]
        or not saved.accepted
        or saved.incompatible
        or review.drafts.review_id ~= saved.accepted.reviewId
    then
        clear_reply_activity(review)
    else
        if not owner then
            owner = { saved = saved, responses = {}, frame = 0 }
            for _, submission in ipairs(saved.snapshot.request.submissions) do
                local baseline = saved.baselines[submission.conversationId]
                if baseline then
                    local response = {
                        id = "pending/"
                            .. saved.snapshot.request.id
                            .. "/"
                            .. submission.conversationId,
                        parent_id = submission.tipId,
                        role = "agent",
                        origin = "request/activity",
                        author = "Agent",
                        created_at = os.time(),
                        lines = {},
                    }
                    owner.responses[baseline.data] = response
                    baseline.data.response = response
                end
            end
            review.reply_activity = owner
        end
        advance_reply_frame(owner)
        for _, response in pairs(owner.responses) do
            response.state = "Reply pending · " .. labels[phase]
        end
    end
    local function refresh()
        local ok, failure = pcall(function()
            if
                active ~= review
                or (saved.accepted and review.drafts.review_id ~= saved.accepted.reviewId)
            then
                if review.reply_activity == owner then
                    clear_reply_activity(review)
                end
                return
            end
            refresh_sources(review)
            for _, source in pairs(review.views) do
                conversation.update_reply(source)
            end
            if owner and review.reply_activity == owner and not owner.timer then
                owner.timer = assert(vim.uv.new_timer())
                owner.timer:start(
                    80,
                    80,
                    vim.schedule_wrap(function()
                        if review.reply_activity == owner then
                            advance_reply_frame(owner)
                            refresh()
                        end
                    end)
                )
            end
            changed()
        end)
        if not ok then
            local cleaned, cleanup_error = true, nil
            if review.reply_activity == owner then
                cleaned, cleanup_error = pcall(clear_reply_activity, review)
            end
            vim.notify(
                "Parley: reply activity presentation failed: "
                    .. tostring(failure)
                    .. (not cleaned and ("; cleanup: " .. tostring(cleanup_error)) or ""),
                vim.log.levels.WARN
            )
        end
    end
    refresh()
end

---@class ParleyWorkspace.RequestOptions
---@field id string Durable request identity, distinct from transport correlation.
---@field kind 'ask'|'investigate'
---@field instructions? string Required only for investigation; never implicit draft submission.
---@field editor_id string Verified editor identity supplied by the paired host.
---@field author string Human author identity supplied by the host.

---Explicit local capture only. Ask visits every conversation in creation order,
---not just the selected file/card. Investigation captures instructions only.
---The copied payload uses artifact field spellings, with explicit JSON nulls;
---the transport host supplies review/preparation/record envelopes.
---No model, transport, acknowledgment or local history mutation occurs here.
---@param options ParleyWorkspace.RequestOptions
---@return table? capture Read-only, process-local handle and serializable payload.
---@return string? failure
function M.capture_request(options)
    local review = active
    if not review then
        return nil, "activate workspace review before requesting agent interaction"
    end
    if not identifier(options.id) or not identifier(options.editor_id) then
        return nil, "request and editor identities must be valid identifiers"
    end
    if type(options.author) ~= "string" or not options.author:find("%S") then
        return nil, "human author must be nonempty"
    end
    if review.editorId ~= options.editor_id then
        return nil, "request editor does not match the active workspace owner"
    end
    ---@type string|vim.NIL
    local instructions = vim.NIL
    if options.kind == "investigate" then
        if type(options.instructions) ~= "string" or not options.instructions:find("%S") then
            return nil, "investigation requires explicit instructions"
        end
        instructions = options.instructions
    elseif options.kind ~= "ask" or options.instructions ~= nil then
        return nil, "Ask captures comments; Investigate requires free-form instructions"
    end
    local payload = {
        workspace = review.workspace,
        sessionId = review.sessionId,
        editorId = options.editor_id,
        request = {
            id = options.id,
            kind = options.kind,
            instructions = instructions,
            submissions = {},
        },
        conversations = {},
        messages = {},
    }
    local batch, seen = {}, {}
    if review.drafts.workflow == "parley" then
        for _, buffer in ipairs(api.nvim_list_bufs()) do
            local filename = api.nvim_buf_get_name(buffer)
            if
                api.nvim_buf_is_loaded(buffer)
                and vim.bo[buffer].buftype == ""
                and filename:sub(1, #review.workspace + 1) == review.workspace .. "/"
                and vim.bo[buffer].modified
            then
                return nil,
                    "Save or reconcile modified workspace source buffers before an implementation turn"
            end
        end
    end
    if options.kind == "ask" then
        for _, note in ipairs(review.drafts.notes) do
            local captured, failure
            if not note.conversation.deleted and not note.conversation.resolved then
                captured, failure = conversation.capture(
                    note.conversation,
                    options.author,
                    "editor/" .. options.editor_id
                )
            end
            if failure then
                return nil, note.path .. ": " .. failure
            end
            if captured then
                if seen[captured.conversation_id] then
                    return nil, "duplicate workspace conversation identity"
                end
                seen[captured.conversation_id] = true
                local anchor, anchor_failure = capture_anchor(review, note, options.editor_id)
                if not anchor then
                    return nil, note.path .. ": " .. anchor_failure
                end
                local first, last = placement(review, note)
                payload.conversations[#payload.conversations + 1] = {
                    id = captured.conversation_id,
                    anchor = anchor,
                    placement = first and { first = first, last = last } or vim.NIL,
                }
                local message = captured.message
                payload.messages[#payload.messages + 1] = {
                    id = message.id,
                    conversationId = captured.conversation_id,
                    requestId = options.id,
                    parentId = message.parent_id or vim.NIL,
                    role = message.role,
                    author = message.author,
                    origin = message.origin,
                    createdAt = message.created_at,
                    lines = vim.list_extend({}, message.lines),
                    version = captured.version,
                    supersedes = vim.list_extend({}, captured.supersedes),
                    replacesId = captured.replaces_id or vim.NIL,
                }
                payload.request.submissions[#payload.request.submissions + 1] = {
                    conversationId = captured.conversation_id,
                    baseVersion = captured.base_version,
                    baseTipId = captured.base_tip_id or vim.NIL,
                    messageIds = { message.id },
                    version = captured.version,
                    tipId = message.id,
                }
                batch[#batch + 1] = captured
            end
        end
        if #batch == 0 then
            return nil, "no new human prose is eligible for Ask"
        end
    end
    requests[payload] = { snapshot = vim.deepcopy(payload), batch = batch, review = review }
    return payload
end

---Invoke only after the host validates a durable accepting request record from
---Pi (not socket delivery, local save or a pre-ack status). The exact accepted
---submissions must match the private capture, including every version/tip/ID.
---Detached owners may accept their own evidence, never a replacement's drafts.
---Stale history fails the entire local batch, leaving durable evidence intact
---for an incompatibility receipt; it is never retargeted or replayed here.
---@param capture table Original capture handle.
---@param accepted table Validated accepting request record, not transport JSON.
---@return true? applied
---@return string? failure
function M.accept_request(capture, accepted)
    local saved = requests[capture]
    if not saved or saved.accepted or not vim.deep_equal(capture, saved.snapshot) then
        return nil, "request capture is unknown, changed or already accepted"
    end
    if type(accepted) ~= "table" or accepted.type ~= "request" then
        return nil, "durable accepting request record is required"
    end
    local request = {
        id = accepted.id,
        kind = accepted.kind,
        instructions = accepted.instructions,
        submissions = accepted.submissions,
    }
    if not vim.deep_equal(request, saved.snapshot.request) then
        return nil, "durable acceptance does not match the exact captured request"
    end
    saved.pending = true
    local applied, failure = conversation.accept(saved.batch)
    saved.accepted = vim.deepcopy(accepted)
    if not applied then
        -- Acceptance is durable even when local history diverged. Keep this
        -- handle solely to classify later publications as incompatible.
        saved.incompatible, saved.baselines, saved.batch = failure, {}, nil
        return nil, failure
    end
    saved.baselines = {}
    for _, note in ipairs(saved.review.drafts.notes) do
        for _, submitted in ipairs(accepted.submissions) do
            if submitted.conversationId == note.conversation.thread.id then
                saved.baselines[submitted.conversationId] = {
                    data = note.conversation,
                    history = vim.deepcopy(note.conversation.thread),
                }
            end
        end
    end
    saved.batch = nil
    return true
end

-- Selection is a focused presentation or an explicitly selected source card
-- at the cursor. Never use the workspace's remembered navigation selection.
local function selected_note()
    local review = active
    if review then
        local window = api.nvim_get_current_win()
        local view = review.views[window]
        -- Source edits can precede the scheduled display refresh. Validate
        -- placement now so a stale card cannot authorize a thread action.
        if view and workspace_source(review.workspace, window) == view.buffer then
            conversation.refresh(view, placed_items(review, view.buffer))
        end
    end
    local data = conversation.active()
    if active == review and review and data and not data.deleted then
        for _, note in ipairs(review.drafts.notes) do
            if note.conversation == data then
                return review, note
            end
        end
    end
end

local function active_note()
    local review, note = selected_note()
    if note then
        return review, note
    end
    vim.notify("Parley: select a thread first", vim.log.levels.WARN)
end

---Resolution is a local submission filter in both workflows. It never submits.
function M.resolve_note(resolved)
    local review, note = active_note()
    if not note then
        return
    end
    note.conversation.resolved = resolved ~= false
    refresh_sources(review)
    changed()
    vim.notify(
        note.conversation.resolved and "Parley: thread resolved; excluded from turns"
            or "Parley: thread reopened; drafts retained",
        vim.log.levels.INFO
    )
end

local function awaiting_response(review, data)
    for _, saved in pairs(requests) do
        if saved.review == review and saved.pending then
            for _, submission in ipairs(saved.snapshot.request.submissions) do
                if submission.conversationId == data.thread.id then
                    return true
                end
            end
        end
    end
    return false
end

---Mark only the active thread deleted. Keep its history, anchors, drafts and
---undo for inspection; deletion never rewrites submitted Pi evidence.
function M.delete_note()
    local review, note = active_note()
    if not note then
        return
    end
    local data = note.conversation
    local function blocked()
        if awaiting_response(review, data) then
            vim.notify(
                "Parley: thread is awaiting a response; deletion blocked",
                vim.log.levels.WARN
            )
            return true
        end
        return false
    end
    if blocked() then
        return
    end
    vim.ui.select({ "Cancel", "Delete" }, {
        prompt = "Delete thread " .. data.thread.id .. "? History and drafts stay local.",
    }, function(choice)
        if choice ~= "Delete" then
            return
        end
        -- A picker can finish after selection, request or workspace changes.
        local current_review, current_note = selected_note()
        if current_review ~= review or current_note ~= note or data.deleted then
            vim.notify("Parley: thread selection changed; deletion cancelled", vim.log.levels.WARN)
            return
        end
        if blocked() then
            return
        end
        data.deleted = true
        if review.drafts.selected == note then
            review.drafts.selected = nil
            review.selection = nil
        end
        conversation.hide(data)
        refresh_sources(review)
        changed()
        vim.notify(
            "Parley: thread deleted locally; history and drafts retained",
            vim.log.levels.INFO
        )
    end)
end

---Resume a selected/overlapping note; C creates a line note only when absent.
---@param create? boolean
function M.edit_note(create)
    if composer.enter() then
        return
    end
    local source = current_source()
    if source then
        local view = source.review.views[source.window]
        if view then
            conversation.edit(view, create)
        end
    end
end

---Visit existing local notes in path/line/identity order. Explicit navigation may
---open a source; only a validated placement permits a cursor jump or source card.
---@param step integer
function M.move_note(step)
    assert(step == 1 or step == -1, "Note navigation requires step 1 or -1")
    local source = current_source()
    if not source then
        return
    end
    local review = source.review
    local drafts = review.drafts
    local notes = {}
    for _, note in ipairs(review.drafts.notes) do
        if not note.conversation.deleted then
            notes[#notes + 1] = { note = note, first = placement(review, note) or note.first }
        end
    end
    if #notes == 0 then
        vim.notify("Parley: no local notes yet", vim.log.levels.INFO)
        return
    end
    table.sort(notes, function(left, right)
        if left.note.path ~= right.note.path then
            return left.note.path < right.note.path
        end
        if left.first ~= right.first then
            return left.first < right.first
        end
        return left.note.id < right.note.id
    end)

    local line = api.nvim_win_get_cursor(source.window)[1]
    local selection = review.selection
    local continuing = selection
        and selection.window == source.window
        and selection.buffer == source.buffer
        and selection.line == line
    local destination
    if continuing then
        for index, item in ipairs(notes) do
            if item.note == review.drafts.selected then
                destination = ((index - 1 + step) % #notes) + 1
                break
            end
        end
    end

    if not destination then
        if step > 0 then
            for index, item in ipairs(notes) do
                if
                    item.note.path > source.path
                    or (item.note.path == source.path and item.first > line)
                then
                    destination = index
                    break
                end
            end
            destination = destination or 1
        else
            for index = #notes, 1, -1 do
                local item = notes[index]
                if
                    item.note.path < source.path
                    or (item.note.path == source.path and item.first < line)
                then
                    destination = index
                    break
                end
            end
            destination = destination or #notes
        end
    end

    local note = notes[destination].note
    local first = placement(review, note)
    local view = review.views[source.window]
    if view then
        conversation.close(view, false)
    end
    if
        active ~= review
        or review.drafts ~= drafts
        or api.nvim_get_current_win() ~= source.window
        or workspace_source(review.workspace, source.window) ~= source.buffer
        or review.views[source.window] ~= view
        or (view and view.presentation ~= nil)
    then
        return
    end
    local contained, failure = source_contained(review.workspace, note.path)
    if not contained then
        vim.notify("Parley: " .. tostring(failure), vim.log.levels.WARN)
        return
    end
    -- Opening a file belongs to explicit navigation, never background import.
    -- Neither command forces abandonment of unsaved source changes.
    local switched, err = pcall(function()
        if first then
            vim.cmd.buffer(tostring(note.source_buf))
        else
            vim.cmd.edit(vim.fn.fnameescape(review.workspace .. "/" .. note.path))
        end
    end)
    if not switched then
        vim.notify("Parley: " .. tostring(err), vim.log.levels.WARN)
        return
    end
    if active ~= review or review.drafts ~= drafts then
        return
    end
    local buffer, path = workspace_source(review.workspace, source.window)
    if
        api.nvim_get_current_win() ~= source.window
        or path ~= note.path
        or (first and buffer ~= note.source_buf)
    then
        vim.notify("Parley: source window changed during note navigation", vim.log.levels.WARN)
        return
    end
    -- BufEnter may already have placed this finding. Recheck after all loading
    -- hooks; changed/unsaved source must not acquire a guessed replacement range.
    place_imported(review, note, buffer)
    first = placement(review, note)
    if first then
        api.nvim_win_set_cursor(source.window, { first, 0 })
    end
    show(review, note, source.window, false)
end

local function thread_action(action)
    if action == "delete" then
        M.delete_note()
    else
        M.resolve_note(action == "resolve")
    end
end

-- Fixed order also defines precedence if configured actions share a key.
local review_actions = {
    {
        mode = "n",
        name = "comment",
        action = function()
            M.comment("line")
        end,
        description = "Compose a local line note",
    },
    {
        mode = "x",
        name = "comment",
        action = function()
            M.comment("range")
        end,
        description = "Compose a local range note",
    },
    {
        mode = "n",
        name = "edit",
        action = function()
            M.edit_note(true)
        end,
        description = "Resume or compose a local note",
    },
    {
        mode = "x",
        name = "edit",
        action = function()
            M.comment("range")
        end,
        description = "Resume or compose a range note",
    },
    {
        mode = "n",
        name = "enter",
        action = function()
            M.edit_note()
        end,
        description = "Edit the selected local note",
    },
    {
        mode = "n",
        name = "resolve",
        action = function()
            M.resolve_note(true)
        end,
        description = "Resolve the active thread",
    },
    {
        mode = "n",
        name = "reopen",
        action = function()
            M.resolve_note(false)
        end,
        description = "Reopen the active thread",
    },
    {
        mode = "n",
        name = "delete",
        action = M.delete_note,
        description = "Mark the active thread deleted locally",
    },
    {
        mode = "n",
        name = "next",
        action = function()
            M.move_note(1)
        end,
        description = "Next local note",
    },
    {
        mode = "n",
        name = "previous",
        action = function()
            M.move_note(-1)
        end,
        description = "Previous local note",
    },
}

---@param configured_keys table<string, string[]>
---@return ParleyWorkspace.Keymap[]
local function resolve_review_bindings(configured_keys)
    local bindings = {}
    for _, action in ipairs(review_actions) do
        for _, key in ipairs(configured_keys[action.name]) do
            local run = action.action
            bindings[#bindings + 1] = {
                mode = action.mode,
                key = keys.concrete(key),
                action = function()
                    run()
                end,
                description = action.description,
            }
        end
    end
    return bindings
end

-- Called for the current file buffer. Mode owns these overrides, independently
-- of whether a comment action can associate this file with the workspace.
local function install_review_bindings(review, buffer)
    if review.maps[buffer] then
        return
    end

    -- Snapshot all originals first, including aliases configured for the same
    -- key. Restoring must never resurrect one of our own overwritten mappings.
    local saved = {}
    for index, binding in ipairs(review.bindings) do
        saved[index] = vim.fn.maparg(binding.key, binding.mode, false, true)
    end
    review.maps[buffer] = saved
    for _, binding in ipairs(review.bindings) do
        vim.keymap.set(
            binding.mode,
            binding.key,
            binding.action,
            { buffer = buffer, desc = binding.description }
        )
    end
end

local function visit_buffer(review)
    if active ~= review then
        return
    end
    local window = api.nvim_get_current_win()
    local buffer = workspace_source(review.workspace, window)
    if not buffer then
        return
    end

    install_review_bindings(review, buffer)

    if active == review then
        review.window = window
        local previous = review.views[window]
        if previous and (previous.closed or previous.buffer ~= buffer) then
            review.views[window] = nil
            conversation.detach(previous)
        end
        if active ~= review or workspace_source(review.workspace, window) ~= buffer then
            return
        end
        if not review.views[window] then
            local path = assert(select(2, workspace_source(review.workspace, window)))
            local view = conversation.attach({
                window = window,
                label = path:gsub("[%c]", "?"),
                items = {},
                keymaps = review.keymaps,
                source_maps = false,
                thread_action = thread_action,
                enabled = function()
                    return active == review
                        and workspace_source(review.workspace, window) == buffer
                end,
                created = function(data, first, last)
                    associate(review, window, data, first, last)
                end,
                selected = function(data)
                    if active == review then
                        review.drafts.selected = data.note
                        selected_position(review, window)
                    end
                end,
                navigate = M.move_note,
                changed = function()
                    if active == review then
                        refresh_sources(review)
                        changed()
                    end
                end,
            })
            if active == review and not review.views[window] then
                review.views[window] = view
            else
                conversation.detach(view)
            end
        end
    end
    for _, note in ipairs(review.drafts.notes) do
        place_imported(review, note, buffer)
    end
    refresh_sources(review)
end

---Validate explicit entry without acquiring presentation or changing selection.
---@param binding ParleyWorkspace.Binding
---@return boolean ready
---@return string? failure
function M.can_activate(binding)
    if
        active and (active.workspace ~= binding.workspace or active.sessionId ~= binding.sessionId)
    then
        return false,
            "Another workspace/Pi session is active; :Parley stop before starting another"
    end
    if vim.fn.mode() ~= "n" or not workspace_source(binding.workspace) then
        return false,
            "Neovim is busy; review requires an ordinary workspace source window in normal mode"
    end
    return true
end

---Copy only the verified workspace/conversation identity. Activation never opens
---an editor, navigates, submits a turn or migrates another conversation's notes.
---@param binding ParleyWorkspace.Binding
---@return boolean activated
---@return string? failure
function M.activate(binding)
    if active then
        if active.workspace == binding.workspace and active.sessionId == binding.sessionId then
            return true
        end
        return false,
            "Another workspace/Pi session is active; stop it explicitly before activating"
    end

    local ready, err = M.can_activate(binding)
    if not ready then
        return false, err
    end
    local window = api.nvim_get_current_win()
    local configured = config.get()
    local sessions = conversations[binding.workspace] or {}
    conversations[binding.workspace] = sessions
    local drafts = sessions[binding.sessionId] or { notes = {} }
    sessions[binding.sessionId] = drafts
    local review = {
        workspace = binding.workspace,
        sessionId = binding.sessionId,
        editorId = binding.editorId,
        group = api.nvim_create_augroup("ParleyWorkspace", { clear = true }),
        window = window,
        drafts = drafts,
        selection_allowed = true,
        keymaps = configured,
        bindings = resolve_review_bindings(configured.review),
        maps = {},
        views = {},
    }
    active = review
    local initialized, failure = pcall(function()
        style.refresh()

        api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
            group = review.group,
            callback = function()
                visit_buffer(review)
            end,
        })
        api.nvim_create_autocmd({
            "TextChanged",
            "TextChangedI",
            "TextChangedP",
            "WinClosed",
            "WinResized",
            "VimResized",
        }, {
            group = review.group,
            callback = function(event)
                if not vim.b[event.buf].parley_composer then
                    schedule_refresh(review)
                end
            end,
        })
        api.nvim_create_autocmd("OptionSet", {
            group = review.group,
            pattern = {
                "wrap",
                "linebreak",
                "tabstop",
                "number",
                "relativenumber",
                "numberwidth",
                "signcolumn",
                "foldcolumn",
                "statuscolumn",
                "winbar",
            },
            callback = function()
                schedule_refresh(review)
            end,
        })
        api.nvim_create_autocmd("ColorScheme", {
            group = review.group,
            callback = function()
                style.refresh()
                schedule_refresh(review)
            end,
        })

        visit_buffer(review)
        changed()
        if active == review then
            api.nvim_exec_autocmds(
                "User",
                { pattern = "ParleyReviewStarted", data = { window = window } }
            )
        end
    end)
    if not initialized then
        if active == review then
            pcall(M.stop)
        end
        error(failure, 0)
    end
    if active ~= review then
        return false, "Workspace activation was stopped or replaced by a hook"
    end
    return true
end

---Explicit :Parley start permits selecting a newly initialized review on the next
---request. Passive health/reconnection never calls this or moves drafts.
function M.allow_review_selection()
    if active then
        active.selection_allowed = true
    end
end

function M.workflow()
    return active and active.drafts.workflow or "review"
end

function M.review_id()
    return active and active.drafts.review_id
end

---Bind local notes once; a fresh review gets a separate retained draft set.
---No submitted identities, native buffers, undo or old source anchors migrate.
function M.select_review(review_id, workflow)
    workflow = workflow or "review"
    if workflow ~= "review" and workflow ~= "parley" then
        return nil, "Unknown workflow authority"
    end
    local review = active
    if not review then
        return nil, "Use :Parley start review before selecting a review"
    end
    if review.drafts.review_id == review_id then
        if (review.drafts.workflow or "review") ~= workflow then
            return nil, "Workflow authority changed for the same identity"
        end
        review.selection_allowed = false
        return true
    end
    if review.drafts.review_id and not review.selection_allowed then
        return nil,
            "Review changed; run :Parley start with the matching workflow explicitly to select the new review. Old notes will remain retained."
    end
    local sessions = review_drafts[review.workspace] or {}
    review_drafts[review.workspace] = sessions
    local retained = sessions[review.sessionId] or {}
    sessions[review.sessionId] = retained
    if retained[review_id] and (retained[review_id].workflow or "review") ~= workflow then
        return nil, "Workflow authority changed for a retained identity"
    end
    if review.drafts.review_id then
        local failed, failure
        for _, view in pairs(review.views) do
            local ok, err = pcall(conversation.detach, view)
            if not ok and not failed then
                failed, failure = true, err
            end
        end
        if failed then
            return nil, tostring(failure)
        end
        review.views = {}
        review.drafts = retained[review_id]
            or { notes = {}, review_id = review_id, workflow = workflow }
        conversations[review.workspace][review.sessionId] = review.drafts
    else
        review.drafts.review_id = review_id
        review.drafts.workflow = workflow
    end
    retained[review_id] = review.drafts
    review.selection_allowed = false
    changed()
    return true
end

---Detach presentation and only our still-owned overrides. Notes, original source
---anchors, accepted local text, unfinished edits and native undo remain retained.
function M.stop()
    local review = active
    if not review then
        return
    end
    active = nil
    local failed, failure
    local function finish(action)
        local ok, err = pcall(action)
        if not ok and not failed then
            failed, failure = true, err
        end
    end
    finish(function()
        clear_reply_activity(review)
    end)
    finish(function()
        api.nvim_del_augroup_by_id(review.group)
    end)
    for _, view in pairs(review.views) do
        finish(function()
            conversation.detach(view)
        end)
    end

    for buffer, saved in pairs(review.maps) do
        if api.nvim_buf_is_valid(buffer) then
            finish(function()
                api.nvim_buf_call(buffer, function()
                    for index, binding in ipairs(review.bindings) do
                        local mapping = vim.fn.maparg(binding.key, binding.mode, false, true)
                        if mapping.buffer == 1 and mapping.callback == binding.action then
                            vim.keymap.del(binding.mode, binding.key, { buffer = buffer })
                            if saved[index].buffer == 1 then
                                vim.fn.mapset(binding.mode, false, saved[index])
                            end
                        end
                    end
                end)
            end)
        end
    end
    finish(changed)
    finish(function()
        api.nvim_exec_autocmds(
            "User",
            { pattern = "ParleyReviewStopped", data = { window = review.window } }
        )
    end)
    if failed then
        error(failure, 0)
    end
end

return M
