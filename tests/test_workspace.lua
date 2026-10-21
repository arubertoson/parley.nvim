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
        assert(vim.api.nvim_get_current_buf() == draft_buf)
    ]])
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
        assert(vim.api.nvim_win_get_cursor(0)[1] == 2)
    ]])
    child.type_keys("gg")
    MiniTest.expect.equality(child.lua_get("vim.api.nvim_win_get_cursor(0)[1]"), 2)
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
        vim.cmd.ReviewDone()
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
        workspace.allow_review_selection() -- Explicit ReviewStart boundary.
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

return T
