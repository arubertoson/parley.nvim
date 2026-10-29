if vim.g.loaded_parley then
    return
end
vim.g.loaded_parley = true

local function invalid(usage)
    vim.notify("Parley: expected :Parley " .. usage, vim.log.levels.ERROR)
end

vim.api.nvim_create_user_command("Parley", function(options)
    local args = options.fargs
    local action = args[1]
    local parley = require("parley")
    if action == "start" then
        if #args > 2 or (args[2] and args[2] ~= "review" and args[2] ~= "implementation") then
            return invalid("start [review|implementation]")
        end
        if args[2] == "review" then
            parley.start()
        else
            parley.start_implementation()
        end
    elseif action == "stop" then
        if #args ~= 1 then
            return invalid("stop")
        end
        parley.stop()
    elseif action == "submit" then
        if #args ~= 1 then
            return invalid("submit")
        end
        if require("parley.workspace").workflow() == "parley" then
            parley.turn()
        else
            parley.ask()
        end
    elseif action == "investigate" then
        local instructions = options.args:match("^%s*investigate%s+(.+)$")
        if not instructions or not instructions:find("%S") then
            return invalid("investigate <instructions>")
        end
        parley.investigate(instructions)
    elseif action == "done" then
        if #args > 2 then
            return invalid("done [review-id]")
        end
        if require("parley.workspace").workflow() == "parley" then
            if args[2] then
                return invalid("done (implementation does not accept a review ID)")
            end
            parley.finish_implementation()
        else
            parley.done(args[2])
        end
    elseif action == "thread" then
        if #args ~= 2 or not vim.tbl_contains({ "resolve", "reopen", "delete" }, args[2]) then
            return invalid("thread resolve|reopen|delete")
        end
        if args[2] == "delete" then
            parley.delete_note()
        else
            parley.resolve_note(args[2] == "resolve")
        end
    elseif action == "demo" then
        if #args > 2 or (args[2] and args[2] ~= "append" and args[2] ~= "reload") then
            return invalid("demo [append|reload]")
        end
        local demo = require("parley.demo")
        if args[2] == "append" then
            demo.append()
        elseif args[2] == "reload" then
            demo.reload()
        else
            demo.open()
        end
    else
        invalid("start|stop|submit|investigate|done|thread|demo")
    end
end, {
    nargs = "*",
    complete = function(lead, line, cursor)
        -- Only consider text before the cursor, including an unfinished argument.
        local prefix = line:sub(1, cursor)
        local args = vim.split(prefix, "%s+", { trimempty = true })
        if prefix:match("%s$") then
            args[#args + 1] = ""
        end
        local candidates = {}
        if #args == 2 then
            candidates = { "start", "stop", "submit", "investigate", "done", "thread", "demo" }
        elseif #args == 3 then
            if args[2] == "start" then
                candidates = { "review", "implementation" }
            elseif args[2] == "thread" then
                candidates = { "resolve", "reopen", "delete" }
            elseif args[2] == "demo" then
                candidates = { "append", "reload" }
            end
        end
        return vim.tbl_filter(function(value)
            return value:sub(1, #lead) == lead
                and (value ~= "investigate" or require("parley.workspace").workflow() ~= "parley")
        end, candidates)
    end,
    desc = "Start, detach, submit, finish, manage threads, or open the local demo",
})
