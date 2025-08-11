local M = {}
local trac = require("wp-commit-msg.trac")
local profiles = require("wp-commit-msg.profiles")

-- Namespace for virtual text
local virt_ns = vim.api.nvim_create_namespace("wp-commit-msg-virtual")

-- Debounce timer for validation
local validation_timer = nil

-- Storage for virtual lines per line (to ensure proper ordering)
local virtual_lines_cache = {}
local pending_requests = {} -- Track pending async requests per line

-- Attach linter to a buffer
function M.attach(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	-- Attach to buffer changes
	vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = function()
			M.validate_buffer(bufnr)
		end,
	})

	-- Also listen for text changes (catches joins, deletions, etc.)
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = bufnr,
		callback = function()
			M.validate_buffer(bufnr)
		end,
	})

	-- Initial validation
	M.validate_buffer(bufnr)
end

-- Validate WordPress commit message format
function M.validate_buffer(bufnr)
	-- Debounce validation to prevent rapid fire
	if validation_timer then
		vim.fn.timer_stop(validation_timer)
	end

	validation_timer = vim.fn.timer_start(100, function()
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local diagnostics = {}

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
		M.validate_structure(lines, diagnostics)

		-- Validate section content
		M.validate_sections(lines, diagnostics)

		-- Count and validate all ticket/changeset references (must be done before section validation)
		M.count_and_validate_references(lines, diagnostics)

		-- Validate ticket and changeset references
		M.validate_references(lines, diagnostics)

		-- Set diagnostics
		vim.diagnostic.set(vim.api.nvim_create_namespace("wp-commit-msg"), bufnr, diagnostics)
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
		})
	end
end

-- Validate overall structure and blank line requirements
function M.validate_structure(lines, diagnostics)
	if #lines < 2 then
		return
	end

	-- Find sections and their line numbers
	local sections = {}
	for i, line in ipairs(lines) do
		local lnum = i - 1

		if string.match(line, "^Follow%-up to%s+") then
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
	local expected_order = { "followup", "reviewed", "merges", "props", "tickets" }
	local last_order_index = 0

	for _, section in ipairs(sections) do
		local order_index = 0
		for i, expected_type in ipairs(expected_order) do
			if section.type == expected_type then
				order_index = i
				break
			end
		end

		if order_index > 0 and order_index < last_order_index then
			table.insert(diagnostics, {
				lnum = section.lnum,
				col = 0,
				end_col = #section.line,
				severity = vim.diagnostic.severity.ERROR,
				message = "Sections must be in order: Follow-up, Reviewed by, Merges, Props, Fixes/See",
				source = "wp-commit-msg",
			})
		end

		if order_index > 0 then
			last_order_index = order_index
		end
	end

	-- Check blank line after summary (line 2 should be blank if description exists)
	if #lines >= 3 and lines[2] ~= "" then
		-- Only require blank line if there's actual description content
		local has_description = false
		for i = 2, #lines do
			if lines[i] ~= "" and not M.is_section_line(lines[i]) then
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
				source = "wp-commit-msg",
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
			source = "wp-commit-msg",
		})
	end

	-- Check for multiple consecutive blank lines
	for i = 1, #lines - 1 do
		if lines[i] == "" and lines[i + 1] == "" then
			table.insert(diagnostics, {
				lnum = i,
				col = 0,
				end_col = 0,
				severity = vim.diagnostic.severity.ERROR,
				message = "Remove extra blank line - only single blank lines allowed",
				source = "wp-commit-msg",
			})
		end
	end

	-- Check blank lines before major sections
	for _, section in ipairs(sections) do
		if section.lnum > 0 and lines[section.lnum] ~= "" then
			local section_name = section.type == "tickets" and "ticket references" or section.type
			table.insert(diagnostics, {
				lnum = section.lnum - 1,
				col = 0,
				end_col = 0,
				severity = vim.diagnostic.severity.WARN,
				message = "Add blank line before " .. section_name .. " section",
				source = "wp-commit-msg",
			})
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
end

