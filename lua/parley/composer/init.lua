-- Adapted from legacy/lua/parley/composer.lua, originally extracted from
-- arubertoson/nvim: lua/aru/workspace/review_composer.lua.
---Reserved-space prose editor, without legacy review/workflow ownership.
---The caller owns each hidden buffer and native undo tree. This module owns
---one editor window, its footer, borrowed inline room and display/lifecycle hooks.
-- Resolve sibling modules from this directory's require path when copied.
local module_path = ...
local style = require(module_path .. ".style")
local help = require(module_path .. ".help")
local keymaps = require(module_path .. ".keymaps")
local M = {}
local api = vim.api

---@class ParleyComposer.Draft
---@field id integer Editor-local identity.
---@field buffer integer Canonical text and native undo; never replaced on reopen.
---@field cursor? integer[] Row and byte column; Insert-mode columns may equal the line's byte length.
---@field saved_lines? string[] Last explicitly accepted local text, not a Pi turn.

---@class ParleyComposer.Room
---@field namespace integer Caller-owned virtual lines allowed below the source.
---@field reserve fun(row: integer, lines: ParleyNoteLine[]): integer Replace the note card; return preceding display rows.
---@field release fun() Release the reservation without altering the draft.

---@class ParleyComposer.Presentation
---@field source_win integer
---@field first? integer Absent for an explicitly unplaced note.
---@field last? integer
---@field source_label string Original source identity, also visible when unplaced.
---@field room? ParleyComposer.Room Borrowed until close; caller owns source cards.
---@field enter? boolean
---@field keymaps? ParleyComposer.Keymaps|false Overrides for this editor; false disables all defaults.
---@field navigate fun(step: integer)
---@field changed fun() Refresh caller presentation after releasing room.

---@class ParleyComposer.Mapping
---@field name string Composer action; aliases share one footer hint.
---@field mode string
---@field key string
---@field action fun()|string
---@field description string
---@field original? table
---@field installed boolean

---@class ParleyComposer.Editor
---@field note ParleyComposer.Draft Borrowed; local saves/cursor mutate it.
---@field source_win integer
---@field source_buf integer
---@field source_tick integer Source edits interrupt presentation; layout changes do not.
---@field source_view table
---@field options ParleyComposer.Presentation
---@field keymaps table<string, string[]> Resolved key choices for this editor.
---@field bindings ParleyComposer.Mapping[] Owned until close, including partial setup.
---@field window integer
---@field resume_cursor? integer[] Unclamped insertion position, retained until first entry.
---@field group integer
---@field display? table Bounded source/view fingerprint after our last layout.
---@field refreshing boolean
---@field refresh_pending boolean One coalesced layout/lifecycle check.
---@field footer ParleyComposer.HelpFooter Non-focusing help for editors without source room.

---@type ParleyComposer.Editor?
local current
---@type integer?
local display_namespace

local display_options = {
    "wrap",
    "linebreak",
    "foldenable",
    "foldmethod",
    "foldlevel",
    "winbar",
    "number",
    "numberwidth",
    "relativenumber",
    "signcolumn",
    "statuscolumn",
    "foldcolumn",
    "breakindent",
    "showbreak",
    "conceallevel",
    "tabstop",
}

local function source_available(editor)
    return api.nvim_win_is_valid(editor.source_win)
        and api.nvim_win_get_buf(editor.source_win) == editor.source_buf
end

local function editor_available(editor)
    return source_available(editor)
        and api.nvim_buf_get_changedtick(editor.source_buf) == editor.source_tick
        and api.nvim_win_is_valid(editor.window)
        and api.nvim_win_get_buf(editor.window) == editor.note.buffer
end

local function remember_cursor(editor)
    if
        api.nvim_win_is_valid(editor.window)
        and api.nvim_win_get_buf(editor.window) == editor.note.buffer
    then
        editor.note.cursor = editor.resume_cursor or api.nvim_win_get_cursor(editor.window)
    end
end

