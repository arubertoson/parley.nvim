vim.cmd([[let &runtimepath.=','.getcwd()]])
vim.cmd("packadd mini.nvim")

if #vim.api.nvim_list_uis() == 0 then require("mini.test").setup() end
