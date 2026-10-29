---Explicit request coordination on the already paired socket. This module owns
---one bounded upload/result download, not conversations, pairing or artifact I/O.
---A lost acknowledgment is never retried or treated as accepted history.
local bridge = require("parley.bridge")
local client = require("parley.client")
local workspace = require("parley.workspace")
local M = {}
local chunk_bytes = 16 * 1024
local max_batch_bytes = 4 * 1024 * 1024
local actions = {
    info = "review-info",
    begin = "review-batch-begin",
    chunk = "review-batch-chunk",
    commit = "review-batch-commit",
    result = "review-result-begin",
    result_chunk = "review-result-chunk",
    receipt = "review-result-receipt",
}
local pending
-- Latest durably acknowledged review request only, retained across disconnect.
-- Identity is frozen at acceptance; result caching never depends on note import.
local latest_report
---@class ParleyInteraction.Status
---@field phase 'idle'|'checking'|'capturing'|'uploading'|'awaiting-acceptance'|'accepted'|'downloading'|'applying'|'completed'|'failed'|'cancelled'|'wrapping'|'review-completed'
---@field accepted boolean Durable acceptance only, not publication/application.
---@field batchId? string
---@field reviewId? string
---@field error? string
---@field application? 'applied'|'incompatible' Local acceptance, not a Pi receipt.
---@field outcome? table Validated correlated outcome, distinct from acceptance.
---@field activity? 'starting'|'working'|'settling' Cached acknowledged-request activity only.
---@field results? { applied: integer, incompatible: integer, unplaced: integer } Local conversation application facts.
---@field receipts? 'pending'|'recorded'|'not-required'|'unknown' Separate durable receipt acknowledgment.
---@type ParleyInteraction.Status
local status = { phase = "idle", accepted = false }

---Cached copy only. Pre-ack phases describe transport, never model activity.
---@return ParleyInteraction.Status
function M.status()
    return vim.deepcopy(status)
end

local function publish(value)
    if vim.deep_equal(status, value) then
        return
    end
    status = value
    if
        latest_report
        and value.batchId == latest_report.requestId
        and value.reviewId == latest_report.reviewId
    then
        latest_report.status = vim.deepcopy(value)
    end
    vim.api.nvim_exec_autocmds("User", { pattern = "ParleyRequestChanged", data = M.status() })
end

local function fields(value, names)
    if type(value) ~= "table" or vim.islist(value) then
        return false
    end
    local count = 0
    for _ in pairs(value) do
        count = count + 1
    end
    if count ~= #names then
        return false
    end
    for _, name in ipairs(names) do
        if value[name] == nil then
            return false
        end
    end
    return true
end

---Copied cached evidence only; opening a view never retrieves/replays work.
function M.request_report()
    return latest_report and vim.deepcopy(latest_report) or nil
end

local function discovery(info)
    return fields(info, { "reviewId", "preparationId", "activeRequestId", "busy", "ended" })
        or (
            fields(
                info,
                { "reviewId", "preparationId", "activeRequestId", "busy", "ended", "workflow" }
            ) and info.workflow == "parley"
        )
end

