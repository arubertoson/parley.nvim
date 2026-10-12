---Owns editor attachment, wire-note conversion and acknowledged saves.
---Detached local notes/drafts retain their composer identities and undo buffers.
local client = require("parley.client")
local composer = require("parley.composer")
local review = require("parley.review")
local M = {}
local records, active = {}, nil
local serial, request = 0, 0
local pending_client

local function notify(message) vim.notify("Parley: " .. message, vim.log.levels.WARN) end

local function notes_for(state)
    local notes = {}
    for _, note in ipairs(composer.comments) do
        local owner = note.target.review
        if owner and owner.session == state.local_id then
            note.remote_id = note.remote_id or client.id()
            notes[#notes + 1] = {
                id = note.remote_id,
                target = {
                    path = owner.path,
                    side = owner.side,
                    first = note.target.first,
                    last = note.target.last,
                    scope = note.target.scope,
                    context = vim.deepcopy(note.target.context),
                },
                text = table.concat(note.lines, "\n"),
                replyTo = note.reply_to,
            }
        end
    end
    return notes
end

local function pending_turn(record)
    for _, turn in ipairs(record.turns) do
        if turn.status == "queued" or turn.status == "running" then return true end
    end
    return false
end

local function accept(state, record)
    state.record = record
    for _, note in ipairs(composer.comments) do
        local owner = note.target.review
        if owner and owner.session == state.local_id then
            note.replies = {}
            for _, turn in ipairs(record.turns) do
                for _, reply in ipairs(turn.replies) do
                    if reply.replyTo == note.remote_id then
                        note.replies[#note.replies + 1] = reply
                    end
                end
            end
        end
    end
    if active == state then
        local latest = record.turns[#record.turns]
        if latest and latest.status == "error" and state.reported_error ~= latest.id then
            state.reported_error = latest.id
            notify("Agent turn failed: " .. (latest.error or "unknown error"))
        end
        review.refresh()
    end
end

-- Every save reads the current version first. Agent progress can change a version,
-- but another editor's comments require an explicit conflict decision.
local function save(state, done, explicit)
    done = done or function() end
    if state.busy then
        done(false, "Another review request is awaiting acknowledgement")
        return
    end
    if not state.client or state.client.closed then
        done(false, "Disconnected; local notes retained. Use :ReviewStart to reattach.")
        return
    end
    state.busy = true
    local sent = notes_for(state)
    local function finish(ok, err)
        state.busy = false
        done(ok, err)
        if state.detached then
            state.client.close()
            return
        end
        if ok and not vim.deep_equal(sent, notes_for(state)) then
            vim.schedule(function()
                if active == state then M.save() end
            end)
        end
    end
    state.client.request("read", state.record.id, nil, function(record, err)
        if not record then
            finish(false, err)
            return
        end
        accept(state, record)
        if vim.deep_equal(sent, record.notes) then
            state.baseline = vim.deepcopy(record.notes)
            finish(true)
            return
        end
        if pending_turn(record) then
            finish(false, "Human edits retained locally until the agent turn finishes")
            return
        end
        if record.status ~= "open" then
            finish(false, "Review is closed; local notes retained")
            return
        end
        local function write()
            state.client.request(
                "save",
                record.id,
                { expectedVersion = record.version, notes = sent },
                function(saved, save_err)
                    if saved then
                        state.baseline = vim.deepcopy(sent)
                        accept(state, saved)
                    end
                    finish(saved ~= nil, save_err)
                end
            )
        end
        if vim.deep_equal(record.notes, state.baseline) then
            write()
            return
        end
        if not explicit or state.detached then
            finish(
                false,
                "Comments changed in another editor; local notes retained. :ReviewSave resolves the conflict."
            )
            return
        end
        vim.ui.select(
            { "Keep local comments and replace remote comments", "Cancel; retain local comments" },
            {
                prompt = "Parley comment conflict (submitted turns remain frozen):",
            },
            function(choice)
                if
                    active ~= state
                    or choice ~= "Keep local comments and replace remote comments"
                then
                    finish(false, "Conflict not resolved; local notes retained")
                else
                    write()
                end
            end
        )
    end)
end

local function stop_timer(state)
    if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
    end
end

local function restore(state, session)
    if state.restored then return end
    local notes = {}
    for _, wire in ipairs(state.record.notes) do
        local target = wire.target
        local index
        for i, piece in ipairs(session.pieces) do
            if piece.file.path == target.path and piece.side == target.side then
                index = index or i
                if target.first >= piece.first and target.first <= piece.last then
                    index = i
                    break
                end
            end
        end
        if not index then error("Stored note has no frozen review piece") end
        local file = session.pieces[index].file
        notes[#notes + 1] = {
            remote_id = wire.id,
            reply_to = wire.replyTo,
            lines = vim.split(wire.text, "\n", { plain = true }),
            target = {
                path = ("parley://%d/%s/%s"):format(
                    state.local_id,
                    target.side,
                    target.side == "old" and file.old_path or file.path
                ),
                first = target.first,
                last = target.last,
                scope = target.scope,
                context = vim.deepcopy(target.context),
                review = {
                    session = state.local_id,
                    piece = index,
                    path = target.path,
                    side = target.side,
                },
            },
        }
    end
    composer.restore_review(notes)
    state.restored = true
end

local function attach(record, pipe)
    local state = records[record.id]
    if state and state.busy then
        pipe.close()
        notify("Previous review request is awaiting acknowledgement; retry :ReviewStart")
        return
    end
    if not state then
        serial = serial - 1 -- Separate from the standalone review's positive local IDs.
        state = { local_id = serial, record = record, baseline = vim.deepcopy(record.notes) }
        records[record.id] = state
    end
    state.client, state.detached, state.busy = pipe, false, false
    accept(state, record)
    local remote = { local_id = state.local_id }
    function remote.status()
        if pipe.closed then return "disconnected" end
        if state.record.status == "closed" then return "closed" end
        for _, turn in ipairs(state.record.turns) do
            if turn.status == "queued" then return "agent queued" end
            if turn.status == "running" then return "agent turn" end
        end
        local turn = state.record.turns[#state.record.turns]
        if turn and turn.status == "error" then return "human turn · agent error" end
        return "human turn"
    end
    function remote.start(session)
        active = state
        restore(state, session)
        accept(state, record)
        pipe.on_disconnect = function(reason)
            if active ~= state or state.client ~= pipe then return end
            stop_timer(state)
            notify(reason or "Pi disconnected; local notes retained")
            review.refresh()
        end
        state.timer = vim.uv.new_timer()
        state.timer:start(
            1000,
            1000,
            vim.schedule_wrap(function()
                if active ~= state or state.busy or pipe.closed then return end
                state.busy = true
                pipe.request("read", record.id, nil, function(current, err)
                    state.busy = false
                    if current then
                        accept(state, current)
                        if
                            active == state
                            and not pending_turn(current)
                            and not vim.deep_equal(notes_for(state), state.baseline)
                            and vim.deep_equal(current.notes, state.baseline)
                        then
                            save(state, function(ok, save_err)
                                if not ok then notify(save_err) end
                            end)
                        end
                    elseif active == state then
                        notify(err)
                    end
                    if state.detached then pipe.close() end
                end)
            end)
        )
    end
    function remote.changed()
        if active ~= state then return end
        state.edit_generation = (state.edit_generation or 0) + 1
        local generation = state.edit_generation
        vim.defer_fn(function()
            if active ~= state or generation ~= state.edit_generation or state.busy then return end
            save(state, function(ok, err)
                if not ok then notify(err) end
            end)
        end, 200)
    end
    function remote.stop()
        if active == state then active = nil end
        stop_timer(state)
        state.detached = true
        if state.busy then return end -- Ack owns the last pipe cleanup.
        save(state, function(ok, err)
            if not ok then notify(err) end
        end)
        if not state.busy then pipe.close() end
    end
    local ok, err = pcall(review.start, record, remote)
    if not ok then
        review.stop()
        stop_timer(state)
        if active == state then active = nil end
        pipe.close()
        notify(tostring(err))
    elseif active ~= state then
        pipe.close()
    end
end

function M.start()
    if review.active_window() then
        notify("Already in review mode")
        return
    end
    request = request + 1
    local token, cwd, win, buf =
        request, vim.fn.getcwd(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local function current()
        return request == token
            and not review.active_window()
            and vim.fn.getcwd() == cwd
            and vim.api.nvim_win_is_valid(win)
            and vim.api.nvim_get_current_win() == win
            and vim.api.nvim_get_current_buf() == buf
    end
    client.discover(cwd, function(items, err)
        if not current() then return end
        if not items then
            notify(err)
            return
        end
        if #items == 0 then
            notify("No open reviews; create one with /review in Pi")
            return
        end
        vim.ui.select(items, {
            prompt = "Attach to frozen review:",
            format_item = function(item)
                return item.id .. " · " .. item.scope .. " · " .. item.createdAt
            end,
        }, function(item)
            if not item or not current() then return end
            pending_client = client.connect(item.endpoint.socket, function(pipe, connect_err)
                pending_client = nil
                if not pipe then
                    if current() then notify(connect_err) end
                    return
                end
                if not current() then
                    pipe.close()
                    return
                end
                pending_client = pipe
                pipe.request("read", item.id, nil, function(record, read_err)
                    if pending_client == pipe then pending_client = nil end
                    if not current() then
                        pipe.close()
                        return
                    end
                    if not record then
                        pipe.close()
                        notify(read_err)
                        return
                    end
                    if
                        record.id ~= item.id
                        or record.root ~= item.root
                        or record.status ~= "open"
                    then
                        pipe.close()
                        notify("Review identity, workspace or status changed")
                        return
                    end
                    attach(record, pipe)
                end)
            end)
        end)
    end)
end

function M.stop()
    request = request + 1
    if pending_client then
        pending_client.close()
        pending_client = nil
    end
    review.stop()
end

function M.save()
    if not active then
        notify("No attached review")
        return
    end
    save(active, function(ok, err)
        if ok then
            vim.notify("Parley comments saved; no agent turn started")
        else
            notify(err)
        end
    end, true)
end

function M.submit()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    for _, item in ipairs(composer.review_items(state.local_id)) do
        if item.state ~= "saved" then
            notify("Save or discard unfinished drafts before submitting")
            return
        end
    end
    save(state, function(ok, err)
        if not ok then
            notify(err)
            return
        end
        if active ~= state then return end
        state.busy = true
        -- Keep the turn ID after uncertain delivery; the server independently deduplicates it.
        local retry = state.turn_id ~= nil
        state.turn_id = state.turn_id or client.id()
        local turn_id = state.turn_id
        state.client.request(
            "submit",
            state.record.id,
            { expectedVersion = state.record.version, turnId = state.turn_id },
            function(record, submit_err)
                state.busy = false
                if record then
                    state.turn_id = nil
                    accept(state, record)
                    local acknowledged
                    for _, turn in ipairs(record.turns) do
                        if turn.id == turn_id then acknowledged = turn end
                    end
                    if retry and acknowledged and not pending_turn(record) then
                        vim.notify(
                            "Parley previous turn acknowledged; submit again to hand over revised comments"
                        )
                    else
                        vim.notify("Parley turn submitted; replies wait for Pi availability")
                    end
                else
                    notify(submit_err)
                end
                if state.detached then state.client.close() end
            end
        )
    end, true)
end

function M.close()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    vim.ui.select(
        { "Close review (retain contents)", "Cancel" },
        { prompt = "Close this review, not delete it?" },
        function(choice)
            if active ~= state or choice ~= "Close review (retain contents)" then return end
            for _, item in ipairs(composer.review_items(state.local_id)) do
                if item.state ~= "saved" then
                    notify("Save or discard unfinished drafts before closing")
                    return
                end
            end
            save(state, function(ok, err)
                if not ok then
                    notify(err)
                    return
                end
                if active ~= state then return end
                state.busy = true
                state.client.request(
                    "close",
                    state.record.id,
                    { expectedVersion = state.record.version },
                    function(record, close_err)
                        state.busy = false
                        if record then
                            accept(state, record)
                            review.stop()
                        else
                            notify(close_err)
                        end
                        if state.detached then state.client.close() end
                    end
                )
            end, true)
        end
    )
end

return M
