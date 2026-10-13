local MiniTest = _G.MiniTest or require("mini.test")
local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "NONE" })
            child.lua([[vim.opt.runtimepath:append(vim.fn.getcwd())
                composer = require('parley.composer')
                vim.o.lines = 30
                vim.o.columns = 100
                vim.o.cmdheight = 1
                local lines = {}
                for i = 1,80 do lines[i] = ('SOURCE-%02d'):format(i) end
                source_path = vim.fn.tempname() .. '.lua'
                vim.fn.writefile(lines, source_path)
                vim.cmd.edit(source_path)
                vim.cmd('normal! A temporary edit')
                vim.cmd('normal! u')
                source_buf = vim.api.nvim_get_current_buf()
                source_win = vim.api.nvim_get_current_win()
                vim.api.nvim_win_set_cursor(0, { 8, 0 })
                before = { lines = vim.api.nvim_buf_get_lines(0,0,-1,false),
                    modified = vim.bo.modified, undo = vim.fn.undotree(),
                    tick = vim.api.nvim_buf_get_changedtick(0), view = vim.fn.winsaveview() }
            ]])
        end,
        post_case = function() child.lua("vim.fn.delete(source_path)") end,
        post_once = child.stop,
    },
})

local function settle()
    child.cmd("redraw!")
    vim.uv.sleep(80)
    child.cmd("redraw!")
end

local function source_unchanged()
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(source_buf,0,-1,false)"),
        child.lua_get("before.lines")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.bo[source_buf].modified"),
        child.lua_get("before.modified")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(source_buf)"),
        child.lua_get("before.tick")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_win_call(source_win, vim.fn.undotree)"),
        child.lua_get("before.undo")
    )
end

local function displayed(line, win)
    return child.lua_get(([[vim.fn.screenpos(%s, %d, 1).row]]):format(win or "source_win", line))
end

local function screen_has(text)
    settle()
    for _, line in ipairs(child.get_screenshot().text) do
        if table.concat(line):find(text, 1, true) then return true end
    end
    return false
end

local function composer_config()
    return child.lua_get("vim.api.nvim_win_get_config(vim.api.nvim_get_current_win())")
end

local function content_origin()
    return child.lua_get(
        "vim.fn.win_screenpos(source_win)[1] + (vim.wo[source_win].winbar ~= '' and 1 or 0)"
    )
end

local function assert_reserved(first, last)
    settle()
    local config = composer_config()
    local row = content_origin() + config.row
    MiniTest.expect.equality(displayed(last) < row, true)
    MiniTest.expect.equality(displayed(last + 1), row + config.height + 1)
    local screen = child.get_screenshot()
    local left = child.lua_get("vim.fn.win_screenpos(source_win)[2]")
    local width = child.lua_get("vim.api.nvim_win_get_width(source_win)")
    for index = row, row + config.height do
        local text = table.concat(screen.text[index], "", left, left + width - 1)
        MiniTest.expect.equality(text:find("SOURCE-", 1, true), nil)
    end
    MiniTest.expect.equality(first <= last, true)
end

T["range composition makes display space, saves in memory and restores reading without source edits"] = function()
    child.lua("composer.open(8,9,'range')")
    assert_reserved(8, 9)
    child.type_keys("What happens if lookup fails?", "<CR>")
    settle()
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.scope"), "range")
    MiniTest.expect.equality(
        child.lua_get("composer.comments[1].lines"),
        { "What happens if lookup fails?" }
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_get_current_win()"),
        child.lua_get("source_win")
    )
    MiniTest.expect.equality(child.lua_get("vim.fn.winsaveview()"), child.lua_get("before.view"))
    MiniTest.expect.equality(displayed(10), 10)
    source_unchanged()
end

