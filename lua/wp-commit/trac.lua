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

-- Request queue for serializing HTTP requests
local request_queue = {}
local is_processing = false
local request_delay = 0
local max_retries = 3
local max_queue_size = 50

-- Cached debug config (nil = not checked yet)
local cached_debug = nil

-- Get current timestamp
local function get_timestamp()
	return os.time()
end

-- Debug logging helper (caches config lookup for performance)
local function debug_log(msg)
	if cached_debug == nil then
		local ok, wp_commit = pcall(require, "wp-commit")
		if ok then
			local config = wp_commit.get_config()
			cached_debug = config and config.debug or false
		else
			cached_debug = false
		end
	end
	if cached_debug then
		vim.schedule(function()
			vim.notify("[wp-commit:trac] " .. msg, vim.log.levels.DEBUG)
		end)
	end
end

-- Decode common HTML entities
local function decode_html_entities(str)
	if not str then
		return nil
	end
	return str
		:gsub("&gt;", ">")
		:gsub("&lt;", "<")
		:gsub("&amp;", "&")
		:gsub("&quot;", '"')
		:gsub("&#39;", "'")
		:gsub("&apos;", "'")
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

-- Process the next request in the queue
local function process_queue()
	if is_processing or #request_queue == 0 then
		return
	end

	is_processing = true
	local request = table.remove(request_queue, 1)

	debug_log("Requesting: " .. request.url .. " (attempt " .. request.attempt .. ")")

	vim.system({ "curl", "-s", "-w", "%{http_code}", "--max-time", "15", request.url }, {}, function(result)
		vim.schedule(function()
			local should_retry = false
			local http_code = nil

			-- Handle curl errors (network failures, timeouts)
			if result.code ~= 0 then
				debug_log("Curl error for " .. request.url .. ": exit code " .. result.code)
				should_retry = true
			else
				-- Extract HTTP status code
				http_code = result.stdout and string.match(result.stdout, "(%d+)$")

				if http_code then
					debug_log("Response: " .. request.url .. " → " .. http_code)

					local code_num = tonumber(http_code)
					-- Retry on rate limiting (429) or server errors (5xx)
					if code_num == 429 or (code_num >= 500 and code_num < 600) then
						debug_log("Retryable HTTP error: " .. http_code)
						should_retry = true
					end
				else
					debug_log("No HTTP code in response for " .. request.url)
					should_retry = true
				end
			end

			-- Handle retry logic
			if should_retry and request.attempt < max_retries then
				local backoff_delay = request_delay * math.pow(2, request.attempt) -- 300, 600, 1200ms
				debug_log(
					"Retry #" .. (request.attempt + 1) .. " for " .. request.url .. " in " .. backoff_delay .. "ms"
				)
				request.attempt = request.attempt + 1
				-- Add back to queue with delay
				vim.defer_fn(function()
					table.insert(request_queue, 1, request) -- Add to front for priority retry
					is_processing = false
					process_queue()
				end, backoff_delay)
				return
			end

			-- Call the handler with the result
			request.handler(result, http_code, should_retry and request.attempt >= max_retries)

			-- Process next request after delay
			vim.defer_fn(function()
				is_processing = false
				process_queue()
			end, request_delay)
		end)
	end)
end

