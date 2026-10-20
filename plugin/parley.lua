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
