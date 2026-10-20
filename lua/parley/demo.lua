---Explicit, editor-local host for discussion, composer and source cards.
---The fixture owns its scratch source and draft buffers for this Neovim process.
---Closing its window releases presentation/maps, not text or native undo. No Pi
---binding, source capture, message commitment or agent execution occurs. Human
---drafts appear in the conversation but stay editable until an agent request.
local composer = require("parley.composer")
local config = require("parley.config")
local discussion = require("parley.discussion")
local inline = require("parley.inline")
local keys = require("parley.composer.keymaps")
local style = require("parley.composer.style")
local thread = require("parley.thread")
local workspace = require("parley.workspace")
local M = {}
local api = vim.api

---@class ParleyDemo.Binding
---@field mode string
---@field key string
---@field action fun()
---@field original table

---@alias ParleyDemo.Draft ParleyDiscussion.Draft

---@class ParleyDemo.Item: ParleyInline.Item
---@field thread? ParleyThread Borrowed immutable history for presentation.
---@field note ParleyDemo.Draft Stable source-card identity, also the initial comment draft.
---@field drafts? table<string, ParleyDemo.Draft> Exact parent ID to unsent human draft.
---@field revisions? table<string, ParleyDemo.Draft> Submitted human ID to unsent revision draft.
---@field pending? ParleyDemo.Draft Current visible draft entry; other parent-keyed buffers stay retained.
---@field discussion_state? ParleyDiscussion.State

---@class ParleyDemo
---@field buffer integer Read-only sample code, never a workspace file.
---@field items ParleyDemo.Item[] Retained host data in source order.
---@field drafts ParleyDemo.Draft[] All buffers, including older parent/revision drafts; never pruned.
---@field selected? ParleyDemo.Item
---@field discussion? ParleyDiscussion.View Disposable active presentation.
---@field serial integer
---@field keys ParleyConfig.Resolved Activation-time key choices.
---@field bindings ParleyDemo.Binding[] Owned only while the view is attached.
---@field window? integer
---@field view? ParleyInline.View
---@field group? integer

---@type ParleyDemo?
local fixture

local source = {
    "-- Parley demo: synthetic history and local drafts; no agent execution.",
    "-- :ParleyDemo reload refreshes the UI; :q leaves drafts/history intact.",
    "-- :ParleyDemo append adds sample history without selecting it. No files written.",
    "",
    "local M = {}",
    "",
    "local defaults = {",
    "    attempts = 3,",
    "    delay_ms = 100,",
    "    maximum_delay_ms = 2000,",
    "}",
    "",
    "local function retry_delay(attempt, options)",
    "    local delay = options.delay_ms * 2 ^ (attempt - 1)",
    "    return math.min(delay, options.maximum_delay_ms)",
    "end",
    "",
    "function M.fetch(client, options)",
    "    options = options or defaults",
    "    local last_error",
    "",
    "    for attempt = 1, options.attempts do",
    "        local response, err = client.request()",
    "        if response then",
    "            return response",
    "        end",
    "        last_error = err",
    "",
    "        if attempt < options.attempts then",
    "            client.wait(retry_delay(attempt, options))",
    "        end",
    "    end",
    "",
    "    return nil, last_error",
    "end",
    "",
    "return M",
}

