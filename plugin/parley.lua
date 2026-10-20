if vim.g.loaded_parley then
    return
end
vim.g.loaded_parley = true

vim.api.nvim_create_user_command("ReviewStart", function()
    require("parley").start()
end, { desc = "Enable workspace review mode using the connected Pi session; no capture" })
vim.api.nvim_create_user_command("ReviewStop", function()
    require("parley").stop()
end, { desc = "Detach workspace review; keep buffers and drafts" })

vim.api.nvim_create_user_command("ParleyBind", function()
    require("parley.bridge").bind()
end, {
    desc = "Explicitly bind the current workspace's advertised Pi session; no review activation",
})

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

vim.schedule(function()
    require("parley.bridge").start()
end)
-- Passive workspace discovery belongs to plugin activation, never require("parley").
