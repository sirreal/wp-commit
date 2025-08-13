local M = {}

-- Parse a specific field from a CSV line (1-indexed)
function M.parse_csv_field(csv_line, field_index)
	local fields = {}
	local current_field = ""
	local in_quotes = false
	local i = 1

	while i <= #csv_line do
		local char = csv_line:sub(i, i)

		if char == '"' then
			if in_quotes and i < #csv_line and csv_line:sub(i + 1, i + 1) == '"' then
				-- Escaped quote (double quote)
				current_field = current_field .. '"'
				i = i + 1 -- Skip the second quote
			else
				-- Toggle quote state
				in_quotes = not in_quotes
			end
		elseif char == "," and not in_quotes then
			-- Field separator
			table.insert(fields, current_field)
			current_field = ""
		else
			current_field = current_field .. char
		end

		i = i + 1
	end

	-- Add the last field
	table.insert(fields, current_field)

	-- Return the requested field
	return fields[field_index] or nil
end

-- Cache for API results to avoid repeated requests
local cache = {}
local cache_ttl = 300 -- 5 minutes
local max_cache_size = 1000 -- Prevent unlimited cache growth

-- Rate limiting
local last_request_time = 0
local min_request_interval = 100 -- 100ms between requests

-- Get current timestamp
local function get_timestamp()
	return os.time()
end

-- Check if cached result is still valid
local function is_cache_valid(cache_entry)
	return cache_entry and (get_timestamp() - cache_entry.timestamp) < cache_ttl
end

-- Clean old cache entries if cache is too large
local function cleanup_cache()
	local cache_size = 0
	for _ in pairs(cache) do
		cache_size = cache_size + 1
	end

	if cache_size > max_cache_size then
		local current_time = get_timestamp()
		for key, entry in pairs(cache) do
			if (current_time - entry.timestamp) > cache_ttl then
				cache[key] = nil
			end
		end
	end
end

-- Validate a ticket number exists
function M.validate_ticket(ticket_num, callback)
	-- Input validation
	if not ticket_num or ticket_num == "" or not string.match(ticket_num, "^%d+$") then
		callback(false, nil)
		return
	end

	local cache_key = "ticket_" .. ticket_num

	-- Check cache first
	if is_cache_valid(cache[cache_key]) then
		callback(cache[cache_key].exists, cache[cache_key].title)
		return
	end

	-- Rate limiting - simple throttling
	local current_time = vim.loop.hrtime() / 1000000 -- Convert to milliseconds
	if (current_time - last_request_time) < min_request_interval then
		vim.defer_fn(function()
			M.validate_ticket(ticket_num, callback)
		end, min_request_interval)
		return
	end
	last_request_time = current_time

	-- Clean cache periodically
	cleanup_cache()

	-- Make API request
	local url = "https://core.trac.wordpress.org/ticket/" .. ticket_num .. "?format=csv"

	vim.system({ "curl", "-s", "-w", "%{http_code}", "--max-time", "10", url }, {}, function(result)
		local exists = false
		local title = nil

		-- Handle curl errors
		if result.code ~= 0 then
			-- Network error - cache as failed but don't show error to user
			cache[cache_key] = {
				exists = false,
				title = nil,
				timestamp = get_timestamp(),
			}
			callback(false, nil)
			return
		end

		if result.stdout then
			-- Extract HTTP status code from the end of response
			local http_code = string.match(result.stdout, "(%d+)$")
			local response_body = string.gsub(result.stdout, "%d+$", "")

			-- Only parse if we got a 2xx status code
			if http_code and tonumber(http_code) >= 200 and tonumber(http_code) < 300 then
				-- Parse CSV response - if we get valid CSV data, ticket exists
				local lines = vim.split(response_body, "\n")
				if #lines >= 2 then
					-- Second line contains the ticket data
					local data_line = lines[2]
					if data_line and data_line ~= "" then
						exists = true
						-- Extract title using proper CSV parsing
						title = M.parse_csv_field(data_line, 2) -- Get second column (summary)
						if title then
							-- Decode HTML character references in ticket title
							title = title
								:gsub("&gt;", ">")
								:gsub("&lt;", "<")
								:gsub("&amp;", "&")
								:gsub("&quot;", '"')
								:gsub("&#39;", "'")
								:gsub("&apos;", "'")
						end
					end
				end
			end
		end

		-- Cache result
		cache[cache_key] = {
			exists = exists,
			title = title,
			timestamp = get_timestamp(),
		}

		callback(exists, title)
	end)
