local M = {}
local trac = require("wp-commit.trac")
local profiles = require("wp-commit.profiles")

-- Namespace for virtual text
local virt_ns = vim.api.nvim_create_namespace("wp-commit-virtual")

-- Debounce timer for validation
local validation_timer = nil

-- Storage for virtual lines per line (to ensure proper ordering)
local virtual_lines_cache = {}
local pending_requests = {} -- Track pending async requests per line

-- Validation generation counter to cancel stale async results
local validation_generation = 0

-- Changeset reference (r12345) at word boundaries - keep the three forms in sync
local CHANGESET_PATTERN = "%f[%w]r%d+%f[%W]"
local CHANGESET_CAPTURE_PATTERN = "%f[%w]r(%d+)%f[%W]"
local function changeset_pattern_for(changeset_num)
	return "%f[%w]r" .. changeset_num .. "%f[%W]"
end

-- Attach linter to a buffer
function M.attach(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Validate buffer is valid and not already attached
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end

	-- Check if already attached (avoid duplicate listeners)
	local existing_var = vim.b[bufnr].wp_commit_msg_attached
	if existing_var then
		return true -- Already attached
	end

	-- Mark as attached
	vim.b[bufnr].wp_commit_msg_attached = true

	-- Use buffer attachment for text changes (more efficient than autocmds)
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function(_, buf)
			-- Double-check buffer is still valid
			if vim.api.nvim_buf_is_valid(buf) then
				M.validate_buffer(buf)
			end
		end,
		on_detach = function(_, buf)
			-- Clean up when buffer is closed
			vim.b[buf].wp_commit_msg_attached = nil
		end,
	})

	-- Initial validation
	M.validate_buffer(bufnr)
	return true
end

-- Validate WordPress commit message format
function M.validate_buffer(bufnr)
	-- Safety checks
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- Don't validate if buffer is too large (performance)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	if line_count > 500 then -- Commit messages shouldn't be this long
		return
	end

	-- Debounce validation to prevent rapid fire
	if validation_timer then
		vim.fn.timer_stop(validation_timer)
	end

	validation_timer = vim.fn.timer_start(100, function()
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local diagnostics = {}
		local code_lines = M.get_code_block_lines(lines)

		-- Increment validation generation to cancel stale async results
		validation_generation = validation_generation + 1
		local current_generation = validation_generation

		-- Clear all existing virtual text first
		vim.api.nvim_buf_clear_namespace(bufnr, virt_ns, 0, -1)

		-- Clear virtual lines cache and pending requests for this buffer
		for cache_key, _ in pairs(virtual_lines_cache) do
			if cache_key:match("^" .. bufnr .. ":") then
				virtual_lines_cache[cache_key] = nil
			end
		end
		for pending_key, _ in pairs(pending_requests) do
			if pending_key:match("^" .. bufnr .. ":") then
				pending_requests[pending_key] = nil
			end
		end

		-- Validate summary line
		M.validate_summary_line(lines, diagnostics)

		-- Validate overall structure and ordering
		M.validate_structure(lines, diagnostics, code_lines)

		-- Validate section content
		M.validate_sections(lines, diagnostics, code_lines)

		-- Count and validate all ticket/changeset references (must be done before section validation)
		M.count_and_validate_references(lines, diagnostics, bufnr, current_generation, code_lines)

		-- Validate ticket and changeset references
		M.validate_references(lines, diagnostics, code_lines)

		-- Set diagnostics
		vim.diagnostic.set(vim.api.nvim_create_namespace("wp-commit"), bufnr, diagnostics)
	end)
end

