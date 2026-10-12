local MiniTest = _G.MiniTest or require("mini.test")
local child = MiniTest.new_child_neovim()
local root
local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            root = vim.fn.tempname()
            vim.fn.mkdir(root, "p")
            child.restart({ "-u", "NONE" })
            child.lua([[
                vim.opt.runtimepath:append(vim.fn.getcwd())
                vim.o.lines, vim.o.columns = 32, 100
                vim.g.mapleader = ';'
                review = require('parley.review')
                composer = require('parley.composer')
                vim.cmd('runtime plugin/parley.lua')
            ]])
        end,
        post_case = function() vim.fn.delete(root, "rf") end,
        post_once = child.stop,
    },
})

local function run(args)
    local out = vim.system(args, { cwd = root, text = true }):wait()
    assert(out.code == 0, out.stderr)
    return out.stdout
end

local function write(name, lines) vim.fn.writefile(lines, vim.fs.joinpath(root, name)) end

local function commit()
    run({ "git", "add", "-A" })
    run({
        "git",
        "-c",
        "user.name=Test",
        "-c",
        "user.email=test@example.invalid",
        "commit",
        "-qm",
        "base",
    })
end

local function start(name)
    child.lua(
        [[
        local root, name = ...
        vim.api.nvim_set_current_dir(root)
        vim.cmd.edit(vim.fn.fnameescape(root .. '/' .. name))
        original_buf = vim.api.nvim_get_current_buf()
        original_win = vim.api.nvim_get_current_win()
        original_windows = #vim.api.nvim_tabpage_list_wins(0)
        original_width = vim.api.nvim_win_get_width(0)
        vim.wo.winbar = 'Original'
        vim.api.nvim_win_set_cursor(0, { 2, 0 })
        original_view = vim.fn.winsaveview()
        original_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
        original_tick = vim.api.nvim_buf_get_changedtick(0)
        original_undo = vim.fn.undotree()
        vim.keymap.set('n', 'c', function() restored = true end, { buffer = true })
        review.start()
        assert(vim.wait(5000, function() return review.status:find('Review ', 1, true) ~= nil end, 10),
            vim.api.nvim_exec2('messages', {output = true}).output)
    ]],
        { root, name }
    )
end

local function progress(index, total, remaining)
    local status = child.lua_get("review.status")
    MiniTest.expect.equality(
        status:find(("Review %d/%d"):format(index, total), 1, true) ~= nil,
        true
    )
    MiniTest.expect.equality(status:find(remaining .. " unseen", 1, true) ~= nil, true)
end

