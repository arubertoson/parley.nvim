-- One active, ordered conversation. Committed messages and their lines are
-- immutable; append extends the tip and rewind replaces an active suffix.
-- Superseded suffixes remain owned by the thread, without a branching UI.
-- Editable drafts belong to the host, not this committed-history sequence.

---@class ParleyThread.Message
---@field id string
---@field parent_id? string
---@field role 'human'|'agent'
---@field author string
---@field origin string
---@field created_at integer
---@field lines string[]

---@class ParleyThread
---@field id string
---@field messages ParleyThread.Message[] Active timeline; rewind replaces this array.
---@field version integer Monotonic active-context version, including rewinds.
---@field superseded ParleyThread.Superseded[] Retained immutable suffixes, not active context.

---@class ParleyThread.Superseded
---@field version integer Active version before replacement.
---@field messages ParleyThread.Message[] Original committed records, never rewritten.

local M = {}

local function is_nonempty_string(value)
    return type(value) == "string" and value ~= ""
end

---@param id string
---@return ParleyThread
function M.new(id)
    assert(is_nonempty_string(id), "thread id must be a nonempty string")
    return { id = id, messages = {}, version = 0, superseded = {} }
end

---Returns a borrowed, read-only message (including its lines), or nil.
---@param thread ParleyThread
---@param id string
---@return ParleyThread.Message?
function M.get(thread, id)
    for _, message in ipairs(thread.messages) do
        if message.id == id then
            return message
        end
    end
end

---Returns a borrowed, read-only message in append order, not timestamp order.
---@param thread ParleyThread
---@return ParleyThread.Message?
function M.latest_agent(thread)
    for index = #thread.messages, 1, -1 do
        local message = thread.messages[index]
        if message.role == "agent" then
            return message
        end
    end
end

local function message_exists(thread, id)
    if M.get(thread, id) then
        return true
    end
    for _, suffix in ipairs(thread.superseded) do
        for _, message in ipairs(suffix.messages) do
            if message.id == id then
                return true
            end
        end
    end
    return false
end

-- Both operations validate/copy before publishing any change. IDs remain
-- unique even after a message has left the active timeline.
---@param thread ParleyThread
---@param message ParleyThread.Message
---@return ParleyThread.Message? copied
---@return string? error
local function copy_message(thread, message)
    if type(message) ~= "table" then
        return nil, "message must be a table"
    end
    if not is_nonempty_string(message.id) then
        return nil, "message id must be a nonempty string"
    end
    if message_exists(thread, message.id) then
        return nil, "duplicate message id: " .. message.id
    end
    if message.parent_id ~= nil and not is_nonempty_string(message.parent_id) then
        return nil, "message parent_id must be a nonempty string when present"
    end
    if message.role ~= "human" and message.role ~= "agent" then
        return nil, "message role must be human or agent"
    end
    if not is_nonempty_string(message.author) then
        return nil, "message author must be a nonempty string"
    end
    if not is_nonempty_string(message.origin) then
        return nil, "message origin must be a nonempty string"
    end

    local created_at = message.created_at
    if
        type(created_at) ~= "number"
        or created_at ~= created_at
        or created_at == math.huge
        or created_at == -math.huge
        or created_at % 1 ~= 0
    then
        return nil, "message created_at must be a finite integer"
    end
    if type(message.lines) ~= "table" then
        return nil, "message lines must be a dense string array"
    end

    local lines = {}
    local line_count = 0
    local max_index = 0
    for index, line in pairs(message.lines) do
        if type(index) ~= "number" or index < 1 or index % 1 ~= 0 or type(line) ~= "string" then
            return nil, "message lines must be a dense string array"
        end
        if line:find("\n", 1, true) then
            return nil, "message lines must not contain embedded newlines"
        end
        line_count = line_count + 1
        max_index = math.max(max_index, index)
        lines[index] = line
    end
    if max_index ~= line_count then
        return nil, "message lines must be a dense string array"
    end

    return {
        id = message.id,
        parent_id = message.parent_id,
        role = message.role,
        author = message.author,
        origin = message.origin,
        created_at = created_at,
        lines = lines,
    }
end

---Append only to the active tip; replying to an older parent requires rewind.
---Failures leave active history, its version and superseded records unchanged.
---@param thread ParleyThread
---@param message ParleyThread.Message
---@return true? success
---@return string? error
function M.append(thread, message)
    local copied, failure = copy_message(thread, message)
    if not copied then
        return nil, failure
    end
    local tip = thread.messages[#thread.messages]
    if copied.parent_id ~= (tip and tip.id or nil) then
        return nil, "message parent_id must be the active thread tip"
    end
    thread.messages[#thread.messages + 1] = copied
    thread.version = thread.version + 1
    return true
end

---Keep the prefix ending at parent_id (nil means no prefix), then add a new
---message. The removed suffix stays immutable in superseded. The expected
---version prevents a confirmation made against old context from pruning updates.
---@param thread ParleyThread
---@param parent_id? string
---@param message ParleyThread.Message
---@param expected_version integer
---@return true? success
---@return string? error
function M.rewind(thread, parent_id, message, expected_version)
    if expected_version ~= thread.version then
        return nil, "thread changed; review the current conversation before rerunning"
    end
    local parent_index = 0
    if parent_id ~= nil then
        for index, candidate in ipairs(thread.messages) do
            if candidate.id == parent_id then
                parent_index = index
                break
            end
        end
        if parent_index == 0 then
            return nil, "rewind parent is no longer active"
        end
    end
    local copied, failure = copy_message(thread, message)
    if not copied then
        return nil, failure
    end
    if copied.parent_id ~= parent_id then
        return nil, "message parent_id must match the rewind parent"
    end
    local active, removed = {}, {}
    for index, candidate in ipairs(thread.messages) do
        if index <= parent_index then
            active[#active + 1] = candidate
        else
            removed[#removed + 1] = candidate
        end
    end
    active[#active + 1] = copied
    if #removed > 0 then
        thread.superseded[#thread.superseded + 1] = {
            version = thread.version,
            messages = removed,
        }
    end
    thread.messages = active
    thread.version = thread.version + 1
    return true
end

return M
