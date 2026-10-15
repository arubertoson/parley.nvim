---Explicit, editor-local host for the current composer and human-note cards.
---The fixture owns its scratch source and draft buffers for this Neovim process.
---Closing its window releases presentation/maps, not text or native undo. No Pi
---binding, source capture, submitted messages or agent execution is simulated.
local composer = require("parley.composer")
local config = require("parley.config")
local inline = require("parley.inline")
local style = require("parley.composer.style")
local workspace = require("parley.workspace")
local M = {}
local api = vim.api

---@class ParleyDemo.Binding
---@field mode string
---@field key string
---@field action fun()
---@field original table

---@class ParleyDemo
---@field buffer integer Read-only sample code, never a workspace file.
---@field items ParleyInline.Item[] Retained local notes in source order.
---@field selected? ParleyInline.Item
---@field serial integer
---@field keys ParleyConfig.Resolved Activation-time key choices.
---@field bindings ParleyDemo.Binding[] Owned only while the view is attached.
---@field window? integer
---@field view? ParleyInline.View
---@field group? integer

---@type ParleyDemo?
local fixture

local source = {
    "-- Parley demo: sample code and local human notes, not an agent conversation.",
    "-- :ParleyDemo returns to the retained fixture; :q leaves its buffers intact.",
    "-- Uses your configured review/composer keys. No files are written.",
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
---@param first integer
---@param last integer
---@param lines? string[]
---@return ParleyInline.Item
local function add_note(demo, first, last, lines)
    demo.serial = demo.serial + 1
    local buffer = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buffer, ("parley://demo/note-%d.md"):format(demo.serial))
    vim.b[buffer].parley_composer = true
    vim.bo[buffer].buftype = ""
    vim.bo[buffer].bufhidden = "hide"
    vim.bo[buffer].swapfile = false
    vim.bo[buffer].undofile = false
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines or { "" })
    local item = {
        note = { id = demo.serial, buffer = buffer, created_at = os.time() },
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
        serial = 0,
        keys = config.get(),
        bindings = {},
    }
    local short = { "Should the retry delay include jitter?" }
    add_note(demo, 13, 16, short).note.saved_lines = vim.deepcopy(short)
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
        inline.update(demo.view, demo.buffer, demo.items, demo.selected and demo.selected.note.id)
    end
end

---@param demo ParleyDemo
local function detach(demo)
    if demo.window and composer.owns_source_window(demo.window) then
        composer.close(false)
    end
    if demo.group then
        api.nvim_del_augroup_by_id(demo.group)
        demo.group = nil
    end
    if demo.view then
        inline.clear(demo.view)
        demo.view = nil
    end
    if api.nvim_buf_is_loaded(demo.buffer) then
        api.nvim_buf_call(demo.buffer, function()
            for _, binding in ipairs(demo.bindings) do
                local mapping = vim.fn.maparg(binding.key, binding.mode, false, true)
                if mapping.buffer == 1 and mapping.callback == binding.action then
                    vim.keymap.del(binding.mode, binding.key, { buffer = demo.buffer })
                    if binding.original.buffer == 1 then
                        vim.fn.mapset(binding.mode, false, binding.original)
                    end
                end
            end
        end)
    end
    demo.bindings = {}
    demo.window = nil
end

---@type fun(demo: ParleyDemo, item: ParleyInline.Item, enter: boolean)
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
    show(demo, demo.items[(index - 1 + step) % #demo.items + 1], false)
end

show = function(demo, item, enter)
    if not source_available(demo) or api.nvim_get_current_win() ~= demo.window then
        return
    end
    composer.close(false)
    demo.selected = item
    refresh(demo)
    local view = assert(demo.view)
    inline.reveal(view)
    if not enter then
        return
    end
    composer.show(item.note, {
        source_win = assert(demo.window),
        source_label = ("Demo source:%d"):format(item.first),
        first = item.first,
        last = item.last,
        keymaps = demo.keys.composer,
        enter = true,
        room = {
            namespace = view.namespace,
            reserve = function(row, lines)
                return inline.reserve(view, item.note.id, row, lines)
            end,
            release = function()
                inline.release(view)
            end,
        },
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
            show(demo, item, true)
            return
        end
    end
    show(demo, add_note(demo, first, last), true)
end

---@param demo ParleyDemo
---@param create boolean
local function edit_note(demo, create)
    local line = api.nvim_win_get_cursor(0)[1]
    local selected = demo.selected
    if selected and line >= selected.first and line <= selected.last then
        show(demo, selected, true)
        return
    end
    for _, item in ipairs(demo.items) do
        if line >= item.first and line <= item.last then
            show(demo, item, true)
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
        for _, key in ipairs(demo.keys.review[action.name]) do
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
        demo.keys = config.get()
        local attached, failure = pcall(function()
            demo.view = inline.open(demo.window)
            attach(demo)
        end)
        if not attached then
            detach(demo)
            error(failure, 0)
        end
    end
    style.refresh()
    show(demo, demo.selected or demo.items[1], true)
end

return M