-- Retained cursors can include the Insert-mode position beyond the final byte.
-- Without one, opening an existing note starts after its final character.
local function entry_cursor(note)
    local count = api.nvim_buf_line_count(note.buffer)
    local row = math.max(1, math.min(note.cursor and note.cursor[1] or count, count))
    local line = api.nvim_buf_get_lines(note.buffer, row - 1, row, false)[1]
    local column = note.cursor and note.cursor[2] or #line
    return { row, math.max(0, math.min(column, #line)) }
end

function M.owns_source_window(window)
    return current ~= nil and current.source_win == window
end

local function restore_bindings(editor)
    if not api.nvim_buf_is_loaded(editor.note.buffer) then
        return
    end
    api.nvim_buf_call(editor.note.buffer, function()
        for _, binding in ipairs(editor.bindings) do
            if binding.installed then
                local mapping = vim.fn.maparg(binding.key, binding.mode, false, true)
                local owned = mapping.buffer == 1
                    and (
                        (type(binding.action) == "function" and mapping.callback == binding.action)
                        or (
                            type(binding.action) == "string"
                            and mapping.rhs == binding.action
                            and mapping.desc == binding.description
                        )
                    )
                if owned then
                    vim.keymap.del(binding.mode, binding.key, { buffer = editor.note.buffer })
                    if binding.original and binding.original.buffer == 1 then
                        vim.fn.mapset(binding.mode, false, binding.original)
                    end
                end
            end
        end
    end)
end

---Release only presentation. Closing, interruption and detach never discard text,
---rewrite native undo, submit anything, or accept an unfinished local edit.
---@param restore? boolean Restore the source view only for an explicit editor exit.
function M.close(restore)
    local editor = current
    if not editor then
        return
    end
    current = nil

    help.close(editor.footer)
    api.nvim_del_augroup_by_id(editor.group)
    api.nvim_set_decoration_provider(assert(display_namespace), {})
    local focused = api.nvim_get_current_win() == editor.window
        and api.nvim_win_get_buf(editor.window) == editor.note.buffer
    remember_cursor(editor)
    if focused then
        vim.cmd.stopinsert()
    end

    restore_bindings(editor)

    if editor.options.room then
        editor.options.room.release()
    end
    -- Restore inactive cards before closing the float triggers focus redraws.
    editor.options.changed()
    if
        api.nvim_win_is_valid(editor.window)
        and api.nvim_win_get_buf(editor.window) == editor.note.buffer
    then
        api.nvim_win_close(editor.window, true)
    end
    -- Closing normally returns to the source. Honour hooks that instead opened
    -- another editor or moved focus elsewhere; never take their focus back.
    if
        restore
        and focused
        and current == nil
        and source_available(editor)
        and api.nvim_get_current_win() == editor.source_win
    then
        vim.fn.winrestview(editor.source_view)
    end
end

---Like the original composer, measure folds/wrapping/filler before redraw rather
---than trusting screenpos(). Work is bounded by the viewport, not the whole file.
local function display_signature(editor)
    if not source_available(editor) then
        return
    end
    local last = editor.options.last
    if last and last > api.nvim_buf_line_count(editor.source_buf) then
        return
    end

    return api.nvim_win_call(editor.source_win, function()
        local view = vim.fn.winsaveview()
        local height = api.nvim_win_get_height(editor.source_win)
        -- This source-window context supplies both window- and buffer-local
        -- values; tabstop must not be queried with a window option handle.
        local options = {}
        for _, name in ipairs(display_options) do
            options[name] = api.nvim_get_option_value(name, {})
        end

        local before, after = -1, -1
        if last and view.topline <= last then
            before = api.nvim_win_text_height(editor.source_win, {
                start_row = view.topline - 1,
                end_row = last - 1,
                max_height = height + 1,
            }).all
            local following = { start_row = view.topline - 1, max_height = height + 1 }
            if last < api.nvim_buf_line_count(editor.source_buf) then
                following.end_row, following.end_vcol = last, 0
            end
            after = api.nvim_win_text_height(editor.source_win, following).all
        end

        return {
            tick = api.nvim_buf_get_changedtick(editor.source_buf),
            cursor = api.nvim_win_get_cursor(editor.source_win),
            position = api.nvim_win_get_position(editor.source_win),
            width = api.nvim_win_get_width(editor.source_win),
            height = height,
            options = options,
            breakat = vim.o.breakat,
            topline = view.topline,
            topfill = view.topfill,
            leftcol = view.leftcol,
            skipcol = view.skipcol,
            fold = last and vim.fn.foldclosed(last) or -1,
            before = before,
            after = after,
        }
    end)
end

local function footer_row(editor, width)
    if api.nvim_get_current_win() ~= editor.window then
        return
    end
    local mode = vim.fn.mode():sub(1, 1)
    if mode == "n" or mode == "i" then
        return help.row(editor.note.buffer, editor.bindings, mode, width)
    end
end

local function geometry(editor, reveal)
    local first, last = editor.options.first, editor.options.last
    local presentation_room = editor.options.room
    local window_height = api.nvim_win_get_height(editor.source_win)
        - (vim.wo[editor.source_win].winbar ~= "" and 1 or 0)
    local window_width = api.nvim_win_get_width(editor.source_win)
    if window_height < 8 or window_width < 24 then
        return
    end

    -- Unplaced notes remain editable, but never reserve space at a guessed source
    -- location. This explicit fallback is labelled and does not move the source.
    if not first or not last or not presentation_room then
        local width = math.min(100, window_width - 8)
        api.nvim_win_set_config(editor.window, { width = width })
        local footer = footer_row(editor, width)
        local rows = api.nvim_win_text_height(editor.window, { max_height = 7 }).all
        local height = math.min(math.max(1, rows), 6, window_height - 4)
        return {
            relative = "win",
            win = editor.source_win,
            row = math.floor((window_height - height - 2) / 2),
            col = 3,
            width = width,
            height = height,
            border = "rounded",
            hide = false,
            title = " You · " .. editor.options.source_label .. " · unplaced ",
        },
            footer
    end

    -- Do not paint an editor over another plugin's virtual text/display editor.
    for _, mark in
        ipairs(
            api.nvim_buf_get_extmarks(
                editor.source_buf,
                -1,
                { last - 1, 0 },
                { last - 1, -1 },
                { details = true }
            )
        )
    do
        local details = mark[4]
        if
            details
            and details.ns_id ~= presentation_room.namespace
            and details.virt_lines
            and not details.virt_lines_above
        then
            return
        end
    end

    local indent, width, padding = style.layout(editor.source_win, first)
    local heading = style.wrap("You · " .. style.label(first, last) .. " · editing", width)
    local available = window_height - #heading - 4
    if available < 1 then
        return
    end

    api.nvim_win_set_config(editor.window, { width = width })
    local content_rows = api.nvim_win_text_height(editor.window, {
        start_row = 0,
        end_row = api.nvim_buf_line_count(editor.note.buffer) - 1,
        max_height = 7,
    }).all
    local content_height = math.min(math.max(1, content_rows), 6, available)
    local room = {}
    for _ = 1, content_height + #heading + 2 do
        room[#room + 1] = style.card_line(indent, width, padding, {}, true)
    end
    for index, text in ipairs(heading) do
        room[index + 1] = style.card_line(indent, width, padding, {
            { text, "ParleyReviewNoteHeading" },
        }, true)
    end
    -- Reuse bottom padding: toggling help or changing modes cannot grow the room.
    local footer = footer_row(editor, width)
    if footer then
        room[#room] = style.footer_line(indent, width, padding, footer)
    end
    local preceding = presentation_room.reserve(last, room)

    local config
    api.nvim_win_call(editor.source_win, function()
        if reveal then
            api.nvim_win_set_cursor(editor.source_win, { last, 0 })
            vim.cmd("normal! zv")
        elseif vim.fn.foldclosed(last) ~= -1 then
            return
        end

        local function space()
            local position = vim.fn.winsaveview()
            if position.topline > last then
                return
            end
            local row = api.nvim_win_text_height(editor.source_win, {
                start_row = position.topline - 1,
                start_vcol = position.skipcol,
                end_row = last - 1,
                max_height = window_height + 1,
            }).all + position.topfill + preceding
            local below = last < api.nvim_buf_line_count(editor.source_buf) and 1 or 0
            if row + #room + below > window_height then
                return
            end
            return row
        end

        local row = space()
        if not row and reveal then
            vim.cmd("normal! zt")
            row = space()
        end
        if not row then
            return
        end
        config = {
            relative = "win",
            win = editor.source_win,
            row = row + #heading + 1,
            col = indent,
            width = width,
            height = content_height,
            border = "none",
            hide = false,
        }
    end)
    return config
end

local function hide_editor_gutter(window)
    vim.wo[window].number = false
    vim.wo[window].relativenumber = false
    vim.wo[window].signcolumn = "no"
    vim.wo[window].statuscolumn = ""
    vim.wo[window].foldcolumn = "0"
end

local function refresh(editor, reveal)
    if current ~= editor then
        return
    end
    if not editor_available(editor) then
        M.close(false)
        return
    end

    editor.refreshing = true
    -- Both initial and scheduled layout own cleanup on failure. A bad host
    -- callback must not leave an inert editor marked as permanently refreshing.
    local laid_out, result = pcall(function()
        hide_editor_gutter(editor.window)
        local config, footer = geometry(editor, reveal)
        if config and current == editor then
            api.nvim_win_set_config(editor.window, config)
            if footer then
                help.present(editor.footer, footer, {
                    relative = "win",
                    win = editor.source_win,
                    row = config.row + config.height + 2,
                    col = config.col + 1,
                    width = config.width,
                })
            else
                help.close(editor.footer)
            end
            editor.display = display_signature(editor)
        end
        return config
    end)
    editor.refreshing = false
    if current ~= editor then
        if not laid_out then
            error(result, 0)
        end
        return
    end
    if not laid_out then
        M.close(false)
        error(result, 0)
    end
    if not result then
        M.close(false)
        vim.notify(
            "Parley: draft retained; no unobscured composer space at its source",
            vim.log.levels.INFO
        )
    end
end

-- Observe events now, but lay out only after focus/option hooks have settled.
-- Never hide a healthy editor or mutate windows from a redraw callback.
local function schedule_refresh(editor)
    if current ~= editor or editor.refreshing or editor.refresh_pending then
        return
    end
    editor.refresh_pending = true
    vim.schedule(function()
        editor.refresh_pending = false
        if current ~= editor then
            return
        end
        local focused = api.nvim_get_current_win()
        if
            not editor_available(editor)
            or (focused ~= editor.source_win and focused ~= editor.window)
        then
            M.close(false)
            return
        end
        refresh(editor, false)
    end)
end

local function invalidate_display()
    local editor = current
    if not editor or editor.refreshing or editor.refresh_pending then
        return
    end
    if
        not editor_available(editor)
        or not vim.deep_equal(editor.display, display_signature(editor))
    then
        schedule_refresh(editor)
    end
end

---Accept locally without submitting a turn. Exposed for user-managed mappings.
function M.accept()
    local editor = current
    if not editor then
        return
    end
    if not editor_available(editor) then
        M.close(false)
        return
    end

    local text = api.nvim_buf_get_lines(editor.note.buffer, 0, -1, false)
    if table.concat(text, "\n"):match("^%s*$") then
        if editor.note.saved_lines then
            vim.notify("Parley: empty text does not delete an accepted note", vim.log.levels.INFO)
            return
        end
    else
        -- Close the current undo block, but retain all redo/alternate branches.
        vim.bo[editor.note.buffer].undolevels = vim.bo[editor.note.buffer].undolevels
        editor.note.saved_lines = text
        vim.bo[editor.note.buffer].modified = false
    end
    M.close(true)
end

---Help belongs only to the focused composer; source/note navigation owns no maps.
function M.toggle_help()
    local editor = current
    if not editor or api.nvim_get_current_win() ~= editor.window or vim.fn.mode() ~= "n" then
        return
    end
    help.toggle()
    refresh(editor, false)
end

local function install_bindings(editor)
    local buffer = editor.note.buffer
    local function bind(name, modes, action, description)
        for _, mode in ipairs(modes) do
            for _, key in ipairs(editor.keymaps[name]) do
                editor.bindings[#editor.bindings + 1] = {
                    name = name,
                    mode = mode,
                    key = key,
                    action = action,
                    description = description,
                    installed = false,
                }
            end
        end
    end

    -- Install in a fixed order; later actions win if configured keys overlap.
    bind("accept", { "n", "i" }, M.accept, "save & close")
    bind("accept_normal", { "n" }, M.accept, "save & close")
    bind("newline", { "i" }, "<CR>", "new line")
    bind("close", { "n", "i" }, function()
        M.close(true)
    end, "close (keep draft)")
    for _, direction in ipairs({ { name = "next", step = 1 }, { name = "previous", step = -1 } }) do
        bind(direction.name, { "n", "i" }, function()
            M.close(true)
            editor.options.navigate(direction.step)
        end, direction.step == 1 and "next note" or "previous note")
    end

    bind("help", { "n" }, M.toggle_help, "hotkeys")
    bind("help_normal", { "n" }, M.toggle_help, "hotkeys")

    api.nvim_buf_call(buffer, function()
        -- Snapshot before installing anything so aliases preserve the original
        -- mapping, rather than another mapping installed during this opening.
        for _, binding in ipairs(editor.bindings) do
            binding.original = vim.fn.maparg(binding.key, binding.mode, false, true)
        end
        for _, binding in ipairs(editor.bindings) do
            vim.keymap.set(binding.mode, binding.key, binding.action, {
                buffer = buffer,
                desc = binding.description,
            })
            binding.installed = true
        end
    end)
end

local function install_hooks(editor)
    -- Record positions while the window still exists, including external closure.
    api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "InsertLeavePre", "BufWinLeave" }, {
        group = editor.group,
        buffer = editor.note.buffer,
        callback = function()
            if current == editor then
                remember_cursor(editor)
            end
        end,
    })
    api.nvim_create_autocmd("ColorScheme", {
        group = editor.group,
        callback = style.refresh,
    })
    api.nvim_set_decoration_provider(assert(display_namespace), {
        on_start = function()
            invalidate_display()
        end,
        on_win = function(_, window)
            if current == editor and window == editor.source_win then
                invalidate_display()
            end
            return false
        end,
    })
    api.nvim_create_autocmd({
        "TextChanged",
        "TextChangedI",
        "TextChangedP",
        "VimResized",
        "WinResized",
        "WinScrolled",
    }, {
        group = editor.group,
        callback = function(event)
            if current ~= editor or editor.refreshing then
                return
            end
            if event.buf == editor.note.buffer and event.event:match("^TextChanged") then
                remember_cursor(editor)
                schedule_refresh(editor)
            else
                invalidate_display()
            end
        end,
    })
    api.nvim_create_autocmd("OptionSet", {
        group = editor.group,
        pattern = display_options,
        callback = function()
            if api.nvim_get_current_win() == editor.window then
                schedule_refresh(editor)
            else
                invalidate_display()
            end
        end,
    })
    api.nvim_create_autocmd({ "WinEnter", "BufEnter", "WinClosed", "BufWipeout" }, {
        group = editor.group,
        callback = function()
            schedule_refresh(editor)
        end,
    })
    api.nvim_create_autocmd("ModeChanged", {
        group = editor.group,
        buffer = editor.note.buffer,
        callback = function()
            -- Esc is native Insert -> Normal; mode hooks may alter our gutter.
            schedule_refresh(editor)
        end,
    })
end

---@return boolean entered
function M.enter()
    local editor = current
    if not editor then
        return false
    end
    local window = api.nvim_get_current_win()
    if window ~= editor.source_win and window ~= editor.window then
        return false
    end
    if not editor_available(editor) then
        M.close(false)
        return false
    end

    -- Entering may run configuration hooks that change the source window's
    -- gutter or winbar. Finalize that layout as part of this explicit action,
    -- rather than treating our own focus transfer as an external interruption.
    editor.refreshing = true
    api.nvim_set_current_win(editor.window)
    if current ~= editor or api.nvim_get_current_win() ~= editor.window then
        editor.refreshing = false
        return false
    end
    -- Apply after WinEnter/BufEnter hooks so source-window number settings
    -- cannot leak into the composer when it receives focus.
    hide_editor_gutter(editor.window)
    local insertion_cursor = editor.resume_cursor
    if insertion_cursor then
        api.nvim_win_set_cursor(editor.window, insertion_cursor)
    else
        insertion_cursor = api.nvim_win_get_cursor(editor.window)
    end
    refresh(editor, true)
    if current ~= editor or api.nvim_get_current_win() ~= editor.window then
        return false
    end

    -- A saved Insert-mode cursor can sit after the final byte. Restoring it
    -- in Normal mode clamps it onto the last character, so resume with A only
    -- for that boundary; i preserves insertion positions within the line.
    local line = api.nvim_buf_get_lines(
        editor.note.buffer,
        insertion_cursor[1] - 1,
        insertion_cursor[1],
        false
    )[1]
    editor.resume_cursor = nil
    vim.cmd(insertion_cursor[2] >= #line and "startinsert!" or "startinsert")
    return true
end

---@param note ParleyComposer.Draft Borrowed caller-owned buffer/history.
---@param options ParleyComposer.Presentation Borrowed until close.
function M.show(note, options)
    local configured_keys = keymaps.resolve_composer(options.keymaps)
    M.close(false)
    if not api.nvim_buf_is_loaded(note.buffer) then
        vim.notify("Parley: draft buffer was unloaded or deleted externally", vim.log.levels.WARN)
        return
    end
    display_namespace = display_namespace or api.nvim_create_namespace(module_path .. ".display")
    local source_buffer = api.nvim_win_get_buf(options.source_win)
    local source_view = vim.fn.winsaveview()
    local window = api.nvim_open_win(note.buffer, false, {
        relative = "win",
        win = options.source_win,
        row = 0,
        col = 0,
        width = 1,
        height = 1,
        style = "minimal",
        border = "none",
        hide = true,
        focusable = false,
        noautocmd = true,
        zindex = 60,
    })
    local editor = {
        note = note,
        options = options,
        keymaps = configured_keys,
        bindings = {},
        source_win = options.source_win,
        source_buf = source_buffer,
        source_tick = api.nvim_buf_get_changedtick(source_buffer),
        source_view = source_view,
        window = window,
        resume_cursor = entry_cursor(note),
        group = api.nvim_create_augroup(module_path, { clear = true }),
        -- Hooks must not invalidate an editor before its first layout exists.
        refreshing = true,
        refresh_pending = false,
        footer = {},
    }
    current = editor

    -- Once the float exists, setup failures release presentation and propagate;
    -- the caller-owned draft/undo buffer is never part of cleanup.
    local initialized, failure = pcall(function()
        style.refresh()
        -- Format the retained buffer in place, including drafts opened earlier.
        -- Use Neovim's Markdown support; no renderer dependency is required.
        if vim.bo[note.buffer].filetype ~= "markdown" then
            vim.bo[note.buffer].filetype = "markdown"
        end
        vim.bo[note.buffer].syntax = "markdown"

        vim.wo[window].wrap = true
        vim.wo[window].linebreak = true
        vim.wo[window].spell = true
        vim.wo[window].foldenable = false
        hide_editor_gutter(window)
        vim.wo[window].winhighlight =
            "Normal:ParleyReviewNoteActive,NormalFloat:ParleyReviewNoteActive,EndOfBuffer:ParleyReviewNoteActive"
        api.nvim_win_set_cursor(window, editor.resume_cursor)
        install_bindings(editor)
        install_hooks(editor)
        refresh(editor, true)
        if current == editor and options.enter then
            M.enter()
        end
    end)
    if not initialized then
        if current == editor then
            M.close(false)
        end
        error(failure, 0)
    end
end

return M