-- Validate the first line (summary)
function M.validate_summary_line(lines, diagnostics)
	if #lines == 0 then
		table.insert(diagnostics, {
			lnum = 0,
			col = 0,
			end_col = 0,
			severity = vim.diagnostic.severity.ERROR,
			message = "Summary line is required",
			source = "wp-commit",
		})
		return
	end

	local summary_line = lines[1]

	-- Check component prefix format
	if not string.match(summary_line, "^[A-Za-z][A-Za-z0-9%s%-/]*:%s*.+$") then
		table.insert(diagnostics, {
			lnum = 0,
			col = 0,
			end_col = #summary_line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Summary line must start with 'Component: Brief summary.'",
			source = "wp-commit",
		})
	end

	-- Check length (50-70 characters ideal)
	if #summary_line > 70 then
		table.insert(diagnostics, {
			lnum = 0,
			col = 50,
			end_col = #summary_line,
			severity = vim.diagnostic.severity.WARN,
			message = "Summary line should be 50-70 characters (currently " .. #summary_line .. ")",
			source = "wp-commit",
		})
	end

	-- Check capitalization
	local component, summary = string.match(summary_line, "^([^:]+):%s*(.+)$")
	if summary and not string.match(summary, "^%u") then
		table.insert(diagnostics, {
			lnum = 0,
			col = #component + 2,
			end_col = #component + 3,
			severity = vim.diagnostic.severity.WARN,
			message = "Summary should start with capital letter",
			source = "wp-commit",
		})
	end

	-- Check ending punctuation
	if summary and not string.match(summary, "%.$") then
		table.insert(diagnostics, {
			lnum = 0,
			col = #summary_line - 1,
			end_col = #summary_line,
			severity = vim.diagnostic.severity.WARN,
			message = "Summary should end with period",
			source = "wp-commit",
		})
	end
end

-- Trailing sections in their expected order. grouped_after marks section types this one
-- may directly follow with no blank line between them (a blank there is an error).
local SECTIONS = {
	{ type = "devlinks", name = "Developed in/Discussed in", grouped_after = { devlinks = true } },
	{ type = "followup", name = "Follow-up" },
	{ type = "reviewed", name = "Reviewed by" },
	{ type = "merges", name = "Merges", grouped_after = { reviewed = true } },
	{ type = "props", name = "Props" },
	{ type = "tickets", name = "Fixes/See", grouped_after = { props = true } },
}
local SECTION_INFO = {}
local section_names = {}
for order, info in ipairs(SECTIONS) do
	SECTION_INFO[info.type] = { order = order, name = info.name, grouped_after = info.grouped_after or {} }
	table.insert(section_names, info.name)
end
local SECTION_ORDER_MESSAGE = "Sections must be in order: " .. table.concat(section_names, ", ")

