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
                        assert(workspace.add_conversation({ id = 'question', lines = { 'Question' } }, 1, 1))
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
                function deliver_result(status, conversations)
                    local bytes = vim.json.encode({
                        reviewId = 'review', requestId = batch_id, sessionId = 'reviewer',
                        outcome = { id = 'outcome-' .. batch_id, status = status, createdAt = 2,
                            detail = status == 'completed' and vim.NIL or 'Reviewer stopped' },
                        conversations = conversations or {},
                    })
                    local result_digest = vim.fn.sha256(bytes)
                    respond('review-result-begin', {
                        reviewId = 'review', requestId = batch_id, status = 'ready',
                        downloadId = 'download', digest = result_digest, bytes = #bytes, parts = 1,
                    })
                    respond('review-result-chunk', {
                        reviewId = 'review', requestId = batch_id, downloadId = 'download', index = 0,
                        hex = bytes:gsub('.', function(byte) return ('%02x'):format(byte:byte()) end),
                    })
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
        assert(vim.wait(1500, function() return #calls == 1 end))
        deliver_result('completed')
        assert(#notices == 2)
        assert(notices[2].message == 'Parley: Investigation completed: no review messages published.')
        assert(notices[2].level == vim.log.levels.INFO)
        assert(parley.request_status().phase == 'completed')
        assert(parley.request_status().receipts == 'not-required')
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

return T