T["rapid editor handoffs do not enlist Markview or leave renders for deleted buffers"] = function()
    local plugin = vim.fn.globpath(vim.o.packpath, "pack/*/opt/markview.nvim", false, true)[1]
    assert(plugin, "Markview must be installed for its composer integration check")
    child.lua(
        [[
        vim.opt.runtimepath:append(...)
        attached = {}
        vim.api.nvim_create_autocmd('User', {
            pattern = 'MarkviewAttach',
            callback = function(event) attached[event.data.buffer] = true end,
        })
        vim.cmd('runtime plugin/markview.lua')
        vim.v.errmsg = ''
    ]],
        { plugin }
    )
    for _ = 1, 8 do
        child.lua("composer.open(8,8,'line'); editor_buf = vim.api.nvim_get_current_buf()")
        child.type_keys("A short note", "<Esc>")
        MiniTest.expect.equality(child.lua_get("attached[editor_buf] == true"), false)
        child.lua([[
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = editor_buf })
        ]])
        child.type_keys("<CR>")
    end
    child.lua("vim.wait(250, function() return false end)")
    MiniTest.expect.equality(child.lua_get("vim.v.errmsg"), "")
    source_unchanged()
    -- The exclusion is local to note editors, not a global Markdown disable.
    child.lua([[
        local buf = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '# Ordinary Markdown' })
        vim.api.nvim_set_current_buf(buf)
        vim.bo[buf].filetype = 'markdown'
        ordinary_markdown = buf
    ]])
    MiniTest.expect.equality(child.lua_get("attached[ordinary_markdown] == true"), true)
end

T["Ctrl+C cancels in either mode and removes new drafts without touching source mappings"] = function()
    child.lua([[
        vim.keymap.set('n', '<C-c>', function() source_cancelled = true end, { buffer = source_buf })
        composer.open(8,8,'line')
    ]])
    child.type_keys("Saved note", "<CR>")
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys("Uncommitted ", "<C-c>")
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_get_current_win()"),
        child.lua_get("source_win")
    )
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "n")
    MiniTest.expect.equality(child.lua_get("vim.fn.winsaveview()"), child.lua_get("before.view"))
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Saved note" })
    child.lua("composer.edit(composer.comments[1])")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Saved note")
    child.type_keys("Changed ", "<Esc>", "<C-c>")
    child.type_keys("<C-c>")
    MiniTest.expect.equality(child.lua_get("source_cancelled"), true)
    child.lua("composer.open(10,10,'line'); cancelled_buf = vim.api.nvim_get_current_buf()")
    child.type_keys("Throw this away", "<C-c>")
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 1)
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_buf_is_valid(cancelled_buf)"), false)
    child.lua("composer.resume()")
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    source_unchanged()
end

T["history position is visible and committing older text discards its future, not its ancestry"] = function()
    child.lua("composer.open(8,8,'line')")
    child.type_keys("Original", "<CR>")
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys(" updated", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Original updated" })
    child.lua("composer.edit(composer.comments[1])")
    MiniTest.expect.equality(screen_has("history 3/3 · saved"), true)
    child.type_keys("<C-p>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original")
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "i")
    MiniTest.expect.equality(screen_has("history 2/3 · unsaved"), true)
    child.type_keys("<C-n>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original updated")
    MiniTest.expect.equality(screen_has("history 3/3 · saved"), true)
    child.type_keys("<C-p>", "<C-c>") -- Cancel navigation back to the saved version.
    child.lua("composer.edit(composer.comments[1])")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original updated")
    child.type_keys("<C-p>", "<CR>") -- Accept old text and discard the later leaf.
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Original" })
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys("<C-n>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original")
    MiniTest.expect.equality(screen_has("history 2/2 · saved"), true)
    child.type_keys("<C-p>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "")
    MiniTest.expect.equality(screen_has("history 1/2 · unsaved"), true)
    child.type_keys("<C-n>", "<C-c>")
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys(" replacement", "<CR>")
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys("<C-p>", "<End>", " branch", "<CR>") -- Editing old text also discards the alternate leaf.
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Original branch" })
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys("<Esc>", "g-")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original")
    child.type_keys("<C-n>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original branch")
    child.type_keys("<C-p>", "q") -- Normal q has the same pruning contract.
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Original" })
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys("<Esc>", "<C-n>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original")
    child.type_keys("g+") -- Discarded versions are gone, not just hidden from Ctrl+N.
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Original")
    child.type_keys("<C-c>")
    source_unchanged()
end

T["saved multiline comments reopen in Insert after the final UTF-8 character"] = function()
    child.lua("composer.open(8,8,'line')")
    child.type_keys("First", "<C-j>", "Last café", "<CR>")
    child.lua("composer.edit(composer.comments[1])")
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "i")
    child.type_keys("!", "<CR>")
    MiniTest.expect.equality(
        child.lua_get("composer.comments[1].lines"),
        { "First", "Last café!" }
    )
    child.lua("composer.edit(composer.comments[1])")
    child.type_keys("<C-j>", "Final", "<CR>")
    MiniTest.expect.equality(
        child.lua_get("composer.comments[1].lines"),
        { "First", "Last café!", "Final" }
    )
    source_unchanged()
