local MiniTest = require("mini.test")
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
                root = ...
                vim.fn.writefile({ 'source' }, root .. '/source.lua')
                vim.cmd.edit(root .. '/source.lua')
                workspace = require('parley.workspace')
                assert(workspace.activate({ workspace = root, sessionId = 'parent', editorId = 'editor' }))
                parley = require('parley')
                source_win, source_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
                statusline = vim.o.statusline
                notices, calls, phases = {}, {}, {}
                cached_review_status = parley.status()
                vim.api.nvim_create_autocmd('User', {
                    pattern = 'ParleyReviewChanged',
                    callback = function(event)
                        cached_review_status = event.data.status
                        assert(cached_review_status == parley.status())
                    end,
                })
                vim.notify = function(message, level)
                    notices[#notices + 1] = { message = message, level = level }
                end
                vim.api.nvim_create_autocmd('User', {
                    pattern = 'ParleyRequestChanged',
                    callback = function(event)
                        phases[#phases + 1] = event.data.phase
                        -- A UI consumer cannot mutate the cached status through event data.
                        event.data.phase = 'consumer-edit'
                    end,
                })
                local bridge = require('parley.bridge')
                bridge.status = function()
                    return {
                        connected = true,
                        editor_id = 'editor',
                        binding = { workspace = root, sessionId = 'parent', instanceId = 'instance' },
                    }
                end
                -- Fake only the remote peer. Capture, import, timers and public events are real.
                bridge.request = function(action, review_id, data, callback)
                    calls[#calls + 1] = { action = action, review_id = review_id, data = data, callback = callback }
                end
                function respond(action, response, err)
                    local call = table.remove(calls, 1)
                    assert(call and call.action == action, vim.inspect(call))
                    call.callback(response, err)
                end
                function accept_request(kind)
                    local request_name = 'Investigation'
                    if kind == 'ask' then
                        question = question or assert(workspace.add_conversation({ id = 'question', lines = { 'Question' } }, 1, 1))
                        request_name = 'Review request'
                        parley.ask()
                    else
                        parley.investigate('Review source')
                    end
                    respond('review-info', {
                        reviewId = 'review', preparationId = 'preparation',
                        activeRequestId = vim.NIL, busy = false, ended = false,
                    })
                    batch_id = calls[1].data.batchId
                    digest = calls[1].data.digest
                    respond('review-batch-begin', { reviewId = 'review', batchId = batch_id, status = 'staging' })
                    respond('review-batch-chunk', { reviewId = 'review', batchId = batch_id, status = 'staging', index = 0 })
                    assert(#notices == 0, 'Staging must not claim acceptance')
                    respond('review-batch-commit', {
                        reviewId = 'review', requestId = batch_id, digest = digest,
                        preparationId = 'preparation', createdAt = 1, status = 'accepted',
                    })
                    assert(#notices == 1 and notices[1].message == 'Parley: ' .. request_name .. ' accepted.')
                    assert(parley.request_status().accepted)
                end
                function deliver_result(status, conversations, report)
                    local bytes = vim.json.encode({
                        reviewId = 'review', requestId = batch_id, sessionId = 'reviewer',
                        outcome = { id = 'outcome-' .. batch_id, status = status, createdAt = 2,
                            detail = status == 'completed' and vim.NIL or 'Reviewer stopped' },
                        conversations = conversations or {},
                        report = report,
                    })
                    local result_digest = vim.fn.sha256(bytes)
                    respond('review-result-begin', {
                        reviewId = 'review', requestId = batch_id, status = 'ready',
                        downloadId = 'download', digest = result_digest, bytes = #bytes, parts = math.ceil(#bytes / 16384),
                    })
                    for index = 0, math.ceil(#bytes / 16384) - 1 do
                        local chunk = bytes:sub(index * 16384 + 1, (index + 1) * 16384)
                        respond('review-result-chunk', {
                            reviewId = 'review', requestId = batch_id, downloadId = 'download', index = index,
                            hex = chunk:gsub('.', function(byte) return ('%02x'):format(byte:byte()) end),
                        })
                    end
                end
                function acknowledge_receipt()
                    local receipt = calls[1].data
                    respond('review-result-receipt', {
                        reviewId = 'review', requestId = batch_id, downloadId = 'download',
                        receiptId = receipt.receiptId, status = 'recorded',
                    })
                end
                function assert_ui_unchanged()
                    assert(vim.api.nvim_get_current_win() == source_win)
                    assert(vim.api.nvim_get_current_buf() == source_buf)
                    assert(vim.o.statusline == statusline)
                    assert(#vim.api.nvim_list_wins() == 1)
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

T["accepted prose is not a duplicate draft; pending agent replies are transient and preserve the reader"] = function()
    child.lua([[
        question = assert(workspace.add_conversation({ id = 'question', lines = { 'Question' } }, 1, 1))
        workspace.edit_note()
    ]])
    child.type_keys("<CR>")
    child.lua([[
        assert_ui_unchanged()
        draft_buffer = question.note.buffer
        draft_undo = vim.api.nvim_buf_call(draft_buffer, vim.fn.undotree)
        parley.ask()
        respond('review-info', { reviewId = 'review', preparationId = 'preparation',
            activeRequestId = vim.NIL, busy = false, ended = false })
        batch_id, digest = calls[1].data.batchId, calls[1].data.digest
        respond('review-batch-begin', { reviewId = 'review', batchId = batch_id, status = 'staging' })
        captured = vim.json.decode((calls[1].data.hex:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)))
        respond('review-batch-chunk', { reviewId = 'review', batchId = batch_id, status = 'staging', index = 0 })
        assert(question.response == nil, 'Staging is not reviewer activity')
        idle_review_status = cached_review_status
        respond('review-batch-commit', { reviewId = 'review', requestId = batch_id, digest = digest,
            preparationId = 'preparation', createdAt = 1, status = 'accepted' })
        assert(#question.thread.messages == 1)
        assert(question.response and question.response.state:find('Accepted', 1, true))
        workspace.edit_note()
        reader_window, reader_buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
        assert(text:find('Agent', 1, true) and text:find('Reply pending', 1, true), text)
        frame = question.response.lines[1]
        assert(cached_review_status == frame .. ' ' .. idle_review_status, 'Statusline receives the reply spinner')
        assert(vim.api.nvim_buf_get_lines(reader_buffer, 1, 2, false)[1] == '', 'One blank row below the header')
        assert(vim.api.nvim_buf_get_lines(reader_buffer, 2, -1, false)[1] == frame)
        local calls_before, label_before = #calls, question.response.state
        reader_cursor = vim.api.nvim_win_get_cursor(0)
        assert(vim.wait(350, function() return question.response.lines[1] ~= frame end, 10), 'Spinner animates faster than the 500 ms host observation interval')
        assert(#calls == calls_before and question.response.state == label_before, 'UI animation does not poll Pi or invent progress')
        assert(cached_review_status == question.response.lines[1] .. ' ' .. idle_review_status, 'Statusline animates on the same tick')
        assert(vim.api.nvim_get_current_win() == reader_window and vim.deep_equal(vim.api.nvim_win_get_cursor(0), reader_cursor))
        frame = question.response.lines[1]
        pending_response = question.response
        reader_cursor = vim.api.nvim_win_get_cursor(0)
        respond('review-result-begin', { reviewId = 'review', requestId = batch_id, status = 'pending', activity = 'working' })
        assert(question.response.lines[1] ~= frame)
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(reader_buffer, 2, -1, false), question.response.lines))
        assert(vim.api.nvim_get_current_win() == reader_window)
        assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), reader_cursor))
        assert(vim.wait(1500, function() return #calls == 1 end))
        local submission = captured.request.submissions[1]
        deliver_result('completed', {{ id = 'question', anchor = captured.conversations[1].anchor, new = false,
            baseVersion = submission.version, baseTipId = submission.tipId,
            messages = {{ id = 'answer', parentId = submission.tipId, version = 2,
                role = 'agent', author = 'Agent', origin = 'pi/reviewer', createdAt = 2, lines = { 'Answer' } }},
        }})
        assert(question.response == nil, 'A received reply replaces its slot before receipt acknowledgment')
        local final_frame = pending_response.lines[1]
        vim.wait(200)
        assert(pending_response.lines[1] == final_frame, 'Completion stops the UI timer')
        assert(cached_review_status == idle_review_status, 'Completion clears the statusline spinner')
        assert(#question.thread.messages == 2)
        assert(vim.api.nvim_get_current_win() == reader_window)
        assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), reader_cursor))
        local text = table.concat(vim.api.nvim_buf_get_lines(reader_buffer, 0, -1, false), '\n')
        assert(text:find('Answer', 1, true) and text:find('2/2', 1, true), text)
        assert(not text:find('draft', 1, true) and not text:find('pending', 1, true), text)
        assert(question.note.buffer == draft_buffer)
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(draft_buffer, 0, -1, false), { 'Question' }))
        assert(vim.deep_equal(vim.api.nvim_buf_call(draft_buffer, vim.fn.undotree), draft_undo))
        acknowledge_receipt()
    ]])
    child.type_keys("za")
    child.lua("assert(vim.api.nvim_buf_line_count(reader_buffer) == 1)")
    child.type_keys("<C-p>")
    child.lua(
        "assert(vim.api.nvim_get_current_line() == 'Question' and not question.state.collapsed)"
    )
    child.type_keys("<C-n>")
    child.lua(
        "assert(vim.api.nvim_get_current_line() == 'Answer' and not question.state.collapsed)"
    )
    child.type_keys("za", "q")
    child.lua("workspace.edit_note()")
    child.lua([[
        local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
        assert(text:find('2/2', 1, true) and not text:find('draft', 1, true), text)
        assert(text:find('Answer', 1, true) and not question.state.collapsed, text)
    ]])
    child.type_keys("<C-p>", "e", "<End>", " later", "<Esc>", "q")
    child.lua([[
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(draft_buffer, 0, -1, false), { 'Question later' }))
        assert(question.thread.messages[1].lines[1] == 'Question')
        workspace.edit_note()
        -- Explicit editing still resumes the original buffer, including its undo.
        assert(vim.api.nvim_get_current_buf() == draft_buffer)
    ]])
    child.type_keys("<C-c>")
    child.lua([[
        notices = {}
        local before_window, before_buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
        accept_request('ask')
        assert(question.response, 'A second explicit submission gets its own waiting slot')
        respond('review-result-begin', nil, 'Disconnected')
        assert(question.response == nil and parley.request_status().phase == 'failed')
        assert(cached_review_status == idle_review_status, 'Disconnect clears the statusline spinner')
        assert(not vim.wait(600, function() return #calls > 0 end), 'No activity polling after disconnect')
        assert(vim.api.nvim_get_current_win() == before_window and vim.api.nvim_get_current_buf() == before_buffer)
        notices = {}
        vim.api.nvim_buf_set_lines(draft_buffer, 0, -1, false, { 'Question final' })
        accept_request('ask')
        assert(question.response)
        deliver_result('cancelled')
        assert(question.response == nil and parley.request_status().phase == 'cancelled')
        assert(cached_review_status == idle_review_status, 'Cancellation clears the statusline spinner')
        notices = {}
        vim.api.nvim_buf_set_lines(draft_buffer, 0, -1, false, { 'Question before detach' })
        accept_request('ask')
        local detached_response = question.response
        assert(detached_response)
        workspace.stop()
        assert(question.response == nil)
        local detached_frame, calls_after_stop = detached_response.lines[1], #calls
        vim.wait(200)
        assert(detached_response.lines[1] == detached_frame and #calls == calls_after_stop, 'Detach stops UI animation and request polling')
        assert(cached_review_status == '' and parley.status() == '', 'Detach clears status without late animation')
    ]])
end

T["request reports are explicit read-only snapshots, including zero findings and missing evidence"] = function()
    child.lua([[
        accept_request()
        function report_text()
            local calls_before = #calls
            local buffer = parley.request_report()
            assert(#calls == calls_before, 'Opening a report must not perform transport I/O')
            assert(vim.bo[buffer].buftype == 'nofile' and vim.bo[buffer].readonly)
            assert(not vim.bo[buffer].modifiable and vim.bo[buffer].filetype == 'markdown')
            assert(not vim.wo.number and not vim.wo.relativenumber and vim.wo.signcolumn == 'no')
            return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), '\n'), buffer
        end
        local text = report_text()
        assert(text:find('Final outcome not received', 1, true))
        assert(text:find('Review source', 1, true))
    ]])
    child.type_keys("q")
    child.lua([[
        assert_ui_unchanged()
        deliver_result('completed', {}, {
            publishedMessages = 0, newFindings = 0,
            explanation = 'Inspected source.lua. No findings. Tests not run; coverage limited to this file.',
        })
        assert_ui_unchanged() -- Arrival does not open the report.
        assert(#calls == 0)
        local cached = require('parley.interaction').request_report()
        cached.projection.explanation = 'consumer-edit'
        local text = report_text()
        assert(text:find('Publication: 0 message(s), 0 new finding(s)', 1, true))
        assert(text:find('Reviewer explanation (claims, not host verification)', 1, true))
        assert(text:find('> Inspected source.lua. No findings. Tests not run;', 1, true))
        assert(not text:find('consumer-edit', 1, true))
        assert(text:find('do not imply approval', 1, true))
    ]])
    child.type_keys("<Esc>")
    child.lua([[
        assert_ui_unchanged()
        local text, buffer = report_text()
        assert(text:find('Tests not run', 1, true))
        report_buffer = buffer
    ]])
    child.type_keys("q")
    child.lua([[
        assert(not vim.api.nvim_buf_is_valid(report_buffer), 'Closing wipes the scratch buffer')
        notices = {}
        accept_request('ask')
        deliver_result('cancelled') -- Older/failed results may have no explanation.
        assert_ui_unchanged()
        local text = report_text()
        assert(text:find('Final execution outcome: cancelled', 1, true))
        assert(text:find('source.lua:1-1 (workspace)', 1, true))
        assert(text:find('Not recorded (no bounded final explanation', 1, true))
    ]])
    child.type_keys("q")
    child.lua([[
        assert_ui_unchanged()
        notices = {}
        accept_request()
        deliver_result('completed', {}, {
            publishedMessages = 0, newFindings = 0, explanation = string.rep('界', 6000),
        })
        assert(parley.request_status().phase == 'failed')
        assert(require('parley.interaction').request_report().projection == nil)
        assert_ui_unchanged()
    ]])
end

T["acceptance and completion notify once; ongoing progress stays available without owning UI"] = function()
    child.lua([[
        accept_request()
        respond('review-result-begin', {
            reviewId = 'review', requestId = batch_id, status = 'pending', activity = 'working',
        })
        assert(#notices == 1, 'Working updates must not produce notifications')
        local status = parley.request_status()
        assert(status.phase == 'accepted' and status.activity == 'working')
        status.activity = 'consumer-edit'
        assert(parley.request_status().activity == 'working')
        assert(#calls == 0, 'Reading progress must not perform transport I/O')
        assert(vim.tbl_contains(phases, 'uploading') and vim.tbl_contains(phases, 'accepted'))
        local frame = cached_review_status
        local phase_count = #phases
        assert(vim.wait(350, function() return cached_review_status ~= frame end, 10), 'Statusline animates investigations without reply cards')
        assert(#calls == 0 and #phases == phase_count, 'Status animation adds no polling or request progress events')
        assert(vim.wait(1500, function() return #calls == 1 end))
        deliver_result('completed')
        assert(#notices == 2)
        assert(notices[2].message == 'Parley: Investigation completed: no review messages published.')
        assert(notices[2].level == vim.log.levels.INFO)
        assert(parley.request_status().phase == 'completed')
        assert(parley.request_status().receipts == 'not-required')
        assert(cached_review_status == 'Workspace review · 0 notes', 'Zero-publication completion clears the spinner')
        assert(#calls == 0)
        assert_ui_unchanged()

        for _, outcome in ipairs({ 'failed', 'cancelled' }) do
            notices = {}
            local kind = outcome == 'failed' and 'ask' or 'investigate'
            local request_name = kind == 'ask' and 'Review request' or 'Investigation'
            accept_request(kind)
            deliver_result(outcome)
            assert(#notices == 2)
            assert(notices[2].message:find(request_name .. ' ' .. outcome .. ':', 1, true))
            assert(notices[2].message:find('Reviewer stopped', 1, true))
            assert(notices[2].level == vim.log.levels.WARN)
            assert(parley.request_status().phase == outcome)
            assert(cached_review_status:sub(1, #'Workspace review') == 'Workspace review', 'Terminal outcomes clear the spinner')
            if kind == 'ask' then
                assert(question.response == nil, 'Failed execution must clear the pending reply slot')
            end
        end
    ]])
end

T["completion reports unplaced publications; a lost receipt is a delivery failure, not a failed review"] = function()
    child.lua([[
        vim.fn.writefile({ 'unloaded source' }, root .. '/unloaded.lua')
        local conversations = {{
            id = 'finding', new = true, baseVersion = 0, baseTipId = vim.NIL,
            anchor = {
                path = 'unloaded.lua', side = 'workspace', first = 1, last = 1,
                lines = { 'unloaded source' }, observedAt = 1, source = { kind = 'disk' },
            },
            messages = {{
                id = 'finding-message', parentId = vim.NIL, version = 1, role = 'agent',
                author = 'Agent', origin = 'pi/reviewer', createdAt = 2, lines = { 'Check this' },
            }},
        }}
        accept_request()
        deliver_result('completed', conversations)
        assert(#notices == 1, 'Wait for receipt settlement before success feedback')
        acknowledge_receipt()
        assert(#notices == 2 and notices[2].level == vim.log.levels.WARN)
        assert(notices[2].message:find('1 review message(s) published.', 1, true))
        assert(notices[2].message:find('0 conversation(s) incompatible; 1 unplaced.', 1, true))
        assert(parley.request_status().results.unplaced == 1)
        assert(parley.request_status().receipts == 'recorded')
        assert(vim.fn.bufnr(root .. '/unloaded.lua') == -1)
        assert_ui_unchanged()

        notices = {}
        accept_request()
        conversations[1].id = 'another-finding'
        conversations[1].messages[1].id = 'another-message'
        deliver_result('completed', conversations)
        respond('review-result-receipt', nil, 'Receipt acknowledgment lost')
        assert(#notices == 2 and notices[2].level == vim.log.levels.ERROR)
        assert(notices[2].message:find('Investigation completed, but result delivery failed:', 1, true))
        local status = parley.request_status()
        assert(status.phase == 'failed' and status.outcome.status == 'completed')
        assert(status.receipts == 'unknown')
        assert(not vim.wait(600, function() return #calls > 0 end), 'No automatic replay')
        assert_ui_unchanged()
    ]])
end

for _, workflow in ipairs({ "review", "parley" }) do
    T[workflow .. ": only awaiting threads block deletion through upload, acceptance and download"] = function()
        child.lua(
            [[
            local workflow = ...
            assert(workspace.select_review('review', workflow))
            question = assert(workspace.add_conversation({ id = 'question', lines = { 'Question' } }, 1, 1))
            workspace.edit_note()
            confirmations = 0
            vim.ui.select = function(_, _, callback)
                confirmations = confirmations + 1
                callback('Delete')
            end
        ]],
            { workflow }
        )
        child.type_keys("<Esc>", "<C-c>")
        child.lua(
            [[
            local workflow = ...
            if workflow == 'parley' then parley.turn() else parley.ask() end
            local info = { reviewId = 'review', preparationId = 'preparation',
                activeRequestId = vim.NIL, busy = false, ended = false }
            if workflow == 'parley' then info.workflow = 'parley' end
            respond('review-info', info)
            batch_id, digest = calls[1].data.batchId, calls[1].data.digest
            parley.delete_note()
            assert(not question.deleted and confirmations == 0)
            assert(notices[#notices].message:find('awaiting a response', 1, true))
            respond('review-batch-begin', { reviewId = 'review', batchId = batch_id, status = 'staging' })
            captured = vim.json.decode((calls[1].data.hex:gsub('..', function(pair) return string.char(tonumber(pair, 16)) end)))
            respond('review-batch-chunk', { reviewId = 'review', batchId = batch_id, status = 'staging', index = 0 })
            parley.delete_note()
            assert(not question.deleted and confirmations == 0, 'Awaiting acceptance is protected')
            respond('review-batch-commit', { reviewId = 'review', requestId = batch_id, digest = digest,
                preparationId = 'preparation', createdAt = 1, status = 'accepted' })
            assert(question.response)
            parley.resolve_note(true)
            parley.delete_note()
            assert(question.resolved and not question.deleted and confirmations == 0)
            -- This note was not part of the request; its deletion remains local.
            idle = assert(workspace.add_conversation({ id = 'idle', lines = { 'Idle draft' } }, 1, 1))
            workspace.edit_note() -- Explicitly opens the selected question.
        ]],
            { workflow }
        )
        child.type_keys("q")
        child.lua([[
            workspace.move_note(1) -- Overlapping notes: navigate explicitly to idle.
            assert(require('parley.conversation').active() == idle)
            parley.delete_note()
            assert(idle.deleted and not question.deleted and confirmations == 1)
            workspace.move_note(1)
            assert(require('parley.conversation').active() == question)
            blocked_phases = {}
            vim.api.nvim_create_autocmd('User', {
                pattern = 'ParleyRequestChanged',
                callback = function(event)
                    if event.data.phase == 'downloading' or event.data.phase == 'applying' then
                        parley.delete_note()
                        assert(not question.deleted and confirmations == 1)
                        blocked_phases[event.data.phase] = true
                    end
                end,
            })
            local submission = captured.request.submissions[1]
            deliver_result('completed', {{ id = 'question', anchor = captured.conversations[1].anchor, new = false,
                baseVersion = submission.version, baseTipId = submission.tipId,
                messages = {{ id = 'answer', parentId = submission.tipId, version = 2,
                    role = 'agent', author = 'Agent', origin = 'pi/reviewer', createdAt = 2, lines = { 'Answer' } }},
            }})
            assert(#question.thread.messages == 2 and question.resolved)
            assert(blocked_phases.downloading and blocked_phases.applying)
            acknowledge_receipt()
            parley.delete_note()
            assert(question.deleted and idle.deleted and confirmations == 2)
            assert(#question.thread.messages == 2, 'Deletion retains the completed response')
        ]])
    end
end

T["failed delivery releases deletion protection without replaying a late callback"] = function()
    child.lua([[
        accept_request('ask')
        workspace.move_note(1)
        assert(require('parley.conversation').active() == question)
        old_callback = calls[1].callback
        respond('review-result-begin', nil, 'Disconnected')
        assert(question.response == nil)
        vim.ui.select = function(_, _, callback) callback('Delete') end
        parley.delete_note()
        assert(question.deleted)
        old_callback({ reviewId = 'review', requestId = batch_id, status = 'pending', activity = 'working' })
        assert(question.deleted and question.response == nil)
        assert(#calls == 0 and parley.request_status().phase == 'failed')
        assert_ui_unchanged()
    ]])
end

return T
