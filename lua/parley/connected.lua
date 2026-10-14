---Owns editor attachment, wire-note conversion and acknowledged saves.
---Detached local notes/drafts retain their composer identities and undo buffers.
local client = require("parley.client")
local composer = require("parley.composer")
local review = require("parley.review")
local source = require("parley.source")
local M = {}
local records, active = {}, nil
local serial, request = 0, 0
local pending_client
local sync_findings
local watcher = { id = client.id(), hidden = {}, generation = 0 }

local function offer_available(root)
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    return not review.is_active()
        and not composer.is_open()
        and vim.api.nvim_win_get_config(win).relative == ""
        and vim.bo[buf].buftype == ""
        and source.path(root, buf) ~= nil
end

local function watch_payload(root, eligible)
    return {
        editorId = watcher.id,
        editorLabel = "Neovim PID " .. vim.uv.os_getpid() .. " · " .. root:sub(1, 200),
        eligible = eligible,
    }
end

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
                    first = (note.target.anchor or note.target).first,
                    last = (note.target.anchor or note.target).last,
                    scope = note.target.scope,
                    context = vim.deepcopy((note.target.anchor or note.target).context),
                    sourceId = owner.source_id,
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

local function latest_conclusions(record)
    local latest = {}
    for _, conclusion in ipairs(record.conclusions or {}) do
        latest[conclusion.threadId] = conclusion
    end
    return latest
end

local function thread_root(record, id)
    local parents, known = {}, {}
    local function add(message)
        known[message.id] = true
        parents[message.id] = message.replyTo
    end
    for _, conclusion in ipairs(record.conclusions or {}) do
        for _, message in ipairs(conclusion.discussion or {}) do
            add(message)
        end
    end
    for _, turn in ipairs(record.turns) do
        for _, messages in ipairs({ turn.notes, turn.findings or {}, turn.replies }) do
            for _, message in ipairs(messages) do
                add(message)
            end
        end
    end
    for _, note in ipairs(record.notes) do
        add(note)
    end
    local visited = {}
    while id and known[id] and not visited[id] do
        visited[id] = true
        if not parents[id] then return id end
        id = parents[id]
    end
end

local function latest_handoff(record)
    local latest
    for _, collection in ipairs(record.collections or {}) do
        for _, handoff in ipairs(collection.handoffs or {}) do
            if not latest or handoff.requestedAt >= latest.requestedAt then latest = handoff end
        end
    end
    return latest
end

local function unfinished(state)
    if composer.has_drafts(state.local_id) then return true end
    for _, item in ipairs(composer.review_items(state.local_id)) do
        if item.state ~= "saved" then return true end
    end
    return false
end

local function active_stage(record)
    for _, stage in ipairs(record.stages or {}) do
        if stage.id == record.activeStageId then return stage end
    end
end

local function reviewed_units(record)
    local covered = {}
    for _, turn in ipairs(record.turns) do
        if turn.kind == "initial" and turn.status == "complete" then
            local stage
            for _, candidate in ipairs(record.stages or {}) do
                if candidate.id == turn.stageId then stage = candidate end
            end
            if stage and stage.unitIds then
                for _, id in ipairs(stage.unitIds) do
                    covered[id] = true
                end
            else
                for _, unit in ipairs(record.grouping and record.grouping.units or {}) do
                    if
                        not turn.stageId or (stage and vim.tbl_contains(stage.paths, unit.path))
                    then
                        covered[unit.id] = true
                    end
                end
            end
        end
    end
    return covered
end

local function reviewed_paths(record)
    local covered = {}
    for _, turn in ipairs(record.turns) do
        if turn.kind == "initial" and turn.status == "complete" then
            if not turn.stageId then
                for _, file in ipairs(record.files) do
                    covered[file.path] = true
                end
            else
                for _, stage in ipairs(record.stages or {}) do
                    if stage.id == turn.stageId and not stage.unitIds then
                        for _, path in ipairs(stage.paths) do
                            covered[path] = true
                        end
                    end
                end
            end
        end
    end
    local units = reviewed_units(record)
    for _, file in ipairs(record.files) do
        local found, complete = false, true
        for _, unit in ipairs(record.grouping and record.grouping.units or {}) do
            if unit.path == file.path then
                found = true
                complete = complete and units[unit.id] == true
            end
        end
        if found and complete then covered[file.path] = true end
    end
    return covered
end

