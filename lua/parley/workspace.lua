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

---@class ParleyWorkspace.Binding
---@field workspace string Canonical workspace root.
---@field sessionId string Pi conversation identity, independent of runtime reloads.

---@class ParleyWorkspace.Note: ParleyDiscussion.Draft
---@field conversation ParleyConversation Shared conversation data; source metadata stays here.
---@field path string Original workspace-relative source path.
---@field source_buf integer
---@field namespace integer Retained, invisible source anchors.
---@field anchor integer
---@field first integer Original line, identifying an unplaced note.
---@field context string[] Original selected lines, never refreshed on reopen.

---@class ParleyWorkspace.Drafts
---@field notes ParleyWorkspace.Note[] Creation order, not navigation order.
---@field selected? ParleyWorkspace.Note

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
---@field maps table<integer, table[]> Original mapping overrides by visited file buffer.
---@field views table<integer, ParleyConversation.Source> Owned source attachments.
---@field selection? { window: integer, buffer: integer, line: integer }
---@field refresh_pending? boolean

---@class ParleyWorkspace.Source
---@field review ParleyWorkspace.Active
---@field window integer
---@field buffer integer
---@field path string

---@type ParleyWorkspace.Active?
local active
---@type table<string, table<string, ParleyWorkspace.Drafts>>
local conversations = {}
---@type integer?
local anchors
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
    if not api.nvim_buf_is_loaded(note.source_buf) then
        return
    end

    local filename = vim.fs.normalize(api.nvim_buf_get_name(note.source_buf))
    if filename ~= review.workspace .. "/" .. note.path then
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
        if note.source_buf == buffer then
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

local function changed()
    local review = active
    M.status = ""
    if review then
        M.status = ("Workspace review · %d notes"):format(#review.drafts.notes)
        local note = review.drafts.selected
        if note then
            local first = placement(review, note)
            local path = note.path:gsub("[%c]", "?")
            local position = (" · %s:%d"):format(path, first or note.first)
            M.status = M.status .. position .. (first and "" or " · unplaced")
        end
    end

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

---Visit existing local notes in path/line/identity order. Unplaced notes remain in
---that sequence, without switching source buffers or guessing replacement anchors.
---@param step integer
function M.move_note(step)
    assert(step == 1 or step == -1, "Note navigation requires step 1 or -1")
    local source = current_source()
    if not source then
        return
    end
    local review = source.review
    local notes = {}
    for _, note in ipairs(review.drafts.notes) do
        notes[#notes + 1] = { note = note, first = placement(review, note) or note.first }
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
        or api.nvim_get_current_win() ~= source.window
        or workspace_source(review.workspace, source.window) ~= source.buffer
        or review.views[source.window] ~= view
        or (view and view.presentation ~= nil)
    then
        return
    end
    if first then
        -- Respect modified-buffer abandonment policy. Never force a source jump.
        local switched, failure = pcall(vim.cmd.buffer, tostring(note.source_buf))
        if not switched then
            vim.notify("Parley: " .. tostring(failure), vim.log.levels.WARN)
            return
        end
        if active ~= review then
            return
        end
        if
            api.nvim_get_current_win() ~= source.window
            or workspace_source(review.workspace, source.window) ~= note.source_buf
        then
            vim.notify("Parley: source window changed during note navigation", vim.log.levels.WARN)
            return
        end
        first = placement(review, note)
        if first then
            api.nvim_win_set_cursor(source.window, { first, 0 })
        end
    end
    show(review, note, source.window, false)
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
    refresh_sources(review)
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

    local window = api.nvim_get_current_win()
    if vim.fn.mode() ~= "n" or not workspace_source(binding.workspace, window) then
        return false,
            "Neovim is busy; activation requires an ordinary workspace source window in normal mode"
    end

    local configured = config.get()
    local sessions = conversations[binding.workspace] or {}
    conversations[binding.workspace] = sessions
    local drafts = sessions[binding.sessionId] or { notes = {} }
    sessions[binding.sessionId] = drafts
    local review = {
        workspace = binding.workspace,
        sessionId = binding.sessionId,
        group = api.nvim_create_augroup("ParleyWorkspace", { clear = true }),
        window = window,
        drafts = drafts,
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