end

T["wrapped source, multiline growth and viewport edges never put the float over code"] = function()
    child.lua([[vim.wo[source_win].number = true
        vim.wo[source_win].linebreak = true
        vim.wo[source_win].breakindent = true
        vim.wo[source_win].winbar = 'SOURCE WINBAR'
        vim.api.nvim_buf_set_lines(source_buf,7,8,false,{string.rep('wrapped ',26)})
        vim.api.nvim_win_set_cursor(source_win, { 28, 0 })
        composer.open(8,8,'line')]])
    settle()
    local config = composer_config()
    local anchor_end = child.lua_get(
        "vim.fn.screenpos(source_win,8,#vim.api.nvim_buf_get_lines(source_buf,7,8,false)[1]).row"
    )
    local float_start = content_origin() + config.row
    MiniTest.expect.equality(float_start, anchor_end + 3)
    MiniTest.expect.equality(displayed(9), float_start + config.height + 1)
    assert_reserved(8, 8)
    child.type_keys("First", "<C-j>", "Second", "<C-CR>", "Third", "<C-j>", "Fourth", "<Esc>")
    settle()
    MiniTest.expect.equality(composer_config().height, 4)
    child.type_keys("q")
    child.lua("composer.open(78,80,'hunk')")
    settle()
    local eof_config = composer_config()
    local eof_end = child.lua_get("vim.fn.screenpos(source_win,80,9).row")
    MiniTest.expect.equality(content_origin() + eof_config.row, eof_end + 3)
    child.type_keys("<Esc>", "q")
end

T["reservation stays out of another window displaying the same buffer"] = function()
    child.cmd("vsplit")
    child.lua([[other_win = source_win
        source_win = vim.api.nvim_get_current_win()
        before.view = vim.fn.winsaveview()
        composer.open(8,8,'hunk')]])
    settle()
    assert_reserved(8, 8) -- Metadata may wrap in a narrow split; measure actual room.
    MiniTest.expect.equality(displayed(9, "other_win") - displayed(8, "other_win"), 1)
    child.type_keys("Hunk note", "<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.scope"), "hunk")
    source_unchanged()
end