-- Validate overall structure and blank line requirements
function M.validate_structure(lines, diagnostics, code_lines)
	if #lines < 2 then
		return
	end

	code_lines = code_lines or M.get_code_block_lines(lines)

	-- Find sections and their line numbers
	local sections = {}
	for i, line in ipairs(lines) do
		local lnum = i - 1

		if code_lines[lnum] then
			-- Lines inside {{{ }}} code blocks are never sections
		elseif M.is_devlink_line(line) then
			table.insert(sections, { type = "devlinks", lnum = lnum, line = line })
		elseif string.match(line, "^Follow%-up to%s+") then
			table.insert(sections, { type = "followup", lnum = lnum, line = line })
		elseif string.match(line, "^Reviewed by%s+") then
			table.insert(sections, { type = "reviewed", lnum = lnum, line = line })
		elseif string.match(line, "^Merges%s+") then
			table.insert(sections, { type = "merges", lnum = lnum, line = line })
		elseif string.match(line, "^Props%s+") then
			table.insert(sections, { type = "props", lnum = lnum, line = line })
		elseif string.match(line, "^Fixes%s+") or string.match(line, "^See%s+") then
			table.insert(sections, { type = "tickets", lnum = lnum, line = line })
		end
	end

	-- Check section order (expected order at end of commit message)
	local last_order_index = 0

	for _, section in ipairs(sections) do
		local order_index = SECTION_INFO[section.type].order

		if order_index < last_order_index then
			table.insert(diagnostics, {
				lnum = section.lnum,
				col = 0,
				end_col = #section.line,
				severity = vim.diagnostic.severity.ERROR,
				message = SECTION_ORDER_MESSAGE,
				source = "wp-commit",
			})
		end

		last_order_index = order_index
	end

	-- Grouped sections should be on consecutive lines (no blank line between)
	for i = 1, #sections - 1 do
		local current_section = sections[i]
		local next_section = sections[i + 1]
		local next_info = SECTION_INFO[next_section.type]

		if next_info.grouped_after[current_section.type] and next_section.lnum > current_section.lnum + 1 then
			-- There's a gap, check if it's a blank line
			for gap_line = current_section.lnum + 1, next_section.lnum - 1 do
				if lines[gap_line + 1] == "" and not code_lines[gap_line] then -- +1 because lines is 1-indexed but lnum is 0-indexed
					local current_name = SECTION_INFO[current_section.type].name
					local message = "Remove blank line between "
						.. current_name
						.. " and "
						.. next_info.name
						.. " sections"
					if current_section.type == next_section.type then
						message = "Remove blank line between " .. current_name .. " lines"
					end
					table.insert(diagnostics, {
						lnum = gap_line,
						col = 0,
						end_col = 0,
						severity = vim.diagnostic.severity.ERROR,
						message = message,
						source = "wp-commit",
					})
				end
			end
		end
	end

	-- Check blank line after summary (line 2 should be blank if description exists)
	if #lines >= 3 and lines[2] ~= "" then
		-- Only require blank line if there's actual description content
		local has_description = false
		for i = 2, #lines do
			-- Code block content counts as description even when a line looks like a section
			if lines[i] ~= "" and (code_lines[i - 1] or not M.is_section_line(lines[i])) then
				has_description = true
				break
			end
		end

		if has_description then
			table.insert(diagnostics, {
				lnum = 1,
				col = 0,
				end_col = 0,
				severity = vim.diagnostic.severity.ERROR,
				message = "Blank line required after summary line",
				source = "wp-commit",
			})
		end
	end

	-- Check for separate Fixes/See lines (should be combined)
	local fixes_line = nil
	local see_line = nil
	for _, section in ipairs(sections) do
		if section.type == "tickets" then
			if string.match(section.line, "^Fixes%s+") then
				fixes_line = section.lnum
			elseif string.match(section.line, "^See%s+") then
				see_line = section.lnum
			end
		end
	end

	if fixes_line and see_line and fixes_line ~= see_line then
		table.insert(diagnostics, {
			lnum = see_line,
			col = 0,
			end_col = #lines[see_line + 1],
			severity = vim.diagnostic.severity.ERROR,
			message = "Fixes and See should be on the same line: 'Fixes #123. See #456.'",
			source = "wp-commit",
		})
	end

	-- Check for multiple consecutive blank lines (allowed inside {{{ }}} code blocks)
	for i = 1, #lines - 1 do
		if lines[i] == "" and lines[i + 1] == "" and not code_lines[i - 1] and not code_lines[i] then
			table.insert(diagnostics, {
				lnum = i,
				col = 0,
				end_col = 0,
				severity = vim.diagnostic.severity.ERROR,
				message = "Remove extra blank line - only single blank lines allowed",
				source = "wp-commit",
			})
		end
	end

	-- Check blank lines before major sections
	for i, section in ipairs(sections) do
		if section.lnum > 0 and lines[section.lnum] ~= "" then
			-- Grouped sections don't need a blank line when directly after their partner
			local skip_blank_line = false
			if i > 1 then
				local prev_section = sections[i - 1]
				skip_blank_line = SECTION_INFO[section.type].grouped_after[prev_section.type] == true
					and prev_section.lnum == section.lnum - 1
			end

			if not skip_blank_line then
				table.insert(diagnostics, {
					lnum = section.lnum - 1,
					col = 0,
					end_col = 0,
					severity = vim.diagnostic.severity.WARN,
					message = "Add blank line before " .. SECTION_INFO[section.type].name .. " section",
					source = "wp-commit",
				})
			end
		end
	end
end

-- Helper function to identify section lines
function M.is_section_line(line)
	return string.match(line, "^Props%s+")
		or string.match(line, "^Fixes%s+")
		or string.match(line, "^See%s+")
		or string.match(line, "^Follow%-up to%s+")
		or string.match(line, "^Reviewed by%s+")
		or string.match(line, "^Merges%s+")
		or M.is_devlink_line(line)
end

-- Devlink shape: the keyword must be followed by a colon or directly by a URL, so prose
-- like "Discussed in the Slack thread: <URL>" isn't misidentified, while a colon form
-- with no URL is still detected (validate_devlink_line reports the missing URL).
local function is_devlink_shaped(line)
	return string.match(line, "^%a+ in:") ~= nil or string.match(line, "^%a+ in%s+https?://") ~= nil
