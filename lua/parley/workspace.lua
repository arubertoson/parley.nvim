---Editor-local notes and navigation, bound to one verified workspace/Pi session.
---Hidden prose buffers own text/native undo. Source extmarks and original selected
---lines establish conservative placement, not frozen evidence or submission state.
---Detach/disconnect retain notes in this Neovim process; there is no restart store.
local config = require("parley.config")
local composer = require("parley.composer")
local inline = require("parley.inline")
local style = require("parley.composer.style")
local M = {}
local api = vim.api

---@class ParleyWorkspace.Binding
---@field workspace string Canonical workspace root.
---@field sessionId string Pi conversation identity, independent of runtime reloads.

---@class ParleyWorkspace.Note: ParleyComposer.Draft
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
---@field views table<integer, ParleyInline.View> Owned source-window presentation.
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
local serial = 0
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

    return { review = review, window = window, buffer = buffer, path = path }
end

local function refresh_sources(review)
    if active ~= review then
        return
    end

    local selected = review.drafts.selected
    for window, view in pairs(review.views) do
        if not api.nvim_win_is_valid(window) then
            inline.clear(view)
            review.views[window] = nil
        elseif not composer.owns_source_window(window) then
            local buffer = workspace_source(review.workspace, window)
            if not buffer then
                inline.clear(view)
            else
                local items = {}
                for _, note in ipairs(review.drafts.notes) do
                    if note.source_buf == buffer then
                        local first, last = placement(review, note)
                        if first and last then
                            items[#items + 1] = { note = note, first = first, last = last }
                        end
                    end
                end
                inline.update(view, buffer, items, selected and selected.id)
            end
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
    if active ~= review or api.nvim_get_current_win() ~= window then
        return
    end
    local buffer = api.nvim_win_get_buf(window)
    composer.close(false)
    review.drafts.selected = note
    selected_position(review, window)
    refresh_sources(review)
    changed()

    -- A User hook may detach or replace the view. Do not open over that action.
    if
        active ~= review
        or api.nvim_get_current_win() ~= window
        or api.nvim_win_get_buf(window) ~= buffer
    then
        return
    end

    local first, last = placement(review, note)
    if buffer ~= note.source_buf then
        first, last = nil, nil
    end
    local view = review.views[window]
    if not enter and first and view then
        inline.reveal(view)
        selected_position(review, window)
        return
    end

    -- Only the workspace knows which note card lends room to the editor.
    -- The composer borrows display operations, not our note/view state.
    local room
    if view then
        room = {
            namespace = view.namespace,
            reserve = function(row, lines)
                return inline.reserve(view, note.id, row, lines)
            end,
            release = function()
                inline.release(view)
            end,
        }
    end

    composer.show(note, {
        source_win = window,
        source_label = ("%s:%d"):format(note.path:gsub("[%c]", "?"), note.first),
        keymaps = review.keymaps.composer,
        first = first,
        last = last,
        room = room,
        enter = enter,
        navigate = M.move_note,
        changed = function()
            if active == review then
                refresh_sources(review)
                changed()
            end
        end,
    })
end

---Explicit local composition only: no source discovery, captures or submitted turns.
---@param scope 'line'|'range'
function M.comment(scope)
    local source = current_source()
    if not source then
        return
    end
    local review = source.review
    local first = api.nvim_win_get_cursor(source.window)[1]
    local last = first
    if scope == "range" then
        first, last = vim.fn.line("v"), first
        if first > last then
            first, last = last, first
        end
        vim.cmd("normal! " .. api.nvim_replace_termcodes("<Esc>", true, false, true))
    end
    if active ~= review then
        return
    end

    -- Recover the original composer's same-target resume behavior. Reopening
    -- never replaces text, creates a second editor buffer, or resets history.
    for index = #review.drafts.notes, 1, -1 do
        local note = review.drafts.notes[index]
        if note.source_buf == source.buffer then
            local existing_first, existing_last = placement(review, note)
            if existing_first == first and existing_last == last then
                show(review, note, source.window, true)
                return
            end
        end
    end

    local context = api.nvim_buf_get_lines(source.buffer, first - 1, last, false)
    anchors = anchors or api.nvim_create_namespace("parley.anchors")
    local anchor = api.nvim_buf_set_extmark(source.buffer, anchors, first - 1, 0, {
        end_row = last,
        end_col = 0,
        right_gravity = true,
        end_right_gravity = false,
        invalidate = true,
        undo_restore = true,
    })

    -- Unwritten draft buffer: closing presentation retains text/native undo.
    -- The composer applies Markdown formatting when presenting it.
    serial = serial + 1
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buffer, vim.fn.tempname() .. "-Parley Composer.md")
    vim.b[buffer].parley_composer = true
    vim.bo[buffer].buftype = ""
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undofile = false

    local note = {
        id = serial,
        buffer = buffer,
        created_at = os.time(),
        path = source.path,
        source_buf = source.buffer,
        namespace = anchors,
        anchor = anchor,
        first = first,
        context = context,
    }
    review.drafts.notes[#review.drafts.notes + 1] = note
    show(review, note, source.window, true)
end

---Resume a selected/overlapping note; C creates a line note only when absent.
---@param create? boolean
function M.edit_note(create)
    if composer.enter() then
        return
    end
    local source = current_source()
    if not source then
        return
    end

    local review = source.review
    local line = api.nvim_win_get_cursor(source.window)[1]
    local function contains(note)
        if not note or note.source_buf ~= source.buffer then
            return false
        end
        local first, last = placement(review, note)
        return first ~= nil and last ~= nil and line >= first and line <= last
    end

    local selected = review.drafts.selected
    if contains(selected) then
        show(review, selected, source.window, true)
        return
    end
    for index = #review.drafts.notes, 1, -1 do
        local note = review.drafts.notes[index]
        if contains(note) then
            show(review, note, source.window, true)
            return
        end
    end

    if create then
        M.comment("line")
    else
        vim.notify("Parley: no note at the cursor; c creates a draft", vim.log.levels.INFO)
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
    composer.close(false)
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

---@param keys table<string, string[]>
---@return ParleyWorkspace.Keymap[]
local function resolve_review_bindings(keys)
    local bindings = {}
    for _, action in ipairs(review_actions) do
        for _, key in ipairs(keys[action.name]) do
            bindings[#bindings + 1] = {
                mode = action.mode,
                key = key,
                action = action.action,
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
    local buffer = ordinary_file_buffer(window)
    if not buffer then
        return
    end

    install_review_bindings(review, buffer)

    -- Source presentation remains workspace-scoped. Visiting an unrelated file
    -- installs mode bindings, but never adds a note or captures a new source.
    if workspace_source(review.workspace, window) then
        review.window = window
        if not review.views[window] and api.nvim__ns_set then
            review.views[window] = inline.open(window)
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
    style.refresh()

    api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
        group = review.group,
        callback = function()
            visit_buffer(review)
        end,
    })
    api.nvim_create_autocmd(
        { "TextChanged", "TextChangedI", "TextChangedP", "WinClosed", "WinResized", "VimResized" },
        {
            group = review.group,
            callback = function(event)
                if not vim.b[event.buf].parley_composer then
                    schedule_refresh(review)
                end
            end,
        }
    )
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
    api.nvim_exec_autocmds("User", { pattern = "ParleyReviewStarted", data = { window = window } })
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
    api.nvim_del_augroup_by_id(review.group)
    composer.close(true)
    for _, view in pairs(review.views) do
        inline.clear(view)
    end

    for buffer, saved in pairs(review.maps) do
        if api.nvim_buf_is_valid(buffer) then
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
        end
    end
    changed()
    api.nvim_exec_autocmds(
        "User",
        { pattern = "ParleyReviewStopped", data = { window = review.window } }
    )
end

return M
