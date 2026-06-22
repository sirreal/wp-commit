local M = {}

-- Default configuration
local default_config = {
	enabled = true,
	debug = false, -- Enable debug logging for HTTP requests
	additional_patterns = {},
	trac = {
		cookie_file = nil,
		cookie_env = "WP_COMMIT_TRAC_COOKIE_FILE",
		auth_required = true,
	},
}

local config = {}

function M.setup(opts)
	opts = opts or {}
	config = vim.tbl_deep_extend("force", vim.deepcopy(default_config), config, opts)

	-- Reset plugin autocommands on every setup call so repeated setup is deterministic.
	vim.api.nvim_create_augroup("wp_commit_msg", { clear = true })

	-- Don't set up if disabled
	if not config.enabled then
		return
	end

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
				-- Enable spell checking for commit messages
				vim.opt_local.spell = true

				local ok, linter = pcall(require, "wp-commit.linter")
				if ok then
					linter.attach(bufnr)
				else
					vim.notify("wp-commit: Failed to load linter module", vim.log.levels.WARN)
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
