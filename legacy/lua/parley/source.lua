---Workspace source identity and conservative frozen-to-buffer coordinate projection.
---Durable anchors never move; only their editor placements do. The session owns caches.
local M = {}
local api = vim.api

function M.path(root, buf)
    if vim.b[buf].parley_path then
        if vim.b[buf].parley_root == root then return vim.b[buf].parley_path end
        return
    end
    if vim.bo[buf].buftype ~= "" then return end
    local name = vim.fs.normalize(api.nvim_buf_get_name(buf))
    local prefix = vim.fs.normalize(root) .. "/"
    if name:sub(1, #prefix) ~= prefix then return end
    local path = name:sub(#prefix + 1)
    if path == "" or path:match("^%.git/") or path:match("^%.jj/") then return end
    return path
end

function M.text(buf)
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        .. (vim.bo[buf].endofline and "\n" or "")
end

local function normalized(text) return text:gsub("\n$", "") .. "\n" end

---Only unchanged intervals have an unambiguous mapping. Changed/deleted text is stale.
function M.project(s, file, side, buf, first, last, reverse)
    if vim.b[buf].parley_snapshot then
        if vim.b[buf].parley_session ~= s.id then return end
        if
            vim.b[buf].parley_path == file.path
            and vim.b[buf].parley_side == side
            and vim.b[buf].parley_source_id == file.source_id
        then
            return first, last
        end
        return
    end
    local tick = api.nvim_buf_get_changedtick(buf)
    if s.projection_buf ~= buf or s.projection_tick ~= tick then
        s.projection_buf, s.projection_tick, s.projections = buf, tick, {}
    end
    local cached = s.projections[file]
    if not cached then
        cached = {}
        s.projections[file] = cached
    end
    local hunks = cached[side]
    if not hunks then
        hunks = vim.text.diff(normalized(file[side]), normalized(M.text(buf)), {
            result_type = "indices",
            algorithm = "histogram",
        })
        cached[side] = hunks
    end
    local old, new = 1, 1
    for _, hunk in ipairs(hunks) do
        local a, count_a, b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
        if reverse then
            a, count_a, b, count_b = b, count_b, a, count_a
        end
        if count_a == 0 then a = a + 1 end
        if count_b == 0 then b = b + 1 end
        if first >= old and last < a then return first + new - old, last + new - old end
        old, new = a + count_a, b + count_b
    end
    if first >= old then return first + new - old, last + new - old end
end

---Append supplemental sources to the local navigation catalogue, never to the original diff.
function M.sync(s, record)
    s.evidence = s.evidence or {}
    for _, evidence in ipairs(record.evidence or {}) do
        if not s.evidence[evidence.id] then
            local file = {
                path = evidence.path,
                old_path = evidence.path,
                old = evidence.text,
                new = evidence.text,
                source_id = evidence.id,
                status = "context",
                new_fileformat = evidence.fileformat,
                old_fileformat = evidence.fileformat,
            }
            local count = #vim.split(evidence.text:gsub("\n$", ""), "\n", { plain = true })
            s.pieces[#s.pieces + 1] = {
                file = file,
                side = "new",
                first = 1,
                last = math.max(1, count),
                old_first = 1,
                new_first = 1,
                old_count = 0,
                new_count = 0,
                seen = true,
            }
            s.evidence[evidence.id] = #s.pieces
        end
    end
end

---Resolve the active file separately from the change-navigation cursor.
function M.select(s, buf)
    local path = M.path(s.root, buf)
    if not path then return false end
    local side, id = vim.b[buf].parley_side, vim.b[buf].parley_source_id
    local selected = s.pieces[s.index]
    if
        selected.file.path == path
        and (not side or selected.side == side)
        and (not vim.b[buf].parley_snapshot or selected.file.source_id == id)
    then
        return true
    end
    for index, piece in ipairs(s.pieces) do
        if
            piece.file.path == path
            and (not side or piece.side == side)
            and (not vim.b[buf].parley_snapshot or piece.file.source_id == id)
        then
            s.index = index
            return true
        end
    end
    return false
end

---A whole-side context piece lets unchanged lines share ordinary note/navigation paths.
function M.context_piece(s, file, side)
    for index, piece in ipairs(s.pieces) do
        if piece.file == file and piece.side == side then return index end
    end
    local count = #vim.split(file[side]:gsub("\n$", ""), "\n", { plain = true })
    s.pieces[#s.pieces + 1] = {
        file = file,
        side = side,
        first = 1,
        last = count,
        old_first = 1,
        new_first = 1,
        old_count = 0,
        new_count = 0,
        seen = true,
    }
    return #s.pieces
end

---Choose a frozen source for the inspected selection, including unchanged lines.
---Returns editor-independent anchor coordinates or nil when explicit capture is needed.
function M.anchor(s, buf, first, last)
    local path = M.path(s.root, buf)
    local side = vim.b[buf].parley_side or "new"
    for _, file in ipairs(s.files) do
        if file.path == path then
            M.context_piece(s, file, side)
            break
        end
    end
    local context = api.nvim_buf_get_lines(buf, first - 1, last, false)
    for index, piece in ipairs(s.pieces) do
        if piece.file.path == path and piece.side == side then
            local a, b = M.project(s, piece.file, side, buf, first, last, true)
            if a and a >= 1 then
                local lines = vim.split(piece.file[side]:gsub("\n$", ""), "\n", { plain = true })
                if
                    piece.file[side] ~= ""
                    and b <= #lines
                    and vim.deep_equal(vim.list_slice(lines, a, b), context)
                then
                    return {
                        session = s.id,
                        piece = index,
                        path = path,
                        side = side,
                        source_id = piece.file.source_id,
                    }, { first = a, last = b, context = context }
                end
            end
        end
    end
end

return M
