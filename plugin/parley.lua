if vim.g.loaded_parley then return end
vim.g.loaded_parley = true

vim.api.nvim_create_user_command(
    "ReviewStart",
    function() require("parley").start() end,
    { desc = "Select a frozen Pi review in this workspace" }
)
vim.api.nvim_create_user_command(
    "ReviewStop",
    function() require("parley").stop() end,
    { desc = "Exit review and restore the source window" }
)

for command, action in pairs({
    ReviewTurn = "submit",
    ReviewSave = "save",
    ReviewClose = "close",
    ReviewReply = "reply",
}) do
    vim.api.nvim_create_user_command(command, function() require("parley")[action]() end, {
        desc = "Parley: " .. action,
    })
end
