local MiniTest = _G.MiniTest or require("mini.test")
local child = MiniTest.new_child_neovim()
local root
local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            root = vim.fn.tempname()
            vim.fn.mkdir(root, "p")
            child.restart({ "-u", "NONE" })
            child.lua([[
                vim.opt.runtimepath:append(vim.fn.getcwd())
                snapshot = require('parley.snapshot')
            ]])
        end,
        post_case = function() vim.fn.delete(root, "rf") end,
        post_once = child.stop,
    },
})

local function run(args)
    local result = vim.system(args, { cwd = root, text = false }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout:gsub("\n$", "")
end

local function write(path, content)
    local fd = assert(vim.uv.fs_open(vim.fs.joinpath(root, path), "w", 420))
    assert(vim.uv.fs_write(fd, content, 0))
    assert(vim.uv.fs_close(fd))
end

local function init(vcs)
    if vcs == "git" then
        run({ "git", "init", "-q" })
        run({ "git", "config", "core.autocrlf", "false" })
        run({ "git", "config", "user.name", "Test" })
        run({ "git", "config", "user.email", "test@example.invalid" })
    else
        run({ "jj", "git", "init" })
    end
end

local function commit(vcs)
    if vcs == "git" then
        run({ "git", "add", "-A" })
        run({ "git", "commit", "-qm", "base" })
    else
        run({ "jj", "commit", "-m", "base" })
    end
end

local function collect()
    child.lua(
        [[
        local cwd = ...
        collected, failure, done = nil, nil, false
        snapshot.collect(cwd, function(result, err)
            collected, failure, done = result, err, true
        end)
        assert(vim.wait(10000, function() return done end, 10), 'Snapshot timed out')
    ]],
        { root }
    )
    return child.lua_get("collected"), child.lua_get("failure")
end

local function successful()
    local result, err = collect()
    assert(result, err)
    return result
end

local function rejected(message)
    local result, err = collect()
    MiniTest.expect.equality(result, vim.NIL)
    assert(type(err) == "string" and err:find(message, 1, true), vim.inspect(err))
end

for _, vcs in ipairs({ "git", "jj" }) do
    T[vcs .. " CRLF text matches real buffers and retains format-only changes"] = function()
        init(vcs)
        write("a.txt", "first\r\nold\r\nlast\r\n")
        write("format.txt", "same\n")
        commit(vcs)
        write("a.txt", "first\r\nnew\r\nlast\r\n")
        write("format.txt", "same\r\n")
        local result = successful()
        local changed, format = result.files[1], result.files[2]
        MiniTest.expect.equality(changed.old, "first\nold\nlast\n")
        MiniTest.expect.equality(changed.new, "first\nnew\nlast\n")
        MiniTest.expect.equality(
            { changed.old_fileformat, changed.new_fileformat },
            { "dos", "dos" }
        )
        MiniTest.expect.equality(
            { format.old_fileformat, format.new_fileformat },
            { "unix", "dos" }
        )
        MiniTest.expect.equality(format.old, format.new)
        child.cmd("edit " .. vim.fn.fnameescape(root .. "/a.txt"))
        MiniTest.expect.equality(
            child.lua_get("snapshot.lines(collected.files[1].new)"),
            child.lua_get("vim.api.nvim_buf_get_lines(0, 0, -1, false)")
        )
        MiniTest.expect.equality(
            child.lua_get(
                "vim.diff(collected.files[1].old, collected.files[1].new, {result_type = 'indices'})"
            ),
            { { 2, 1, 2, 1 } }
        )
    end

    T[vcs .. " rejects live and dangling working-tree symlinks"] = function()
        init(vcs)
        write("target.txt", "target\n")
        commit(vcs)
        local link = vim.fs.joinpath(root, "link.txt")
        assert(vim.uv.fs_symlink("target.txt", link))
        rejected("does not support symlinks")
        assert(vim.uv.fs_unlink(link))
        assert(vim.uv.fs_symlink("missing.txt", link))
        rejected("Replace it with a regular file or remove it from the change")
    end

    T[vcs .. " rejects deleted baseline symlinks rather than reviewing target names"] = function()
        init(vcs)
        local link = vim.fs.joinpath(root, "link.txt")
        assert(vim.uv.fs_symlink("missing.txt", link))
        commit(vcs)
        assert(vim.uv.fs_unlink(link))
        rejected("does not support symlinks: link.txt")
    end
end

T["Git intent-to-add gets an empty baseline, including unborn HEAD"] = function()
    init("git")
    write("first.txt", "first\n")
    run({ "git", "add", "-N", "first.txt" })
    local first = successful().files[1]
    MiniTest.expect.equality({ first.old, first.new, first.deleted }, { "", "first\n", false })
    commit("git")
    write("added.txt", "added\n")
    run({ "git", "add", "-N", "added.txt" })
    local added = successful().files[1]
    MiniTest.expect.equality({ added.path, added.old, added.new }, { "added.txt", "", "added\n" })
end

T["Git baseline read failures remain visible"] = function()
    init("git")
    write("a.txt", "old\n")
    commit("git")
    local blob = run({ "git", "rev-parse", "HEAD:a.txt" })
    assert(vim.uv.fs_unlink(vim.fs.joinpath(root, ".git/objects", blob:sub(1, 2), blob:sub(3))))
    write("a.txt", "new\n")
    rejected("git show")
end

T["Git working-file read failures close the descriptor and remain visible"] = function()
    init("git")
    write("a.txt", "old\n")
    commit("git")
    write("a.txt", "new\n")
    child.lua([[
        local open, read = vim.uv.fs_open, vim.uv.fs_read
        -- Inject an I/O failure at the filesystem boundary, using a real descriptor.
        -- Capturing its handle lets us verify resource lifetime after rejection.
        vim.uv.fs_open = function(...)
            review_fd = assert(open(...))
            return review_fd
        end
        vim.uv.fs_read = function(fd, ...)
            if fd == review_fd then return nil, 'EIO: injected read failure' end
            return read(fd, ...)
        end
    ]])
    rejected("EIO: injected read failure")
    MiniTest.expect.equality(child.lua_get("vim.uv.fs_fstat(review_fd) == nil"), true)
end

T["jj forced color and unusual fileset paths preserve text, including Binary files in hunks"] = function()
    init("jj")
    run({ "jj", "config", "set", "--repo", "ui.color", "always" })
    local path = 'quote"slash\\back\btab\tnewline\n.txt'
    write(path, "Binary files are ordinary text\nold\n")
    write("mode.txt", "unchanged\n")
    commit("jj")
    write(path, "Binary files are ordinary text\nnew\n")
    assert(vim.uv.fs_chmod(vim.fs.joinpath(root, "mode.txt"), 493))
    local result = successful()
    MiniTest.expect.equality(result.vcs, "jj")
    MiniTest.expect.equality(result.files[1].old, "unchanged\n")
    MiniTest.expect.equality(result.files[1].new, "unchanged\n")
    local file = result.files[2]
    MiniTest.expect.equality(file.path, path)
    MiniTest.expect.equality(file.old, "Binary files are ordinary text\nold\n")
    MiniTest.expect.equality(file.new, "Binary files are ordinary text\nnew\n")
end

T["jj discovery configuration errors do not silently select colocated Git"] = function()
    init("git")
    write("a.txt", "base\n")
    commit("git")
    run({ "jj", "git", "init", "--colocate" })
    write("a.txt", "changed\n")
    local config = vim.fn.tempname()
    vim.fn.writefile({ "malformed = [" }, config)
    child.lua("vim.env.JJ_CONFIG = ...", { config })
    local ok, err = pcall(rejected, "Cannot discover jj repository: Config error")
    vim.fn.delete(config)
    if not ok then error(err) end
end

T["jj binary patch headers still reject binary changes"] = function()
    init("jj")
    write("binary.dat", "before\0bytes")
    commit("jj")
    write("binary.dat", "after\0bytes")
    rejected("supports text files only")
end

---Control a real HEAD transition at the process boundary, forwarding Git's actual output.
local function head_race(repeated)
    init("git")
    write("a.txt", "base\n")
    commit("git")
    local first = run({ "git", "rev-parse", "HEAD" })
    write("a.txt", "next\n")
    commit("git")
    local second = run({ "git", "rev-parse", "HEAD" })
    run({ "git", "reset", "--hard", first })
    write("a.txt", "working\n")
    local bin = root .. "/.git/test-bin"
    vim.fn.mkdir(bin, "p")
    local real_git = vim.fn.exepath("git")
    local shell = vim.fn.shellescape
    write(
        ".git/test-bin/git",
        ([=[#!/bin/sh
if [ "$1" = status ]; then
    %s "$@"
    code=$?
    if [ "$code" -ne 0 ]; then exit "$code"; fi
    current=$(%s rev-parse HEAD) || exit $?
    if [ "$current" = %s ]; then
        %s update-ref HEAD %s || exit $?
    elif %s; then
        %s update-ref HEAD %s || exit $?
    fi
    exit 0
fi
exec %s "$@"
]=]):format(
            shell(real_git),
            shell(real_git),
            shell(first),
            shell(real_git),
            shell(second),
            repeated and "true" or "false",
            shell(real_git),
            shell(first),
            shell(real_git)
        )
    )
    assert(vim.uv.fs_chmod(bin .. "/git", 493))
    child.lua("vim.env.PATH = ... .. ':' .. vim.env.PATH", { bin })
    return second
end

T["Git HEAD movement retries the whole snapshot against the new baseline"] = function()
    local second = head_race(false)
    local result = successful()
    MiniTest.expect.equality(result.revision, second)
    MiniTest.expect.equality(result.files[1].old, "next\n")
    MiniTest.expect.equality(result.files[1].new, "working\n")
end

T["Git repeatedly moving HEAD fails visibly instead of returning a mixed snapshot"] = function()
    head_race(true)
    rejected("Git HEAD changed repeatedly")
end

return T