end

-- Devlink lines: "Developed in: <URL>" per the handbook, but "Developed in <URL>." (no
-- colon, trailing period) also appears in real commits.
function M.is_devlink_line(line)
	if not string.match(line, "^Developed in") and not string.match(line, "^Discussed in") then
		return false
	end
	return is_devlink_shaped(line)
end

-- Identify lines inside {{{ }}} code blocks (returns set keyed by 0-indexed lnum)
function M.get_code_block_lines(lines)
	local in_block = false
	local block_lines = {}
	for i, line in ipairs(lines) do
		if not in_block and string.match(line, "^%s*{{{") then
			block_lines[i - 1] = true
			-- A block opened and closed on the same line must not latch in_block
			in_block = string.match(line, "}}}%s*$") == nil
		elseif in_block then
			block_lines[i - 1] = true
			if string.match(line, "^%s*}}}%s*$") then
				in_block = false
			end
		end
	end
	return block_lines
end

-- Blank out pattern matches with same-length spaces so scans skip them while
-- column positions are preserved
local function mask_matches(line, pattern)
	return (string.gsub(line, pattern, function(match)
		return string.rep(" ", #match)
	end))
end

-- Mask URLs so reference scans don't match r123/#123 sequences inside them
-- (e.g. GitHub #discussion_r123 anchors)
function M.mask_urls(line)
	return mask_matches(line, "https?://%S+")
end

-- Validate section structure (Props, Fixes, etc.)
function M.validate_sections(lines, diagnostics, code_lines)
	code_lines = code_lines or M.get_code_block_lines(lines)

	for i, line in ipairs(lines) do
		local lnum = i - 1

		-- Lines inside {{{ }}} code blocks are never sections. Detection is
		-- case-insensitive so miscapitalized sections are still validated; each
		-- validator reports the capitalization error itself.
		if not code_lines[lnum] then
			local lower_line = string.lower(line)

			if string.match(lower_line, "^props%s+") then
				M.validate_props_line(line, lnum, diagnostics)
			end

			if string.match(lower_line, "^fixes%s+") then
				M.validate_fixes_line(line, lnum, diagnostics)
			end

			if string.match(lower_line, "^see%s+") then
				M.validate_see_line(line, lnum, diagnostics)
			end

			if string.match(lower_line, "^follow%-up to%s+") then
				M.validate_followup_line(line, lnum, diagnostics)
			end

			if string.match(lower_line, "^reviewed by%s+") then
				M.validate_reviewed_line(line, lnum, diagnostics)
			end

			if string.match(lower_line, "^merges%s+") then
				M.validate_merges_line(line, lnum, diagnostics)
			end

			if
				(string.match(lower_line, "^developed in") or string.match(lower_line, "^discussed in"))
				and is_devlink_shaped(lower_line)
			then
				M.validate_devlink_line(line, lnum, diagnostics)
			end
		end
	end
end

-- Validate Props line: "Props username, another, third."
function M.validate_props_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Props%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 5,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Props' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check basic format
	if not string.match(line, "^Props%s+[a-zA-Z0-9_%-]") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Props format should be 'Props username, another.'",
			source = "wp-commit",
		})
		return
	end

	-- Check ending period
	if not string.match(line, "%.$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = #line - 1,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Props line must end with period",
			source = "wp-commit",
		})
	end

	-- Extract and validate usernames
	local props_content = string.match(line, "^Props%s+(.+)%.$")
	if props_content then
		local usernames = {}
		-- Split by comma and collect usernames
		for username in string.gmatch(props_content, "([^,]+)") do
			username = string.match(username, "^%s*(.-)%s*$") -- trim spaces
			if not string.match(username, "^[a-zA-Z0-9_%-]+$") then
				table.insert(diagnostics, {
					lnum = lnum,
					col = 0,
					end_col = #line,
					severity = vim.diagnostic.severity.WARN,
					message = "Invalid username format: '" .. username .. "'",
					source = "wp-commit",
				})
			else
				table.insert(usernames, username)
			end
		end

		-- Validate usernames exist on WordPress.org
		if #usernames > 0 then
			local bufnr = vim.api.nvim_get_current_buf()
			local current_gen = validation_generation
			profiles.validate_usernames(usernames, function(results)
				-- Only apply results if this validation is still current
				if current_gen == validation_generation then
					M.update_username_virtual_text(bufnr, lnum, usernames, results)
				end
			end)
		end
	end
