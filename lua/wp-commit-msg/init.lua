local M = {}

-- Default configuration
local default_config = {
	enabled = true,
	additional_patterns = {},
}

local config = {}

function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_extend("force", default_config, opts)

	-- Don't set up if disabled
	if not config.enabled then
		return
	end

	-- Set up autocommands for commit message files
	vim.api.nvim_create_augroup("wp_commit_msg", { clear = true })

	-- Build file patterns (default + user additions)
	local patterns = { "COMMIT_EDITMSG", "svn-commit.tmp" }
	for _, pattern in ipairs(config.additional_patterns) do
		table.insert(patterns, pattern)
	end

	-- Detect commit message files and enable the plugin
	vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
		group = "wp_commit_msg",
		pattern = patterns,
		callback = function()
			local bufnr = vim.api.nvim_get_current_buf()

			-- Only attach to normal buffers with proper filetype
			if vim.api.nvim_buf_get_option(bufnr, "buftype") == "" then
				local ok, linter = pcall(require, "wp-commit-msg.linter")
				if ok then
					linter.attach(bufnr)
				else
					vim.notify("wp-commit-msg: Failed to load linter module", vim.log.levels.WARN)
				end
			end
		end,
	})
end

-- Get current configuration (useful for testing/debugging)
function M.get_config()
	return config
end

return M
