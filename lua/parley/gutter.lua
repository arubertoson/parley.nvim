---Window-scoped signs for immutable review pairs; no live VCS queries.
---The review session owns the displayed marks and the per-file diff cache.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("parley.gutter")

---@class ParleyReviewGutter
---@field buf integer?
---@field file ParleyReviewFile?
---@field side 'old'|'new'?
---@field outside boolean? Muted scope styling; does not change frozen coordinates.
---@field hunks table<ParleyReviewFile, integer[][]>

---@param win integer
---@return ParleyReviewGutter
function M.open(win)
    api.nvim__ns_set(ns, { wins = { win } })
    return { hunks = {} }
end

---The active workspace window can change without ending the review.
function M.rebind(win) api.nvim__ns_set(ns, { wins = { win } }) end

---@param gutter ParleyReviewGutter
function M.clear(gutter)
    if gutter.buf and api.nvim_buf_is_valid(gutter.buf) then
        api.nvim_buf_clear_namespace(gutter.buf, ns, 0, -1)
    end
    gutter.buf, gutter.file, gutter.side = nil, nil, nil
end

---Render only frozen changes; an optional projection omits outdated live-buffer rows.
---@param gutter ParleyReviewGutter
---@param buf integer
---@param file ParleyReviewFile
---@param side 'old'|'new'
---@param project fun(row: integer): integer? Conservative frozen-to-editor placement.
---@param outside boolean? Show frozen changes outside the active review piece in muted styling.
---@param ranges integer[][]? Original line intervals; nil means unrestricted, empty means excluded.
function M.update(gutter, buf, file, side, project, outside, ranges)
    local tick = api.nvim_buf_get_changedtick(buf)
    if
        gutter.buf == buf
        and gutter.file == file
        and gutter.side == side
        and gutter.outside == outside
        and vim.deep_equal(gutter.ranges, ranges)
        and gutter.tick == tick
    then
        return
    end
    M.clear(gutter)
    local hunks = gutter.hunks[file]
    if not hunks then
        hunks =
            vim.text.diff(file.old, file.new, { result_type = "indices", algorithm = "histogram" })
        gutter.hunks[file] = hunks
    end
    local signs = {}
    local line_count = api.nvim_buf_line_count(buf)
    local function at(row)
        row = math.max(1, row)
        local muted = outside or ranges ~= nil
        for _, range in ipairs(ranges or {}) do
            if row >= range[1] and row <= range[2] then muted = outside or false end
        end
        if project then row = project(row) end
        if not row or row > line_count then return end
        signs[row] = signs[row] or { outside = muted }
        signs[row].outside = signs[row].outside and muted
        return signs[row]
    end
    for _, hunk in ipairs(hunks) do
        local offset = side == "old" and 1 or 3
        local first, count = hunk[offset], hunk[offset + 1]
        local other_count = hunk[side == "old" and 4 or 2]
        for i = 0, count - 1 do
            local sign = at(first + i)
            if sign then
                sign.kind = i < other_count and "Change" or (side == "new" and "Add" or "Delete")
            end
        end
        -- Missing lines belong to a boundary, including before the first line
        -- and in an empty file's placeholder row. Preserve any bar on that row.
        if other_count > count then
            local sign = at(count == 0 and first or first + count - 1)
            if sign then
                sign[first == 0 and "above" or "below"] = true
                sign.gap_kind = side == "new" and "Delete" or "Add"
            end
        end
    end
    for row, sign in pairs(signs) do
        -- VCSigns-inspired bars and upper/lower boundary strokes, implemented
        -- independently with Parley's own highlight groups.
        local boundary = sign.above and sign.below and "▔▁"
            or sign.above and "▔"
            or sign.below and "▁"
            or ""
        local text = sign.kind and "▎" or ""
        if sign.above and sign.below then text = "" end -- Sign text has at most two cells.
        local kind = sign.kind and sign.gap_kind and "Change" or sign.kind or sign.gap_kind
        api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
            sign_text = text .. boundary,
            sign_hl_group = sign.outside and "ParleyReviewSignOutside"
                or ("ParleyReviewSign" .. kind),
            priority = 10,
        })
    end
    gutter.buf, gutter.file, gutter.side, gutter.tick = buf, file, side, tick
    gutter.outside = outside
    gutter.ranges = ranges
end

return M