---@param demo ParleyDemo
---@param lines? string[]
---@return ParleyDemo.Draft
local function create_draft(demo, lines)
    demo.serial = demo.serial + 1
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buffer, ("parley://demo/note-%d.md"):format(demo.serial))
    vim.b[buffer].parley_composer = true
    vim.bo[buffer].buftype = "nofile"
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undofile = false
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines or { "" })
    local draft = {
        id = demo.serial,
        entry_id = "demo-draft-" .. demo.serial,
        buffer = buffer,
        created_at = os.time(),
    }
    demo.drafts[#demo.drafts + 1] = draft
    return draft
end

---@param demo ParleyDemo
---@param first integer
---@param last integer
---@param lines? string[]
---@return ParleyDemo.Item
local function add_note(demo, first, last, lines)
    local item = {
        note = create_draft(demo, lines),
        first = first,
        last = last,
    }
    demo.items[#demo.items + 1] = item
    table.sort(demo.items, function(left, right)
        if left.first ~= right.first then
            return left.first < right.first
        end
        return left.note.id < right.note.id
    end)
    return item
end

---@return ParleyDemo
local function create_fixture()
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buffer, "parley://demo/source.lua")
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undofile = false
    api.nvim_buf_set_lines(buffer, 0, -1, false, source)
    vim.bo[buffer].filetype = "lua"
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].modified = false

    local demo = {
        buffer = buffer,
        items = {},
        drafts = {},
        serial = 0,
        keys = config.get(),
        bindings = {},
    }
    local item = add_note(demo, 13, 16)
    item.thread = thread.new("demo-retry")
    item.discussion_state = {}
    local created = os.time() - 600
    local samples = {
        {
            id = "demo-question",
            role = "human",
            author = "You",
            lines = { "Should the retry delay include jitter?" },
        },
        {
            id = "demo-jitter",
            parent_id = "demo-question",
            role = "agent",
            author = "Sample agent",
            lines = {
                "## Jitter and the cap",
                "",
                "Jitter can keep clients from retrying in lockstep. The current delay is deterministic.",
                "",
                "One option is to choose a delay between zero and the capped exponential delay.",
                "This is synthetic discussion text, not an instruction to change the code.",
            },
        },
        {
            id = "demo-cap-question",
            parent_id = "demo-jitter",
            role = "human",
            author = "You",
            lines = {
                "Would the maximum delay still apply? Keep this a discussion, not a code change.",
            },
        },
        {
            id = "demo-cap",
            parent_id = "demo-cap-question",
            role = "agent",
            author = "Sample agent",
            lines = {
                "Yes: apply the cap before choosing a random delay.",
                "",
                "```lua",
                "local ceiling = math.min(delay, options.maximum_delay_ms)",
                "local wait_ms = random_between(0, ceiling)",
                "```",
                "",
                "The source above remains the original sample. Nothing has been edited or executed.",
                "",
                "### Questions still worth discussing",
                "",
                "- Should the first retry be immediate?",
                "- How should callers supply randomness for reproducible behavior?",
                "- Are attempts counted consistently at the request boundary?",
                "",
                "History navigation changes only the selected read-only message.",
                "Each explicit reply uses its own retained human draft with an exact parent.",
                "",
                "An oversized token for narrow reading panes:",
                string.rep("sample_token_", 16),
            },
        },
    }
    for index, message in ipairs(samples) do
        message.origin = "synthetic/demo"
        message.created_at = created + index * 60
        assert(thread.append(item.thread, message))
    end
    item.note.parent_id = "demo-cap"
    item.drafts = { ["demo-cap"] = item.note }
    add_note(demo, 18, 19, {
        "This is an unfinished local draft.",
        "",
        "Try editing, closing, reopening, and native undo/redo.",
    })
    add_note(demo, 22, 32, {
        "## A longer Markdown note",
        "",
        "This fixture deliberately exercises wrapping and height limits. It is not an agent reply.",
        "",
        "- Keep the source code visible while discussing it.",
        "- Navigate between notes without discarding unfinished edits.",
        "- Resize the window and inspect the current presentation.",
        "",
        "```lua",
        "local response, err = client.request()",
        "if response then",
        "    return response",
        "end",
        "```",
        "",
        "An unbroken token for narrow-window wrapping:",
        string.rep("long_token_", 16),
        "",
        "More notes can be created on other sample lines with the configured comment action.",
    })
    return demo
end

---@param demo ParleyDemo
local function source_available(demo)
    return demo.window ~= nil
        and api.nvim_win_is_valid(demo.window)
        and api.nvim_win_get_buf(demo.window) == demo.buffer
end