-- Validate section structure (Props, Fixes, etc.)
function M.validate_sections(lines, diagnostics)
	for i, line in ipairs(lines) do
		local lnum = i - 1

		-- Check Props section format (case-insensitive detection, but validate capitalization)
		if string.match(string.lower(line), "^props%s+") then
			M.validate_props_line(line, lnum, diagnostics)
		end

		-- Check Fixes section format (case-insensitive detection, but validate capitalization)
		if string.match(string.lower(line), "^fixes%s+") then
			M.validate_fixes_line(line, lnum, diagnostics)
		end

		-- Check See section format (case-insensitive detection, but validate capitalization)
		if string.match(string.lower(line), "^see%s+") then
			M.validate_see_line(line, lnum, diagnostics)
		end

		-- Check Follow-up section format (case-insensitive detection, but validate capitalization)
		if string.match(string.lower(line), "^follow%-up to%s+") then
			M.validate_followup_line(line, lnum, diagnostics)
		end

		-- Check Reviewed by section format (case-insensitive detection, but validate capitalization)
		if string.match(string.lower(line), "^reviewed by%s+") then
			M.validate_reviewed_line(line, lnum, diagnostics)
		end

		-- Check Merges section format (case-insensitive detection, but validate capitalization)
		if string.match(string.lower(line), "^merges%s+") then
			M.validate_merges_line(line, lnum, diagnostics)
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
					source = "wp-commit-msg",
				})
			else
				table.insert(usernames, username)
			end
		end

		-- Validate usernames exist on WordPress.org
		if #usernames > 0 then
			local bufnr = vim.api.nvim_get_current_buf()
			profiles.validate_usernames(usernames, function(results)
				M.update_props_virtual_text(bufnr, lnum, usernames, results)
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
		})
	end
end

-- Validate Follow-up line: "Follow-up to [12345], [67890]."
function M.validate_followup_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Follow%-up to%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 9,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Follow-up' (capitalized)",
			source = "wp-commit-msg",
		})
	end

	-- Check basic format - must have changeset numbers
	if not string.match(line, "%[%d+%]") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Follow-up line must contain changeset numbers like [12345]",
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
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
			source = "wp-commit-msg",
		})
	end
end

-- Validate Merges line: "Merges [12345] to the 6.4 branch."
function M.validate_merges_line(line, lnum, diagnostics)
	-- Check capitalization first
	if not string.match(line, "^Merges%s+") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = 6,
			severity = vim.diagnostic.severity.ERROR,
			message = "Should be 'Merges' (capitalized)",
			source = "wp-commit-msg",
		})
	end

	-- Check format with changeset and branch
	if not string.match(line, "^Merges%s+%[%d+%]%s+to%s+the%s+[%d%.]+%s+branch%.$") then
		table.insert(diagnostics, {
			lnum = lnum,
			col = 0,
			end_col = #line,
			severity = vim.diagnostic.severity.ERROR,
			message = "Merges format should be 'Merges [12345] to the x.x branch.'",
			source = "wp-commit-msg",
		})
	end
end

-- Count and validate all ticket/changeset references per line
function M.count_and_validate_references(lines, diagnostics)
	local bufnr = vim.api.nvim_get_current_buf()

	for i, line in ipairs(lines) do
		local lnum = i - 1
		local total_references = 0

		-- Count all tickets and changesets on this line
		local tickets = {}
		for ticket_match in string.gmatch(line, "(#%d+)") do
			local ticket_num = string.match(ticket_match, "#(%d+)")
			table.insert(tickets, ticket_num)
			total_references = total_references + 1
		end

		local changesets = {}
		for changeset_match in string.gmatch(line, "(%[%d+%])") do
			local changeset_num = string.match(changeset_match, "%[(%d+)%]")
			table.insert(changesets, changeset_num)
			total_references = total_references + 1
		end

		-- If we have any references on this line, initialize and validate them
		if total_references > 0 then
			M.init_pending_requests(bufnr, lnum, total_references)

			-- Validate all tickets
			for _, ticket_num in ipairs(tickets) do
				trac.validate_ticket(ticket_num, function(exists, title)
					M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title)
				end)
			end

			-- Validate all changesets
			for _, changeset_num in ipairs(changesets) do
				trac.validate_changeset(changeset_num, function(exists, message)
					M.update_changeset_virtual_text(bufnr, lnum, changeset_num, exists, message)
				end)
			end
		end
	end