local function screen_has(text)
    local lines = {}
    for _, row in ipairs(child.get_screenshot().text) do
        lines[#lines + 1] = table.concat(row)
    end
    return table.concat(lines, "\n"):find(text, 1, true) ~= nil
end

local function note(text)
    child.type_keys(text, "<Esc>", "<CR>")
    child.cmd("redraw!")
end

T["Git cross-file visits, old-side notes and exit preserve source and mappings"] = function()
    child.lua([[
        vim.o.columns = 180
        vim.api.nvim_set_hl(0, 'Normal', { fg = 0xcccccc, bg = 0x202020 })
        vim.api.nvim_set_hl(0, 'Comment', { fg = 0x888888 })
        vim.api.nvim_set_hl(0, 'LspInlayHint', { fg = 0x707070 })
    ]])
    run({ "git", "init", "-q" })
    local lines = {}
    for i = 1, 60 do
        lines[i] = "local value_" .. i .. " = " .. i
    end
    lines[4] = "        " .. lines[4]
    write("a.lua", lines)
    write("b.lua", { "local removed = true", "return removed" })
    write("c.lua", { "local staged = false", "return staged" })
    commit()
    lines[4], lines[50] = "        local value_4 = false", "local value_50 = false"
    write("a.lua", lines)
    vim.fn.delete(vim.fs.joinpath(root, "b.lua"))
    write("c.lua", { "local staged = true", "return staged" })
    run({ "git", "add", "c.lua" })
    write("d.lua", { "local untracked = true", "return untracked" })
    start("a.lua")
    progress(1, 5, 4)
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 4)
    child.type_keys("C")
    note("Hunk note")
    MiniTest.expect.equality(child.lua_get("vim.wo[original_win].winbar"), "Original")
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_get_current_win() == original_win"), true)
    local first = child.lua_get("vim.fn.screenpos(original_win, 4, 1).row")
    local following = child.lua_get("vim.fn.screenpos(original_win, 5, 1).row")
    local screen, displayed = child.get_screenshot(), {}
    local left = child.lua_get("vim.api.nvim_win_get_position(original_win)[2]")
    local width = child.lua_get("vim.api.nvim_win_get_width(original_win)")
    local note_row, note_column
    for row = first + 1, following - 1 do
        local text = table.concat(screen.text[row], "", left + 1, left + width)
        displayed[#displayed + 1] = text
        local column = text:find("Hunk note", 1, true)
        if column then
            note_row, note_column = row, left + column
        end
    end
    MiniTest.expect.equality(note_row ~= nil, true)
    local area = table.concat(displayed, "\n")
    for _, border in ipairs({ "╭", "╮", "╰", "╯", "│", "─" }) do
        MiniTest.expect.equality(area:find(border, 1, true), nil)
    end
    local source_column = child.lua_get("vim.fn.screenpos(original_win, 4, 9).col")
    MiniTest.expect.equality(note_column, source_column + 4) -- Eight spaces in code, twelve in notes.
    -- A blank top margin and a subtle, uniform area span the window, including the gutter.
    MiniTest.expect.equality(
        table.concat(screen.text[first + 1], "", left + 1, left + width),
        string.rep(" ", width)
    )
    for _, column in ipairs({ left + 1, left + width }) do
        MiniTest.expect.equality(
            child.lua_get(
                ("vim.fn.screenattr(%d, %d) == vim.fn.screenattr(%d, %d)"):format(
                    note_row,
                    column,
                    note_row,
                    note_column
                )
            ),
            true
        )
    end
    local style =
        child.lua_get("vim.api.nvim_get_hl(0, {name = 'ParleyReviewNote', link = false})")
    MiniTest.expect.equality(style.bg > 0x202020 and style.bg < 0x282828, true)
    MiniTest.expect.equality(
        style.fg
                < child.lua_get("vim.api.nvim_get_hl(0, {name = 'LspInlayHint', link = false}).fg")
            and style.fg > style.bg,
        true
    )
    MiniTest.expect.equality(style.italic, true)
    MiniTest.expect.equality(style.bold == true, false)
    local heading =
        child.lua_get("vim.api.nvim_get_hl(0, {name = 'ParleyReviewNoteHeading', link = false})")
    MiniTest.expect.equality(heading.bg, style.bg)
    MiniTest.expect.equality(heading.fg < style.fg and heading.fg > style.bg, true)
    MiniTest.expect.equality(heading.italic, true)
    MiniTest.expect.equality(heading.bold == true, false)
    -- Theme changes refresh existing notes; metadata has less contrast on light themes too.
    child.lua([[
        vim.api.nvim_set_hl(0, 'Normal', { fg = 0x202020, bg = 0xf0f0f0 })
        vim.api.nvim_set_hl(0, 'LspInlayHint', { fg = 0x909090 })
        vim.api.nvim_exec_autocmds('ColorScheme', { pattern = 'review-test-light' })
    ]])
    local light_style =
        child.lua_get("vim.api.nvim_get_hl(0, {name = 'ParleyReviewNote', link = false})")
    local light_heading =
        child.lua_get("vim.api.nvim_get_hl(0, {name = 'ParleyReviewNoteHeading', link = false})")
    MiniTest.expect.equality(light_style.fg > 0x909090 and light_style.fg < light_style.bg, true)
    MiniTest.expect.equality(light_style.bg < 0xf0f0f0 and light_style.bg > 0xe8e8e8, true)
    MiniTest.expect.equality(light_heading.bg, light_style.bg)
    MiniTest.expect.equality(
        light_heading.fg > light_style.fg and light_heading.fg < light_style.bg,
        true
    )
    MiniTest.expect.equality(light_heading.italic, true)
    MiniTest.expect.equality(
        child.lua_get(
            ("vim.fn.screenattr(%d, %d) ~= vim.fn.screenattr(%d, %d)"):format(
                note_row,
                note_column,
                first,
                source_column
            )
        ),
        true
    )
    MiniTest.expect.equality(
        child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"),
        child.lua_get("original_windows")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_win_get_width(0)"),
        child.lua_get("original_width")
    )
    child.lua("reading_view = vim.fn.winsaveview()")
    child.type_keys("<CR>", "<Esc>", "gg0Di")
    note("Edited hunk note")
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 1)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Edited hunk note" })
    MiniTest.expect.equality(child.lua_get("vim.fn.winsaveview()"), child.lua_get("reading_view"))
    child.type_keys("c") -- Line and hunk comments can share an anchor.
    note("Line detail")
    child.type_keys("<CR>", "<Esc>", "gg0Di") -- Closing composition leaves that exact note selected.
    note("Edited line detail")
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 2)
    MiniTest.expect.equality(child.lua_get("composer.comments[2].target.scope"), "line")
    MiniTest.expect.equality(child.lua_get("composer.comments[2].lines"), { "Edited line detail" })
    MiniTest.expect.equality(screen_has("Edited hunk note"), true)
    MiniTest.expect.equality(screen_has("Edited line detail"), true)
    progress(1, 5, 4)
    child.type_keys("]c")
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 50)
    child.lua("vim.api.nvim_win_set_cursor(0, { 51, 0 })")
    child.type_keys("[c", "]c")
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 51)
    child.type_keys("]c")
    progress(3, 5, 2)
    MiniTest.expect.equality(child.lua_get("vim.bo.readonly and not vim.bo.modifiable"), true)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"),
        { "local removed = true", "return removed" }
    )
    child.type_keys("v", "j", "c")
    note("Why remove this?")
    MiniTest.expect.equality(child.lua_get("composer.comments[3].target.scope"), "range")
    MiniTest.expect.equality(child.lua_get("composer.comments[3].target.review.side"), "old")
    MiniTest.expect.equality(screen_has("Lines 1–2"), true)
    MiniTest.expect.equality(screen_has("Why remove this?"), true)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.scope"), "hunk")
    progress(3, 5, 2)
    child.type_keys("]c", "]c")
    progress(5, 5, 0)
    child.type_keys("[c")
    progress(4, 5, 0)
    child.type_keys("[c", "[c", "[c") -- Revisiting never changes the seen count or queue order.
    progress(1, 5, 0)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Edited hunk note" })
    child.type_keys(";rq")
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_get_current_buf() == original_buf"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.winsaveview()"), child.lua_get("original_view"))
    MiniTest.expect.equality(child.lua_get("vim.wo.winbar"), "Original")
    MiniTest.expect.equality(
        child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"),
        child.lua_get("original_windows")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_win_get_width(0)"),
        child.lua_get("original_width")
    )
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"), lines)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(0)"),
        child.lua_get("original_tick")
    )
    MiniTest.expect.equality(child.lua_get("vim.bo.modified"), false)
    MiniTest.expect.equality(child.lua_get("vim.fn.undotree()"), child.lua_get("original_undo"))
    child.cmd("redraw!")
    MiniTest.expect.equality(
        child.lua_get(
            "vim.fn.screenpos(original_win, 5, 1).row - vim.fn.screenpos(original_win, 4, 1).row"
        ),
        1
    )
    child.type_keys("c")
    MiniTest.expect.equality(child.lua_get("restored"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.maparg(']', 'n')"), "")
    MiniTest.expect.equality(vim.fn.filereadable(vim.fs.joinpath(root, "b.lua")), 0)
    child.cmd("edit c.lua")
    MiniTest.expect.equality(child.lua_get("vim.wo.winbar"), "")
    MiniTest.expect.equality(child.lua_get("vim.fn.maparg('x', 'n')"), "")
end

T["colocated jj reviews only its current change, retains renamed and newline paths, and deleted-line content"] = function()
    run({ "git", "init", "-q" })
    run({ "jj", "git", "init", "--colocate" })
    write("a.lua", { "local keep = 1", "local remove = 2", "return keep" })
    write("old name.lua", { "local renamed = true", "return renamed" })
    run({ "jj", "commit", "-m", "previous" })
    write("a.lua", { "local keep = 1", "return keep" })
    assert(
        vim.uv.fs_rename(
            vim.fs.joinpath(root, "old name.lua"),
            vim.fs.joinpath(root, "b new\nname.lua")
        )
    )
    write("c.lua", { "local added = 3", "return added" })
    start("a.lua")
    progress(1, 3, 2)
    MiniTest.expect.equality(child.lua_get("vim.b.parley_oldside"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.getline('.')"), "local remove = 2")
    child.type_keys("c")
    note("Deleted-line note")
    child.type_keys("]c")
    progress(2, 3, 1)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_name(0)"),
        vim.fs.joinpath(root, "b new\nname.lua")
    )
    child.type_keys("]c")
    progress(3, 3, 0)
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "local added = 3")
    child.type_keys(";rq")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)"),
        { "local keep = 1", "return keep" }
    )