---@param demo ParleyDemo
local function refresh(demo)
    if source_available(demo) and demo.view then
        for _, item in ipairs(demo.items) do
            if item.thread then
                local pending = item.pending
                local latest = item.thread.messages[#item.thread.messages]
                item.preview = pending
                        and {
                            buffer = pending.buffer,
                            role = "human",
                            state = ("draft · %d entries"):format(#item.thread.messages + 1),
                            created_at = pending.created_at,
                        }
                    or latest and {
                        lines = latest.lines,
                        role = latest.role,
                        state = ("%d messages"):format(#item.thread.messages),
                        created_at = latest.created_at,
                    }
                    or { lines = { "No messages yet" }, state = "0 messages" }
            end
        end
        inline.update(demo.view, demo.buffer, demo.items, demo.selected and demo.selected.note.id)
    end
end

---@param demo ParleyDemo
local function detach(demo)
    -- Unpublish these exact resources before anything can run user hooks.
    local reader, group, view = demo.discussion, demo.group, demo.view
    local window, bindings = demo.window, demo.bindings
    local editor = window and composer.for_source_window(window)
    demo.discussion, demo.group, demo.view, demo.window = nil, nil, nil, nil
    demo.bindings = {}
    local failed, failure
    local function finish(action)
        local ok, err = pcall(action)
        if not ok and not failed then
            failed, failure = true, err
        end
    end
    if group then
        finish(function()
            api.nvim_del_augroup_by_id(group)
        end)
    end
    if view then
        finish(function()
            inline.clear(view)
        end)
    end
    if api.nvim_buf_is_loaded(demo.buffer) then
        finish(function()
            api.nvim_buf_call(demo.buffer, function()
                for _, binding in ipairs(bindings) do
                    local mapping = vim.fn.maparg(binding.key, binding.mode, false, true)
                    if mapping.buffer == 1 and mapping.callback == binding.action then
                        vim.keymap.del(binding.mode, binding.key, { buffer = demo.buffer })
                        if binding.original.buffer == 1 then
                            vim.fn.mapset(binding.mode, false, binding.original)
                        end
                    end
                end
            end)
        end)
    end
    if reader then
        finish(function()
            discussion.close(reader, false)
        end)
    end
    if editor then
        finish(function()
            composer.close(false, editor)
        end)
    end
    if failed then
        error(failure, 0)
    end
end

---Resume the same canonical buffer for each exact reply target. Closing or
---saving never commits it; only one retained draft is presented at a time.
---@param demo ParleyDemo
---@param item ParleyDemo.Item
---@param parent_id? string
---@return ParleyDemo.Draft
local function reply_draft(demo, item, parent_id)
    if parent_id == nil then
        assert(item.note.parent_id == nil, "Parley: initial comment has a reply parent")
        item.pending = item.note
        return item.note
    end
    item.drafts = item.drafts or {}
    local drafts = assert(item.drafts)
    if not drafts[parent_id] then
        local draft = create_draft(demo)
        draft.parent_id = parent_id
        drafts[parent_id] = draft
    end
    item.pending = drafts[parent_id]
    return drafts[parent_id]
end

---@param demo ParleyDemo
---@param item ParleyDemo.Item
---@param id string
---@return ParleyDemo.Draft
local function revision_draft(demo, item, id)
    local message = assert(thread.get(assert(item.thread), id))
    assert(message.role == "human", "Parley: only human messages can be revised")
    item.revisions = item.revisions or {}
    local draft = item.revisions[id]
    if not draft then
        draft = create_draft(demo, message.lines)
        draft.parent_id = message.parent_id
        draft.replaces_id = id
        item.revisions[id] = draft
    end
    item.pending = draft
    return draft
end

---@type fun(demo: ParleyDemo, item: ParleyDemo.Item, entry?: 'read'|'reply'|'resume')
local show

---@param demo ParleyDemo
---@param step integer
local function move_note(demo, step)
    if not source_available(demo) or api.nvim_get_current_win() ~= demo.window then
        return
    end
    local index = 1
    for position, item in ipairs(demo.items) do
        if item == demo.selected then
            index = position
            break
        end
    end
    show(demo, demo.items[(index - 1 + step) % #demo.items + 1])
end

show = function(demo, item, entry)
    if not source_available(demo) or api.nvim_get_current_win() ~= demo.window then
        return
    end
    local source_window = demo.window
    local previous = demo.discussion
    local editor = composer.for_source_window(source_window)
    demo.discussion = nil
    if previous then
        discussion.close(previous, false)
    end
    if editor then
        composer.close(false, editor)
    end
    if
        not source_available(demo)
        or demo.window ~= source_window
        or api.nvim_get_current_win() ~= source_window
        or demo.discussion
        or composer.owns_source_window(source_window)
    then
        return
    end
    demo.selected = item
    refresh(demo)
    local view = assert(demo.view)
    inline.reveal(view)
    if
        not source_available(demo)
        or demo.view ~= view
        or api.nvim_get_current_win() ~= demo.window
        or demo.discussion
        or composer.owns_source_window(demo.window)
    then
        return
    end
    if not entry then
        return
    end
    local room_owner = {}
    local room = {
        namespace = view.namespace,
        reserve = function(row, lines)
            return inline.reserve(view, item.note.id, row, lines, room_owner)
        end,
        release = function()
            inline.release(view, room_owner)
        end,
    }
    if item.thread then
        -- Explicit source entry targets the message shown by inline.card,
        -- never an older remembered reader selection. Reload resumes State.
        local message_id
        if entry ~= "resume" then
            local latest = item.thread.messages[#item.thread.messages]
            message_id = item.pending and item.pending.entry_id or (latest and latest.id)
        end
        local continue_draft = entry == "reply" or (entry == "read" and item.pending ~= nil)
        local opened, failure = pcall(function()
            demo.discussion = discussion.open(item.thread, {
                source_win = assert(demo.window),
                source_label = ("Demo source:%d"):format(item.first),
                first = item.first,
                last = item.last,
                room = room,
                state = item.discussion_state,
                message_id = message_id,
                enter = not continue_draft,
                keymaps = demo.keys.discussion,
                composer_keymaps = demo.keys.composer,
                reply = function(parent_id)
                    return reply_draft(demo, item, parent_id)
                end,
                edit = function(id)
                    return revision_draft(demo, item, id)
                end,
                draft = function()
                    return item.pending
                end,
                changed = function()
                    refresh(demo)
                end,
            })
            if not demo.discussion then
                return
            end
            if continue_draft and not discussion.reply(demo.discussion) then
                discussion.close(demo.discussion, false)
                demo.discussion = nil
            end
        end)
        if not opened then
            if demo.discussion then
                local reader = demo.discussion
                demo.discussion = nil
                pcall(discussion.close, reader, false)
            end
            error(failure, 0)
        end
        return
    end
    composer.show(item.note, {
        source_win = assert(demo.window),
        source_label = ("Demo source:%d"):format(item.first),
        first = item.first,
        last = item.last,
        keymaps = demo.keys.composer,
        enter = true,
        room = room,
        navigate = function(step)
            move_note(demo, step)
        end,
        changed = function()
            refresh(demo)
        end,
    })
end

---@param demo ParleyDemo
---@param range boolean
local function comment(demo, range)
    local first = api.nvim_win_get_cursor(0)[1]
    local last = first
    if range then
        first, last = math.min(vim.fn.line("v"), first), math.max(vim.fn.line("v"), first)
        vim.cmd("normal! " .. api.nvim_replace_termcodes("<Esc>", true, false, true))
    end
    for _, item in ipairs(demo.items) do
        if item.first == first and item.last == last then
            show(demo, item, "read")
            return
        end
    end
    show(demo, add_note(demo, first, last), "read")
end

---@param demo ParleyDemo
---@param create boolean
---@param entry? 'read'|'reply'
local function edit_note(demo, create, entry)
    local line = api.nvim_win_get_cursor(0)[1]
    local selected = demo.selected
    if selected and line >= selected.first and line <= selected.last then
        show(demo, selected, entry or "read")
        return
    end
    for _, item in ipairs(demo.items) do
        if line >= item.first and line <= item.last then
            show(demo, item, entry or "read")
            return
        end
    end
    if create then
        comment(demo, false)
    end
end

---@param demo ParleyDemo
local function attach(demo)
    local actions = {
        {
            name = "comment",
            mode = "n",
            run = function()
                comment(demo, false)
            end,
        },
        {
            name = "comment",
            mode = "x",
            run = function()
                comment(demo, true)
            end,
        },
        {
            name = "edit",
            mode = "n",
            run = function()
                edit_note(demo, true)
            end,
        },
        {
            name = "edit",
            mode = "x",
            run = function()
                comment(demo, true)
            end,
        },
        {
            name = "enter",
            mode = "n",
            run = function()
                edit_note(demo, false)
            end,
        },
        {
            name = "reply",
            mode = "n",
            run = function()
                edit_note(demo, false, "reply")
            end,
        },
        {
            name = "next",
            mode = "n",
            run = function()
                move_note(demo, 1)
            end,
        },
        {
            name = "previous",
            mode = "n",
            run = function()
                move_note(demo, -1)
            end,
        },
    }
    -- Snapshot all originals before installing aliases or overlapping actions.
    for _, action in ipairs(actions) do
        local function run()
            if workspace.is_active() then
                vim.notify(
                    "Parley: stop workspace review before using the demo",
                    vim.log.levels.WARN
                )
                return
            end
            if source_available(demo) and api.nvim_get_current_win() == demo.window then
                action.run()
            end
        end
        for _, configured_key in ipairs(demo.keys.review[action.name]) do
            local key = keys.concrete(configured_key)
            demo.bindings[#demo.bindings + 1] = {
                mode = action.mode,
                key = key,
                action = run,
                original = vim.fn.maparg(key, action.mode, false, true),
            }
        end
    end
    for _, binding in ipairs(demo.bindings) do
        vim.keymap.set(binding.mode, binding.key, binding.action, {
            buffer = demo.buffer,
            desc = "Parley demo: local note action",
        })
    end

    demo.group = api.nvim_create_augroup("ParleyDemo", { clear = true })
    api.nvim_create_autocmd({ "BufWinLeave", "WinClosed" }, {
        group = demo.group,
        callback = function()
            vim.schedule(function()
                if demo.view and not source_available(demo) then
                    detach(demo)
                end
            end)
        end,
    })
    api.nvim_create_autocmd({ "WinResized", "VimResized", "ColorScheme" }, {
        group = demo.group,
        callback = function(event)
            if event.event == "ColorScheme" then
                style.refresh()
            end
            if demo.window and not composer.owns_source_window(demo.window) then
                refresh(demo)
            end
        end,
    })
end

-- Also repair retained buffers created before the demo used scratch semantics.
-- This changes only buffer options, never text, native undo or local acceptance.
local function retain_scratch_drafts(demo)
    for _, draft in ipairs(demo.drafts) do
        if api.nvim_buf_is_valid(draft.buffer) then
            vim.bo[draft.buffer].buftype = "nofile"
        end
    end
end

---Open/re-enter the same in-process fixture. Refuse active workspace review;
---the demo never detaches a real session or borrows its drafts/identity.
function M.open()
    if workspace.is_active() then
        vim.notify("Parley: stop workspace review before opening the demo", vim.log.levels.WARN)
        return
    end
    if vim.fn.mode() ~= "n" then
        vim.notify("Parley: open the demo from Normal mode", vim.log.levels.WARN)
        return
    end
    fixture = fixture or create_fixture()
    local demo = fixture
    retain_scratch_drafts(demo)
    if not api.nvim_buf_is_loaded(demo.buffer) then
        vim.notify(
            "Parley: the retained demo source buffer was deleted externally",
            vim.log.levels.WARN
        )
        return
    end

    if source_available(demo) then
        api.nvim_set_current_win(assert(demo.window))
    else
        detach(demo)
        -- A separate scratch tab never replaces a user's source/modified buffer.
        vim.cmd.tabnew()
        demo.window = api.nvim_get_current_win()
        api.nvim_win_set_buf(demo.window, demo.buffer)
    end
    if not demo.view then
        local attached, failure = pcall(function()
            demo.view = inline.open(assert(demo.window))
            attach(demo)
        end)
        if not attached then
            pcall(detach, demo)
            error(failure, 0)
        end
    end
    style.refresh()
    show(demo, demo.selected or demo.items[1], "resume")
end

---Explicit development reload of the presentation modules, not the host fixture,
---configuration, workspace or bridge. Existing module tables keep their identity
---so cached host imports cannot retain a second composer with separate ownership.
---All code is staged before teardown; syntax/load failures leave the old view up.
function M.reload()
    if workspace.is_active() then
        vim.notify("Parley: stop workspace review before reloading the demo", vim.log.levels.WARN)
        return
    end
    if vim.fn.mode() ~= "n" then
        vim.notify("Parley: reload the demo from Normal mode", vim.log.levels.WARN)
        return
    end
    local demo = fixture
    local window = demo and source_available(demo) and demo.window or nil
    for _, candidate in ipairs(api.nvim_list_wins()) do
        if composer.owns_source_window(candidate) and candidate ~= window then
            vim.notify(
                "Parley: close the other composer before reloading the demo",
                vim.log.levels.WARN
            )
            return
        end
    end

    local help = require("parley.composer.help")
    local help_enabled = help.is_enabled()
    local editing = window ~= nil and composer.owns_source_window(window)
    local staged, modules = pcall(function()
        local source_path = debug.getinfo(1, "S").source
        assert(source_path:sub(1, 1) == "@", "demo reload requires filesystem-backed Lua")
        local directory = vim.fs.dirname(source_path:sub(2))
        local replacements = {}
        -- These modules acquire no resources at import time. Their dependencies
        -- bind the existing export tables, which are updated together below.
        for _, spec in ipairs({
            { "parley.composer.style", "composer/style.lua" },
            { "parley.composer.keymaps", "composer/keymaps.lua" },
            { "parley.composer.help", "composer/help.lua" },
            { "parley.composer", "composer/init.lua" },
            { "parley.discussion", "discussion.lua" },
            { "parley.inline", "inline.lua" },
        }) do
            local chunk, failure = loadfile(directory .. "/" .. spec[2])
            assert(chunk, failure)
            local replacement = chunk(spec[1])
            assert(type(replacement) == "table", spec[1] .. " must return an export table")
            replacements[#replacements + 1] =
                { target = require(spec[1]), replacement = replacement }
        end
        return replacements
    end)
    if not staged then
        vim.notify(
            "Parley: demo reload failed; old presentation retained: " .. tostring(modules),
            vim.log.levels.ERROR
        )
        return
    end

    local previous_focus = api.nvim_get_current_win()
    if demo then
        detach(demo)
    end
    -- Closing windows can synchronously open replacement UI or move focus.
    -- Do not invalidate its module ownership or reopen over that action.
    local interrupted = demo ~= nil
        and (demo.view ~= nil or demo.discussion ~= nil or demo.group ~= nil)
    for _, candidate in ipairs(api.nvim_list_wins()) do
        interrupted = interrupted or composer.owns_source_window(candidate)
    end
    local focused = api.nvim_get_current_win()
    if interrupted or (focused ~= previous_focus and focused ~= window) then
        vim.notify(
            "Parley: reload interrupted by a presentation/focus hook; modules were not replaced",
            vim.log.levels.WARN
        )
        return
    end
    for _, module in ipairs(modules) do
        for name in pairs(module.target) do
            module.target[name] = nil
        end
        for name, value in pairs(module.replacement) do
            module.target[name] = value
        end
    end
    if help_enabled then
        help.toggle()
    end
    if
        demo
        and window
        and api.nvim_win_is_valid(window)
        and api.nvim_win_get_buf(window) == demo.buffer
    then
        demo.window = window
    end
    M.open()
    if editing and demo and demo.discussion and not demo.discussion.closed then
        discussion.reply(demo.discussion)
    end
end

---Explicit synthetic incoming history. No local draft is read or submitted;
---refreshing an existing reader does not focus it or select the appended reply.
function M.append()
    local demo = fixture
    if not demo or workspace.is_active() then
        vim.notify("Parley: open the local demo first", vim.log.levels.WARN)
        return
    end
    local data
    for _, item in ipairs(demo.items) do
        if item.thread then
            data = item.thread
            break
        end
    end
    assert(data)
    local count = data.version + 1
    assert(thread.append(data, {
        id = "demo-incoming-" .. count,
        parent_id = data.messages[#data.messages].id,
        role = "agent",
        author = "Sample agent",
        origin = "synthetic/demo",
        created_at = os.time(),
        lines = {
            ("Synthetic incoming reply %d."):format(count),
            "",
            "The current selection, reading position and human draft should stay where you left them.",
            "This message was appended by the demo command, not an agent or a submitted draft.",
        },
    }))
    if demo.discussion then
        discussion.update(demo.discussion)
    end
    refresh(demo)
end

return M
