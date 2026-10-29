---Explicit, cached per-request evidence view. Owns one disposable scratch float;
---never reads artifacts, captures drafts, imports conversations or starts work.
local M = {}
local api = vim.api
local window, buffer

local function render(report)
    local status = report.status or {}
    local projection = report.projection
    local lines = {
        "# Request report",
        "",
        "Workspace: " .. report.workspace,
        "Parent session: " .. report.sessionId,
        "Review: " .. report.reviewId,
        "Request: " .. report.requestId,
        "",
        "## Submitted scope (not observed coverage)",
        "",
        "Kind: " .. report.kind,
    }
    local function quote(text)
        for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
            lines[#lines + 1] = "> " .. line
        end
    end
    if report.instructions ~= vim.NIL then
        quote(report.instructions)
    end
    for _, scope in ipairs(report.scope) do
        lines[#lines + 1] = ("- %s:%d-%d (%s) — %s, version %d, %d submitted message(s)"):format(
            scope.path,
            scope.first,
            scope.last,
            scope.side,
            scope.conversationId,
            scope.version,
            scope.messages
        )
    end
    if #report.scope == 0 then
        lines[#lines + 1] = "No anchored conversations submitted."
    end
    vim.list_extend(lines, {
        "",
        "## Observed facts",
        "",
        "- Durable acceptance: acknowledged at " .. report.acceptedAt .. " (Unix seconds).",
        "- Local submitted-history acceptance: " .. (status.application or "not recorded") .. ".",
        "- Reviewer session: "
            .. (report.reviewerSessionId ~= vim.NIL and report.reviewerSessionId or "not recorded"),
    })
    if status.outcome then
        lines[#lines + 1] = "- Final execution outcome: " .. status.outcome.status .. "."
        if status.outcome.detail ~= vim.NIL then
            quote(status.outcome.detail)
        end
    else
        lines[#lines + 1] = "- Final outcome not received; execution completion is unknown."
        lines[#lines + 1] = "- Cached delivery phase: "
            .. (status.phase or "accepted")
            .. (status.activity and ("; host activity: " .. status.activity) or "")
            .. "."
    end
    if projection then
        lines[#lines + 1] = ("- Publication: %d message(s), %d new finding(s)."):format(
            projection.publishedMessages,
            projection.newFindings
        )
    else
        lines[#lines + 1] = "- Publication totals: not recorded in this cache."
    end
    if status.results then
        lines[#lines + 1] = ("- Local result import: %d conversation(s) applied, %d incompatible, %d unplaced."):format(
            status.results.applied,
            status.results.incompatible,
            status.results.unplaced
        )
    else
        lines[#lines + 1] = "- Local result import: not recorded."
    end
    lines[#lines + 1] = "- Durable application receipts: "
        .. (status.receipts or "not recorded")
        .. "."
    if status.error then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Delivery/application diagnostic:"
        quote(status.error)
    end
    vim.list_extend(lines, {
        "",
        "## Reviewer explanation (claims, not host verification)",
        "",
        "Reported coverage, conclusion, verification and limitations:",
        "Details omitted by the reviewer are not recorded.",
        "",
    })
    if projection and projection.explanation ~= vim.NIL then
        quote(projection.explanation)
    else
        lines[#lines + 1] = "Not recorded (no bounded final explanation available in this cache)."
    end
    vim.list_extend(lines, {
        "",
        "Zero findings or resolved conversations do not imply approval, exhaustive coverage or successful verification.",
        "Missing evidence stays unknown. This view does not retrieve missing outcomes or restart work.",
    })
    return vim.split(table.concat(lines, "\n"), "\n", { plain = true })
end

---Borrow copied, validated request evidence. q/Esc closes and wipes this view.
function M.show(report)
    local lines = render(report)
    if window and api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == buffer then
        api.nvim_win_close(window, false)
    end
    buffer = api.nvim_create_buf(false, true)
    local owned_buffer = buffer
    vim.bo[buffer].bufhidden = "wipe"
    vim.bo[buffer].swapfile = false
    api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    vim.bo[buffer].modifiable = false
    vim.bo[buffer].readonly = true
    vim.bo[buffer].filetype = "markdown"
    local width = math.max(1, math.min(100, vim.o.columns - 6))
    local height = math.max(1, math.min(30, vim.o.lines - 6))
    local ok, opened = pcall(api.nvim_open_win, buffer, true, {
        relative = "editor",
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "single",
        title = " Request report ",
    })
    if not ok then
        if api.nvim_buf_is_valid(owned_buffer) then
            api.nvim_buf_delete(owned_buffer, { force = true })
        end
        error(opened, 0)
    end
    window = opened
    -- Hooks may have replaced the attachment. Do not configure/close their UI.
    if api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == owned_buffer then
        vim.wo[window].number = false
        vim.wo[window].relativenumber = false
        vim.wo[window].signcolumn = "no"
        vim.wo[window].foldcolumn = "0"
        vim.wo[window].statuscolumn = ""
        vim.wo[window].wrap = true
        local owned_window = window
        vim.keymap.set("n", { "q", "<Esc>" }, function()
            if
                api.nvim_get_current_win() == owned_window
                and api.nvim_win_is_valid(owned_window)
                and api.nvim_win_get_buf(owned_window) == owned_buffer
            then
                api.nvim_win_close(owned_window, false)
            end
        end, { buffer = owned_buffer, desc = "Close request report" })
    end
    return owned_buffer
end

return M