end

-- Validate ticket (#123) and changeset ([123]) references
function M.validate_references(lines, diagnostics)
	for i, line in ipairs(lines) do
		local lnum = i - 1

		-- Find ticket references (#123)
		for ticket_num in string.gmatch(line, "#(%d+)") do
			local start_col = string.find(line, "#" .. ticket_num) - 1
			-- TODO: Validate ticket exists via API
			-- For now, just highlight the reference
		end

		-- Find changeset references ([123])
		for changeset_num in string.gmatch(line, "%[(%d+)%]") do
			local start_col = string.find(line, "%[" .. changeset_num .. "%]") - 1
			-- TODO: Validate changeset exists via API
			-- For now, just highlight the reference
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
				source = "wp-commit-msg",
			})
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

-- Update virtual text for Props usernames
function M.update_props_virtual_text(bufnr, lnum, usernames, results)
	vim.schedule(function()
		local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""

		-- Clear existing extmarks for this line
		local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, virt_ns, { lnum, 0 }, { lnum, -1 }, {})
		for _, extmark in ipairs(extmarks) do
			vim.api.nvim_buf_del_extmark(bufnr, virt_ns, extmark[1])
		end

		-- Add inline status for each username
		for _, username in ipairs(usernames) do
			local pattern = "(" .. vim.pesc(username) .. ")"
			local start_col, end_col = string.find(line_text, pattern)

			if start_col and end_col then
				local status = results[username] and " ✓" or " ✗"
				local hl = results[username] and "DiagnosticOk" or "DiagnosticError"

				vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, end_col, {
					virt_text = { { status, hl } },
					virt_text_pos = "inline",
				})
			end
		end
	end)
end

-- Update virtual text for ticket validation
function M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title)
	vim.schedule(function()
		local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""

		-- Find the ticket reference in the line to get its position
		local pattern = "#" .. ticket_num
		local start_col, end_col = string.find(line_text, vim.pesc(pattern))

		if start_col and end_col then
			local status = exists and " ✓" or " ✗"
			local hl = exists and "DiagnosticOk" or "DiagnosticError"

			-- Add status right after the ticket reference
			vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, end_col, {
				virt_text = { { status, hl } },
				virt_text_pos = "inline",
			})

			-- Add detailed info to virtual lines cache (using start_col for ordering)
			local content
			if exists and title then
				content = " → " .. title
				hl = "DiagnosticInfo"
			elseif exists then
				content = " → Ticket #" .. ticket_num .. " exists"
				hl = "DiagnosticOk"
			else
				content = " → Ticket #" .. ticket_num .. " not found"
				hl = "DiagnosticError"
			end

			M.add_virtual_line(bufnr, lnum, start_col, content, hl)
		end
	end)
end

-- Update virtual text for changeset validation
function M.update_changeset_virtual_text(bufnr, lnum, changeset_num, exists, message)
	vim.schedule(function()
		local line_text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""

		-- Find the changeset reference in the line to get its position
		local pattern = "%[" .. changeset_num .. "%]"
		local start_col, end_col = string.find(line_text, pattern)

		if start_col and end_col then
			local status = exists and " ✓" or " ✗"
			local hl = exists and "DiagnosticOk" or "DiagnosticError"

			-- Add status right after the changeset reference
			vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, end_col, {
				virt_text = { { status, hl } },
				virt_text_pos = "inline",
			})

			-- Add detailed info to virtual lines cache (using start_col for ordering)
			local content
			if exists and message then
				content = " → " .. message
				hl = "DiagnosticInfo"
			elseif exists then
				content = " → Changeset [" .. changeset_num .. "] exists"
				hl = "DiagnosticOk"
			else
				content = " → Changeset [" .. changeset_num .. "] not found"
				hl = "DiagnosticError"
			end

			M.add_virtual_line(bufnr, lnum, start_col, content, hl)
		end
	end)
end

return M