end

-- Validate Fixes line: "Fixes #12345, #67890."
function M.validate_fixes_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Fixes%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 5,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Fixes' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check basic format - must have ticket numbers
	if not string.match(line, "#%d+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Fixes line must contain ticket numbers like #12345",
			source = "wp-commit",
		})
	end

	-- Check ending period
	if not string.match(line, "%.$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = #line - 1,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Fixes line must end with period",
			source = "wp-commit",
		})
	end
end

-- Validate See line: "See #12345, #67890."
function M.validate_see_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^See%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 3,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'See' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check basic format - must have ticket numbers
	if not string.match(line, "#%d+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "See line must contain ticket numbers like #12345",
			source = "wp-commit",
		})
	end

	-- Check ending period
	if not string.match(line, "%.$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = #line - 1,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "See line must end with period",
			source = "wp-commit",
		})
	end
end

-- Validate Follow-up line: "Follow-up to r12345, r67890."
function M.validate_followup_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Follow%-up to%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 9,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Follow-up' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check basic format - must have changeset references. The legacy [123] form counts:
	-- it already gets a dedicated deprecated-format error from validate_references.
	if not string.match(line, CHANGESET_PATTERN) and not string.match(line, "%[%d+%]") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Follow-up line must contain changeset references like r12345",
			source = "wp-commit",
		})
	end

	-- Check ending period
	if not string.match(line, "%.$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = #line - 1,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Follow-up line must end with period",
			source = "wp-commit",
		})
	end
end

-- Validate Reviewed by line: "Reviewed by username, another."
function M.validate_reviewed_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Reviewed by%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 11,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Reviewed by' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check basic format
	if not string.match(line, "^Reviewed by%s+[a-zA-Z0-9_%-]") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Reviewed by format should be 'Reviewed by username, another.'",
			source = "wp-commit",
		})
	end

	-- Check ending period
	if not string.match(line, "%.$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = #line - 1,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Reviewed by line must end with period",
			source = "wp-commit",
		})
	end

	-- Extract and validate usernames
	local reviewed_content = string.match(line, "^Reviewed by%s+(.+)%.$")
	if reviewed_content then
		local usernames = {}
		for username in string.gmatch(reviewed_content, "([^,]+)") do
			username = string.match(username, "^%s*(.-)%s*$") -- trim spaces
			if not string.match(username, "^[a-zA-Z0-9_%-]+$") then
				table.insert(diagnostics, {
					lnum = lnum,
					col = 0,
					end_col = #line,
					severity = vim.diagnostic.severity.WARN,
					message = "Invalid username format: '" .. username .. "'",
					source = "wp-commit",
				})
			else
				table.insert(usernames, username)
			end
		end

		if #usernames > 0 then
			local bufnr = vim.api.nvim_get_current_buf()
			local current_gen = validation_generation
			profiles.validate_usernames(usernames, function(results)
				if current_gen == validation_generation then
					M.update_username_virtual_text(bufnr, lnum, usernames, results)
				end
			end)
		end
	end
end

-- Validate Merges line: "Merges r12345 to the 6.4 branch." - backport commits routinely
-- list several changesets, so comma- and "and"-separated lists are accepted.
function M.validate_merges_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Merges%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 6,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Merges' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check format with changeset list and branch
	local refs = string.match(line, "^Merges%s+(.-)%s+to%s+the%s+[%d%.]+%s+branch%.$")
	local valid_refs = false
	if refs then
		for token in string.gmatch(refs, "[^,%s]+") do
			-- Legacy [123] refs count: they get a dedicated deprecated-format error
			if string.match(token, "^r%d+$") or string.match(token, "^%[%d+%]$") then
				valid_refs = true
			elseif token ~= "and" then
				valid_refs = false
				break
			end
		end
	end
	if not valid_refs then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Merges format should be 'Merges r12345 to the x.x branch.'",
			source = "wp-commit",
		})
	end
