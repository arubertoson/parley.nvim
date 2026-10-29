local MiniTest = _G.MiniTest or require("mini.test")
local child = MiniTest.new_child_neovim()
local root
local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            root = vim.fn.tempname()
            vim.fn.mkdir(root, "p")
            child.restart({ "-u", "NONE" })
            child.lua(
                [[
                vim.opt.runtimepath:append(vim.fn.getcwd())
                workspace = require('parley.workspace')
                conversation = require('parley.conversation')
                root = ...
                vim.o.lines, vim.o.columns = 32, 100
                vim.fn.writefile({ 'first source line', 'second source line', 'tail' }, root .. '/source.lua')
                vim.cmd.edit(root .. '/source.lua')
                binding = { workspace = root, sessionId = 'parent', editorId = 'editor' }
                source_buf, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
                assert(workspace.activate(binding))

                function capture(id, kind)
                    return assert(workspace.capture_request({
                        id = id, kind = kind, editor_id = 'editor', author = 'Reviewer',
                        instructions = kind == 'investigate' and 'Look for missing error handling' or nil,
                    }))
                end
                function accept(value)
                    local record = vim.tbl_extend('force', value.request, { type = 'request' })
                    assert(workspace.accept_request(value, record))
                end
                function import_finding(path, first, lines)
                    local request = capture('navigate-finding', 'investigate')
                    accept(request)
                    return assert(workspace.import_results(request, {{
                        id = 'finding', new = true, baseVersion = 0, baseTipId = vim.NIL,
                        anchor = { path = path, side = 'workspace', first = first, last = first + #lines - 1,
                            lines = lines, observedAt = 1, source = { kind = 'disk' } },
                        messages = {{ id = 'finding-message', parentId = vim.NIL, version = 1,
                            role = 'agent', author = 'Agent', origin = 'review', createdAt = 2,
                            lines = { 'Check this finding' } }},
                    }}))
                end
            ]],
                { root }
            )
        end,
        post_case = function()
            child.lua("require('parley.workspace').stop()")
            vim.fn.delete(root, "rf")
        end,
        post_once = child.stop,
    },
})

T["Ask captures all conversations; acceptance and replies preserve later edits and reject stale history"] = function()
    child.lua([[
        a = assert(workspace.add_conversation({ id = 'a', lines = { 'Question A' } }, 1, 1))
        b = assert(workspace.add_conversation({ id = 'b', lines = { 'Question B' } }, 2, 2))
        request = capture('ask-1', 'ask')
        assert(#request.request.submissions == 2 and #request.messages == 2)
        assert(#a.thread.messages == 0 and #b.thread.messages == 0)
        vim.api.nvim_buf_set_lines(a.note.buffer, 0, -1, false, { 'Later unsent edit' })
        accept(request)
        assert(a.thread.messages[1].lines[1] == 'Question A')
        assert(b.thread.messages[1].lines[1] == 'Question B')
        assert(not workspace.accept_request(request, vim.tbl_extend('force', request.request, { type = 'request' })))

        -- A conflicting local history must not retarget B's incoming reply.
        assert(conversation.receive_batch(b, {{
            id = 'other-reply', parent_id = b.thread.messages[1].id, role = 'agent',
            author = 'Agent', origin = 'other', created_at = 1, lines = { 'Other reply' },
        }}, 1, b.thread.messages[1].id))
        groups = {}
        for index, submitted in ipairs(request.request.submissions) do
            groups[index] = {
                id = submitted.conversationId, anchor = request.conversations[index].anchor, new = false,
                baseVersion = submitted.version, baseTipId = submitted.tipId,
                messages = {{ id = 'reply-' .. index, parentId = submitted.tipId, version = 2,
                    role = 'agent', author = 'Agent', origin = 'review', createdAt = 2, lines = { 'Answer' } }},
            }
        end
        before = { window = vim.api.nvim_get_current_win(), view = vim.fn.winsaveview(),
            undo = vim.api.nvim_buf_call(a.note.buffer, vim.fn.undotree),
            source = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false) }
        receipts = assert(workspace.import_results(request, groups))
        assert(receipts[1].status == 'applied' and receipts[2].status == 'incompatible')
        assert(a.thread.messages[2].id == 'reply-1' and b.thread.messages[2].id == 'other-reply')
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(a.note.buffer, 0, -1, false), { 'Later unsent edit' }))
        assert(vim.deep_equal(vim.api.nvim_buf_call(a.note.buffer, vim.fn.undotree), before.undo))
        assert(vim.api.nvim_get_current_win() == before.window and vim.deep_equal(vim.fn.winsaveview(), before.view))
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), before.source))
        assert(not workspace.import_results(request, groups))
        assert(#a.thread.messages == 2)
    ]])
end

T["selected history previews expand beyond the compact source-card limit"] = function()
    child.lua([[
        vim.o.lines = 40
        local data = assert(workspace.add_conversation({ id = 'expanded', lines = { 'Question' } }, 1, 1))
        local request = capture('expand-history', 'ask')
        accept(request)
        local lines = {}
        for index = 1, 12 do lines[index] = 'Response line ' .. index end
        assert(conversation.receive_batch(data, {{
            id = 'long-answer', parent_id = data.thread.messages[1].id, version = 2,
            role = 'agent', author = 'Agent', origin = 'review', created_at = 1, lines = lines,
        }}, 1, data.thread.messages[1].id))
        workspace.move_note(1)
        local rendered = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source_buf, -1, 0, -1, { details = true })) do
            for _, line in ipairs(mark[4].virt_lines or {}) do
                for _, chunk in ipairs(line) do rendered[#rendered + 1] = chunk[1] end
            end
        end
        local text = table.concat(rendered, '\n')
        assert(text:find('Response line 12', 1, true), text)
        assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_list_wins() == 1)
    ]])