end

T["jj merge review uses the merged-parent baseline rather than either parent"] = function()
    run({ "jj", "git", "init" })
    local lines = {}
    for i = 1, 10 do
        lines[i] = "local value_" .. i .. " = " .. i
    end
    write("a.lua", lines)
    run({ "jj", "commit", "-m", "base" })
    local base = run({ "jj", "log", "--no-graph", "-r", "@-", "-T", "commit_id" })
    lines[1] = "local from_a = true"
    write("a.lua", lines)
    run({ "jj", "commit", "-m", "a" })
    local a = run({ "jj", "log", "--no-graph", "-r", "@-", "-T", "commit_id" })
    run({ "jj", "new", base })
    lines[1], lines[5] = "local value_1 = 1", "local from_b = true"
    write("a.lua", lines)
    run({ "jj", "commit", "-m", "b" })
    local b = run({ "jj", "log", "--no-graph", "-r", "@-", "-T", "commit_id" })
    run({ "jj", "new", a, b })
    lines[1], lines[10] = "local from_a = true", "local review_this = true"
    write("a.lua", lines)
    child.lua("vim.o.columns = 60") -- Inline review does not require room for a side pane.
    start("a.lua")
    progress(1, 1, 0)
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 10)
    child.type_keys("C")
    note("Only the merge change")
    MiniTest.expect.equality(
        child.lua_get("composer.comments[1].target.context"),
        { "local review_this = true" }
    )
    child.type_keys(";rq")
