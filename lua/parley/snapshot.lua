-- Extracted from arubertoson/nvim: lua/aru/workspace/review_snapshot.lua.
---Frozen text pairs for Parley's changed-file review.
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

---@class ParleyReviewCommandResult: vim.SystemCompleted
---@field stdout string Default captured pipe, never disabled by this module.
---@field stderr string

---A command boundary that yields without blocking Neovim's UI.
---@param args string[]
---@param cwd string
---@return ParleyReviewCommandResult
local function command(args, cwd)
    local thread = coroutine.running()
    vim.system(args, { cwd = cwd, text = false }, function(result)
        vim.schedule(function()
            local ok, err = coroutine.resume(thread, result)
            if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
        end)
    end)
    return coroutine.yield()
end

---@param args string[]
---@param cwd string
---@return string
local function checked(args, cwd)
    local result = command(args, cwd)
    if result.code ~= 0 then error(table.concat(args, " ") .. ": " .. result.stderr) end
    return result.stdout
end

local function unsupported_symlink(path)
    error(
        "Review prototype does not support symlinks: "
            .. path
            .. ". Replace it with a regular file or remove it from the change before starting review."
    )
end

local function file_stat(path)
    local stat, err, code = vim.uv.fs_lstat(path)
    if not stat and code ~= "ENOENT" then
        error("Cannot inspect review file " .. path .. ": " .. err)
    end
    if stat and stat.type == "link" then unsupported_symlink(path) end
    return stat
end

---@param content string
---@return string text
---@return 'unix'|'dos' fileformat
local function canonical_text(content)
    local fileformat = content:find("\r\n", 1, true) and "dos" or "unix"
    return content:gsub("\r\n", "\n"), fileformat
end

---jj string literals are not JSON: control bytes use hex escapes, not \b or \u.
---@param path string
---@return string
local function fileset(path)
    local quoted = path:gsub('[%z\1-\31\127\\"]', function(char)
        if char == '"' or char == "\\" then return "\\" .. char end
        return ("\\x%02x"):format(char:byte())
    end)
    return 'file:"' .. quoted .. '"'
end

---Only an absent symbolic HEAD is an unborn repository; other Git failures surface.
---@param root string
---@return string? revision Absent only for an unborn HEAD.
local function git_head(root)
    local head = command({ "git", "rev-parse", "--verify", "--quiet", "HEAD" }, root)
    if head.code == 0 then return (head.stdout:gsub("\n$", "")) end
    if head.code ~= 1 then error("Cannot resolve Git HEAD: " .. head.stderr) end
    local ref = checked({ "git", "symbolic-ref", "HEAD" }, root):gsub("\n$", "")
    local exists = command({ "git", "show-ref", "--verify", "--quiet", ref }, root)
    if exists.code == 1 then return nil end
    error("Cannot resolve Git HEAD: " .. head.stderr .. exists.stderr)
end