end

T["Investigate needs no comments and retains unloaded findings without opening their files"] = function()
    child.lua([[
        empty = capture('investigate-empty', 'investigate')
        assert(#empty.messages == 0 and #empty.request.submissions == 0)
        accept(empty)
        assert(vim.deep_equal(assert(workspace.import_results(empty, {})), {}))

        vim.fn.writefile({ 'not loaded' }, root .. '/unloaded.lua')
        request = capture('investigate-finding', 'investigate')
        accept(request)
        before_buf, before_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
        receipts = assert(workspace.import_results(request, {{
            id = 'finding', new = true, baseVersion = 0, baseTipId = vim.NIL,
            anchor = { path = 'unloaded.lua', side = 'workspace', first = 1, last = 1,
                lines = { 'not loaded' }, observedAt = 1, source = { kind = 'disk' } },
            messages = {{ id = 'finding-message', parentId = vim.NIL, version = 1,
                role = 'agent', author = 'Agent', origin = 'review', createdAt = 2, lines = { 'Check this' } }},
        }}))
        assert(receipts[1].status == 'applied' and receipts[1].placement == 'unplaced')
        assert(vim.fn.bufnr(root .. '/unloaded.lua') == -1)
        assert(vim.api.nvim_get_current_buf() == before_buf and vim.api.nvim_get_current_win() == before_win)
        assert(workspace.status:find('1 notes', 1, true))
    ]])
end

T["explicit navigation opens and reopens an unloaded finding and cycles across files"] = function()
    child.lua([[
        local local_note = assert(workspace.add_conversation({ id = 'local-note' }, 1, 1))
        local path = root .. '/z finding.lua'
        vim.fn.writefile({ 'header', 'finding source', 'tail' }, path)
        local receipts = import_finding('z finding.lua', 2, { 'finding source' })
        assert(receipts[1].placement == 'unplaced')
        assert(vim.fn.bufnr(path) == -1)
        assert(vim.api.nvim_get_current_buf() == source_buf)

        require('parley').move_note(1)
        finding_buf = vim.api.nvim_get_current_buf()
        assert(vim.api.nvim_buf_get_name(finding_buf) == path)
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(vim.api.nvim_win_get_cursor(source_win)[1] == 2)
        assert(workspace.status:find('z finding.lua:2', 1, true))
        assert(not workspace.status:find('unplaced', 1, true))
        workspace.edit_note()
        assert(vim.api.nvim_get_current_win() ~= source_win)
        assert(vim.api.nvim_get_current_line() == 'Check this finding')
    ]])
    child.type_keys("q", "<C-n>")
    child.lua([[
        assert(vim.api.nvim_get_current_buf() == source_buf)
        assert(vim.api.nvim_win_get_cursor(source_win)[1] == 1)
    ]])
    child.type_keys("<C-p>")
    child.lua([[
        assert(vim.api.nvim_get_current_buf() == finding_buf)
        assert(vim.api.nvim_win_get_cursor(source_win)[1] == 2)
        workspace.move_note(1)
        vim.cmd.bunload(tostring(finding_buf))
        assert(not vim.api.nvim_buf_is_loaded(finding_buf))
        workspace.move_note(-1)
        assert(vim.api.nvim_buf_get_name(0) == root .. '/z finding.lua')
        assert(vim.api.nvim_win_get_cursor(source_win)[1] == 2)
        assert(not workspace.status:find('unplaced', 1, true))
        workspace.move_note(1)
        vim.cmd.bwipeout(tostring(finding_buf))
        assert(not vim.api.nvim_buf_is_valid(finding_buf))
        workspace.move_note(-1)
        assert(vim.api.nvim_buf_get_name(0) == root .. '/z finding.lua')
        assert(vim.api.nvim_win_get_cursor(source_win)[1] == 2)
        assert(not workspace.status:find('unplaced', 1, true))
    ]])
end

for _, changed in ipairs({ "disk", "unsaved buffer" }) do
    T["navigation opens a finding with changed " .. changed .. " without guessing its range"] = function()
        child.lua(
            [[
            local changed = ...
            local path = root .. '/finding.lua'
            vim.fn.writefile({ 'header', 'original source', 'tail' }, path)
            assert(import_finding('finding.lua', 2, { 'original source' })[1].placement == 'unplaced')
            if changed == 'disk' then
                vim.fn.writefile({ 'header', 'different source', 'tail' }, path)
            else
                vim.o.hidden = true
                vim.cmd.edit(path)
                -- Loading the original source places it; edits then invalidate
                -- the range without permission to relocate the observation.
                vim.api.nvim_buf_set_lines(0, 1, 2, false, { 'different source' })
                vim.api.nvim_win_set_cursor(0, { 1, 0 })
                vim.cmd.buffer(source_buf)
            end
            local notices = {}
            vim.notify = function(message) notices[#notices + 1] = message end
            workspace.move_note(1)
            assert(vim.api.nvim_buf_get_name(0) == path)
            assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
            assert(vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == 'different source')
            assert(workspace.status:find('finding.lua:2', 1, true))
            assert(workspace.status:find('unplaced', 1, true))
            assert(notices[#notices]:find('unplaced', 1, true))
            workspace.edit_note()
            assert(#vim.api.nvim_list_wins() == 1)
            assert(vim.bo.modified == (changed == 'unsaved buffer'))
        ]],
            { changed }
        )
    end
end

T["navigation never forces abandonment of a modified source buffer"] = function()
    child.lua([[
        vim.fn.writefile({ 'header', 'finding source' }, root .. '/finding.lua')
        import_finding('finding.lua', 2, { 'finding source' })
        vim.o.hidden, vim.o.autowrite, vim.o.autowriteall = false, false, false
        vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { 'unsaved source' })
        local notices = {}
        vim.notify = function(message) notices[#notices + 1] = message end
        workspace.move_note(1)
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(vim.api.nvim_get_current_buf() == source_buf)
        assert(vim.bo.modified)
        assert(vim.api.nvim_buf_get_lines(source_buf, 0, 1, false)[1] == 'unsaved source')
        assert(workspace.status == 'Workspace review · 1 notes')
        assert(#notices == 1 and notices[1]:find('E37', 1, true))
    ]])
end

T["navigation respects focus taken by a source-loading hook"] = function()
    child.lua([[
        local path = root .. '/finding.lua'
        vim.fn.writefile({ 'header', 'finding source' }, path)
        import_finding('finding.lua', 2, { 'finding source' })
        vim.api.nvim_create_autocmd('BufEnter', {
            pattern = path, once = true,
            callback = function()
                vim.cmd.vsplit(root .. '/source.lua')
                vim.api.nvim_win_set_cursor(0, { 3, 0 })
            end,
        })
        vim.notify = function() end
        workspace.move_note(1)
        assert(vim.api.nvim_get_current_win() ~= source_win)
        assert(vim.api.nvim_get_current_buf() == source_buf)
        assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
        assert(workspace.status == 'Workspace review · 1 notes')
    ]])
end

T["source-loading hooks cannot navigate an old note into a newly selected review"] = function()
    child.lua([[
        assert(workspace.select_review('original-review'))
        local path = root .. '/finding.lua'
        vim.fn.writefile({ 'header', 'finding source' }, path)
        import_finding('finding.lua', 2, { 'finding source' })
        vim.api.nvim_create_autocmd('BufEnter', {
            pattern = path, once = true,
            callback = function()
                workspace.allow_review_selection()
                assert(workspace.select_review('replacement-review'))
            end,
        })
        workspace.move_note(1)
        assert(workspace.review_id() == 'replacement-review')
        assert(workspace.status == 'Workspace review · 0 notes')
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(vim.api.nvim_buf_get_name(0) == path)
        assert(vim.api.nvim_win_get_cursor(0)[1] == 1)
    ]])
end

T["local save, close and workspace detach retain the same draft buffer and native undo without submitting"] = function()
    child.lua([[
        data = assert(workspace.add_conversation({ id = 'draft' }, 1, 1))
        draft_buf = data.note.buffer
        workspace.edit_note()
    ]])
    child.type_keys("Draftλ", "<Esc>", "<C-c>")
    child.lua([[
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(data.note.buffer == draft_buf and vim.api.nvim_buf_is_loaded(draft_buf))
        workspace.edit_note()
    ]])
    child.type_keys(" more", "<CR>")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false)"),
        { "Draftλ more" }
    )
    child.lua([[
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(#data.thread.messages == 0)
        undo = vim.api.nvim_buf_call(draft_buf, vim.fn.undotree)
        workspace.stop()
        assert(workspace.activate(binding))
        workspace.edit_note()
        assert(vim.api.nvim_get_current_buf() == draft_buf)
        assert(vim.deep_equal(vim.fn.undotree(), undo))
    ]])
    child.type_keys("<Esc>", "u")
    MiniTest.expect.equality(
        child.lua_get("vim.api.nvim_buf_get_lines(draft_buf, 0, -1, false)"),
        { "Draftλ" }
    )
    MiniTest.expect.equality(child.lua_get("#data.thread.messages"), 0)

    -- With history present, Enter returns to the reader; Normal q exits the thread.
    child.type_keys("<C-c>")
    child.lua([[
        accept(capture('draft-history', 'ask'))
        workspace.edit_note()
    ]])
    child.type_keys("e") -- Submitted text opens as history; editing explicitly resumes its buffer.
    child.lua("assert(vim.api.nvim_get_current_buf() == draft_buf)")
    child.type_keys("<CR>")
    child.lua([[
        assert(vim.api.nvim_get_current_win() ~= source_win)
        assert(vim.api.nvim_get_current_buf() ~= draft_buf)
    ]])
    child.type_keys("e", "<End>", " continued", "<Esc>", "q")
    child.lua([[
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(#vim.api.nvim_list_wins() == 1, vim.inspect(vim.api.nvim_list_wins()))
        assert(data.note.buffer == draft_buf and vim.api.nvim_buf_is_loaded(draft_buf), vim.inspect(data.note))
        assert(data.note.saved_lines[1] == 'Draftλ continued', vim.inspect(data.note.saved_lines))
        assert(#data.thread.messages == 1 and data.thread.messages[1].lines[1] == 'Draftλ')
        assert(conversation.receive_batch(data, {{
            id = 'draft-answer', parent_id = data.thread.messages[1].id, role = 'agent',
            author = 'Agent', origin = 'review', created_at = 1, lines = { 'Answer' },
        }}, 1, data.thread.messages[1].id))
        workspace.edit_note()
    ]])
    child.type_keys("<Esc>", "<C-p>")
    child.lua([[
        assert(vim.api.nvim_get_current_win() ~= source_win)
        assert(vim.api.nvim_get_current_buf() ~= draft_buf)
        assert(vim.api.nvim_get_current_line() == 'Answer')
        assert(vim.api.nvim_win_get_cursor(0)[1] == 3)
    ]])
    child.type_keys("gg")
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 3)
    child.type_keys("q")
    child.lua([[
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(#vim.api.nvim_list_wins() == 1)
        assert(vim.api.nvim_buf_is_loaded(draft_buf))
        assert(#data.thread.messages == 2)
    ]])
end

T["Done displays a read-only summary without submitting drafts; a fresh review cannot inherit old notes"] = function()
    child.lua([[
        assert(workspace.select_review('first-review'))
        old = assert(workspace.add_conversation({ id = 'unsent', lines = { 'Keep this draft' } }, 1, 1))
        old_buf = old.note.buffer
        old_undo = vim.api.nvim_buf_call(old_buf, vim.fn.undotree)
        old_source = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
        bridge = require('parley.bridge')
        bridge.status = function()
            return { connected = true, editor_id = 'editor', binding = { workspace = root, sessionId = 'parent', instanceId = 'instance' } }
        end
        polls, begins = 0, 0
        bridge.request = function(action, review_id, data, callback)
            assert(review_id == 'first-review')
            if action == 'review-finish-begin' then
                begins = begins + 1
                result = { reviewId = review_id, finishId = 'finish', state = 'wrapping', summary = vim.NIL,
                    artifactPath = '/outside/reviews/first-review.jsonl', error = vim.NIL, cleanupError = vim.NIL }
            elseif action == 'review-finish-status' then
                polls = polls + 1
                assert(data.finishId == 'finish')
                result = { reviewId = review_id, finishId = 'finish', state = 'completed', summary = '# Review completed\nNo fixes authorized.',
                    artifactPath = '/outside/reviews/first-review.jsonl', error = vim.NIL, cleanupError = vim.NIL }
            else error('Unexpected submission: ' .. action) end
            local response = vim.deepcopy(result)
            vim.schedule(function() callback(response) end)
        end
        vim.cmd.runtime('plugin/parley.lua')
        vim.cmd('Parley done')
        assert(vim.wait(2000, function() return require('parley').request_status().phase == 'review-completed' end))
        assert(begins == 1 and polls == 1)
        assert(vim.wait(1000, function() return vim.b.parley_summary == 'first-review' end))
        summary_buf = vim.api.nvim_get_current_buf()
        assert(summary_buf ~= source_buf and summary_buf ~= old_buf)
        assert(vim.bo.readonly and not vim.bo.modifiable)
        assert(not pcall(vim.api.nvim_buf_set_lines, summary_buf, 0, -1, false, { 'overwrite' }))
        assert(#old.thread.messages == 0)
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(old_buf, 0, -1, false), { 'Keep this draft' }))
        assert(vim.deep_equal(vim.api.nvim_buf_call(old_buf, vim.fn.undotree), old_undo))
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), old_source))
    ]])
    child.type_keys("q")
    child.lua([[
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(not workspace.select_review('second-review'))
        workspace.allow_review_selection() -- Explicit :Parley start boundary.
        assert(workspace.select_review('second-review'))
        assert(workspace.review_id() == 'second-review')
        assert(#capture('new-investigation', 'investigate').conversations == 0)
        local no_prose, failure = workspace.capture_request({ id = 'new-ask', kind = 'ask', editor_id = 'editor', author = 'Reviewer' })
        assert(not no_prose and failure:find('no new human prose', 1, true))
        assert(vim.api.nvim_buf_is_loaded(old_buf))
        workspace.allow_review_selection()
        assert(workspace.select_review('first-review'))
        assert(old.note.buffer == old_buf)
        assert(vim.deep_equal(vim.api.nvim_buf_call(old_buf, vim.fn.undotree), old_undo))
        assert(#capture('old-ask', 'ask').messages == 1)
    ]])
end

T["Parley turns capture workspace-wide unresolved prose and preserve resolved drafts and undo"] = function()
    child.lua([[
        assert(workspace.select_review('implementation', 'parley'))
        local first = assert(workspace.add_conversation({ id = 'first', lines = { 'First localized edit' } }, 1, 1))
        local resolved = assert(workspace.add_conversation({ id = 'resolved', lines = { 'Do not submit this' } }, 2, 2))
        local buffer = resolved.note.buffer
        local undo = vim.api.nvim_buf_call(buffer, vim.fn.undotree)
        local text = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
        workspace.move_note(1)
        workspace.resolve_note(true)
        assert(resolved.resolved and #resolved.thread.messages == 0)
        -- Capture does not depend on the cursor or on a source window at all.
        vim.cmd.enew()
        local request = capture('first-turn', 'ask')
        assert(#request.messages == 1 and request.messages[1].conversationId == 'first')
        accept(request)
        assert(#first.thread.messages == 1 and #resolved.thread.messages == 0)
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), text))
        assert(vim.deep_equal(vim.api.nvim_buf_call(buffer, vim.fn.undotree), undo))
        -- Reopening requires an active thread, not the remembered selection
        -- while this unrelated empty buffer has focus.
        vim.cmd.buffer(source_buf)
        vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
        workspace.edit_note()
        workspace.resolve_note(false)
        local reopened = capture('reopened-turn', 'ask')
        assert(#reopened.messages == 1 and reopened.messages[1].conversationId == 'resolved')
        assert(reopened.messages[1].lines[1] == 'Do not submit this')
        assert(#resolved.thread.messages == 0, 'Reopen/capture are not acceptance')
        assert(resolved.note.buffer == buffer)
        assert(vim.deep_equal(vim.api.nvim_buf_call(buffer, vim.fn.undotree), undo))
    ]])
end

T["workflow authority cannot change for selected or retained identities"] = function()
    child.lua([[
        assert(workspace.select_review('readonly', 'review'))
        local draft = assert(workspace.add_conversation({ id = 'draft', lines = { 'Retain me' } }, 1, 1))
        assert(not workspace.select_review('readonly', 'parley'))
        assert(workspace.workflow() == 'review')
        workspace.allow_review_selection()
        assert(workspace.select_review('implementation', 'parley'))
        workspace.allow_review_selection()
        assert(not workspace.select_review('readonly', 'parley'))
        assert(workspace.review_id() == 'implementation' and workspace.workflow() == 'parley')
        assert(workspace.select_review('readonly', 'review'))
        assert(capture('retained', 'ask').messages[1].lines[1] == 'Retain me')
        assert(vim.api.nvim_buf_is_loaded(draft.note.buffer))
    ]])
end

T["Parley capture rejects unsaved workspace sources without committing prose"] = function()
    child.lua([[
        assert(workspace.select_review('implementation', 'parley'))
        local draft = assert(workspace.add_conversation({ id = 'draft', lines = { 'Localized request' } }, 1, 1))
        vim.api.nvim_buf_set_lines(source_buf, 2, 3, false, { 'unsaved source' })
        local request, failure = workspace.capture_request({ id = 'unsafe', kind = 'ask', editor_id = 'editor', author = 'Human' })
        assert(not request and failure:find('modified workspace source', 1, true))
        assert(#draft.thread.messages == 0)
        assert(vim.api.nvim_buf_get_lines(draft.note.buffer, 0, -1, false)[1] == 'Localized request')
        vim.cmd.write()
        assert(#capture('saved', 'ask').messages == 1)
    ]])
end

for _, workflow in ipairs({ "review", "parley" }) do
    T[workflow .. ": resolve and reopen require an active selection and filter submissions"] = function()
        child.lua(
            [[
            local workflow = ...
            assert(workspace.select_review('thread-actions', workflow))
            parley = require('parley')
            vim.cmd.runtime('plugin/parley.lua')
            notices = {}
            vim.notify = function(message) notices[#notices + 1] = message end
            a = assert(workspace.add_conversation({ id = 'a', lines = { 'Keep A' } }, 1, 1))
            b = assert(workspace.add_conversation({ id = 'b', lines = { 'Keep B' } }, 2, 2))
            vim.ui.select = function() error('No active selection must not open confirmation') end
            parley.resolve_note(true)
            parley.delete_note()
            assert(#notices == 2 and notices[1]:find('select a thread', 1, true))
            assert(not a.resolved and not b.resolved and not a.deleted)
            workspace.edit_note()
            assert(conversation.active() == a)
            before = { text = vim.api.nvim_buf_get_lines(a.note.buffer, 0, -1, false),
                undo = vim.api.nvim_buf_call(a.note.buffer, vim.fn.undotree), history = vim.deepcopy(a.thread) }
            vim.cmd('Parley thread resolve')
            assert(a.resolved and not b.resolved)
            local request = capture('only-b', 'ask')
            assert(#request.messages == 1 and request.messages[1].conversationId == 'b')
            assert(vim.deep_equal(a.thread, before.history))
            assert(vim.deep_equal(vim.api.nvim_buf_call(a.note.buffer, vim.fn.undotree), before.undo))
        ]],
            { workflow }
        )
        child.type_keys("<C-c>")
        child.lua([[
            -- Moving away from A must not use its remembered selection.
            vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
            assert(not conversation.active())
            parley.resolve_note(false)
            parley.delete_note()
            assert(a.resolved and not a.deleted)
            assert(notices[#notices]:find('select a thread', 1, true))
            -- B at the cursor is not selected merely because A was selected.
            vim.api.nvim_win_set_cursor(source_win, { 2, 0 })
            assert(not conversation.active())
            parley.resolve_note(true)
            assert(not b.resolved)
            vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
            workspace.edit_note()
            assert(conversation.active() == a)
            vim.cmd('Parley thread reopen')
            local reopened = capture('reopened', 'ask')
            assert(#reopened.messages == 2 and not a.resolved)
            assert(a.note.buffer == vim.api.nvim_get_current_buf())
            assert(vim.deep_equal(vim.api.nvim_buf_get_lines(a.note.buffer, 0, -1, false), before.text))
            -- Leaving Insert mode synchronizes an undo block without changing
            -- its entries. Check retained history, not that transient flag.
            local after_undo = vim.api.nvim_buf_call(a.note.buffer, vim.fn.undotree)
            after_undo.synced = before.undo.synced
            assert(vim.deep_equal(after_undo, before.undo))
            assert(vim.deep_equal(a.thread, before.history))
        ]])
        child.type_keys("<C-c>")
        child.lua([[
            -- Neither another source window nor an unrelated buffer can borrow A.
            vim.cmd.vsplit(root .. '/other.lua')
            assert(not conversation.active())
            parley.resolve_note(true)
            assert(not a.resolved)
        ]])
    end

    T[workflow .. ": confirmed deletion hides threads but retains text, history, undo and anchors"] = function()
        child.lua(
            [[
            local workflow = ...
            assert(workspace.select_review('delete-thread', workflow))
            vim.cmd.runtime('plugin/parley.lua')
            a = assert(workspace.add_conversation({ id = 'deleted-a', lines = { 'Retained A' }, messages = {
                { id = 'human-a', role = 'human', author = 'Human', origin = 'editor', created_at = 1, lines = { 'Original A' } },
                { id = 'agent-a', parent_id = 'human-a', role = 'agent', author = 'Agent', origin = 'pi', created_at = 2, lines = { 'Answer A' } },
            } }, 1, 1))
            b = assert(workspace.add_conversation({ id = 'kept-b', lines = { 'Retained B' } }, 2, 2))
            workspace.edit_note()
            reader_win = vim.api.nvim_get_current_win()
            assert(conversation.active() == a)
        ]],
            { workflow }
        )
        child.type_keys("r")
        child.lua([[
            reply_buffer = vim.api.nvim_get_current_buf()
            vim.api.nvim_buf_set_lines(reply_buffer, 0, -1, false, { 'Unsubmitted reply A' })
        ]])
        child.type_keys("<Esc>", "<C-c>", "q")
        child.lua([[
            assert(vim.api.nvim_get_current_win() == source_win)
            workspace.edit_note()
        ]])
        child.type_keys("<Esc>")
        child.lua(
            [[
            local workflow = ...
            -- Snapshot every retained draft, not only the initial or visible one.
            retained = {}
            for _, draft in ipairs(a.drafts) do
                retained[#retained + 1] = { buffer = draft.buffer,
                    text = vim.api.nvim_buf_get_lines(draft.buffer, 0, -1, false),
                    undo = vim.api.nvim_buf_call(draft.buffer, vim.fn.undotree) }
            end
            assert(#retained >= 2)
            history = vim.deepcopy(a.thread)
            anchors_before = vim.api.nvim_buf_get_extmarks(source_buf, -1, 0, -1, { details = true })
            anchor_count = 0
            for _, mark in ipairs(anchors_before) do
                if not mark[4].virt_lines then anchor_count = anchor_count + 1 end
            end
            confirmations = 0
            vim.ui.select = function(items, options, callback)
                confirmations = confirmations + 1
                assert(items[1] == 'Cancel' and options.prompt:find('deleted-a', 1, true))
                confirmation = callback
            end
            vim.cmd('Parley thread delete')
            confirmation('Cancel')
            assert(not a.deleted and conversation.active() == a)
            assert(#capture('not-deleted', 'ask').messages == 2)
            vim.cmd('Parley thread delete')
            confirmation('Delete')
            assert(confirmations == 2 and a.deleted and not b.deleted)
            assert(vim.api.nvim_get_current_win() == source_win)
            assert(not conversation.active())
            assert(vim.deep_equal(a.thread, history))
            for _, saved in ipairs(retained) do
                assert(vim.api.nvim_buf_is_loaded(saved.buffer))
                assert(vim.deep_equal(vim.api.nvim_buf_get_lines(saved.buffer, 0, -1, false), saved.text))
                assert(vim.deep_equal(vim.api.nvim_buf_call(saved.buffer, vim.fn.undotree), saved.undo))
            end
            local current_anchors, rendered = 0, {}
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source_buf, -1, 0, -1, { details = true })) do
                if not mark[4].virt_lines then current_anchors = current_anchors + 1 end
                for _, line in ipairs(mark[4].virt_lines or {}) do
                    for _, chunk in ipairs(line) do rendered[#rendered + 1] = chunk[1] end
                end
            end
            assert(current_anchors == anchor_count, 'Source anchors remain available for inspection')
            local text = table.concat(rendered, '\n')
            assert(not text:find('Answer A', 1, true) and not text:find('Unsubmitted reply A', 1, true))
            assert(require('parley').status():find('1 notes', 1, true))
            local request = capture('after-delete', 'ask')
            assert(#request.messages == 1 and request.messages[1].conversationId == 'kept-b')
            assert(not conversation.capture(a, 'Human', 'editor'))
            workspace.move_note(1)
            assert(conversation.active() == b)
            workspace.move_note(1)
            assert(conversation.active() == b, 'Navigation must skip deleted threads')
            workspace.stop()
            assert(workspace.activate(binding))
            workspace.allow_review_selection()
            assert(workspace.select_review('delete-thread', workflow))
            assert(#capture('after-reattach', 'ask').messages == 1)
            vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
            workspace.edit_note()
            assert(not conversation.active(), 'Reattachment must not display a deleted thread')
        ]],
            { workflow }
        )
    end
end

T["delete confirmation rechecks selection, request activity and workspace identity"] = function()
    child.lua([[
        notices = {}
        vim.notify = function(message) notices[#notices + 1] = message end
        assert(workspace.select_review('confirm-owner'))
        a = assert(workspace.add_conversation({ id = 'a', lines = { 'A' } }, 1, 1))
        workspace.edit_note()
        vim.ui.select = function(_, _, callback) confirmation = callback end
        workspace.delete_note()
    ]])
    child.type_keys("<C-c>")
    child.lua([[
        vim.api.nvim_win_set_cursor(source_win, { 3, 0 })
        confirmation('Delete')
        assert(not a.deleted and notices[#notices]:find('selection changed', 1, true))
        vim.api.nvim_win_set_cursor(source_win, { 1, 0 })
        workspace.edit_note()
        workspace.delete_note()
        request = capture('raced-request', 'ask')
        workspace.request_activity(request, 'uploading')
        confirmation('Delete')
        assert(not a.deleted and notices[#notices]:find('awaiting a response', 1, true))
        workspace.request_activity(request, nil)
        workspace.delete_note()
        workspace.stop()
        assert(workspace.activate(binding))
        confirmation('Delete')
        assert(not a.deleted and notices[#notices]:find('selection changed', 1, true))
    ]])
end

T["deleted threads reject stale acceptance and late replies without resurrection"] = function()
    child.lua([[
        a = assert(workspace.add_conversation({ id = 'a', lines = { 'A' } }, 1, 1))
        b = assert(workspace.add_conversation({ id = 'b', lines = { 'B' } }, 2, 2))
        request = capture('stale-capture', 'ask')
        workspace.edit_note()
        vim.ui.select = function(_, _, callback) callback('Delete') end
        workspace.delete_note()
        local record = vim.tbl_extend('force', request.request, { type = 'request' })
        assert(not workspace.accept_request(request, record))
        assert(#a.thread.messages == 0 and #b.thread.messages == 0, 'Acceptance remains atomic')
        workspace.request_activity(request, nil)
        local message = { id = 'late', role = 'agent', author = 'Agent', origin = 'pi', created_at = 2, lines = { 'Late reply' } }
        assert(not conversation.receive(a, message))
        assert(not conversation.receive_batch(a, { message }, 0, nil))
        assert(a.deleted and #a.thread.messages == 0)
        workspace.move_note(1)
        assert(conversation.active() == b)
    ]])
end

T["custom thread bindings work in source and initial composer and restore prior mappings"] = function()
    child.lua([[
        workspace.stop()
        parley = require('parley')
        parley.setup({ keymaps = {
            review = { resolve = '<F6>', reopen = '<F7>', delete = '<F8>' },
            composer = { resolve = '<F6>', reopen = '<F7>', delete = '<F8>' },
        } })
        original = function() end
        vim.keymap.set('n', '<F6>', original, { buffer = source_buf })
        assert(workspace.activate(binding))
        a = assert(workspace.add_conversation({ id = 'mapped', lines = { 'Mapped thread' } }, 1, 1))
        workspace.edit_note()
    ]])
    child.type_keys("<Esc>", "<F6>")
    child.lua("assert(a.resolved and conversation.active() == a)")
    child.type_keys("<F7>")
    child.lua("assert(not a.resolved)")
    child.type_keys("<C-c>", "<F6>")
    child.lua("assert(a.resolved and vim.api.nvim_get_current_win() == source_win)")
    child.type_keys("<F7>")
    child.lua([[
        assert(not a.resolved)
        vim.ui.select = function(_, _, callback) callback('Delete') end
        workspace.edit_note()
    ]])
    child.type_keys("<Esc>", "<F8>")
    child.lua([[
        assert(a.deleted and vim.api.nvim_get_current_win() == source_win)
        assert(vim.fn.maparg('<F6>', 'n', false, true).callback ~= original)
        assert(vim.api.nvim_buf_call(a.note.buffer, function() return vim.fn.maparg('<F6>', 'n', false, true).buffer end) ~= 1)
        workspace.stop()
        assert(vim.fn.maparg('<F6>', 'n', false, true).callback == original)
    ]])
end

T["reader, parent reader and reply composer bindings act on the complete active thread"] = function()
    child.lua([[
        workspace.stop()
        require('parley').setup({ keymaps = {
            discussion = { resolve = '<F6>', reopen = '<F7>', delete = '<F8>' },
            composer = { resolve = '<F6>', reopen = '<F7>', delete = '<F8>' },
        } })
        assert(workspace.activate(binding))
        a = assert(workspace.add_conversation({ id = 'reader', lines = { 'Retained draft' }, messages = {
            { id = 'human', role = 'human', author = 'Human', origin = 'editor', created_at = 1, lines = { 'Question' } },
            { id = 'agent', parent_id = 'human', role = 'agent', author = 'Agent', origin = 'pi', created_at = 2, lines = { 'Answer' } },
        } }, 1, 1))
        workspace.edit_note()
        reader_win = vim.api.nvim_get_current_win()
        assert(conversation.active() == a)
    ]])
    child.type_keys("<F6>")
    child.lua([[
        assert(a.resolved and vim.api.nvim_get_current_win() == reader_win)
        for _, window in ipairs(vim.api.nvim_list_wins()) do
            if window ~= source_win and window ~= reader_win then parent_win = window end
        end
        vim.api.nvim_set_current_win(assert(parent_win))
        assert(conversation.active() == a)
    ]])
    child.type_keys("<F7>")
    child.lua([[
        assert(not a.resolved and vim.api.nvim_get_current_win() == parent_win)
        vim.api.nvim_set_current_win(reader_win)
    ]])
    child.type_keys("r", "<Esc>", "<F6>")
    child.lua([[
        assert(a.resolved and conversation.active() == a)
        reply_buf = vim.api.nvim_get_current_buf()
        assert(reply_buf ~= a.note.buffer)
    ]])
    child.type_keys("<F7>")
    child.lua([[
        assert(not a.resolved)
        vim.ui.select = function(_, _, callback) callback('Delete') end
    ]])
    child.type_keys("<F8>")
    child.lua([[
        assert(a.deleted and #a.thread.messages == 2)
        assert(vim.api.nvim_buf_is_loaded(reply_buf))
        assert(vim.api.nvim_get_current_win() == source_win)
        assert(not vim.api.nvim_win_is_valid(reader_win) and not vim.api.nvim_win_is_valid(parent_win))
        assert(#vim.api.nvim_list_wins() == 1)
    ]])
end

T["thread bindings can be disabled in source, reader and composer"] = function()
    child.lua([[
        workspace.stop()
        local disabled = { resolve = false, reopen = false, delete = false }
        require('parley').setup({ keymaps = { review = disabled, discussion = disabled, composer = disabled } })
        assert(workspace.activate(binding))
        function assert_no_thread_keys(buffer)
            vim.api.nvim_buf_call(buffer, function()
                for _, key in ipairs({ '\\tr', '\\tR', '\\td' }) do
                    assert(vim.fn.maparg(key, 'n') == '')
                end
            end)
        end
        assert_no_thread_keys(source_buf)
        a = assert(workspace.add_conversation({ id = 'disabled', lines = { 'Draft' } }, 1, 1))
        workspace.edit_note()
        assert_no_thread_keys(a.note.buffer)
        assert(conversation.receive(a, { id = 'agent', role = 'agent', author = 'Agent', origin = 'pi', created_at = 1, lines = { 'Answer' } }))
    ]])
    child.type_keys("<C-c>")
    child.lua([[
        workspace.edit_note()
        assert_no_thread_keys(vim.api.nvim_get_current_buf())
        assert(not a.deleted and not a.resolved)
    ]])
end

T["deletion clears cards in every source window and survives later refreshes"] = function()
    child.lua([[
        a = assert(workspace.add_conversation({ id = 'multi-window', lines = { 'Unique deleted prose' } }, 1, 1))
        b = assert(workspace.add_conversation({ id = 'kept', lines = { 'Unique retained prose' } }, 2, 2))
        vim.cmd.vsplit()
        second_win = vim.api.nvim_get_current_win()
        workspace.edit_note()
    ]])
    child.type_keys("<Esc>", "<C-c>")
    child.lua([[
        assert(conversation.active() == a)
        local function card_text()
            local chunks = {}
            for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(source_buf, -1, 0, -1, { details = true })) do
                for _, line in ipairs(mark[4].virt_lines or {}) do
                    for _, chunk in ipairs(line) do chunks[#chunks + 1] = chunk[1] end
                end
            end
            return table.concat(chunks, '\n')
        end
        assert(card_text():find('Unique deleted prose', 1, true))
        vim.ui.select = function(_, _, callback) callback('Delete') end
        workspace.delete_note()
        assert(a.deleted and not card_text():find('Unique deleted prose', 1, true))
        assert(card_text():find('Unique retained prose', 1, true))
        vim.api.nvim_set_current_win(source_win)
        vim.api.nvim_exec_autocmds('WinResized', {})
        local refreshed = false
        vim.schedule(function() refreshed = true end)
        assert(vim.wait(1000, function() return refreshed end))
        assert(not card_text():find('Unique deleted prose', 1, true))
        workspace.move_note(1)
        assert(conversation.active() == b)
        vim.api.nvim_set_current_win(second_win)
        vim.api.nvim_win_set_cursor(second_win, { 1, 0 })
        assert(not conversation.active())
    ]])
end

T["source changes invalidate selection before a scheduled card refresh or confirmation"] = function()
    child.lua([[
        a = assert(workspace.add_conversation({ id = 'stale-source', lines = { 'Keep draft' } }, 1, 1))
        workspace.edit_note()
    ]])
    child.type_keys("<Esc>", "<C-c>")
    child.lua([[
        vim.ui.select = function(_, _, callback) confirmation = callback end
        workspace.delete_note()
        assert(confirmation)
        vim.api.nvim_buf_set_lines(source_buf, 0, 1, false, { 'Changed source' })
        confirmation('Delete')
        assert(not a.deleted)
        workspace.resolve_note(true)
        assert(not a.resolved)
    ]])
end

T["default thread bindings show composer hints and allow deletion from the parent reader"] = function()
    child.lua([[
        a = assert(workspace.add_conversation({ id = 'defaults', lines = { 'Draft' } }, 1, 1))
        workspace.edit_note()
        local bindings = {}
        for _, action in ipairs({ 'resolve', 'reopen', 'delete' }) do
            local key = require('parley.config').get().composer[action][1]
            key = require('parley.composer.keymaps').concrete(key)
            local mapping = vim.fn.maparg(key, 'n', false, true)
            assert(mapping.callback, action .. ' must be bound')
            bindings[#bindings + 1] = { name = action, mode = 'n', key = key,
                action = mapping.callback, description = mapping.desc }
        end
        local help = require('parley.composer.help')
        help.toggle()
        local row = assert(help.row(a.note.buffer, bindings, 'n', 500))
        local labels = {}
        for _, chunk in ipairs(row) do labels[#labels + 1] = chunk[1] end
        local text = table.concat(labels)
        assert(text:find('resolve', 1, true) and text:find('reopen', 1, true) and text:find('delete', 1, true), text)
        for _, chunk in ipairs(help.row(a.note.buffer, bindings, 'i', 500) or {}) do
            assert(not chunk[1]:find('resolve', 1, true) and not chunk[1]:find('reopen', 1, true) and not chunk[1]:find('delete', 1, true))
        end
        local request = capture('default-request', 'ask')
        accept(request)
        assert(workspace.import_results(request, {}))
        assert(conversation.receive(a, { id = 'agent-default', parent_id = a.thread.messages[1].id, role = 'agent', author = 'Agent', origin = 'pi', created_at = 2, lines = { 'Answer' } }))
    ]])
    child.type_keys("<Esc>", "<C-c>")
    child.lua([[
        workspace.edit_note()
        local reader = vim.api.nvim_get_current_win()
        for _, window in ipairs(vim.api.nvim_list_wins()) do
            if window ~= source_win and window ~= reader then vim.api.nvim_set_current_win(window) break end
        end
        assert(conversation.active() == a)
        vim.ui.select = function(_, _, callback) callback('Delete') end
    ]])
    child.type_keys("\\td")
    child.lua([[
        assert(a.deleted and #a.thread.messages == 2)
        assert(vim.api.nvim_get_current_win() == source_win and #vim.api.nvim_list_wins() == 1)
    ]])
end

return T