end

T["note traversal, revision navigation and confirmed deletion preserve exact targets"] = function()
    run({ "git", "init", "-q" })
    write("a.lua", { "local a = 1", "return a" })
    write("b.lua", { "local b = 1", "return b" })
    commit()
    write("a.lua", { "local a = 2", "return a" })
    write("b.lua", { "local b = 2", "return b" })
    child.cmd("edit " .. vim.fn.fnameescape(root .. "/a.lua"))
    child.lua([[
        vim.keymap.set('n', '<leader>rd', function() restored_delete = true end, { buffer = true })
        original_delete_map = vim.fn.maparg('<leader>rd', 'n', false, true)
    ]])
    start("a.lua")
    child.type_keys("C")
    note("Hunk note")
    child.type_keys("c")
    child.lua("review.delete_note()") -- Deletion is a source action, never a composer action.
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "i")
    child.lua("line_editor = vim.api.nvim_get_current_buf()")
    note("Line note")
    child.type_keys("C", "<Esc>") -- Identical targets edit instead of duplicating.
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Hunk note")
    child.type_keys("gg0Di", "Revised hunk note", "<Esc>", "q")
    child.type_keys("]c", "c", "<Esc>", "q") -- Empty new drafts disappear.
    MiniTest.expect.equality(child.lua_get("#composer.review_items(1)"), 2)
    child.type_keys("c", "File B note", "<CR>")
    child.type_keys("<C-p>") -- Across files, no editor is opened by navigation.
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_name(0)"),
        vim.fs.joinpath(root, "a.lua")
    )
    MiniTest.expect.equality(screen_has("Revised hunk note"), true)
    child.type_keys("<CR>", "<C-p>")
    -- Replacing a line is two native undo blocks: deletion, then insertion.
    child.type_keys("<C-p>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Hunk note")
    child.type_keys("<C-c>") -- Cancellation restores the latest committed revision.
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Revised hunk note" })
    MiniTest.expect.equality(child.lua_get("composer.review_items(1)[1].state"), "saved")
    child.type_keys("<C-p>", "<CR>", "<Esc>") -- Same anchor, a different exact note.
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Line note")
    child.type_keys("q")
    child.lua(
        "deletion_view = vim.fn.winsaveview(); deletion_cursor = vim.api.nvim_win_get_cursor(0)"
    )
    child.type_keys(";rd")
    MiniTest.expect.equality(screen_has("Delete note? Enter confirm · Esc/Ctrl+C cancel"), true)
    child.lua([[
        local api = vim.api
        local red = api.nvim_get_hl(0, { name = 'ParleyReviewNoteDelete', link = false })
        local heading = api.nvim_get_hl(0, { name = 'ParleyReviewNoteHeading', link = false })
        assert(red.fg == api.nvim_get_hl(0, { name = 'DiagnosticError', link = false }).fg)
        assert(red.bg == heading.bg and red.italic and not red.bold)
        local found = false
        for row = 1, vim.o.lines do
            local text = ''
            for col = 1, vim.o.columns do text = text .. vim.fn.screenstring(row, col) end
            local label = text:find('Delete note?', 1, true)
            if label then
                local hints = assert(text:find('Enter confirm', 1, true))
                assert(vim.fn.screenattr(row, label) ~= vim.fn.screenattr(row, hints))
                found = true
            end
        end
        assert(found)
    ]])
    MiniTest.expect.equality(screen_has("Line 1 · selected"), false)
    MiniTest.expect.equality(screen_has("Line note"), true)
    MiniTest.expect.equality(screen_has("Revised hunk note"), true)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_get_current_win()"),
        child.lua_get("original_win")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_get_current_buf()"),
        child.lua_get("original_buf")
    )
    MiniTest.expect.equality(
        child.lua_get("#vim.api.nvim_tabpage_list_wins(0)"),
        child.lua_get("original_windows")
    )
    MiniTest.expect.equality(child.lua_get("vim.fn.winsaveview()"), child.lua_get("deletion_view"))
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_win_get_cursor(0)"),
        child.lua_get("deletion_cursor")
    )
    child.type_keys("<C-c>")
    MiniTest.expect.equality(screen_has("Delete note?"), false)
    MiniTest.expect.equality(screen_has("Line 1 · selected"), true)
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 3)
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "n")
    child.type_keys(";rd", "<C-n>") -- A same-anchor selection change cancels the original identity.
    MiniTest.expect.equality(screen_has("Delete note?"), false)
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 3)
    child.type_keys("<C-p>", ";rd", "<CR>")
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 2)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Revised hunk note" })
    MiniTest.expect.equality(child.lua_get("composer.comments[2].lines"), { "File B note" })
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "n")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(0,0,-1,false)"),
        child.lua_get("original_lines")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(0)"),
        child.lua_get("original_tick")
    )
    -- Focus changes may synchronize an undo block, but must not change its history.
    MiniTest.expect.equality(
        child.lua_get(
            "(function() local u = vim.fn.undotree(); return { u.seq_cur, u.seq_last, u.entries } end)()"
        ),
        child.lua_get("{ original_undo.seq_cur, original_undo.seq_last, original_undo.entries }")
    )
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_buf_is_valid(line_editor)"), false)
    child.type_keys("c", "<C-n>") -- The same target cannot recover a deleted note's history.
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "")
    child.type_keys("<C-c>", "<C-n>", "<C-n>")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_name(0)"),
        vim.fs.joinpath(root, "b.lua")
    )
    child.type_keys(";rd", "<CR>")
    MiniTest.expect.equality(child.lua_get("#composer.review_items(1)"), 1)
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "n")
    child.type_keys(";rq")
    MiniTest.expect.equality(
        child.lua_get(
            "vim.deep_equal(vim.fn.maparg('<leader>rd', 'n', false, true), original_delete_map)"
        ),
        true
    )
    child.type_keys(";rd")
    MiniTest.expect.equality(child.lua_get("restored_delete"), true)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(0,0,-1,false)"),
        child.lua_get("original_lines")
    )
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(0)"),
        child.lua_get("original_tick")
    )
    MiniTest.expect.equality(
        child.lua_get(
            "(function() local u = vim.fn.undotree(); return { u.seq_cur, u.seq_last, u.entries } end)()"
        ),
        child.lua_get("{ original_undo.seq_cur, original_undo.seq_last, original_undo.entries }")
    )
    MiniTest.expect.equality(child.lua_get("vim.fn.maparg('<C-n>', 'n')"), "")
    MiniTest.expect.equality(child.lua_get("vim.fn.maparg('<C-p>', 'n')"), "")
    MiniTest.expect.equality(
        child.lua_get(
            "vim.fn.exists(':ReviewCompose') + vim.fn.exists(':ReviewNotes') + vim.fn.exists(':ReviewPieces')"
        ),
        0
    )
