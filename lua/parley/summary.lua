---Explicit, read-only wrap-up view. Owns only its scratch buffers/windows; never
---borrows composer buffers or changes source options, layout, history or drafts.
local M = {}
local api = vim.api
local buffers = {}
local windows = {}

function M.show(review_id, text)
    local buffer = buffers[review_id]
    if not buffer or not api.nvim_buf_is_valid(buffer) then
        buffer = api.nvim_create_buf(false, true)
        buffers[review_id] = buffer
        vim.bo[buffer].bufhidden = "hide"
        vim.bo[buffer].swapfile = false
        vim.bo[buffer].filetype = "markdown"
        api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(text, "\n", { plain = true }))
        vim.bo[buffer].modifiable = false
        vim.bo[buffer].readonly = true
        vim.b[buffer].parley_summary = review_id
    end
    local width = math.max(1, math.min(100, vim.o.columns - 6))
    local height = math.max(1, math.min(30, vim.o.lines - 6))
    local window = api.nvim_open_win(buffer, true, {
        relative = "editor",
        row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
        col = math.max(0, math.floor((vim.o.columns - width) / 2)),
        width = width,
        height = height,
        style = "minimal",
        border = "single",
        title = " Review completed ",
    })
    -- Filetype/window hooks may have changed the attachment. Own only this view.
    if api.nvim_win_is_valid(window) and api.nvim_win_get_buf(window) == buffer then
        vim.wo[window].number = false
        vim.wo[window].relativenumber = false
        vim.wo[window].signcolumn = "no"
        vim.wo[window].foldcolumn = "0"
        vim.wo[window].wrap = true
        windows[window] = buffer
        local function close()
            local current = api.nvim_get_current_win()
            if windows[current] == buffer and api.nvim_win_get_buf(current) == buffer then
                windows[current] = nil
                api.nvim_win_close(current, false)
            end
        end
        vim.keymap.set(
            "n",
            { "q", "<Esc>" },
            close,
            { buffer = buffer, desc = "Close review summary" }
        )
    end
    return buffer
end

return M