-- Queue a request (with deduplication and size limit)
local function queue_request(url, handler)
	-- Check queue size limit
	if #request_queue >= max_queue_size then
		debug_log("Queue full, dropping request: " .. url)
		vim.schedule(function()
			handler({ code = -1 }, nil, true)
		end)
		return
	end

	-- Check for duplicate URL already in queue
	for _, req in ipairs(request_queue) do
		if req.url == url then
			debug_log("Duplicate request, merging handlers: " .. url)
			local orig_handler = req.handler
			req.handler = function(result, http_code, max_retries_exceeded)
				orig_handler(result, http_code, max_retries_exceeded)
				handler(result, http_code, max_retries_exceeded)
			end
			return
		end
	end

	debug_log("Queuing request: " .. url)
	table.insert(request_queue, {
		url = url,
		handler = handler,
		attempt = 1,
	})
	process_queue()
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
		debug_log("Cache hit: " .. cache_key)
		callback(cache[cache_key].exists, cache[cache_key].title)
		return
	end

	-- Clean cache periodically
	cleanup_cache()

	-- Make API request via queue
	local url = "https://core.trac.wordpress.org/ticket/" .. ticket_num .. "?format=csv"

	queue_request(url, function(result, http_code, max_retries_exceeded)
		local exists = false
		local title = nil

		-- If we exhausted retries due to network errors, don't cache
		if max_retries_exceeded then
			debug_log("Max retries exceeded for ticket " .. ticket_num .. ", not caching")
			callback(false, nil)
			return
		end

		-- Handle curl errors - don't cache network failures
		if result.code ~= 0 then
			debug_log("Network error for ticket " .. ticket_num .. ", not caching")
			callback(false, nil)
			return
		end

		if result.stdout and http_code then
			local response_body = string.gsub(result.stdout, "%d+$", "")
			local code_num = tonumber(http_code)

			-- Only parse and cache if we got a valid response
			if code_num and code_num >= 200 and code_num < 300 then
				-- Parse CSV response - if we get valid CSV data, ticket exists
				local lines = vim.split(response_body, "\n")
				if #lines >= 2 then
					-- Second line contains the ticket data
					local data_line = lines[2]
					if data_line and data_line ~= "" then
						exists = true
						-- Extract title using proper CSV parsing
						title = M.parse_csv_field(data_line, 2) -- Get second column (summary)
						title = decode_html_entities(title)
					end
				end

				-- Cache valid response
				cache[cache_key] = {
					exists = exists,
					title = title,
					timestamp = get_timestamp(),
				}
			elseif code_num == 404 then
				-- Ticket doesn't exist - cache this
				cache[cache_key] = {
					exists = false,
					title = nil,
					timestamp = get_timestamp(),
				}
			end
			-- Don't cache 429, 5xx, or other error responses
		end

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
		debug_log("Cache hit: " .. cache_key)
		callback(cache[cache_key].exists, cache[cache_key].message)
		return
	end

	-- Clean cache periodically
	cleanup_cache()

	-- Make API request via queue
	local url = "https://core.trac.wordpress.org/changeset/" .. changeset_num

	queue_request(url, function(result, http_code, max_retries_exceeded)
		local exists = false
		local message = nil

		-- If we exhausted retries due to network errors, don't cache
		if max_retries_exceeded then
			debug_log("Max retries exceeded for changeset " .. changeset_num .. ", not caching")
			callback(false, nil)
			return
		end

		-- Handle curl errors - don't cache network failures
		if result.code ~= 0 then
			debug_log("Network error for changeset " .. changeset_num .. ", not caching")
			callback(false, nil)
			return
		end

		if result.stdout and http_code then
			local response_body = string.gsub(result.stdout, "%d+$", "")
			local code_num = tonumber(http_code)

			-- Only parse and cache if we got a valid response
			if code_num and code_num >= 200 and code_num < 300 then
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
						-- Try matching until <br first, then try </p>
						local match = string.match(message_section, "<p[^>]*>%s*(.-)<br[ />]")
							or string.match(message_section, "<p[^>]*>%s*(.-)</p>")

						if match then
							-- Clean up the message text
							message = match:gsub("<[^>]+>", "") -- Remove any remaining HTML tags
							message = decode_html_entities(message)
							message = message
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
								message = decode_html_entities(message_match)
								message = message
									:gsub("%s+", " ") -- Normalize whitespace
									:gsub("^%s+", "") -- Trim leading
									:gsub("%s+$", "") -- Trim trailing
							end
						end
					end
				end

				-- Cache valid response
				cache[cache_key] = {
					exists = exists,
					message = message,
					timestamp = get_timestamp(),
				}
			elseif code_num == 404 or string.match(response_body or "", "No such changeset") then
				-- Changeset doesn't exist - cache this
				cache[cache_key] = {
					exists = false,
					message = nil,
					timestamp = get_timestamp(),
				}
			end
			-- Don't cache 429, 5xx, or other error responses
		end

		callback(exists, message)
	end)
end

-- Clear cache (useful for testing or manual refresh)
function M.clear_cache()
	cache = {}
end

-- Clear request queue (useful for testing)
function M.clear_queue()
	request_queue = {}
	is_processing = false
end

return M