end

-- Validate link lines: "Developed in: <URL>" / "Discussed in: <URL>"
-- The colon and a trailing period are both optional (see is_devlink_line).
function M.validate_devlink_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Developed in") and not string.match(line, "^Discussed in") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 12,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Developed in' or 'Discussed in' (capitalized)",
			source = "wp-commit",
		})
	end

	-- Check format - keyword followed by a single URL (compared case-insensitively so a
	-- miscapitalized line doesn't also get a redundant format error)
	if not string.match(string.lower(line), "^%a+ in:?%s+https?://%S+$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Format should be 'Developed in: <URL>' or 'Discussed in: <URL>'",
			source = "wp-commit",
		})
	end
end

-- Count and validate all ticket/changeset references per line
function M.count_and_validate_references(lines, diagnostics, bufnr, generation, code_lines)
	code_lines = code_lines or M.get_code_block_lines(lines)

	for i, line in ipairs(lines) do
		local lnum = i - 1

		-- Lines inside {{{ }}} code blocks have no live references
		if not code_lines[lnum] then
			local total_references = 0

			-- Count all tickets and changesets on this line, deduplicated so a repeated
			-- ref doesn't stack duplicate markers on its first occurrence (URLs masked
			-- so their digits don't register as references)
			local scannable = M.mask_urls(line)
			local seen = {}
			local tickets = {}
			for ticket_num in string.gmatch(scannable, "#(%d+)") do
				if not seen["#" .. ticket_num] then
					seen["#" .. ticket_num] = true
					table.insert(tickets, ticket_num)
					total_references = total_references + 1
				end
			end

			local changesets = {}
			for changeset_num in string.gmatch(scannable, CHANGESET_CAPTURE_PATTERN) do
				if not seen["r" .. changeset_num] then
					seen["r" .. changeset_num] = true
					table.insert(changesets, changeset_num)
					total_references = total_references + 1
				end
			end

			-- If we have any references on this line, initialize and validate them
			if total_references > 0 then
				M.init_pending_requests(bufnr, lnum, total_references)

				-- Validate all tickets
				for _, ticket_num in ipairs(tickets) do
					trac.validate_ticket(ticket_num, function(exists, title, status)
						-- Only apply results if this validation is still current
						if generation == validation_generation then
							M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title, status)
						end
					end)
				end

				-- Validate all changesets
				for _, changeset_num in ipairs(changesets) do
					trac.validate_changeset(changeset_num, function(exists, message, status)
						-- Only apply results if this validation is still current
						if generation == validation_generation then
							M.update_changeset_virtual_text(bufnr, lnum, changeset_num, exists, message, status)
						end
					end)
				end
			end
		end
	end
end