local function identifier(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 128
        and value:match("^[a-zA-Z0-9_-]+$") ~= nil
end

local function timestamp(value)
    return type(value) == "number" and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end

---Explicitly capture and submit once. No queue, uncertain replay or source/UI
---navigation. Durable acceptance is attested by the host's digest of the entire
---byte sequence, not by a staging acknowledgment or a locally fabricated marker.
---@param kind 'ask'|'investigate'
---@param instructions? string
function M.submit(kind, instructions, workflow)
    if kind == "investigate" and workspace.workflow() == "parley" then
        vim.notify(
            "Parley: investigation is only available in the review workflow",
            vim.log.levels.ERROR
        )
        return
    end
    workflow = workflow or "review"
    if pending then
        vim.notify("Parley: request transport is busy; nothing queued", vim.log.levels.WARN)
        return
    end
    local pairing = bridge.status()
    if not workspace.is_active() or not pairing.connected or not pairing.binding then
        vim.notify(
            "Parley: use :Parley start with the matching workflow to pair and activate first",
            vim.log.levels.ERROR
        )
        return
    end
    local endpoint = assert(pairing.binding)
    local batch_id = client.id()
    local request_name = workflow == "parley" and "Implementation turn"
        or kind == "investigate" and "Investigation"
        or "Review request"
    local review_id, preparation_id, digest
    local operation = {}
    pending = operation
    local accepted = false
    local application
    local outcome, results, receipt_status, acceptance_error
    local request_capture
    local poll_timer, group
    local function cleanup()
        local failure
        local function finish(action)
            local ok, err = pcall(action)
            if not ok and not failure then
                failure = tostring(err)
            end
        end
        local timer, owned_group = poll_timer, group
        if request_capture then
            finish(function()
                workspace.request_activity(request_capture, nil)
            end)
        end
        poll_timer, group = nil, nil
        if timer then
            finish(function()
                timer:stop()
            end)
            finish(function()
                timer:close()
            end)
        end
        if owned_group then
            finish(function()
                vim.api.nvim_del_augroup_by_id(owned_group)
            end)
        end
        return failure
    end
    local function fail(err)
        if pending ~= operation then
            -- A completion hook may already have started another explicit request.
            -- Report the old callback failure without clearing/replacing its owner.
            vim.notify("Parley: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        pending = nil
        local cleanup_failure = cleanup()
        if cleanup_failure then
            err = tostring(err) .. "; cleanup: " .. cleanup_failure
        end
        publish({
            phase = "failed",
            batchId = batch_id,
            reviewId = review_id,
            accepted = accepted,
            application = application,
            error = tostring(err),
            outcome = outcome,
            results = results,
            receipts = receipt_status == "pending" and "unknown" or receipt_status,
        })
        local context = request_name .. " error: "
        if outcome then
            context = request_name .. " " .. outcome.status .. ", but result delivery failed: "
        elseif accepted then
            context = request_name .. " accepted, but result delivery failed: "
        end
        vim.notify("Parley: " .. context .. tostring(err), vim.log.levels.ERROR)
    end
    local function phase(name, activity)
        if request_capture then
            workspace.request_activity(request_capture, name, activity)
        end
        publish({
            phase = name,
            batchId = batch_id,
            reviewId = review_id,
            accepted = accepted,
            application = application,
            outcome = outcome,
            results = results,
            receipts = receipt_status,
            activity = activity,
            error = acceptance_error,
        })
    end
    -- Protect asynchronous application callbacks too: an encoding, validation or
    -- host-hook failure must clear the coordinator, not leave a permanent busy UI.
    local function send(action, payload, callback)
        if pending ~= operation then
            return
        end
        local current = bridge.status()
        if
            not current.connected
            or not current.binding
            or not workspace.is_active()
            or current.binding.workspace ~= endpoint.workspace
            or current.binding.sessionId ~= endpoint.sessionId
            or current.binding.instanceId ~= endpoint.instanceId
            or current.editor_id ~= pairing.editor_id
        then
            fail("Request owner disconnected or changed; evidence retained without replay")
            return
        end
        bridge.request(action, review_id, payload, function(result, err)
            if pending ~= operation then
                return
            end
            if err then
                fail(err)
                return
            end
            local ok, failure = pcall(callback, result)
            if not ok then
                fail(failure)
            end
        end)
    end
    local function require_condition(value, message)
        if not value then
            error(message, 0)
        end
    end
    local function validate_staging(result, index)
        require_condition(
            fields(
                result,
                index == nil and { "reviewId", "batchId", "status" }
                    or { "reviewId", "batchId", "status", "index" }
            )
                and result.reviewId == review_id
                and result.batchId == batch_id
                and result.status == "staging"
                and (index == nil or result.index == index),
            "Invalid batch staging correlation; nothing replayed"
        )
    end
    local function deliver(capture)
        -- Only this acknowledged request owns polling. Stop/disconnect ends it;
        -- pairing health, reconnection and idle never start result/model work.
        poll_timer = assert(vim.uv.new_timer())
        group = vim.api.nvim_create_augroup("ParleyRequestDelivery", { clear = true })
        vim.api.nvim_create_autocmd("User", {
            group = group,
            pattern = { "ParleyBridgeChanged", "ParleyReviewStopped" },
            callback = function(event)
                if event.match == "ParleyReviewStopped" or not bridge.status().connected then
                    fail("Result delivery stopped; durable evidence retained, no automatic replay")
                end
            end,
        })
        vim.api.nvim_create_autocmd("VimLeavePre", {
            group = group,
            callback = function()
                pending = nil
                cleanup()
            end,
        })
        local function apply(bytes, download)
            ---@type unknown
            local result = vim.json.decode(bytes)
            local envelope = fields(
                result,
                { "reviewId", "requestId", "sessionId", "outcome", "conversations" }
            ) or fields(
                result,
                { "reviewId", "requestId", "sessionId", "outcome", "conversations", "report" }
            )
            require_condition(
                envelope
                    and result.reviewId == review_id
                    and result.requestId == batch_id
                    and (result.sessionId == vim.NIL or identifier(result.sessionId)),
                "Invalid result identity/envelope"
            )
            local completion = result.outcome
            require_condition(
                fields(completion, { "id", "status", "detail", "createdAt" })
                    and identifier(completion.id)
                    and timestamp(completion.createdAt)
                    and (completion.status == "completed" or completion.status == "failed" or completion.status == "cancelled")
                    and (completion.detail == vim.NIL or (type(completion.detail) == "string" and completion.detail:find(
                        "%S"
                    ) and #completion.detail <= 32768))
                    and (completion.status == "completed" or completion.detail ~= vim.NIL),
                "Invalid request outcome"
            )
            require_condition(
                type(result.conversations) == "table" and vim.islist(result.conversations),
                "Invalid result conversation array"
            )
            local delivered_messages, delivered_findings = 0, 0
            for _, conversation in ipairs(result.conversations) do
                require_condition(
                    type(conversation) == "table"
                        and type(conversation.messages) == "table"
                        and vim.islist(conversation.messages)
                        and conversation.id ~= completion.id,
                    "Invalid result conversation/messages"
                )
                delivered_messages = delivered_messages + #conversation.messages
                if conversation.new == true then
                    delivered_findings = delivered_findings + 1
                end
                for _, message in ipairs(conversation.messages) do
                    require_condition(
                        type(message) == "table"
                            and message.id ~= completion.id
                            and identifier(result.sessionId)
                            and message.origin == "pi/" .. result.sessionId,
                        "Publication does not identify the recorded review session"
                    )
                end
            end
            if result.report ~= nil then
                local projection = result.report
                require_condition(
                    workflow == "review"
                        and fields(
                            projection,
                            { "publishedMessages", "newFindings", "explanation" }
                        )
                        and timestamp(projection.publishedMessages)
                        and timestamp(projection.newFindings)
                        and projection.newFindings <= projection.publishedMessages
                        and projection.publishedMessages == delivered_messages
                        and projection.newFindings == delivered_findings
                        and (
                            projection.explanation == vim.NIL
                            or (
                                type(projection.explanation) == "string"
                                and #projection.explanation <= 16 * 1024
                                and projection.explanation:find("%S")
                                and not projection.explanation:find("[%z\1-\8\11-\31\127]")
                            )
                        ),
                    "Invalid bounded request report projection"
                )
            end
            if workflow == "review" then
                local current = bridge.status()
                require_condition(
                    current.binding
                        and current.binding.workspace == endpoint.workspace
                        and current.connected
                        and current.binding.sessionId == endpoint.sessionId
                        and current.binding.instanceId == endpoint.instanceId
                        and current.editor_id == pairing.editor_id
                        and workspace.is_active()
                        and workspace.review_id() == review_id
                        and latest_report
                        and latest_report.workspace == endpoint.workspace
                        and latest_report.sessionId == endpoint.sessionId
                        and latest_report.requestId == batch_id
                        and latest_report.reviewId == review_id,
                    "Report owner changed; no retargeting"
                )
                latest_report.projection = result.report and vim.deepcopy(result.report) or nil
                latest_report.reviewerSessionId = result.sessionId
            end
            outcome = completion
            phase("applying")
            local facts, failure = workspace.import_results(capture, result.conversations)
            if not facts then
                error("Result import rejected without retargeting: " .. tostring(failure), 0)
            end
            workspace.request_activity(capture, nil)
            results = { applied = 0, incompatible = 0, unplaced = 0 }
            local published_messages = 0
            for _, fact in ipairs(facts) do
                published_messages = published_messages + #fact.messageIds
                results[fact.status] = results[fact.status] + 1
                if fact.placement == "unplaced" then
                    results.unplaced = results.unplaced + 1
                end
            end
            receipt_status = #facts == 0 and "not-required" or "pending"
            local function finish()
                if #facts > 0 then
                    receipt_status = "recorded"
                end
                local cleanup_failure = cleanup()
                if cleanup_failure then
                    fail(
                        "Result application/receipts completed, but delivery cleanup failed: "
                            .. cleanup_failure
                    )
                    return
                end
                pending = nil
                publish({
                    phase = completion.status,
                    batchId = batch_id,
                    reviewId = review_id,
                    accepted = true,
                    application = application,
                    outcome = outcome,
                    results = results,
                    receipts = receipt_status,
                    error = completion.status ~= "completed" and completion.detail
                        or acceptance_error,
                })
                local message = ("Parley: %s %s: "):format(request_name, completion.status)
                local level = vim.log.levels.INFO
                if published_messages == 0 then
                    message = message .. "no review messages published."
                else
                    message = message
                        .. ("%d review message(s) published."):format(published_messages)
                end
                if results.incompatible > 0 or results.unplaced > 0 then
                    message = message
                        .. (" %d conversation(s) incompatible; %d unplaced."):format(
                            results.incompatible,
                            results.unplaced
                        )
                    level = vim.log.levels.WARN
                end
                if acceptance_error then
                    message = message
                        .. " Local submission history is incompatible; evidence retained."
                    level = vim.log.levels.WARN
                end
                if completion.status ~= "completed" then
                    message = message .. " " .. completion.detail
                    level = vim.log.levels.WARN
                end
                vim.notify(message, level)
            end
            local function receipt(index, offset)
                local fact = facts[index]
                if not fact then
                    finish()
                    return
                end
                local ids = {}
                for message = offset, math.min(offset + 127, #fact.messageIds) do
                    ids[#ids + 1] = fact.messageIds[message]
                end
                local receipt_id = client.id()
                send(actions.receipt, {
                    requestId = batch_id,
                    downloadId = download.downloadId,
                    digest = download.digest,
                    receiptId = receipt_id,
                    messageIds = ids,
                    status = fact.status,
                    placement = fact.placement,
                    detail = fact.detail,
                }, function(recorded)
                    require_condition(
                        fields(
                            recorded,
                            { "reviewId", "requestId", "downloadId", "receiptId", "status" }
                        )
                            and recorded.reviewId == review_id
                            and recorded.requestId == batch_id
                            and recorded.downloadId == download.downloadId
                            and recorded.receiptId == receipt_id
                            and recorded.status == "recorded",
                        "Invalid application receipt acknowledgment; no replay"
                    )
                    if offset + #ids > #fact.messageIds then
                        receipt(index + 1, 1)
                    else
                        receipt(index, offset + #ids)
                    end
                end)
            end
            -- Receipt correlation uses the verified transport metadata, never
            -- mutable presentation state or a second canonical result history.
            return receipt
        end
        local check
        check = function()
            send(actions.result, { requestId = batch_id }, function(result)
                require_condition(
                    type(result) == "table"
                        and result.reviewId == review_id
                        and result.requestId == batch_id,
                    "Invalid result discovery correlation"
                )
                if result.status == "pending" then
                    require_condition(
                        fields(result, { "reviewId", "requestId", "status", "activity" })
                            and (
                                result.activity == "starting"
                                or result.activity == "working"
                                or result.activity == "settling"
                            ),
                        "Invalid acknowledged-request activity"
                    )
                    phase("accepted", result.activity)
                    poll_timer:start(
                        500,
                        0,
                        vim.schedule_wrap(function()
                            if pending == operation then
                                local ok, failure = pcall(check)
                                if not ok then
                                    fail(failure)
                                end
                            end
                        end)
                    )
                    return
                end
                require_condition(
                    fields(result, {
                        "reviewId",
                        "requestId",
                        "status",
                        "downloadId",
                        "digest",
                        "bytes",
                        "parts",
                    })
                        and result.status == "ready"
                        and identifier(result.downloadId)
                        and type(result.digest) == "string"
                        and #result.digest == 64
                        and result.digest:match("^[a-f0-9]+$")
                        and timestamp(result.bytes)
                        and result.bytes > 0
                        and result.bytes <= 16 * 1024 * 1024
                        and result.parts == math.ceil(result.bytes / chunk_bytes),
                    "Invalid bounded result download"
                )
                phase("downloading")
                local chunks = {}
                local function chunk(index)
                    if index == result.parts then
                        local bytes = table.concat(chunks)
                        require_condition(
                            #bytes == result.bytes and vim.fn.sha256(bytes) == result.digest,
                            "Incomplete/mismatched result bytes; nothing applied"
                        )
                        local receipts = apply(bytes, result)
                        receipts(1, 1)
                        return
                    end
                    send(
                        actions.result_chunk,
                        { requestId = batch_id, downloadId = result.downloadId, index = index },
                        function(part)
                            local size = math.min(chunk_bytes, result.bytes - index * chunk_bytes)
                            require_condition(
                                fields(
                                    part,
                                    { "reviewId", "requestId", "downloadId", "index", "hex" }
                                )
                                    and part.reviewId == review_id
                                    and part.requestId == batch_id
                                    and part.downloadId == result.downloadId
                                    and part.index == index
                                    and type(part.hex) == "string"
                                    and #part.hex == size * 2
                                    and part.hex:match("^[a-f0-9]+$"),
                                "Invalid result chunk; nothing replayed/applied"
                            )
                            chunks[#chunks + 1] = part.hex:gsub("..", function(byte)
                                return string.char(tonumber(byte, 16))
                            end)
                            chunk(index + 1)
                        end
                    )
                end
                chunk(0)
            end)
        end
        check()
    end

    local function start()
        phase("checking")
        send(actions.info, {}, function(info)
            require_condition(
                discovery(info)
                    and (info.workflow or "review") == workflow
                    and identifier(info.reviewId)
                    and identifier(info.preparationId)
                    and (info.activeRequestId == vim.NIL or identifier(info.activeRequestId))
                    and type(info.busy) == "boolean"
                    and type(info.ended) == "boolean",
                "Invalid review discovery response"
            )
            require_condition(
                info.activeRequestId == vim.NIL and not info.busy,
                "Review is busy; request was not captured or queued"
            )
            require_condition(
                not info.ended,
                "Review is completed. Use /parley review in Pi, then :Parley start review to select the new review."
            )
            local selected, selection_error = workspace.select_review(info.reviewId, info.workflow)
            require_condition(selected, selection_error)
            review_id, preparation_id = info.reviewId, info.preparationId
            phase("capturing")
            local capture, failure = workspace.capture_request({
                id = batch_id,
                kind = kind,
                instructions = instructions,
                editor_id = pairing.editor_id,
                author = vim.env.USER or pairing.editor_id,
            })
            if not capture then
                error(failure, 0)
            end
            require_condition(
                capture.workspace == endpoint.workspace
                    and capture.sessionId == endpoint.sessionId
                    and capture.editorId == pairing.editor_id,
                "Capture no longer matches the verified pairing"
            )
            request_capture = capture
            local bytes = vim.json.encode(capture)
            require_condition(
                #bytes > 0 and #bytes <= max_batch_bytes,
                "Captured batch exceeds 4 MiB; no upload or truncation performed"
            )
            digest = vim.fn.sha256(bytes)
            local parts = math.ceil(#bytes / chunk_bytes)
            local function commit()
                phase("awaiting-acceptance")
                send(actions.commit, { batchId = batch_id, digest = digest }, function(result)
                    require_condition(
                        fields(result, {
                            "reviewId",
                            "requestId",
                            "digest",
                            "preparationId",
                            "createdAt",
                            "status",
                        })
                            and result.reviewId == review_id
                            and result.requestId == batch_id
                            and result.digest == digest
                            and result.preparationId == preparation_id
                            and timestamp(result.createdAt)
                            and result.status == "accepted",
                        "Invalid durable acceptance; delivery may be unknown, no replay"
                    )
                    accepted = true
                    if workflow == "review" then
                        local scope = {}
                        for index, submission in ipairs(capture.request.submissions) do
                            local anchor = capture.conversations[index].anchor
                            scope[#scope + 1] = {
                                conversationId = submission.conversationId,
                                path = anchor.path,
                                side = anchor.side,
                                first = anchor.first,
                                last = anchor.last,
                                version = submission.version,
                                messages = #submission.messageIds,
                            }
                        end
                        latest_report = {
                            workspace = endpoint.workspace,
                            sessionId = endpoint.sessionId,
                            reviewId = review_id,
                            requestId = batch_id,
                            kind = capture.request.kind,
                            instructions = capture.request.instructions,
                            acceptedAt = result.createdAt,
                            scope = scope,
                        }
                    end
                    -- The exact digest attests all copied submissions, including their
                    -- versions, parent tips and message IDs. Avoid echoing a potentially
                    -- multi-megabyte request into a single acknowledgment frame.
                    local record = vim.deepcopy(capture.request)
                    record.type, record.reviewId, record.preparationId, record.createdAt =
                        "request", review_id, preparation_id, result.createdAt
                    local applied, apply_failure = workspace.accept_request(capture, record)
                    application = applied and "applied" or "incompatible"
                    if not applied then
                        acceptance_error = "Durably accepted, but local history is incompatible: "
                            .. tostring(apply_failure)
                        vim.notify(
                            "Parley: "
                                .. acceptance_error
                                .. ". Evidence retained; no retargeting.",
                            vim.log.levels.WARN
                        )
                    end
                    workspace.request_activity(capture, "accepted")
                    publish({
                        phase = "accepted",
                        accepted = true,
                        application = application,
                        batchId = batch_id,
                        reviewId = review_id,
                    })
                    if applied then
                        vim.notify("Parley: " .. request_name .. " accepted.", vim.log.levels.INFO)
                    end
                    deliver(capture)
                end)
            end
            local function chunk(index)
                if index == parts then
                    commit()
                    return
                end
                local data = bytes:sub(index * chunk_bytes + 1, (index + 1) * chunk_bytes)
                local hex = data:gsub(".", function(byte)
                    return ("%02x"):format(byte:byte())
                end)
                send(
                    actions.chunk,
                    { batchId = batch_id, index = index, hex = hex },
                    function(result)
                        validate_staging(result, index)
                        chunk(index + 1)
                    end
                )
            end
            phase("uploading")
            send(actions.begin, {
                batchId = batch_id,
                digest = digest,
                bytes = #bytes,
                parts = parts,
                preparationId = preparation_id,
            }, function(result)
                validate_staging(result)
                chunk(0)
            end)
        end)
    end
    local ok, failure = pcall(start)
    if not ok then
        fail(failure)
    end
end

---Capture-free selection after explicit :Parley start. Select an initialized fresh
---review before the user composes its notes, not by migrating old notes on Ask.
function M.select_prepared(workflow)
    workflow = workflow or "review"
    if pending then
        vim.notify("Parley: request active; review selection left unchanged", vim.log.levels.WARN)
        return
    end
    local window, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    bridge.request(actions.info, nil, {}, function(info, err)
        if pending or not workspace.is_active() then
            return
        end
        if err then
            vim.notify("Parley: paired; review unavailable: " .. err, vim.log.levels.INFO)
            return
        end
        if
            not discovery(info)
            or (info.workflow or "review") ~= workflow
            or not identifier(info.reviewId)
            or not identifier(info.preparationId)
            or not (info.activeRequestId == vim.NIL or identifier(info.activeRequestId))
            or type(info.busy) ~= "boolean"
            or type(info.ended) ~= "boolean"
        then
            vim.notify("Parley: invalid review response; nothing selected", vim.log.levels.ERROR)
            return
        end
        if
            not vim.api.nvim_win_is_valid(window)
            or vim.api.nvim_get_current_win() ~= window
            or vim.api.nvim_win_get_buf(window) ~= buffer
        then
            vim.notify(
                "Parley: source focus changed; run :Parley start with the matching workflow again",
                vim.log.levels.WARN
            )
            return
        end
        local selected, failure = workspace.select_review(info.reviewId, info.workflow)
        if not selected then
            vim.notify("Parley: " .. failure, vim.log.levels.ERROR)
            return
        end
        vim.notify(
            workflow == "parley"
                    and "Parley: implementation ready — :Parley submit, :Parley thread resolve, :Parley done"
                or info.ended and "Parley: review already completed; :Parley done shows its summary"
                or info.busy and "Parley: paired; review work is active"
                or "Parley: review ready — :Parley investigate <instructions> or :Parley submit",
            vim.log.levels.INFO
        )
    end)
end

---Explicit wrap-up only; a disconnected or lost response is never retried.
---A later explicit Done can read the same saved summary without rerunning it.
---@param requested_review? string Older retained review ID, not a request to rebind.
function M.done(requested_review, workflow)
    workflow = workflow or "review"
    if workspace.review_id() and workspace.workflow() ~= workflow then
        vim.notify(
            "Parley: completion command does not match the selected workflow",
            vim.log.levels.ERROR
        )
        return
    end
    if pending then
        vim.notify("Parley: request transport is busy; nothing queued", vim.log.levels.WARN)
        return
    end
    local pairing = bridge.status()
    if not workspace.is_active() or not pairing.connected or not pairing.binding then
        vim.notify(
            "Parley: use :Parley start with the matching workflow to pair and activate first",
            vim.log.levels.ERROR
        )
        return
    end
    if requested_review and not identifier(requested_review) then
        vim.notify("Parley: invalid review ID", vim.log.levels.ERROR)
        return
    end
    local endpoint = assert(pairing.binding)
    local review_id = requested_review or workspace.review_id()
    local finish_id = client.id()
    local operation = {}
    local window, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    pending = operation
    local timer, group
    local polling, durably_completed = false, false
    local function cleanup()
        local owned_timer, owned_group = timer, group
        timer, group = nil, nil
        local failure
        for _, action in ipairs({
            function()
                if owned_timer then
                    owned_timer:stop()
                    owned_timer:close()
                end
            end,
            function()
                if owned_group then
                    vim.api.nvim_del_augroup_by_id(owned_group)
                end
            end,
        }) do
            local ok, err = pcall(action)
            if not ok and not failure then
                failure = tostring(err)
            end
        end
        if pending == operation then
            pending = nil
        end
        return failure
    end
    local function fail(err)
        local cleanup_error = cleanup()
        local detail = tostring(err) .. (cleanup_error and ("; cleanup: " .. cleanup_error) or "")
        if durably_completed then
            vim.notify(
                "Parley: review completed, but presentation failed: "
                    .. detail
                    .. ". Run :Parley done again to view the saved summary.",
                vim.log.levels.ERROR
            )
            return
        end
        publish({ phase = "failed", accepted = false, reviewId = review_id, error = detail })
        vim.notify(
            "Parley: "
                .. detail
                .. ". Completion may be unknown; inspect evidence or explicitly run :Parley done again. No automatic replay.",
            vim.log.levels.ERROR
        )
    end
    local function send(action, data, callback)
        if pending ~= operation then
            return
        end
        local current = bridge.status()
        if
            not current.connected
            or not current.binding
            or not workspace.is_active()
            or current.binding.workspace ~= endpoint.workspace
            or current.binding.sessionId ~= endpoint.sessionId
            or current.binding.instanceId ~= endpoint.instanceId
            or current.editor_id ~= pairing.editor_id
        then
            fail("Wrap-up delivery owner changed")
            return
        end
        bridge.request(action, review_id, data, function(result, err)
            if pending ~= operation then
                return
            end
            if err then
                fail(err)
                return
            end
            local ok, failure = pcall(callback, result)
            if not ok then
                fail(failure)
            end
        end)
    end
    local function observe(result)
        if
            not fields(result, {
                "reviewId",
                "finishId",
                "state",
                "summary",
                "artifactPath",
                "error",
                "cleanupError",
            })
            or result.reviewId ~= review_id
            or result.finishId ~= finish_id
            or (result.state ~= "wrapping" and result.state ~= "completed" and result.state ~= "failed")
            or type(result.artifactPath) ~= "string"
            or result.artifactPath == ""
            or not (result.error == vim.NIL or (type(result.error) == "string" and #result.error <= 4096))
            or not (result.cleanupError == vim.NIL or (type(result.cleanupError) == "string" and #result.cleanupError <= 4096))
            or not (result.summary == vim.NIL or (type(result.summary) == "string" and #result.summary <= 16384))
            or (result.state == "completed" and (result.summary == vim.NIL or result.summary == "" or result.error ~= vim.NIL))
            or (result.state ~= "completed" and result.summary ~= vim.NIL)
            or (result.state == "failed" and result.error == vim.NIL)
        then
            error("Invalid correlated wrap-up response", 0)
        end
        polling = false
        if result.state == "wrapping" then
            return
        end
        if result.state == "failed" then
            -- Failure may include uncertain artifact I/O, not a proven open review.
            fail(result.error)
            return
        end
        durably_completed = true
        local cleanup_error = cleanup()
        publish({
            phase = "review-completed",
            accepted = true,
            reviewId = review_id,
            error = result.cleanupError ~= vim.NIL and result.cleanupError or cleanup_error,
        })
        vim.notify(
            "Parley: review completed. Unsubmitted drafts retained. Use /parley review in Pi, then :Parley start review.",
            vim.log.levels.INFO
        )
        if result.cleanupError ~= vim.NIL or cleanup_error then
            vim.notify(
                "Parley: review completed, but cleanup failed: "
                    .. tostring(
                        result.cleanupError ~= vim.NIL and result.cleanupError or cleanup_error
                    ),
                vim.log.levels.WARN
            )
        end
        if
            vim.api.nvim_win_is_valid(window)
            and vim.api.nvim_get_current_win() == window
            and vim.api.nvim_win_get_buf(window) == buffer
        then
            local shown, show_error = pcall(function()
                require("parley.summary").show(review_id, result.summary)
            end)
            if not shown then
                vim.notify(
                    "Parley: review completed, but summary display failed: "
                        .. tostring(show_error)
                        .. ". Run :Parley done again to view it.",
                    vim.log.levels.ERROR
                )
            end
        else
            vim.notify(
                "Parley: summary saved; run :Parley done "
                    .. review_id
                    .. " to view it. Focus left unchanged.",
                vim.log.levels.INFO
            )
        end
    end
    local function begin()
        send("review-finish-begin", { finishId = finish_id }, function(result)
            -- An already completed/in-progress review returns its original ID.
            if type(result) ~= "table" or not identifier(result.finishId) then
                error("Invalid wrap-up identity", 0)
            end
            finish_id = result.finishId
            observe(result)
            if pending ~= operation then
                return
            end
            publish({ phase = "wrapping", accepted = false, reviewId = review_id })
            vim.notify("Parley: wrapping up…", vim.log.levels.INFO)
            timer = assert(vim.uv.new_timer())
            timer:start(
                250,
                250,
                vim.schedule_wrap(function()
                    if pending ~= operation or polling then
                        return
                    end
                    polling = true
                    send("review-finish-status", { finishId = finish_id }, observe)
                end)
            )
        end)
    end
    local ok, failure = pcall(function()
        group = vim.api.nvim_create_augroup("ParleyWrapUp", { clear = true })
        vim.api.nvim_create_autocmd("User", {
            group = group,
            pattern = { "ParleyBridgeChanged", "ParleyReviewStopped" },
            callback = function(event)
                if event.match == "ParleyReviewStopped" or not bridge.status().connected then
                    fail("Wrap-up delivery stopped; durable evidence retained")
                end
            end,
        })
        vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = cleanup })
        if review_id then
            begin()
            return
        end
        send(actions.info, {}, function(info)
            if
                not discovery(info)
                or (info.workflow or "review") ~= workflow
                or not identifier(info.reviewId)
                or not identifier(info.preparationId)
                or not (info.activeRequestId == vim.NIL or identifier(info.activeRequestId))
                or type(info.busy) ~= "boolean"
                or type(info.ended) ~= "boolean"
            then
                error("Invalid review identity response", 0)
            end
            review_id = info.reviewId
            local selected, selection_error = workspace.select_review(review_id, info.workflow)
            if not selected then
                error(selection_error, 0)
            end
            begin()
        end)
    end)
    if not ok then
        fail(failure)
    end
end

return M
