---Synthetic scenario data and development controls for the normal conversation API.
---No reply, draft, navigation, mapping or presentation policy is implemented here.
local composer = require("parley.composer")
local config = require("parley.config")
local conversation = require("parley.conversation")
local workspace = require("parley.workspace")
local M = {}
local api = vim.api

---@class ParleyDemo
---@field buffer integer Read-only scratch source, never a workspace file.
---@field items ParleyConversation.Item[] Scenario data retained for this process.
---@field state { selected: ParleyConversation? }
---@field keys ParleyConfig.Resolved
---@field source? ParleyConversation.Source Disposable normal feature attachment.
---@field window? integer Scratch tab window.

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
---@param first integer
---@param last integer
---@param seed? ParleyConversation.Seed
local function add_note(demo, first, last, seed)
    demo.items[#demo.items + 1] = {
        conversation = conversation.new(seed),
        first = first,
        last = last,
    }
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
        state = {},
        keys = config.get(),
    }
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
    end
    add_note(demo, 13, 16, { id = "demo-retry", messages = samples, parent_id = "demo-cap" })
    add_note(demo, 18, 19, {
        lines = {
            "This is an unfinished local draft.",
            "",
            "Try editing, closing, reopening, and native undo/redo.",
        },
    })
    add_note(demo, 22, 32, {
        lines = {
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
        },
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
local function detach(demo)
    local source = demo.source
    demo.source, demo.window = nil, nil
    conversation.detach(source)
end

---Open/re-enter the same in-process fixture. Refuse active workspace review;
---the demo never detaches a real session or borrows its drafts/identity.
---@param entry? 'resume'|'reply' Development reload may resume active editing.
function M.open(entry)
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
    end
    if not demo.source or demo.source.closed then
        demo.source = conversation.attach({
            window = assert(demo.window),
            label = "Demo source",
            items = demo.items,
            state = demo.state,
            keymaps = demo.keys,
            enabled = function()
                if workspace.is_active() then
                    vim.notify(
                        "Parley: stop workspace review before using the demo",
                        vim.log.levels.WARN
                    )
                    return false
                end
                return true
            end,
        })
    end
    conversation.show(
        demo.source,
        demo.state.selected or demo.items[1].conversation,
        entry or "resume"
    )
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
    local interrupted = demo ~= nil and demo.source ~= nil
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
    M.open(editing and "reply" or "resume")
end

---Explicit synthetic incoming history. No local draft is read or submitted;
---refreshing an existing reader does not focus it or select the appended reply.
function M.append()
    local demo = fixture
    if not demo or workspace.is_active() then
        vim.notify("Parley: open the local demo first", vim.log.levels.WARN)
        return
    end
    local data = demo.items[1].conversation
    local count = data.thread.version + 1
    assert(conversation.receive(data, {
        id = "demo-incoming-" .. count,
        parent_id = data.thread.messages[#data.thread.messages].id,
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
end

return M