-- Validate ticket (#123) and changeset (r123) reference formatting
function M.validate_references(lines, diagnostics, code_lines)
	code_lines = code_lines or M.get_code_block_lines(lines)

	for i, line in ipairs(lines) do
		local lnum = i - 1

		-- Skip lines inside {{{ }}} code blocks
		if not code_lines[lnum] then
			-- Flag deprecated changeset format: [123] is now r123. Backtick code spans
			-- are masked and subscripts like $args[0] are skipped - those brackets are
			-- code, not changeset references.
			local bracket_scannable = mask_matches(line, "`[^`]*`")
			local search_start = 1
			while true do
				local start_col, end_col, changeset_num = string.find(bracket_scannable, "%[(%d+)%]", search_start)
				if not start_col then
					break
				end
				local preceding = start_col > 1 and string.sub(bracket_scannable, start_col - 1, start_col - 1) or ""
				if not string.match(preceding, "[%w_%]]") then
					table.insert(diagnostics, {
						lnum = lnum,
						col = start_col - 1,
						end_col = end_col,
						severity = vim.diagnostic.severity.ERROR,
						message = "Changesets use the r" .. changeset_num .. " format, not [" .. changeset_num .. "]",
						source = "wp-commit",
					})
				end
				search_start = end_col + 1
			end

			-- Find code spans (`code`) and validate backticks are paired
			local backtick_count = 0
			for _ in string.gmatch(line, "`") do
				backtick_count = backtick_count + 1
			end
			if backtick_count % 2 ~= 0 then
				table.insert(diagnostics, {
					lnum = lnum,
					col = 0,
					end_col = #line,
					severity = vim.diagnostic.severity.WARN,
					message = "Unpaired backticks - code should be wrapped in `backticks`",
					source = "wp-commit",
				})
			end
		end
	end
end

-- Helper functions for managing virtual lines ordering

-- Initialize pending requests counter for a line
function M.init_pending_requests(bufnr, lnum, count)
	local pending_key = bufnr .. ":" .. lnum
	pending_requests[pending_key] = count

	-- Clear any existing cache for this line
	local cache_key = bufnr .. ":" .. lnum
	virtual_lines_cache[cache_key] = {}
end

-- Add a virtual line to the cache and check if we should apply
function M.add_virtual_line(bufnr, lnum, position, content, hl_group)
	local cache_key = bufnr .. ":" .. lnum
	local pending_key = bufnr .. ":" .. lnum

	if not virtual_lines_cache[cache_key] then
		virtual_lines_cache[cache_key] = {}
	end

	table.insert(virtual_lines_cache[cache_key], {
		position = position,
		content = content,
		hl_group = hl_group,
	})

	-- Decrement pending counter
	if pending_requests[pending_key] then
		pending_requests[pending_key] = pending_requests[pending_key] - 1

		-- If all requests are complete, apply virtual lines
		if pending_requests[pending_key] <= 0 then
			M.apply_virtual_lines(bufnr, lnum)
			pending_requests[pending_key] = nil
		end
	end
end

-- Apply all cached virtual lines for a specific buffer and line
function M.apply_virtual_lines(bufnr, lnum)
	local cache_key = bufnr .. ":" .. lnum
	local line_cache = virtual_lines_cache[cache_key]

	if line_cache and #line_cache > 0 then
		-- Sort by position to ensure correct order
		table.sort(line_cache, function(a, b)
			return a.position < b.position
		end)

		-- Create virtual lines array
		local virt_lines = {}
		for _, item in ipairs(line_cache) do
			table.insert(virt_lines, { { item.content, item.hl_group } })
		end

		vim.schedule(function()
			vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, 0, {
				virt_lines = virt_lines,
				virt_lines_above = false,
			})
		end)
	end
end

-- Virtual text functions for API validation results

local function get_trac_unknown_message(status)
	if status == "auth_missing" then
		return "Trac cookie not configured"
	elseif status == "cookie_unreadable" then
		return "Trac cookie file is not readable"
	elseif status == "cookie_invalid_format" then
		return "Trac cookie file format is not supported"
	elseif status == "auth_failed" then
		return "Trac auth failed; cookie may be expired"
	elseif status == "network" then
		return "Trac unavailable; not checked"
	elseif status == "unexpected_response" then
		return "Trac returned an unexpected response"
	end

	return "Trac reference not checked"
end

-- Update virtual text for usernames (Props, Reviewed by)
function M.update_username_virtual_text(bufnr, lnum, usernames, results)
	vim.schedule(function()
		local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""

		-- Clear existing extmarks for this line
		local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, virt_ns, { lnum, 0 }, { lnum, -1 }, {})
		for _, extmark in ipairs(extmarks) do
			vim.api.nvim_buf_del_extmark(bufnr, virt_ns, extmark[1])
		end

		-- Add inline status for each username
		local valid_users_with_names = {}
		for _, username in ipairs(usernames) do
			local pattern = "(" .. vim.pesc(username) .. ")"
			local start_col, end_col = string.find(line_text, pattern)

			if start_col and end_col then
				local user_data = results[username]
				local exists = user_data and user_data.exists or false
				local status = exists and " ✓" or " ✗"
				local hl = exists and "DiagnosticOk" or "DiagnosticError"

				vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, end_col, {
					virt_text = { { status, hl } },
					virt_text_pos = "inline",
				})

				-- Collect valid users with full names for virtual line
				if exists and user_data.full_name then
					table.insert(valid_users_with_names, user_data.full_name .. " (" .. username .. ")")
				end
			end
		end

		-- Add virtual line showing full names of valid users
		if #valid_users_with_names > 0 then
			local message = " → " .. table.concat(valid_users_with_names, ", ")
			vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, 0, {
				virt_lines = { { { message, "DiagnosticInfo" } } },
				virt_lines_above = false,
			})
		end
	end)
