-- Text helper retained from arubertoson/nvim: lua/aru/workspace/review_snapshot.lua.
---Pi owns capture; this module only converts frozen text for Neovim buffers.
local M = {}

---@class ParleyReviewFile
---@field path string Repository-relative current path.
---@field old_path string Repository-relative original path.
---@field status string
---@field old string Canonical LF text; final-newline presence is preserved.
---@field new string Canonical LF text; final-newline presence is preserved.
---@field old_fileformat 'unix'|'dos' Original line-ending format, separate from canonical LF text.
---@field new_fileformat 'unix'|'dos'
---@field deleted boolean

---@class ParleyReviewSnapshot
---@field root string
---@field vcs 'git'|'jj'
---@field revision string? Absent only for an unborn Git HEAD.
---@field files ParleyReviewFile[] Owned frozen text pairs, sorted by current path.

---Return a new line sequence suitable for Neovim buffers, without the final EOL.
---@param text string Canonical LF text.
---@return string[]
function M.lines(text)
    if text == "" then return { "" } end
    local lines = vim.split(text, "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    return lines
end

return M