T["folds open for composition and source scrolling closes without losing the draft"] = function()
    child.cmd("5,12fold")
    child.lua("composer.open(5,12,'range')")
    assert_reserved(5, 12)
    child.type_keys("Folded target", "<Esc>")
    child.lua([[vim.api.nvim_win_call(source_win, function()
        vim.cmd('execute "normal! 2\\<C-e>"')
    end)]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua("vim.api.nvim_set_current_win(source_win); composer.resume()")
    settle()
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Folded target" })
    source_unchanged()
end

T["window closure and buffer switches clean up reservations and keep drafts"] = function()
    child.lua("composer.open(8,8,'line')")
    child.type_keys("Retain me", "<Esc>")
    child.lua("vim.api.nvim_win_close(vim.api.nvim_get_current_win(), true)")
    settle()
    MiniTest.expect.equality(displayed(9) - displayed(8), 1)
    child.lua("composer.resume()")
    child.type_keys("<Esc>")
    child.lua([[replacement = vim.api.nvim_create_buf(true,false)
        vim.api.nvim_win_set_buf(source_win, replacement)]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua(
        "vim.api.nvim_win_set_buf(source_win, source_buf); vim.api.nvim_set_current_win(source_win); composer.resume()"
    )
    settle()
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Retain me" })
    source_unchanged()
end

T["leaving the composer retains the draft without taking focus back"] = function()
    child.cmd("vsplit")
    child.lua([[other_win = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(source_win)
        composer.open(8,8,'line')]])
    child.type_keys("Focus changed", "<Esc>")
    child.lua("vim.api.nvim_set_current_win(other_win)")
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_get_current_win() == other_win"), true)
    child.lua("vim.api.nvim_set_current_win(source_win); composer.resume()")
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Focus changed" })
    source_unchanged()
end

T["resizing closes the composer and retains its unfinished draft"] = function()
    child.lua("composer.open(8,8,'line')")
    child.type_keys("Resize draft")
    child.o.columns = 60
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.o.lines = 8
    child.api.nvim_exec_autocmds("VimResized", {})
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "n")
    child.o.lines = 30
    child.lua("composer.resume()")
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Resize draft" })
    source_unchanged()
end

T["existing virtual diff text is never covered by the composer"] = function()
    child.lua([[diff_ns = vim.api.nvim_create_namespace('external.diff')
        vim.api.nvim_buf_set_extmark(source_buf,diff_ns,7,0,{
            virt_lines = { { { 'DELETED CODE', 'Normal' } } }
        })
        composer.open(8,8,'line')]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    local screen = child.get_screenshot()
    MiniTest.expect.equality(
        table.concat(screen.text[9]):find("DELETED CODE", 1, true) ~= nil,
        true
    )
    child.lua(
        "vim.api.nvim_buf_clear_namespace(source_buf,diff_ns,0,-1); composer.open(8,8,'line')"
    )
    child.type_keys("Resumed without hiding the diff", "<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.first"), 8)
    source_unchanged()
end

T["dirty source remains dirty and stale drafts are retained instead of silently retargeting"] = function()
    child.type_keys("A", " unsaved", "<Esc>")
    child.lua([[before.lines = vim.api.nvim_buf_get_lines(source_buf,0,-1,false)
        before.modified = vim.bo[source_buf].modified
        before.tick = vim.api.nvim_buf_get_changedtick(source_buf)
        before.undo = vim.fn.undotree()
        composer.open(8,8,'line')]])
    child.type_keys("Locked draft", "<Esc>")
    source_unchanged()
    child.lua([[vim.api.nvim_buf_set_lines(source_buf,7,8,false,{'Different target'})]])
    settle()
    child.lua("composer.resume()")
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 0)
    child.lua([[vim.api.nvim_buf_set_lines(source_buf,7,8,false,{'SOURCE-08 unsaved'})
        composer.resume()]])
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Locked draft" })
end

T["closing a fold closes the composer and retains its locked draft"] = function()
    child.cmd("5,12fold")
    child.lua("composer.open(5,12,'range')")
    child.type_keys("Fold closure draft", "<Esc>")
    child.lua([[vim.api.nvim_win_call(source_win, function()
        vim.cmd('normal! zc')
    end)]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.cmd("normal! zv")
    child.lua("composer.resume()")
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Fold closure draft" })
    source_unchanged()
end

T["truncating past an active target closes safely and retains its original draft"] = function()
    child.lua("composer.open(78,80,'range')")
    child.type_keys("Truncated target draft", "<Esc>")
    child.lua([[
        vim.v.errmsg = ''
        vim.api.nvim_buf_set_lines(source_buf, 10, -1, false, {})
    ]])
    settle()
    MiniTest.expect.equality(child.lua_get("vim.v.errmsg"), "")
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua("composer.resume()")
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua([[
        vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, before.lines)
        composer.resume()
    ]])
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.first"), 78)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.last"), 80)
    MiniTest.expect.equality(
        child.lua_get("composer.comments[1].lines"),
        { "Truncated target draft" }
    )
end

T["background source edits and virtual lines close rather than realign the composer"] = function()
    child.lua("composer.open(8,8,'line')")
    child.type_keys("Background draft", "<Esc>")
    child.lua([[vim.api.nvim_buf_set_lines(source_buf,1,2,false,{string.rep('wrapped ',26)})]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua("composer.resume()")
    child.type_keys("<Esc>")
    child.lua([[diff_ns = vim.api.nvim_create_namespace('external.diff')
        vim.api.nvim_buf_set_extmark(source_buf,diff_ns,7,0,{
            virt_lines = { { { 'CODE ABOVE', 'Normal' } } }, virt_lines_above = true,
        })]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua("composer.resume()")
    child.type_keys("<Esc>")
    child.lua([[vim.api.nvim_buf_set_extmark(source_buf,diff_ns,7,0,{
            virt_lines = { { { 'CODE BELOW', 'Normal' } } },
        })]])
    settle()
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua("vim.api.nvim_buf_clear_namespace(source_buf,diff_ns,0,-1); composer.resume()")
    child.type_keys("<Esc>", "<CR>")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Background draft" })
end

return T