local function accept(state, record)
    state.record = record
    if state.session then
        source.sync(state.session, record)
        sync_findings(state)
    end
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
    for _, note in ipairs(composer.findings) do
        if note.target.review.session == state.local_id then
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
    local conclusions = latest_conclusions(record)
    local conclusion_turns = {}
    for _, turn in ipairs(record.turns) do
        local draft = turn.conclusionDraft
        if turn.kind == "conclusion" and draft and draft.autoRecord then
            conclusion_turns[draft.threadId] = turn
        end
    end
    for _, collection in ipairs({ composer.comments, composer.findings }) do
        for _, note in ipairs(collection) do
            if note.target.review and note.target.review.session == state.local_id then
                local root = thread_root(record, note.remote_id)
                note.conclusion = root and conclusions[root] or nil
                local turn = root and conclusion_turns[root]
                note.conclusion_turn = turn
                        and turn.status ~= "complete"
                        and turn.conclusionDraft.previousConclusionId == (note.conclusion and note.conclusion.id)
                        and turn
                    or nil
            end
        end
    end
    if active == state then
        local latest = record.turns[#record.turns]
        if latest and latest.status == "error" and state.reported_error ~= latest.id then
            state.reported_error = latest.id
            notify("Agent turn failed: " .. (latest.error or "unknown error"))
        end
        state.reported_collection_errors = state.reported_collection_errors or {}
        for _, collection in ipairs(record.collections or {}) do
            if
                collection.status == "error"
                and not state.reported_collection_errors[collection.id]
            then
                state.reported_collection_errors[collection.id] = true
                notify("Planning collection failed: " .. (collection.error or "unknown error"))
            end
        end
        state.reported_handoff_errors = state.reported_handoff_errors or {}
        for _, collection in ipairs(record.collections or {}) do
            for _, handoff in ipairs(collection.handoffs or {}) do
                if
                    handoff.error
                    and state.reported_handoff_errors[handoff.id] ~= handoff.error
                then
                    state.reported_handoff_errors[handoff.id] = handoff.error
                    notify(
                        "Planning handoff: " .. handoff.error .. ". Review and bundle retained."
                    )
                end
            end
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

-- Acknowledged, versioned mutation. Conclusion drafts never enter discussion notes.
local function mutate(state, action, payload, done)
    if active ~= state or state.detached or state.busy or state.client.closed then
        done(false, "Review detached, disconnected or awaiting acknowledgement; retry explicitly")
        return
    end
    state.busy = true
    state.client.request("read", state.record.id, nil, function(current, err)
        if not current or active ~= state or state.detached then
            state.busy = false
            if state.detached then state.client.close() end
            done(false, err or "Review detached; draft retained")
            return
        end
        accept(state, current)
        payload.expectedVersion = current.version
        state.client.request(action, current.id, payload, function(record, mutation_err)
            state.busy = false
            if record then accept(state, record) end
            done(record ~= nil, mutation_err, not state.client.closed)
            if state.detached then state.client.close() end
        end)
    end)
end

local function edit_conclusion(
    state,
    message_id,
    target,
    presentation,
    reopen,
    focused,
    editing_id
)
    if composer.has_drafts(state.local_id) then
        -- A retained conclusion draft can be resumed below; ordinary discussion drafts must finish first.
        for _, item in ipairs(composer.review_items(state.local_id)) do
            if item.state ~= "saved" then
                notify("Save or discard discussion drafts before concluding")
                return
            end
        end
    end
    local win, buf, cursor =
        vim.api.nvim_get_current_win(),
        vim.api.nvim_get_current_buf(),
        vim.api.nvim_win_get_cursor(0)
    target = vim.deepcopy(target)
    local function current()
        return active == state
            and not state.detached
            and vim.api.nvim_get_current_win() == win
            and (not focused or focused())
            and vim.api.nvim_get_current_buf() == buf
            and vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(win))
            and vim.deep_equal(
                target.context,
                vim.api.nvim_buf_get_lines(buf, target.first - 1, target.last, false)
            )
    end
    save(state, function(ok, err)
        if not ok then
            notify(err)
            return
        end
        if not current() then return end
        local root = thread_root(state.record, message_id)
        if not root then
            notify("Thread parent unavailable; no conclusion changed")
            return
        end
        local previous = latest_conclusions(state.record)[root]
        if
            editing_id
            and (not previous or previous.id ~= editing_id or previous.state ~= "concluded")
        then
            notify("Conclusion changed; enter the current conclusion before editing")
            return
        end
        if reopen and (not previous or previous.state ~= "concluded") then
            notify("This thread has no current conclusion to reopen")
            return
        end
        local action = reopen and "reopen" or "conclude"
        local key = state.record.id .. ":" .. root .. ":" .. action
        if composer.resume_auxiliary(key, presentation) then return end
        local function open(decision)
            if not current() then return end
            state.conclusion_ids = state.conclusion_ids or {}
            state.conclusion_ids[key] = state.conclusion_ids[key] or client.id()
            local payload = {
                conclusionId = state.conclusion_ids[key],
                threadId = root,
                previousConclusionId = previous and previous.id,
                decision = decision,
            }
            local text = reopen and "" or previous.summary
            composer.auxiliary(
                key,
                target,
                vim.split(text, "\n", { plain = true }),
                reopen and "Reopen thread · reason (history retained)"
                    or "Edit conclusion · save revision",
                presentation,
                function(lines, done)
                    payload.summary = table.concat(lines, "\n")
                    mutate(state, action, payload, function(saved, save_err, acknowledged)
                        if saved or acknowledged then state.conclusion_ids[key] = nil end
                        done(saved, save_err)
                        if
                            saved
                            and active == state
                            and presentation
                            and presentation.concluded
                        then
                            presentation.concluded(payload.conclusionId)
                        end
                    end)
                end
            )
        end
        if reopen then
            open()
            return
        end
        if editing_id then
            open(previous.decision)
            return
        end
        local function request_draft(fresh)
            local turn_id
            if not fresh then
                for index = #state.record.turns, 1, -1 do
                    local candidate = state.record.turns[index]
                    local draft = candidate.conclusionDraft
                    if
                        candidate.kind == "conclusion"
                        and candidate.status ~= "error"
                        and draft
                        and draft.threadId == root
                        and draft.decision == nil
                        and draft.previousConclusionId == (previous and previous.id)
                    then
                        turn_id = candidate.id
                        break
                    end
                end
            end
            turn_id = turn_id or client.id()
            state.conclusion_requesting = true
            review.refresh()
            mutate(state, "draft-conclusion", {
                turnId = turn_id,
                threadId = root,
                previousConclusionId = previous and previous.id,
            }, function(saved, draft_err, acknowledged)
                state.conclusion_requesting = false
                if not saved then
                    -- Replace a stale draft only after this explicit request is definitively rejected.
                    if
                        not fresh
                        and acknowledged
                        and current()
                        and draft_err
                        and draft_err:find("Conclusion draft is stale", 1, true)
                    then
                        request_draft(true)
                        return
                    end
                    notify(draft_err)
                    if active == state then review.refresh() end
                    return
                end
                if active ~= state or state.detached then return end
                -- Pi owns persistence; polling never selects/reveals a tail or opens its editor.
                review.refresh()
            end)
        end
        request_draft(false)
    end, true)
