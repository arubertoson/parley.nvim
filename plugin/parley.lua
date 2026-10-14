if vim.g.loaded_parley then return end
vim.g.loaded_parley = true

vim.api.nvim_create_user_command(
    "ReviewStart",
    function() require("parley").start() end,
    { desc = "Enable workspace review mode using the connected Pi session; no capture" }
)
vim.api.nvim_create_user_command(
    "ReviewStop",
    function() require("parley").stop() end,
    { desc = "Detach workspace review; keep buffers and drafts" }
)

vim.api.nvim_create_user_command("ParleyBind", function() require("parley.bridge").bind() end, {
    desc = "Explicitly bind the current workspace's advertised Pi session; no review activation",
})

vim.schedule(function() require("parley.bridge").start() end)
-- Passive workspace discovery belongs to plugin activation, never require("parley").