end

-- Validate a changeset number exists
function M.validate_changeset(changeset_num, callback)
	-- Input validation
	if not changeset_num or changeset_num == "" or not string.match(changeset_num, "^%d+$") then
		callback(false, nil)
		return
	end

	local cache_key = "changeset_" .. changeset_num

	-- Check cache first
	if is_cache_valid(cache[cache_key]) then
		callback(cache[cache_key].exists, cache[cache_key].message)
		return
	end

	-- Rate limiting - simple throttling
	local current_time = vim.loop.hrtime() / 1000000 -- Convert to milliseconds
	if (current_time - last_request_time) < min_request_interval then
		vim.defer_fn(function()
			M.validate_changeset(changeset_num, callback)
		end, min_request_interval)
		return
	end
	last_request_time = current_time

	-- Clean cache periodically
	cleanup_cache()

	-- Make API request
	local url = "https://core.trac.wordpress.org/changeset/" .. changeset_num

	vim.system({ "curl", "-s", "-w", "%{http_code}", "--max-time", "10", url }, {}, function(result)
		local exists = false
		local message = nil

		-- Handle curl errors
		if result.code ~= 0 then
			-- Network error - cache as failed but don't show error to user
			cache[cache_key] = {
				exists = false,
				message = nil,
				timestamp = get_timestamp(),
			}
			callback(false, nil)
			return
		end

		if result.stdout then
			-- Extract HTTP status code from the end of response
			local http_code = string.match(result.stdout, "(%d+)$")
			local response_body = string.gsub(result.stdout, "%d+$", "")

			-- Only parse if we got a 2xx status code
			if http_code and tonumber(http_code) >= 200 and tonumber(http_code) < 300 then
				-- Check if we got a valid changeset page (not 404)
				if not string.match(response_body, "No such changeset") then
					exists = true
					-- Extract commit message from the message section
					-- Look for <dt class="property message">Message:</dt> followed by <dd class="message">
					local message_section = string.match(
						response_body,
						"<dt[^>]*property message[^>]*>.-</dt>%s*<dd[^>]*message[^>]*>(.-)</dd>"
					)
					if message_section then
						-- Extract first paragraph or line of the commit message
						local first_p = string.match(message_section, "<p[^>]*>%s*([^<]+)")
						if first_p then
							-- Clean up the message text
							message = first_p
								:gsub("<[^>]+>", "") -- Remove any remaining HTML tags
								:gsub("&gt;", ">") -- Decode HTML character references
								:gsub("&lt;", "<")
								:gsub("&amp;", "&")
								:gsub("&quot;", '"')
								:gsub("&#39;", "'")
								:gsub("&apos;", "'")
								:gsub("%s+", " ") -- Normalize whitespace
								:gsub("^%s+", "") -- Trim leading
								:gsub("%s+$", "") -- Trim trailing
								:gsub("%.+$", ".") -- Normalize ending periods
						end
					end

					-- Fallback to simpler parsing if the above didn't work
					if not message then
						local overview_match = string.match(response_body, '<dl id="overview".-</dl>')
						if overview_match then
							local message_match =
								string.match(overview_match, "<dt>Message:</dt>%s*<dd[^>]*>%s*([^<]+)")
							if message_match then
								message = message_match
									:gsub("&gt;", ">") -- Decode HTML character references
									:gsub("&lt;", "<")
									:gsub("&amp;", "&")
									:gsub("&quot;", '"')
									:gsub("&#39;", "'")
									:gsub("&apos;", "'")
									:gsub("%s+", " ") -- Normalize whitespace
									:gsub("^%s+", "") -- Trim leading
									:gsub("%s+$", "") -- Trim trailing
							end
						end
					end
				end
			end
		end

		-- Cache result
		cache[cache_key] = {
			exists = exists,
			message = message,
			timestamp = get_timestamp(),
		}

		callback(exists, message)
	end)
end

-- Clear cache (useful for testing or manual refresh)
function M.clear_cache()
	cache = {}
end

return M
