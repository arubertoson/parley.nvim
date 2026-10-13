---Borrowed discussion messages in display order; no persistence or editor ownership.
local M = {}

---@class ParleyThreadMessage
---@field key integer|string Local note identity or stable agent-reply/conclusion identity.
---@field root integer Local identity of the thread's first available note.
---@field item ParleyReviewComposer.Item Source anchor and editable human-note owner.
---@field reply table? Immutable agent reply, absent for notes/findings.
---@field conclusion table? Latest durable decision/reopening record, shown at the thread tail.
---@field conclusion_turn table? Acknowledged generation/failure shown in its own tail block.
---@field tails ParleyReviewComposer.Item[]? Notes whose next agent reply belongs after this message/subtree.

---Follow explicit relationships, retaining orphaned notes and historical replies.
---@param items ParleyReviewComposer.Item[]
---@return ParleyThreadMessage[]
function M.messages(items)
    local parents, children, rendered, messages = {}, {}, {}, {}
    for _, item in ipairs(items) do
        local note = item.note.comment or item.note
        if note.remote_id then parents[note.remote_id] = true end
        for _, reply in ipairs(note.replies or {}) do
            parents[reply.id] = true
        end
        if note.reply_to then
            children[note.reply_to] = children[note.reply_to] or {}
            table.insert(children[note.reply_to], item)
        end
    end
    local render
    local function descendants(id, root)
        for _, child in ipairs(children[id] or {}) do
            render(child, root)
        end
    end
    render = function(item, root)
        local note = item.note.comment or item.note
        if rendered[note.id] then return end
        rendered[note.id] = true
        root = root or note.id
        messages[#messages + 1] = { key = note.id, root = root, item = item }
        if note.remote_id then descendants(note.remote_id, root) end
        for _, reply in ipairs(note.replies or {}) do
            messages[#messages + 1] = { key = reply.id, root = root, item = item, reply = reply }
            descendants(reply.id, root)
        end
        local tail = messages[#messages]
        tail.tails = tail.tails or {}
        table.insert(tail.tails, item)
    end
    for _, item in ipairs(items) do
        local note = item.note.comment or item.note
        if not note.reply_to or not parents[note.reply_to] then render(item) end
    end
    for _, item in ipairs(items) do
        render(item)
    end
    local latest, pending, tails = {}, {}, {}
    for index, message in ipairs(messages) do
        local note = message.item.note.comment or message.item.note
        latest[message.root] = note.conclusion or latest[message.root]
        pending[message.root] = note.conclusion_turn or pending[message.root]
        tails[message.root] = index
    end
    local result = {}
    for index, message in ipairs(messages) do
        result[#result + 1] = message
        local conclusion = latest[message.root]
        if conclusion and tails[message.root] == index then
            result[#result + 1] = {
                key = "conclusion:" .. conclusion.id,
                root = message.root,
                item = message.item,
                conclusion = conclusion,
            }
        end
        local turn = pending[message.root]
        if turn and tails[message.root] == index then
            result[#result + 1] = {
                key = "conclusion:" .. turn.id,
                root = message.root,
                item = message.item,
                conclusion_turn = turn,
                conclusion = {
                    id = turn.id,
                    decision = turn.conclusionDraft.decision,
                    state = turn.status,
                    summary = turn.status == "error"
                            and ("Generation failed: " .. (turn.error or "unknown error") .. "\nConclusion not recorded · gc to retry explicitly")
                        or "",
                },
            }
        end
    end
    return result
end

---@param message ParleyThreadMessage
---@return string[]
function M.lines(message)
    if message.conclusion then
        return vim.split(message.conclusion.summary, "\n", { plain = true })
    end
    if message.reply then return vim.split(message.reply.text, "\n", { plain = true }) end
    return message.item.note.lines
end

---@param message ParleyThreadMessage
---@return boolean
function M.is_agent(message)
    return not message.conclusion and (message.reply ~= nil or message.item.note.author == "agent")
end

return M