---With all context included, a Git-format text patch contains both complete sides.
---This also captures jj's merged-parent baseline, without selecting one parent.
---@param patch string
---@param path string
---@return string old
---@return string new
---@return boolean has_hunks
local function patch_pair(patch, path)
    local old, new = {}, {}
    local in_hunk = false
    local old_eol, new_eol = true, true
    local previous
    local files = 0
    for _, line in ipairs(vim.split(patch, "\n", { plain = true })) do
        if line:match("^diff %-%-git ") then
            files = files + 1
            in_hunk = false
        elseif not in_hunk and (line:match("^Binary files ") or line == "GIT binary patch") then
            error("Review prototype supports text files only: " .. path)
        elseif
            not in_hunk
            and (
                line == "new file mode 120000"
                or line == "deleted file mode 120000"
                or line == "old mode 120000"
                or line == "new mode 120000"
                or line:match("^index .* 120000$")
            )
        then
            unsupported_symlink(path)
        elseif line:match("^@@ %-") then
            in_hunk = true
        elseif in_hunk then
            local prefix = line:sub(1, 1)
            if prefix == " " or prefix == "-" then old[#old + 1] = line:sub(2) end
            if prefix == " " or prefix == "+" then new[#new + 1] = line:sub(2) end
            if line == "\\ No newline at end of file" then
                if previous == " " or previous == "-" then old_eol = false end
                if previous == " " or previous == "+" then new_eol = false end
            else
                previous = prefix
            end
        end
    end
    assert(files <= 1, "Expected one file in the review patch")
    local function text(lines, eol)
        return table.concat(lines, "\n") .. (#lines > 0 and eol and "\n" or "")
    end
    return text(old, old_eol), text(new, new_eol), in_hunk
end

---@param path string
---@return string
local function read_file(path)
    file_stat(path) -- Git baseline commands yielded; recheck before opening the working file.
    local fd, err = vim.uv.fs_open(path, "r", 438)
    if not fd then error("Cannot read review file " .. path .. ": " .. err) end
    -- Close even when stat/read fails; this boundary owns the descriptor.
    local ok, content = pcall(function()
        local stat = assert(vim.uv.fs_fstat(fd))
        return assert(vim.uv.fs_read(fd, stat.size, 0))
    end)
    local closed, close_err = vim.uv.fs_close(fd)
    if not ok then error(content, 0) end
    assert(closed, close_err)
    if content:find("\0", 1, true) then
        error("Review prototype supports text files only: " .. path)
    end
    return content
end

---@param cwd string
---@return ParleyReviewSnapshot? result Absent when HEAD moved during collection.
local function snapshot_attempt(cwd)
    local jj = vim.fn.executable("jj") == 1 and command({ "jj", "--color=never", "root" }, cwd)
        or nil
    -- jj uses exit 1 for both discovery misses and configuration/repository
    -- failures. Only its explicit no-repository diagnostic permits Git fallback
    -- (verified with the installed jj 0.45.1); all other failures stay visible.
    if
        jj
        and jj.code ~= 0
        and not (jj.code == 1 and jj.stderr:find("Error: There is no jj repo in ", 1, true))
    then
        error("Cannot discover jj repository: " .. jj.stderr)
    end
    local root, vcs, revision, entries
    local baseline = {}
    if jj and jj.code == 0 then
        root, vcs = jj.stdout:gsub("\n$", ""), "jj"
        -- Snapshot once; subsequent commands refer to an immutable commit ID.
        revision = checked(
            { "jj", "--color=never", "log", "--no-graph", "-r", "@", "-T", "commit_id" },
            root
        )
        local listed = checked({
            "jj",
            "--ignore-working-copy",
            "--color=never",
            "diff",
            "-r",
            revision,
            "-T",
            'status ++ "\\0" ++ path ++ "\\0" ++ source.path() ++ "\\0"',
        }, root)
        local fields = vim.split(listed, "\0", { plain = true })
        assert(fields[#fields] == "" and (#fields - 1) % 3 == 0, "Malformed jj diff listing")
        entries = {}
        for i = 1, #fields - 1, 3 do
            entries[#entries + 1] = {
                path = fields[i + 1],
                old_path = fields[i + 2],
                status = fields[i],
                deleted = fields[i] == "removed",
            }
        end
    else
        local git = command({ "git", "rev-parse", "--show-toplevel" }, cwd)
        if git.code ~= 0 then error("Not in a jj or Git repository") end
        root, vcs = git.stdout:gsub("\n$", ""), "git"
        revision = git_head(root)
        if revision then
            local tree = checked({ "git", "ls-tree", "-r", "-z", revision }, root)
            for _, record in ipairs(vim.split(tree, "\0", { plain = true, trimempty = true })) do
                local mode, path = record:match("^(%d+) %w+ %x+\t(.*)$")
                assert(mode, "Malformed Git tree entry")
                baseline[path] = mode
            end
        end
        local listed =
            checked({ "git", "status", "--porcelain=v1", "-z", "--untracked-files=all" }, root)
        local fields = vim.split(listed, "\0", { plain = true, trimempty = true })
        entries = {}
        local i = 1
        while i <= #fields do
            local status, path = fields[i]:sub(1, 2), fields[i]:sub(4)
            local old_path = path
            if status:find("[RC]") then
                i = i + 1
                old_path = fields[i]
                assert(old_path, "Missing original path in Git status entry")
            end
            entries[#entries + 1] = {
                path = path,
                old_path = old_path,
                status = status,
            }
            i = i + 1
        end
    end
    table.sort(entries, function(a, b) return a.path < b.path end)
    for _, entry in ipairs(entries) do
        local path = vim.fs.joinpath(root, entry.path)
        local stat = file_stat(path)
        if vcs == "git" then entry.deleted = not stat end
        local buf = vim.fn.bufnr(path)
        if buf ~= -1 and vim.bo[buf].modified then
            error("Save or discard unsaved changes before review: " .. entry.path)
        end
        if vcs == "jj" then
            local patch = checked({
                "jj",
                "--ignore-working-copy",
                "--color=never",
                "diff",
                "-r",
                revision,
                "--git",
                "--context",
                "2147483647",
                "--",
                fileset(entry.path),
            }, root)
            local has_hunks
            entry.old, entry.new, has_hunks = patch_pair(patch, entry.path)
            if not has_hunks and not entry.deleted then
                entry.new = checked({
                    "jj",
                    "--ignore-working-copy",
                    "--color=never",
                    "file",
                    "show",
                    "-r",
                    revision,
                    "--",
                    fileset(entry.path),
                }, root)
                entry.old = entry.new -- Metadata-only change, including pure renames.
            end
        else
            entry.old = ""
            if baseline[entry.old_path] == "120000" then unsupported_symlink(entry.old_path) end
            if baseline[entry.old_path] then
                entry.old = checked({ "git", "show", revision .. ":" .. entry.old_path }, root)
            end
            entry.new = entry.deleted and "" or read_file(path)
        end
        if entry.old:find("\0", 1, true) or entry.new:find("\0", 1, true) then
            error("Review prototype supports text files only: " .. entry.path)
        end
        entry.old, entry.old_fileformat = canonical_text(entry.old)
        entry.new, entry.new_fileformat = canonical_text(entry.new)
    end
    if vcs == "git" and git_head(root) ~= revision then return nil end
    return { root = root, vcs = vcs, revision = revision, files = entries }
end

---@param cwd string
---@return ParleyReviewSnapshot
local function snapshot(cwd)
    for _ = 1, 3 do
        local result = snapshot_attempt(cwd)
        if result then return result end
    end
    error(
        "Git HEAD changed repeatedly while collecting review. Wait for Git operations to finish and retry."
    )
end

---Collect asynchronously; callback receives either owned frozen pairs or an error.
---Collection does not retain the result after handing it to the callback.
---@param cwd string
---@param callback fun(result: ParleyReviewSnapshot?, err: any)
function M.collect(cwd, callback)
    local thread = coroutine.create(function()
        local ok, result = pcall(snapshot, cwd)
        if ok then
            callback(result, nil)
        else
            callback(nil, result)
        end
    end)
    local ok, err = coroutine.resume(thread)
    if not ok then error(err) end
end

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