end

T["a delayed overlapping-note picker cannot reopen a deleted note"] = function()
    run({ "git", "init", "-q" })
    write("a.lua", { "local a = 1", "return a" })
    commit()
    write("a.lua", { "local a = 2", "return a" })
    start("a.lua")
    child.type_keys("C")
    note("Keep the hunk note")
    child.type_keys("c")
    note("Delete the line note")
    child.lua([[
        -- Control asynchronous completion at the user-interface boundary.
        vim.ui.select = function(items, _, callback)
            pending_choice, complete_picker = items[2], callback
        end
    ]])
    child.type_keys("j", "k", "<CR>") -- Clear exact selection and open the overlap picker.
    MiniTest.expect.equality(
        child.lua_get("pending_choice.note.lines"),
        { "Delete the line note" }
    )
    child.type_keys("<C-n>", ";rd", "<CR>") -- Delete that note while selection is pending.
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 1)
    child.lua("complete_picker(pending_choice)")
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(child.lua_get("#composer.review_items(1)"), 1)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Keep the hunk note" })
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_get_current_win() == original_win"), true)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(original_buf)"),
        child.lua_get("original_tick")
    )
end

T["inline deletion cancels on departure and restores temporary source mappings"] = function()
    run({ "git", "init", "-q" })
    write("a.lua", { "local a = 1", "return a" })
    commit()
    write("a.lua", { "local a = 2", "return a" })
    start("a.lua")
    child.type_keys("c")
    note("Keep this note")
    child.lua([[
        vim.keymap.set('n', '<Esc>', function() restored_escape = true end, { buffer = true })
        vim.keymap.set('n', '<C-c>', function() restored_cancel = true end, { buffer = true })
        escape_map = vim.fn.maparg('<Esc>', 'n', false, true)
        cancel_map = vim.fn.maparg('<C-c>', 'n', false, true)
    ]])
    local function begin_deletion()
        child.type_keys(";rd")
        MiniTest.expect.equality(screen_has("Delete note?"), true)
    end
    local function cancelled()
        child.cmd("redraw!")
        MiniTest.expect.equality(screen_has("Delete note?"), false)
        MiniTest.expect.equality(child.lua_get("#composer.comments"), 1)
        MiniTest.expect.equality(
            child.lua_get("vim.deep_equal(vim.fn.maparg('<Esc>', 'n', false, true), escape_map)"),
            true
        )
        MiniTest.expect.equality(
            child.lua_get("vim.deep_equal(vim.fn.maparg('<C-c>', 'n', false, true), cancel_map)"),
            true
        )
    end
    begin_deletion()
    child.type_keys("<Esc>")
    cancelled()
    child.type_keys("<Esc>", "<C-c>")
    MiniTest.expect.equality(child.lua_get("restored_escape and restored_cancel"), true)
    begin_deletion()
    child.type_keys("j") -- Ordinary source movement cancels, not a dialog choice.
    cancelled()
    child.type_keys("k", "<C-n>")
    begin_deletion()
    child.cmd("vsplit")
    child.cmd("close")
    cancelled()
    begin_deletion()
    child.cmd("enew") -- Same window, different buffer.
    child.cmd("buffer " .. child.lua_get("original_buf"))
    cancelled()
    begin_deletion()
    child.type_keys("v", "<Esc>") -- Leaving Normal mode also cancels.
    cancelled()
    begin_deletion()
    child.type_keys("]c") -- Exhausted navigation must not leave a live prompt.
    cancelled()
    begin_deletion()
    child.lua("review.stop()")
    cancelled()
    MiniTest.expect.equality(child.lua_get("review.status"), "")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_get_current_win()"),
        child.lua_get("original_win")
    )
    MiniTest.expect.equality(child.lua_get("vim.fn.mode()"), "n")
    MiniTest.expect.equality(child.lua_get("vim.fn.winsaveview()"), child.lua_get("original_view"))
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(0)"),
        child.lua_get("original_tick")
    )
