-- Extracted from arubertoson/nvim: lua/aru/workspace/review_peek.lua.
---Frozen before/after excerpts above the source; full comparison owns a temporary tab.
local M = {}
local api = vim.api
local style = require("parley.style")
local snapshot = require("parley.snapshot")
local serial = 0

---@class ParleyReviewPeek
---@field win integer
---@field ns integer
---@field render ParleyReviewPeekRender? Absent when no excerpt is displayed.

---@class ParleyReviewPeekRender
---@field buf integer
---@field mark integer
---@field piece ParleyReviewPiece Borrowed frozen piece; never mutated here.
---@field width integer
---@field budget integer
---@field first integer
---@field last integer
---@field scope 'line'|'range'|'hunk'
---@field anchor integer
---@field rows integer

---@class ParleyReviewPeekTarget
---@field first integer
---@field last integer
---@field scope 'line'|'range'|'hunk'

---The caller owns this window-scoped state and must clear it on session teardown.
---@param win integer
---@return ParleyReviewPeek
function M.open(win)
    assert(api.nvim__ns_set, "Review comparison requires Neovim's experimental nvim__ns_set API")
    local ns = api.nvim_create_namespace("")
    api.nvim__ns_set(ns, { wins = { win } })
    style.refresh()
    return { win = win, ns = ns }
end

---@param state ParleyReviewPeek
function M.clear(state)
    local rendered = state.render
    if rendered and api.nvim_buf_is_valid(rendered.buf) then
        api.nvim_buf_clear_namespace(rendered.buf, state.ns, 0, -1)
    end
    state.render = nil
end

---Translate the selected source interval into each side's changed-line coordinates.
---@param piece ParleyReviewPiece
---@param target ParleyReviewPeekTarget?
---@param side 'old'|'new'
---@return integer first
---@return integer last
local function focus(piece, target, side)
    local count = piece[side .. "_count"]
    local source_count = piece[piece.side .. "_count"]
    if not target or target.scope == "hunk" or source_count == 0 then return 1, 1 end
    local source_first = piece[piece.side .. "_first"]
    local first = math.max(0, math.min(source_count - 1, target.first - source_first))
    local last = math.max(first, math.min(source_count - 1, target.last - source_first))
    if side == piece.side then return first + 1, last + 1 end
    return math.floor(first * count / source_count) + 1,
        math.max(1, math.ceil((last + 1) * count / source_count))
end