end

local function stop_timer(state)
    if state.timer then
        state.timer:stop()
        state.timer:close()
        state.timer = nil
    end
end

local function local_note(state, session, wire, author)
    local target = wire.target
    local index
    for i, piece in ipairs(session.pieces) do
        if
            piece.file.path == target.path
            and piece.side == target.side
            and piece.file.source_id == target.sourceId
        then
            index = index or i
            if target.first >= piece.first and target.first <= piece.last then
                index = i
                break
            end
        end
    end
    if not index then
        -- Findings may reference the other frozen side or unchanged context.
        -- Add one context piece only when that side has no navigation piece.
        local file
        for _, candidate in ipairs(state.record.files) do
            if candidate.path == target.path then
                file = candidate
                break
            end
        end
        if not file then error("Finding outside frozen files") end
        local old_count = #vim.split(file.old:gsub("\n$", ""), "\n", { plain = true })
        local new_count = #vim.split(file.new:gsub("\n$", ""), "\n", { plain = true })
        session.pieces[#session.pieces + 1] = {
            file = file,
            side = target.side,
            first = 1,
            last = target.side == "old" and old_count or new_count,
            old_first = 1,
            old_count = old_count,
            new_first = 1,
            new_count = new_count,
            seen = false,
        }
        index = #session.pieces
    end
    if not index then error("Stored note has no frozen review piece") end
    local file = session.pieces[index].file
    return {
        remote_id = wire.id,
        author = author,
        reply_to = wire.replyTo,
        lines = vim.split(wire.text, "\n", { plain = true }),
        target = {
            path = vim.fs.joinpath(session.root, file.path),
            first = target.first,
            last = target.last,
            scope = target.scope,
            context = vim.deepcopy(target.context),
            anchor = {
                first = target.first,
                last = target.last,
                context = vim.deepcopy(target.context),
            },
            review = {
                session = state.local_id,
                piece = index,
                path = target.path,
                side = target.side,
                source_id = target.sourceId,
            },
        },
    }
end

sync_findings = function(state)
    state.findings = state.findings or {}
    for _, turn in ipairs(state.record.turns) do
        if turn.status == "complete" then
            for _, wire in ipairs(turn.findings or {}) do
                local note = state.findings[wire.id]
                local restored = local_note(state, state.session, wire, "agent")
                if note then
                    note.target = restored.target
                else
                    composer.restore_review({ restored })
                    state.findings[wire.id] = restored
                end
            end
        end
    end
end

