local M = {}

function M.setup(opts)
  opts = opts or {}
  
  -- Set up autocommands for commit message files
  vim.api.nvim_create_augroup("wp_commit_msg", { clear = true })
  
  -- Detect commit message files and enable the plugin
  vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
    group = "wp_commit_msg",
    pattern = { "COMMIT_EDITMSG", "svn-commit.tmp" },
    callback = function()
      require("wp-commit-msg.linter").attach(0)
    end,
  })
end

return M