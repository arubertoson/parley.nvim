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
    { desc = "Detach workspace review and restore visited-buffer mappings; keep drafts" }
)

for command, action in pairs({
    ReviewTurn = "submit",
    ReviewSave = "save",
    ReviewScope = "scope",
    ReviewClose = "close",
    ReviewReply = "reply",
    ReviewConclude = "conclude",
    ReviewReopen = "reopen",
    ReviewCollect = "collect",
    ReviewFinish = "finish",
    ReviewDone = "finish",
    ReviewOpen = "open_offer",
    ReviewDismiss = "dismiss_offer",
    ReviewConclusions = "conclusions",
}) do
    vim.api.nvim_create_user_command(command, function() require("parley")[action]() end, {
        desc = action == "finish"
                and "Hand all review threads to Pi for planning; no fixing authority"
            or action == "open_offer" and "Open the exact offered frozen review"
            or action == "dismiss_offer" and "Hide the offer; retain the frozen review"
            or action == "scope" and "Show current frozen piece and agent coverage; no model work"
            or "Parley: " .. action,
    })
end

-- Passive workspace discovery belongs to plugin activation, never require("parley").
vim.schedule(function() require("parley.connected").watch() end)