end

-- Update virtual text for ticket validation
function M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title, status)
	vim.schedule(function()
		local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""

		-- Find the ticket reference in the line to get its position
		-- (URLs masked so a #digit fragment inside one isn't picked as the anchor)
		local pattern = "#" .. ticket_num
		local start_col, end_col = string.find(M.mask_urls(line_text), vim.pesc(pattern))

		if start_col and end_col then
			local state = status or (exists and "valid" or "not_found")
			local marker = state == "valid" and " ✓" or state == "not_found" and " ✗" or " ?"
			local hl = state == "valid" and "DiagnosticOk"
				or state == "not_found" and "DiagnosticError"
				or "DiagnosticWarn"

			-- Add status right after the ticket reference
			vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, end_col, {
				virt_text = { { marker, hl } },
				virt_text_pos = "inline",
			})

			-- Add detailed info to virtual lines cache (using start_col for ordering)
			local content
			if state == "valid" and title then
				content = " → " .. title
				hl = "DiagnosticInfo"
			elseif state == "valid" then
				content = " → Ticket #" .. ticket_num .. " exists"
				hl = "DiagnosticOk"
			elseif state == "not_found" then
				content = " → Ticket #" .. ticket_num .. " not found"
				hl = "DiagnosticError"
			else
				content = " → Ticket #" .. ticket_num .. " not checked (" .. get_trac_unknown_message(state) .. ")"
				hl = "DiagnosticWarn"
			end

			M.add_virtual_line(bufnr, lnum, start_col, content, hl)
		end
	end)
end

-- Update virtual text for changeset validation
function M.update_changeset_virtual_text(bufnr, lnum, changeset_num, exists, message, status)
	vim.schedule(function()
		local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""

		-- Find the changeset reference in the line to get its position
		-- (URLs masked so an r-digit sequence inside one isn't picked as the anchor)
		local pattern = changeset_pattern_for(changeset_num)
		local start_col, end_col = string.find(M.mask_urls(line_text), pattern)

		if start_col and end_col then
			local state = status or (exists and "valid" or "not_found")
			local marker = state == "valid" and " ✓" or state == "not_found" and " ✗" or " ?"
			local hl = state == "valid" and "DiagnosticOk"
				or state == "not_found" and "DiagnosticError"
				or "DiagnosticWarn"

			-- Add status right after the changeset reference
			vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, end_col, {
				virt_text = { { marker, hl } },
				virt_text_pos = "inline",
			})

			-- Add detailed info to virtual lines cache (using start_col for ordering)
			local content
			if state == "valid" and message then
				content = " → " .. message
				hl = "DiagnosticInfo"
			elseif state == "valid" then
				content = " → Changeset r" .. changeset_num .. " exists"
				hl = "DiagnosticOk"
			elseif state == "not_found" then
				content = " → Changeset r" .. changeset_num .. " not found"
				hl = "DiagnosticError"
			else
				content = " → Changeset r"
					.. changeset_num
					.. " not checked ("
					.. get_trac_unknown_message(state)
					.. ")"
				hl = "DiagnosticWarn"
			end

			M.add_virtual_line(bufnr, lnum, start_col, content, hl)
		end
	end)
end

-- Cleanup function for memory management
function M.cleanup()
	-- Stop any running validation timer
	if validation_timer then
		vim.fn.timer_stop(validation_timer)
		validation_timer = nil
	end

	-- Clear all caches
	virtual_lines_cache = {}
	pending_requests = {}

	-- Reset validation generation
	validation_generation = 0

	-- Clear namespace
	vim.api.nvim_buf_clear_namespace(0, virt_ns, 0, -1)
end

-- Expose some internal state for debugging
function M._debug_info()
	return {
		validation_generation = validation_generation,
		cache_size = vim.tbl_count(virtual_lines_cache),
		pending_size = vim.tbl_count(pending_requests),
		timer_active = validation_timer ~= nil,
	}
end

return M