end

T["inline deletion revalidates frozen source before Enter even before change events"] = function()
    run({ "git", "init", "-q" })
    write("a.lua", { "local a = 1", "return a" })
    commit()
    write("a.lua", { "local a = 2", "return a" })
    start("a.lua")
    child.type_keys("c")
    note("Retain original context")
    child.type_keys(";rd")
    child.lua([[
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'local a = 3' })
        review.edit_note()
    ]])
    MiniTest.expect.equality(child.lua_get("#composer.comments"), 1)
    MiniTest.expect.equality(
        child.lua_get("composer.comments[1].lines"),
        { "Retain original context" }
    )
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    MiniTest.expect.equality(screen_has("Delete note?"), false)
    MiniTest.expect.equality(child.lua_get("vim.fn.maparg('<Esc>', 'n')"), "")
    MiniTest.expect.equality(child.lua_get("vim.fn.maparg('<C-c>', 'n')"), "")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "local a = 3")
end

T["explicit comparison reveal keeps its excerpt and source anchor visible at viewport edges"] = function()
    run({ "git", "init", "-q" })
    local lines = {}
    for i = 1, 80 do
        lines[i] = "local value_" .. i .. " = " .. i
    end
    write("a.lua", lines)
    commit()
    for i = 30, 70 do
        lines[i] = "local value_" .. i .. " = false"
    end
    write("a.lua", lines)
    start("a.lua")
    child.type_keys("30G", "zt", " ")
    MiniTest.expect.equality(screen_has("--- BEFORE"), true)
    MiniTest.expect.equality(screen_has("+++ AFTER"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 30)
    MiniTest.expect.equality(child.lua_get("vim.fn.screenpos(original_win,30,1).row > 0"), true)
    child.type_keys(" ", "70G", "zb", " ")
    MiniTest.expect.equality(screen_has("--- BEFORE"), true)
    MiniTest.expect.equality(screen_has("+++ AFTER"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 70)
    MiniTest.expect.equality(child.lua_get("vim.fn.screenpos(original_win,70,1).row > 0"), true)
    child.type_keys(" ", "c", "Edge note", "<Esc>", " ")
    MiniTest.expect.equality(screen_has("--- BEFORE"), true)
    MiniTest.expect.equality(screen_has("+++ AFTER"), true)
    MiniTest.expect.equality(screen_has("Edge note"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Edge note")
    child.type_keys("q", " ", "30G", "C")
    note("Long target")
    child.type_keys("zt", " ") -- Focus the whole selected target, but anchor at the cursor.
    MiniTest.expect.equality(screen_has("--- BEFORE"), true)
    MiniTest.expect.equality(screen_has("+++ AFTER"), true)
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 30)
    MiniTest.expect.equality(child.lua_get("vim.fn.screenpos(original_win,30,1).row > 0"), true)
    child.type_keys(";rq")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(0)"),
        child.lua_get("original_tick")
    )
end

T["manual movement targets comments at the cursor without changing queue order"] = function()
    run({ "git", "init", "-q" })
    local lines = {}
    for i = 1, 60 do
        lines[i] = "local value_" .. i .. " = " .. i
    end
    write("a.lua", lines)
    commit()
    lines[4] = "local value_4 = false"
    lines[40], lines[41] = "local value_40 = false", "local value_41 = false"
    write("a.lua", lines)
    start("a.lua")
    child.type_keys("40G", "c")
    note("Cursor line")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.first"), 40)
    MiniTest.expect.equality(child.lua_get("composer.comments[1].target.review.piece"), 2)
    progress(1, 2, 0)
    child.type_keys("C")
    note("Cursor hunk")
    MiniTest.expect.equality(child.lua_get("composer.comments[2].target.first"), 40)
    MiniTest.expect.equality(child.lua_get("composer.comments[2].target.last"), 41)
    child.type_keys("40G", "v", "j", "c")
    note("Cursor range")
    MiniTest.expect.equality(child.lua_get("composer.comments[3].target.scope"), "range")
    MiniTest.expect.equality(child.lua_get("composer.comments[3].target.review.piece"), 2)
    child.type_keys("4G", "C")
    note("Queue hunk")
    MiniTest.expect.equality(child.lua_get("composer.comments[4].target.first"), 4)
    child.type_keys("]c")
    progress(2, 2, 0)
    MiniTest.expect.equality(child.lua_get("vim.fn.line('.')"), 40)
    child.type_keys("[c", ";rq")
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_buf_get_lines(0,0,-1,false)"), lines)
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_changedtick(0)"),
        child.lua_get("original_tick")
    )
end

T["source edits never retarget the frozen queue or its drafts"] = function()
    run({ "git", "init", "-q" })
    write("a.lua", { "local a = 1", "return a" })
    commit()
    write("a.lua", { "local a = 2", "return a" })
    start("a.lua")
    child.type_keys(" ", "c")
    child.type_keys("Locked draft", "<Esc>", "q")
    child.cmd("redraw!")
    MiniTest.expect.equality(screen_has("Locked draft"), true)
    child.type_keys("<CR>", "<Esc>")
    MiniTest.expect.equality(child.lua_get("vim.fn.getline(1)"), "Locked draft")
    child.type_keys("q") -- The inline draft can be reopened without another targeting step.
    child.lua("vim.api.nvim_buf_set_lines(0, 0, 0, false, {'-- new line'})")
    child.type_keys("C")
    progress(1, 1, 0)
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.cmd("redraw!")
    MiniTest.expect.equality(screen_has("Locked draft"), false)
    MiniTest.expect.equality(screen_has("BEFORE"), false)
    child.cmd("ReviewStop")
    MiniTest.expect.equality(child.lua_get("vim.bo.modified"), true)
    child.lua("composer.edit(composer.comments[1])")
    MiniTest.expect.equality(child.lua_get("composer.current_item() == nil"), true)
    child.lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, {})")
    child.lua("composer.edit(composer.comments[1])")
    note("")
    MiniTest.expect.equality(child.lua_get("composer.comments[1].lines"), { "Locked draft" })
end

return T