---Only materialize the chosen lines, not an entire second copy of a frozen file.
local function slice(text, first, count)
    local lines, row, pos = {}, 1, 1
    while #lines < count and pos <= #text do
        local ending = text:find("\n", pos, true)
        if row >= first then lines[#lines + 1] = text:sub(pos, ending and ending - 1 or #text) end
        if not ending then break end
        pos, row = ending + 1, row + 1
    end
    assert(#lines == count, "Review piece exceeds its frozen text")
    return lines
end

---Bound work and display columns even for enormous lines; never split UTF-8.
---Control characters (including tabs) are shown with Neovim's printable notation.
local function excerpt(text, width)
    local chunks, columns, bytes = {}, 0, 0
    while bytes < #text do
        -- Inspect at most one UTF-8 sequence. Invalid bytes remain printable
        -- instead of being skipped or greedily consuming a huge continuation run.
        local next_bytes = text:sub(bytes + 1, bytes + 4)
        local char = next_bytes:match("^[\194-\223][\128-\191]")
            or next_bytes:match("^[\224-\239][\128-\191][\128-\191]")
            or next_bytes:match("^[\240-\244][\128-\191][\128-\191][\128-\191]")
            or next_bytes:sub(1, 1)
        local printable = vim.fn.strtrans(char)
        local size = vim.fn.strdisplaywidth(printable)
        if columns + size > width then break end
        chunks[#chunks + 1] = printable
        columns, bytes = columns + size, bytes + #char
        -- Also bound zero-width combining sequences in malicious/huge input.
        if bytes >= width * 8 then break end
    end
    return table.concat(chunks), bytes
end

---@param state ParleyReviewPeek
---@param buf integer
---@param piece ParleyReviewPiece? nil hides the comparison (e.g. stale source).
---@param target ParleyReviewPeekTarget?
---@param anchor integer? Display anchor, independent of the focused excerpt interval.
function M.update(state, buf, piece, target, anchor)
    if not piece then
        M.clear(state)
        return
    end
    local width = api.nvim_win_get_width(state.win)
    local budget = math.max(1, math.floor(api.nvim_win_get_height(state.win) / 3))
    local first = target and target.first or piece.first
    local last = target and target.last or piece.first
    local scope = target and target.scope or "hunk"
    anchor = anchor or last
    local rendered = state.render
    if
        rendered
        and rendered.buf == buf
        and rendered.piece == piece
        and rendered.width == width
        and rendered.budget == budget
        and rendered.first == first
        and rendered.last == last
        and rendered.scope == scope
        and rendered.anchor == anchor
    then
        return
    end
    local rows = {}
    local function row(text, highlight)
        local padding = string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(text)))
        rows[#rows + 1] = { { text .. padding, highlight } }
    end
    if width < 40 or budget < 6 then
        -- Tiny windows cannot fit two labelled sides with totals. Explicitly show
        -- an excerpt placeholder rather than silently displaying one side only.
        if budget >= 2 then
            row(
                ("--- BEFORE · excerpt · 0/%d lines"):format(piece.old_count),
                "ParleyReviewDiffDelete"
            )
            row(
                ("+++ AFTER · excerpt · 0/%d lines"):format(piece.new_count),
                "ParleyReviewDiffAdd"
            )
        else
            row(
                ("Excerpt · 0/%d changed lines"):format(piece.old_count + piece.new_count),
                "ParleyReviewDiffHeader"
            )
        end
    else
        row(
            ("@@ -%d,%d +%d,%d @@ · frozen"):format(
                piece.old_first,
                piece.old_count,
                piece.new_first,
                piece.new_count
            ),
            "ParleyReviewDiffHeader"
        )
        local capacity = budget - 4 -- hunk header, two side labels, excerpt footer
        local old_rows = math.min(piece.old_count, math.floor(capacity / 2))
        local new_rows = math.min(piece.new_count, capacity - old_rows)
        old_rows = math.min(piece.old_count, capacity - new_rows)
        local clipped, shown_bytes, total_bytes = 0, 0, 0
        for _, side in ipairs({ "old", "new" }) do
            local count = piece[side .. "_count"]
            local take = side == "old" and old_rows or new_rows
            local first, last = focus(piece, target, side)
            local start =
                math.max(1, math.min(count - take + 1, math.floor((first + last - take + 1) / 2)))
            local absolute = piece[side .. "_first"] + start - 1
            local label = side == "old" and "BEFORE" or "AFTER"
            local marker = side == "old" and "-" or "+"
            local highlight = side == "old" and "ParleyReviewDiffDelete" or "ParleyReviewDiffAdd"
            if count == 0 then
                row(marker:rep(3) .. " " .. label .. " · 0 changed lines", highlight)
            else
                local heading = ("%s · %d/%d lines%s"):format(
                    label,
                    take,
                    count,
                    take < count and " · excerpt" or ""
                )
                row(marker:rep(3) .. " " .. heading, highlight)
                for i, text in ipairs(slice(piece.file[side], absolute, take)) do
                    local prefix = ("%s %d │ "):format(marker, absolute + i - 1)
                    local available = width - vim.fn.strdisplaywidth(prefix) - 2
                    local display, bytes = excerpt(text, available)
                    if bytes < #text then
                        clipped = clipped + 1
                        shown_bytes, total_bytes = shown_bytes + bytes, total_bytes + #text
                        display = display .. " …"
                    end
                    row(prefix .. display, highlight)
                end
            end
        end
        if clipped > 0 then
            local footer = ("Excerpt · %d rows: %d/%d bytes"):format(
                clipped,
                shown_bytes,
                total_bytes
            )
            -- Totals can exceed a narrow window only for truly enormous inputs;
            -- scientific notation keeps that metadata bounded rather than clipping it.
            if vim.fn.strdisplaywidth(footer) > width then
                footer = ("Excerpt · %d rows: ~%.1g/~%.1g B"):format(
                    clipped,
                    shown_bytes,
                    total_bytes
                )
            end
            row(footer, "ParleyReviewDiffHeader")
        else
            row("Frozen comparison · full view available via Lua", "ParleyReviewDiffHeader")
        end
    end
    if rendered and rendered.buf ~= buf then
        M.clear(state)
        rendered = nil
    end
    local mark = api.nvim_buf_set_extmark(buf, state.ns, anchor - 1, 0, {
        virt_lines = rows,
        id = rendered and rendered.mark or nil,
        virt_lines_above = true,
        virt_lines_leftcol = true,
        priority = 100,
    })
    state.render = {
        buf = buf,
        mark = mark,
        piece = piece,
        width = width,
        budget = budget,
        first = first,
        last = last,
        scope = scope,
        anchor = anchor,
        rows = #rows,
    }
end

---An explicit reveal may scroll, but ordinary updates never move the viewport.
---@param state ParleyReviewPeek
function M.reveal(state)
    local rendered = state.render
    if not rendered then return end
    api.nvim_win_call(state.win, function()
        local view = vim.fn.winsaveview()
        local anchor = rendered.anchor
        if view.topline <= anchor then
            local height = api.nvim_win_get_height(state.win)
                - (vim.wo[state.win].winbar ~= "" and 1 or 0)
            local before = api.nvim_win_text_height(state.win, {
                start_row = view.topline - 1,
                start_vcol = view.skipcol,
                end_row = anchor - 1,
                max_height = height + 1,
            }).all + view.topfill
            if (view.topline < anchor or view.topfill >= rendered.rows) and before <= height then
                return
            end
        end
        -- topfill includes the virtual comparison above topline. Unlike zt,
        -- this keeps both labelled sides and the source anchor on screen.
        vim.fn.winrestview({ topline = anchor, topfill = rendered.rows, skipcol = 0 })
    end)
end

---Borrow the frozen piece. The returned tab owns its scratch buffers until closed.
---Failed construction tears down the partial comparison and propagates the error.
---@param piece ParleyReviewPiece
---@return integer tab Temporary comparison tab handle.
function M.full(piece)
    serial = serial + 1
    local original_win = api.nvim_get_current_win()
    vim.cmd("tabnew")
    local tab = api.nvim_get_current_tabpage()
    local initial_buf = api.nvim_get_current_buf()
    local windows, buffers = {}, { initial_buf }
    local ok, result = xpcall(function()
        for i, side in ipairs({ "old", "new" }) do
            if i == 2 then vim.cmd("rightbelow vsplit") end
            local win = api.nvim_get_current_win()
            local buf = api.nvim_create_buf(false, true)
            buffers[#buffers + 1] = buf
            vim.bo[buf].bufhidden = "wipe"
            local path = side == "old" and piece.file.old_path or piece.file.path
            local label = side == "old" and "BEFORE" or "AFTER"
            api.nvim_buf_set_name(
                buf,
                ("parley-comparison://%d/%s/%s"):format(serial, label, path)
            )
            api.nvim_buf_set_lines(buf, 0, -1, false, snapshot.lines(piece.file[side]))
            vim.bo[buf].filetype = vim.filetype.match({ filename = path }) or ""
            vim.bo[buf].fileformat = piece.file[side .. "_fileformat"]
            vim.bo[buf].endofline = piece.file[side]:sub(-1) == "\n"
            vim.bo[buf].fixendofline = false
            vim.bo[buf].modified = false
            vim.bo[buf].modifiable = false
            vim.bo[buf].readonly = true
            api.nvim_win_set_buf(win, buf)
            vim.wo[win].winbar = label
                .. " · frozen · q closes comparison · "
                .. path:gsub("%%", "%%%%")
            vim.keymap.set("n", "q", function()
                if api.nvim_tabpage_is_valid(tab) then
                    vim.cmd(api.nvim_tabpage_get_number(tab) .. "tabclose")
                end
            end, { buffer = buf, nowait = true, desc = "Close frozen comparison tab" })
            vim.cmd("diffthis")
            windows[side] = win
        end
        if api.nvim_buf_is_valid(initial_buf) then
            api.nvim_buf_delete(initial_buf, { force = true })
        end
        vim.cmd("diffupdate")
        local win = windows[piece.side]
        api.nvim_set_current_win(win)
        local first = math.max(1, piece[piece.side .. "_first"])
        api.nvim_win_set_cursor(
            win,
            { math.min(first, api.nvim_buf_line_count(api.nvim_win_get_buf(win))), 0 }
        )
        vim.cmd("normal! zvzz")
        return tab
    end, debug.traceback)
    if ok then return result end

    -- A buffer can still be detached when setup fails, so closing the tab alone
    -- is insufficient. Preserve the construction error if cleanup also fails.
    local cleaned, cleanup_err = pcall(function()
        if api.nvim_tabpage_is_valid(tab) then
            vim.cmd(api.nvim_tabpage_get_number(tab) .. "tabclose!")
        end
        for _, buf in ipairs(buffers) do
            if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
        end
        if api.nvim_win_is_valid(original_win) then api.nvim_set_current_win(original_win) end
    end)
    if not cleaned then
        error(tostring(result) .. "\nComparison cleanup failed: " .. tostring(cleanup_err), 0)
    end
    error(result, 0)
end

return M