local function restore(state, session)
    if state.restored then
        -- Keep local prose and native undo, but bind owners to this attachment's catalogue.
        local retained = {}
        for _, note in ipairs(composer.comments) do
            retained[#retained + 1] = note
        end
        for _, item in ipairs(composer.review_items(state.local_id)) do
            retained[#retained + 1] = item.note
        end
        for _, note in ipairs(retained) do
            local owner = note.target.review
            if owner and owner.session == state.local_id then
                local anchor = note.target.anchor or note.target
                local restored = local_note(state, session, {
                    id = note.remote_id,
                    text = table.concat(note.lines, "\n"),
                    replyTo = note.reply_to,
                    target = {
                        path = owner.path,
                        side = owner.side,
                        sourceId = owner.source_id,
                        first = anchor.first,
                        last = anchor.last,
                        scope = note.target.scope,
                        context = anchor.context,
                    },
                }, note.author)
                note.target.review = restored.target.review
            end
        end
        return
    end
    local notes = {}
    for _, wire in ipairs(state.record.notes) do
        notes[#notes + 1] = local_note(state, session, wire)
    end
    composer.restore_review(notes)
    state.restored = true
end

local function attach(record, pipe, endpoint)
    local state = records[record.id]
    if state and state.busy then
        pipe.close()
        notify("Previous review request is awaiting acknowledgement; retry :ReviewStart")
        return
    end
    if not state then
        serial = serial - 1 -- Editor-local draft identity remains separate from the durable review ID.
        state = { local_id = serial, record = record, baseline = vim.deepcopy(record.notes) }
        records[record.id] = state
    end
    state.client, state.detached, state.busy = pipe, false, false
    state.endpoint, state.reconnecting = endpoint, false
    state.attach_generation = (state.attach_generation or 0) + 1
    state.reconnect_busy = false
    local attachment = state.attach_generation
    local function attached()
        return active == state and not state.detached and state.attach_generation == attachment
    end
    accept(state, record)
    local remote = { local_id = state.local_id }
    function remote.conclude(id, target, presentation, focused, editing_id)
        edit_conclusion(state, id, target, presentation, false, focused, editing_id)
    end
    function remote.reopen(id, target, presentation, focused)
        edit_conclusion(state, id, target, presentation, true, focused)
    end
    function remote.capture(payload, done)
        local started = vim.uv.hrtime()
        local conflicts = 0
        local function attempt()
            if active ~= state or pipe.closed or state.detached then
                done(nil, "Review detached; buffer contents were not handed over")
                return
            end
            if state.busy then
                if vim.uv.hrtime() - started > 10e9 then
                    done(nil, "Review acknowledgement still pending; try composing again")
                else
                    vim.defer_fn(attempt, 50)
                end
                return
            end
            state.busy = true
            local function finish(record, err)
                state.busy = false
                if record then accept(state, record) end
                done(record, err)
                if state.detached then pipe.close() end
            end
            pipe.request("read", state.record.id, nil, function(current, err)
                if not current then
                    finish(nil, err)
                    return
                end
                if active ~= state or state.detached then
                    finish(nil, "Review detached; buffer contents were not handed over")
                    return
                end
                payload.expectedVersion = current.version
                pipe.request("capture", current.id, payload, function(record, capture_err)
                    if
                        not record
                        and capture_err
                        and capture_err:find("Review changed;", 1, true)
                        and conflicts < 2
                    then
                        conflicts = conflicts + 1
                        state.busy = false
                        attempt()
                    else
                        finish(record, capture_err)
                    end
                end)
            end)
        end
        attempt()
    end
    function remote.in_stage(path)
        local stage = active_stage(state.record)
        return not stage or vim.tbl_contains(stage.paths, path)
    end
    function remote.scope_ranges(path, side)
        local record, stage = state.record, active_stage(state.record)
        if not stage then return record.grouping and {} or nil end
        if not stage.unitIds then return nil end
        local ranges = {}
        for _, unit in ipairs(record.grouping.units) do
            if unit.path == path and vim.tbl_contains(stage.unitIds, unit.id) then
                if not unit.side then return nil end
                if unit.side == side then ranges[#ranges + 1] = { unit.first, unit.last } end
            end
        end
        return ranges
    end
    function remote.scope(path)
        local record, covered = state.record, reviewed_paths(state.record)
        local count = vim.tbl_count(covered)
        local stage = active_stage(record)
        if record.grouping then
            local units = reviewed_units(record)
            local purpose = stage and vim.fn.strcharpart(stage.purpose:gsub("[%c]", " "), 0, 60)
            return ("%s · %s · %d/%d units · %d/%d files examined · :ReviewScope"):format(
                purpose and "Group: " .. purpose or "Choose group in Pi /review",
                not stage and "no group selected"
                    or remote.in_stage(path) and "inside group path (ranges in :ReviewScope)"
                    or "OUTSIDE group",
                vim.tbl_count(units),
                #record.grouping.units,
                count,
                #record.files
            )
        end
        if not stage then return ("%d/%d files examined"):format(count, #record.files) end
        local purpose = vim.fn.strcharpart(stage.purpose:gsub("[%c]", " "), 0, 80)
        return ("Piece: %s · %d files · %s · %d/%d examined · :ReviewScope"):format(
            purpose,
            #stage.paths,
            remote.in_stage(path) and "inside piece" or "OUTSIDE piece",
            count,
            #record.files
        )
    end
    function remote.status()
        if pipe.closed then
            return state.reconnecting and "reconnecting to Pi" or "disconnected"
        end
        if state.record.status == "closed" then return "closed" end
        for _, turn in ipairs(state.record.turns) do
            if turn.status == "queued" then
                if turn.kind == "grouping" then return "group proposals queued (not review)" end
                return turn.kind == "conclusion" and "conclusion draft queued" or "agent queued"
            end
            if turn.status == "running" then
                if turn.kind == "grouping" then return "organizing groups (not review)" end
                if turn.kind == "initial" then
                    return state.record.preparation.context and "initial agent review"
                        or "preparing context"
                end
                return turn.kind == "conclusion" and "drafting conclusion" or "agent turn"
            end
        end
        local handoff = latest_handoff(state.record)
        if handoff then
            local labels = {
                queued = "planning queued · waiting for Pi",
                creating = "opening planning in Pi",
                open = "planning in Pi · /review-return",
                returning = "returning from planning",
                returned = "human turn · planning retained",
                error = "human turn · handoff error",
            }
            if labels[handoff.status] then return labels[handoff.status] end
        end
        local collection = (state.record.collections or {})[#(state.record.collections or {})]
        if collection and (collection.status == "frozen" or collection.status == "queued") then
            return "human turn · discussion frozen"
        end
        if collection and collection.status == "delivering" then
            return "human turn · interrupted legacy handoff"
        end
        if collection and collection.status == "error" then
            return "human turn · collection error"
        end
        local turn = state.record.turns[#state.record.turns]
        if turn and turn.status == "error" then return "human turn · agent error" end
        if
            turn
            and turn.kind == "initial"
            and turn.status == "complete"
            and #(turn.findings or {}) == 0
        then
            return "human turn · no agent findings"
        end
        return "human turn"
    end
    function remote.pending()
        local notes = {}
        if pipe.closed or state.record.status == "closed" then return notes end
        -- Only acknowledged turn membership gets a pending reply card; submitting is statusline-only.
        for _, turn in ipairs(state.record.turns) do
            if turn.status == "queued" or turn.status == "running" then
                for _, note in ipairs(turn.notes) do
                    notes[note.id] = true
                end
            end
        end
        return notes
    end
    function remote.activity()
        if pipe.closed or state.record.status == "closed" then return end
        if state.submitting then return "Submitting review" end
        if state.conclusion_requesting then return "Requesting conclusion" end
        for _, turn in ipairs(state.record.turns) do
            if turn.status == "queued" then return "Queued · waiting for Pi" end
            if turn.status == "running" then
                if turn.kind == "initial" then
                    return state.record.preparation.context and "Reviewing frozen changes"
                        or "Preparing context"
                end
                return turn.kind == "conclusion" and "Drafting conclusion" or "Agent replying"
            end
        end
    end
    local function bind_disconnect()
        local lost = pipe
        lost.on_disconnect = function(reason)
            if active ~= state or state.client ~= lost then return end
            -- Session replacement owns a new socket in the same process. Rebind transport only:
            -- never detach review mode, replace local prose/drafts, or repeat a handoff.
            if latest_handoff(state.record) or state.handoff_retry then
                state.reconnecting, state.reconnect_attempts = true, 0
                notify(
                    "Pi session changed/disconnected; reconnecting with review and drafts retained"
                )
            else
                stop_timer(state)
                notify(reason or "Pi disconnected; local notes retained")
            end
            review.refresh()
        end
    end
    local function reconnect()
        if state.reconnect_busy or not state.reconnecting then return end
        state.reconnect_attempts = state.reconnect_attempts + 1
        if state.reconnect_attempts > 30 then
            state.reconnecting = false
            stop_timer(state)
            notify(
                "Pi reconnect unavailable; review/drafts retained. Use :ReviewStop then :ReviewStart to reattach explicitly."
            )
            review.refresh()
            return
        end
        state.reconnect_busy = true
        client.discover(state.record.root, function(items)
            if not attached() then return end
            local selected
            for _, item in ipairs(items or {}) do
                if
                    item.id == state.record.id
                    and item.root == state.record.root
                    and item.endpoint.pid == state.endpoint.pid
                then
                    selected = item
                    break
                end
            end
            if not selected then
                state.reconnect_busy = false
                return
            end
            state.reconnect_client = client.connect(selected.endpoint.socket, function(next_pipe)
                if not attached() then
                    if next_pipe then next_pipe.close() end
                    return
                end
                if not next_pipe then
                    state.reconnect_busy = false
                    state.reconnect_client = nil
                    return
                end
                next_pipe.request("read", state.record.id, nil, function(current)
                    if not attached() then
                        next_pipe.close()
                        return
                    end
                    state.reconnect_busy, state.reconnect_client = false, nil
                    if
                        not current
                        or current.id ~= state.record.id
                        or current.root ~= state.record.root
                        or current.status ~= "open"
                    then
                        next_pipe.close()
                        return
                    end
                    pipe, state.client, state.endpoint = next_pipe, next_pipe, selected.endpoint
                    state.reconnecting = false
                    bind_disconnect()
                    accept(state, current)
                end)
            end)
        end)
    end
    function remote.start(session)
        active = state
        state.session = session
        source.sync(session, record)
        sync_findings(state)
        restore(state, session)
        accept(state, record)
        bind_disconnect()
        state.timer = vim.uv.new_timer()
        state.timer:start(
            1000,
            1000,
            vim.schedule_wrap(function()
                if active ~= state or state.busy then return end
                if pipe.closed then
                    reconnect()
                    return
                end
                state.busy = true
                pipe.request("read", record.id, nil, function(current, err)
                    state.busy = false
                    if current then
                        accept(state, current)
                        if
                            active == state
                            and current.status == "open"
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
        state.session = nil
        if state.reconnect_client then
            state.reconnect_client.close()
            state.reconnect_client = nil
        end
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
    elseif watcher.offer and watcher.offer.id == record.id then
        watcher.hidden[watcher.offer.offer_id] = true
        watcher.offer = nil
    end
end

local function connect_review(item, current, done)
    done = done or function() end
    local connecting
    connecting = client.connect(item.endpoint.socket, function(pipe, connect_err)
        if pending_client == connecting then pending_client = nil end
        if not pipe then
            if current() then notify(connect_err) end
            done(false)
            return
        end
        if not current() then
            pipe.close()
            done(false)
            return
        end
        pending_client = pipe
        pipe.request("read", item.id, nil, function(record, read_err)
            if pending_client == pipe then pending_client = nil end
            if not current() then
                pipe.close()
                done(false)
                return
            end
            if
                not record
                or record.id ~= item.id
                or record.root ~= item.root
                or record.status ~= "open"
            then
                pipe.close()
                notify(read_err or "Review identity, workspace or status changed")
                done(false)
                return
            end
            attach(record, pipe, item.endpoint)
            done(active ~= nil and active.record.id == item.id)
        end)
    end)
    pending_client = connecting
end

---Cached guard only; activation must not replace a retained legacy attachment.
function M.is_busy() return active ~= nil or pending_client ~= nil or watcher.opening end

function M.start()
    if review.is_active() then
        notify("Already in review mode")
        return
    end
    request = request + 1
    local token, cwd, win, buf =
        request, vim.fn.getcwd(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    local function current()
        return request == token
            and not review.is_active()
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
            connect_review(item, current)
        end)
    end)
end

---Passive pairing owns one watcher pipe/timer, separate from active-review sync.
---It never creates reviews, opens a picker, saves prose or starts agent work.
function M.watch()
    if watcher.timer then return end
    local function tick()
        if watcher.stopped then return end
        local root = client.workspace(vim.fn.getcwd())
        if root ~= watcher.root then
            watcher.generation = watcher.generation + 1
            if watcher.pipe then watcher.pipe.close() end
            if watcher.connecting then watcher.connecting.close() end
            watcher.root, watcher.pipe, watcher.connecting, watcher.offer = root, nil, nil, nil
            watcher.busy, watcher.opening = false, false
        end
        if not root or watcher.busy or watcher.opening then return end
        local generation = watcher.generation
        local function current() return not watcher.stopped and watcher.generation == generation end
        if not watcher.pipe or watcher.pipe.closed then
            watcher.busy = true
            client.discover(root, function(items)
                if not current() then return end
                if not items or #items == 0 then
                    watcher.busy = false
                    return
                end
                local endpoint = items[1].endpoint
                for _, item in ipairs(items) do
                    if item.endpoint.socket ~= endpoint.socket then
                        watcher.busy = false -- Never resolve ambiguous ownership by recency.
                        return
                    end
                end
                watcher.connecting = client.connect(endpoint.socket, function(pipe)
                    if not current() then
                        if pipe then pipe.close() end
                        return
                    end
                    watcher.busy, watcher.connecting = false, nil
                    watcher.pipe, watcher.endpoint = pipe, endpoint
                end)
            end)
            return
        end
        local pipe = watcher.pipe
        watcher.busy = true
        pipe.request(
            "watch",
            nil,
            watch_payload(root, offer_available(root) and vim.fn.mode() == "n"),
            function(offers)
                if not current() or watcher.pipe ~= pipe then return end
                watcher.busy = false
                if not offers then
                    pipe.close()
                    return -- Passive failures do not repeatedly interrupt editing.
                end
                local selected
                for _, offer in ipairs(offers) do
                    if
                        type(offer) ~= "table"
                        or type(offer.offerId) ~= "string"
                        or type(offer.reviewId) ~= "string"
                        or type(offer.scope) ~= "string"
                    then
                        pipe.close("Invalid review offer")
                        return
                    end
                    if not watcher.hidden[offer.offerId] then
                        selected = offer
                        break
                    end
                end
                if not selected then
                    watcher.offer = nil
                    return
                end
                if not watcher.offer or watcher.offer.offer_id ~= selected.offerId then
                    watcher.offer = {
                        id = selected.reviewId,
                        offer_id = selected.offerId,
                        scope = selected.scope,
                        root = root,
                        endpoint = watcher.endpoint,
                    }
                end
                local offer = watcher.offer
                if not offer.shown and offer_available(root) and vim.fn.mode() == "n" then
                    offer.shown = true
                    vim.notify(
                        "Frozen review " .. offer.id .. " ready · :ReviewOpen / :ReviewDismiss",
                        vim.log.levels.INFO
                    )
                end
            end,
            root
        )
    end
    watcher.timer = vim.uv.new_timer()
    watcher.timer:start(0, 1000, vim.schedule_wrap(tick))
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = vim.api.nvim_create_augroup("ParleyPairing", { clear = true }),
        once = true,
        callback = function()
            watcher.stopped = true
            watcher.timer:stop()
            watcher.timer:close()
            if watcher.pipe then watcher.pipe.close() end
            if watcher.connecting then watcher.connecting.close() end
        end,
    })
end

function M.open_offer()
    local offer, pipe = watcher.offer, watcher.pipe
    if not offer or not pipe or pipe.closed then
        notify("No connected review offer; use :ReviewStart for recovery")
        return
    end
    if watcher.opening or not offer_available(offer.root) then
        notify(
            "Open requires an ordinary workspace source window with no active review or composer"
        )
        return
    end
    request = request + 1
    local token, win, buf, cwd =
        request, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(), vim.fn.getcwd()
    local tick, cursor = vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_win_get_cursor(win)
    local function current()
        return request == token
            and watcher.offer == offer
            and watcher.pipe == pipe
            and vim.fn.getcwd() == cwd
            and offer_available(offer.root)
            and vim.api.nvim_get_current_win() == win
            and vim.api.nvim_get_current_buf() == buf
            and vim.api.nvim_buf_get_changedtick(buf) == tick
            and vim.fn.mode() == "n"
            and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
    end
    watcher.opening = true
    -- Reaffirm eligibility at the explicit action; a heartbeat may predate it.
    pipe.request("watch", nil, watch_payload(offer.root, true), function(registered, register_err)
        if not registered or not current() then
            watcher.opening = false
            if register_err then notify(register_err) end
            return
        end
        pipe.request("open-offer", offer.id, { offerId = offer.offer_id }, function(record, err)
            if not record or not current() then
                watcher.opening = false
                if err then notify(err) end
                return
            end
            connect_review(offer, current, function(opened)
                watcher.opening = false
                if opened then
                    watcher.hidden[offer.offer_id] = true
                    if watcher.offer == offer then watcher.offer = nil end
                end
            end)
        end)
    end, offer.root)
end

function M.dismiss_offer()
    local offer, pipe = watcher.offer, watcher.pipe
    if not offer then
        notify("No review offer")
        return
    end
    watcher.hidden[offer.offer_id], watcher.offer = true, nil
    request = request + 1 -- An in-flight Open cannot supersede Dismiss.
    if pipe and not pipe.closed then
        pipe.request("dismiss-offer", offer.id, { offerId = offer.offer_id }, function(_, err)
            if err then notify("Offer hidden locally; " .. err .. ". Frozen review retained.") end
        end)
    end
    vim.notify(
        "Review offer dismissed; frozen review retained for :ReviewStart",
        vim.log.levels.INFO
    )
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

---Read-only scope/coverage inspection; never selects a piece or requests generation.
function M.scope()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    local record, covered = state.record, reviewed_paths(state.record)
    local stage = active_stage(record)
    local lines = { "Frozen review " .. record.id, record.scope }
    if stage then
        lines[#lines + 1] = "Current group: " .. stage.id .. " · " .. stage.purpose
        if stage.unitIds then
            lines[#lines + 1] = "Only these original source units are in this group:"
            for _, unit in ipairs(record.grouping.units) do
                if vim.tbl_contains(stage.unitIds, unit.id) then
                    lines[#lines + 1] = ("  %s: %s%s"):format(
                        unit.id,
                        unit.path,
                        unit.side and (":%s:%d-%d"):format(unit.side, unit.first, unit.last)
                            or " (whole file)"
                    )
                end
            end
            lines[#lines + 1] = "Advisory dependencies: "
                .. table.concat(stage.dependencies or {}, ", ")
        else
            for _, path in ipairs(stage.paths) do
                lines[#lines + 1] = "  " .. path .. " (whole file)"
            end
        end
        lines[#lines + 1] =
            "All other source units/ranges are excluded; ordinary editing is unrestricted."
    else
        lines[#lines + 1] = "No narrower piece selected."
    end
    lines[#lines + 1] = "Agent coverage (not approval, discussion resolution or proof of fixes):"
    for _, file in ipairs(record.files) do
        lines[#lines + 1] = (covered[file.path] and "  examined: " or "  unexamined: ")
            .. file.path
    end
    if record.grouping then
        local units = reviewed_units(record)
        lines[#lines + 1] = "Original unit coverage:"
        for _, unit in ipairs(record.grouping.units) do
            lines[#lines + 1] = ("  %s %s: %s%s"):format(
                units[unit.id] and "examined" or "unexamined",
                unit.id,
                unit.path,
                unit.side and (":%s:%d-%d"):format(unit.side, unit.first, unit.last)
                    or " (whole file)"
            )
        end
        lines[#lines + 1] = "Stored cross-group questions (not reviewed evidence):"
        for _, summary in ipairs(record.grouping.summaries) do
            for _, question in ipairs(summary.questions) do
                lines[#lines + 1] = "  " .. summary.unitId .. ": " .. question
            end
        end
        for _, limitation in ipairs(record.grouping.limitations) do
            lines[#lines + 1] = limitation
        end
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

function M.submit()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    -- Auxiliary drafts can exist even when no current discussion notes remain.
    if composer.has_drafts(state.local_id) then
        notify("Save or discard unfinished drafts before submitting")
        return
    end
    for _, item in ipairs(composer.review_items(state.local_id)) do
        if item.state ~= "saved" then
            notify("Save or discard unfinished drafts before submitting")
            return
        end
    end
    if state.submitting then
        notify("Review submission is awaiting acknowledgement")
        return
    end
    state.submitting = true
    review.refresh()
    save(state, function(ok, err)
        if not ok then
            state.submitting = false
            if active == state then review.refresh() end
            notify(err)
            return
        end
        if active ~= state then
            state.submitting = false
            return
        end
        state.busy = true
        -- Keep the turn ID after uncertain delivery; the server independently deduplicates it.
        local retry = state.turn_id ~= nil
        state.turn_id = state.turn_id or client.id()
        local turn_id = state.turn_id
        local latest
        for _, turn in ipairs(state.record.turns) do
            if turn.kind ~= "conclusion" and turn.kind ~= "grouping" then latest = turn end
        end
        local kind = latest and latest.kind == "initial" and latest.status == "error" and "initial"
            or "discussion"
        state.client.request(
            "submit",
            state.record.id,
            { expectedVersion = state.record.version, turnId = state.turn_id, kind = kind },
            function(record, submit_err)
                state.busy = false
                state.submitting = false
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
                    if active == state then review.refresh() end
                end
                if state.detached then state.client.close() end
            end
        )
    end, true)
end

---Compatibility action: freeze all threads without switching Pi or starting model work.
function M.collect()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    if unfinished(state) then
        notify("Save or discard unfinished drafts before freezing discussion")
        return
    end
    save(state, function(ok, err)
        if not ok then
            notify(err)
            return
        end
        if active ~= state then return end
        state.collection_retry = state.collection_retry or { collectionId = client.id() }
        mutate(state, "collect", state.collection_retry, function(saved, collect_err, acknowledged)
            if saved or acknowledged then state.collection_retry = nil end
            if saved then
                vim.notify(
                    "Parley discussion frozen; Pi conversation unchanged. No fixes authorized."
                )
            else
                notify(collect_err)
            end
        end)
    end, true)
end

---Review done freezes every thread and queues planning in one acknowledged operation.
---It neither closes the review nor grants implementation authority.
function M.finish()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    if unfinished(state) then
        notify("Save or discard unfinished drafts before handing over the review")
        return
    end
    save(state, function(ok, err)
        if not ok then
            notify(err)
            return
        end
        if active ~= state then return end
        -- Preserve both identities after uncertain delivery; retries never freeze a newer bundle.
        state.handoff_retry = state.handoff_retry
            or { collectionId = client.id(), handoffId = client.id() }
        mutate(state, "finish", state.handoff_retry, function(saved, finish_err, acknowledged)
            if saved or acknowledged then state.handoff_retry = nil end
            if saved then
                vim.notify(
                    "Parley review handed over; Pi opens planning once settled. Review retained; no fixes authorized."
                )
            else
                notify(finish_err)
            end
        end)
    end, true)
end

function M.conclusions()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    local history = state.record.conclusions or {}
    if #history == 0 then
        notify("No conclusion history")
        return
    end
    vim.ui.select(history, {
        prompt = "Durable conclusion history (read-only):",
        format_item = function(item)
            return item.createdAt
                .. " · "
                .. item.threadId
                .. " · "
                .. (item.decision or item.state)
        end,
    }, function(item)
        if not item or active ~= state then return end
        vim.notify(
            item.summary .. "\nThread: " .. item.threadId .. "\nConclusion: " .. item.id,
            vim.log.levels.INFO
        )
    end)
end

function M.close()
    local state = active
    if not state then
        notify("No attached review")
        return
    end
    if composer.has_drafts(state.local_id) then
        notify("Save or discard unfinished drafts before closing")
        return
    end
    vim.ui.select(
        { "Close review (retain contents)", "Cancel" },
        { prompt = "Close this review, not delete it?" },
        function(choice)
            if active ~= state or choice ~= "Close review (retain contents)" then return end
            if composer.has_drafts(state.local_id) then
                notify("Save or discard unfinished drafts before closing")
                return
            end
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
