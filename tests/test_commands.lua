local MiniTest = _G.MiniTest or require("mini.test")
local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "NONE" })
            child.lua([[
                vim.opt.runtimepath:append(vim.fn.getcwd())
                vim.cmd.runtime('plugin/parley.lua')
                parley = require('parley')
                original_investigate = parley.investigate
                workspace = require('parley.workspace')
                calls, notifications = {}, {}
                vim.notify = function(message, level)
                    notifications[#notifications + 1] = { message = message, level = level }
                end
                function record(name)
                    return function(...)
                        calls[#calls + 1] = { name = name, args = { ... } }
                    end
                end
                for _, name in ipairs({ 'start', 'start_implementation', 'stop', 'ask', 'turn',
                    'done', 'finish_implementation', 'investigate', 'resolve_note', 'delete_note' }) do
                    parley[name] = record(name)
                end
                local demo = require('parley.demo')
                for _, name in ipairs({ 'open', 'append', 'reload' }) do
                    demo[name] = record('demo.' .. name)
                end
            ]])
        end,
        post_once = child.stop,
    },
})

T["only the consolidated command is registered and loading is idempotent"] = function()
    child.lua([[
        vim.cmd.runtime('plugin/parley.lua')
        local commands = vim.api.nvim_get_commands({ builtin = false })
        assert(commands.Parley)
        for name in pairs(commands) do
            if name:match('^Review') or name:match('^Parley') then
                assert(name == 'Parley', name)
            end
        end
    ]])
end

T["start defaults to implementation; stop only detaches; investigate preserves instructions"] = function()
    child.lua([[
        vim.cmd('Parley start')
        vim.cmd('Parley start review')
        vim.cmd('Parley start implementation')
        vim.cmd('Parley stop')
        vim.cmd('Parley investigate check  error handling and race conditions')
        assert(vim.deep_equal(calls, {
            { name = 'start_implementation', args = {} },
            { name = 'start', args = {} },
            { name = 'start_implementation', args = {} },
            { name = 'stop', args = {} },
            { name = 'investigate', args = { 'check  error handling and race conditions' } },
        }))
        assert(#notifications == 0)
    ]])
end

for _, workflow in ipairs({ "review", "parley" }) do
    T[workflow .. ": submit and done dispatch using selected workspace authority"] = function()
        child.lua(
            [[
            local workflow = ...
            vim.cmd.edit('plugin/parley.lua')
            assert(workspace.activate({ workspace = vim.fn.getcwd(), sessionId = 'parent', editorId = 'editor' }))
            assert(workspace.select_review('selected-review', workflow))
            vim.cmd('Parley submit')
            vim.cmd('Parley done')
            assert(vim.deep_equal(calls, {
                { name = workflow == 'parley' and 'turn' or 'ask', args = {} },
                { name = workflow == 'parley' and 'finish_implementation' or 'done', args = {} },
            }))
            vim.cmd('Parley done retained-review')
            if workflow == 'review' then
                assert(vim.deep_equal(calls[3], { name = 'done', args = { 'retained-review' } }))
                assert(#notifications == 0)
            else
                assert(#calls == 2 and #notifications == 1)
                assert(notifications[1].message:find('does not accept a review ID', 1, true))
            end
            workspace.stop()
        ]],
            { workflow }
        )
    end
end

T["implementation investigation is guarded below command dispatch and omitted from completion"] = function()
    child.lua([[
        vim.cmd.edit('plugin/parley.lua')
        assert(workspace.activate({ workspace = vim.fn.getcwd(), sessionId = 'parent', editorId = 'editor' }))
        assert(workspace.select_review('implementation', 'parley'))
        parley.investigate = original_investigate
        vim.cmd('Parley investigate inspect error handling')
        assert(#calls == 0 and #notifications == 1)
        assert(notifications[1].message:find('only available in the review workflow', 1, true))
        original_investigate('direct Lua call is also guarded')
        assert(#notifications == 2)
        assert(vim.deep_equal(vim.fn.getcompletion('Parley i', 'cmdline'), {}))
        workspace.stop()
    ]])
end

T["thread and demo subcommands dispatch without submitting"] = function()
    child.lua([[
        for _, command in ipairs({ 'thread resolve', 'thread reopen', 'thread delete',
            'demo', 'demo append', 'demo reload' }) do
            vim.cmd('Parley ' .. command)
        end
        assert(vim.deep_equal(calls, {
            { name = 'resolve_note', args = { true } },
            { name = 'resolve_note', args = { false } },
            { name = 'delete_note', args = {} },
            { name = 'demo.open', args = {} },
            { name = 'demo.append', args = {} },
            { name = 'demo.reload', args = {} },
        }))
    ]])
end

T["invalid arguments report errors without dispatch or side effects"] = function()
    child.lua([[
        local invalid = { '', 'unknown', 'start parley', 'start Review', 'start review extra',
            'stop extra', 'submit extra', 'investigate', 'investigate   ', 'done a b',
            'thread', 'thread unknown', 'thread resolve extra', 'demo unknown', 'demo reload extra' }
        for _, args in ipairs(invalid) do
            local before = #notifications
            vim.cmd('Parley ' .. args)
            assert(#calls == 0, args)
            assert(#notifications == before + 1, args)
            assert(notifications[#notifications].level == vim.log.levels.ERROR, args)
        end
    ]])
end

T["completion filters prefixes and respects subcommand argument positions"] = function()
    child.lua([[
        local function complete(line)
            return vim.fn.getcompletion(line, 'cmdline')
        end
        assert(vim.deep_equal(complete('Parley '),
            { 'start', 'stop', 'submit', 'investigate', 'done', 'thread', 'demo' }))
        assert(vim.deep_equal(complete('Parley st'), { 'start', 'stop' }))
        assert(vim.deep_equal(complete('Parley start '), { 'review', 'implementation' }))
        assert(vim.deep_equal(complete('Parley start i'), { 'implementation' }))
        assert(vim.deep_equal(complete('Parley thread '), { 'resolve', 'reopen', 'delete' }))
        assert(vim.deep_equal(complete('Parley thread re'), { 'resolve', 'reopen' }))
        assert(vim.deep_equal(complete('Parley demo '), { 'append', 'reload' }))
        for _, line in ipairs({ 'Parley stop ', 'Parley submit ', 'Parley done ',
            'Parley investigate ', 'Parley investigate start ', 'Parley start review ',
            'Parley thread resolve ', 'Parley demo reload ', 'Parley unknown ' }) do
            assert(vim.deep_equal(complete(line), {}), line)
        end
    ]])
end

return T
