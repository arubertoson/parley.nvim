if vim.g.loaded_parley then
    return
end
vim.g.loaded_parley = true

vim.api.nvim_create_user_command("ReviewStart", function()
    require("parley").start()
end, { desc = "Pair with the Pi review offer and start local review; no capture or model work" })
vim.api.nvim_create_user_command("ReviewStop", function()
    require("parley").stop()
end, { desc = "Detach workspace review; keep buffers and drafts" })

vim.api.nvim_create_user_command("ReviewDone", function(options)
    require("parley").done(options.args ~= "" and options.args or nil)
end, {
    nargs = "?",
    desc = "Wrap up this review (or a retained review ID); preserve notes and drafts",
})

vim.api.nvim_create_user_command("ReviewAsk", function()
    require("parley").ask()
end, { desc = "Explicitly submit eligible human comments across all conversations" })
vim.api.nvim_create_user_command("ReviewInvestigate", function(options)
    require("parley").investigate(options.args)
end, { nargs = "+", desc = "Explicitly request investigation with free-form instructions" })

vim.api.nvim_create_user_command("ParleyStart", function()
    require("parley").start_implementation()
end, { desc = "Pair with the /parley implementation fork; no submission" })
vim.api.nvim_create_user_command("ParleyTurn", function()
    require("parley").turn()
end, { desc = "Submit eligible prose across unresolved implementation conversations" })
vim.api.nvim_create_user_command("ParleyDone", function()
    require("parley").finish_implementation()
end, { desc = "Finish implementation and return a recap to the originating Pi parent" })
vim.api.nvim_create_user_command("ParleyStop", function()
    require("parley").stop()
end, { desc = "Detach presentation; does not finish or cancel implementation" })
vim.api.nvim_create_user_command("ParleyResolve", function()
    require("parley").resolve_note(true)
end, { desc = "Exclude the selected conversation from turns; preserve history and drafts" })
vim.api.nvim_create_user_command("ParleyReopen", function()
    require("parley").resolve_note(false)
end, { desc = "Include the selected conversation in future turns; no submission" })

vim.api.nvim_create_user_command("ParleyDemo", function(options)
    if options.args == "append" then
        require("parley.demo").append()
    elseif options.args == "reload" then
        require("parley.demo").reload()
    elseif options.args == "" then
        require("parley.demo").open()
    else
        vim.notify("Parley: expected :ParleyDemo [append|reload]", vim.log.levels.ERROR)
    end
end, {
    nargs = "?",
    complete = function()
        return { "append", "reload" }
    end,
    desc = "Open, append sample history, or reload local demo UI; no agent execution",
})
