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
	local field = fields[field_index]
	if field then
		field = field:gsub("^\239\187\191", "")
		field = field:gsub("\r$", "")
	end
	return field or nil
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
local warned_cookie_file = false

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

local function warn_once_cookie_file(msg)
	if warned_cookie_file then
		return
	end

	warned_cookie_file = true
	vim.schedule(function()
		vim.notify("wp-commit: " .. msg, vim.log.levels.WARN)
	end)
end

local function get_trac_config()
	local ok, wp_commit = pcall(require, "wp-commit")
	if not ok then
		return {}
	end

	local config = wp_commit.get_config() or {}
	return config.trac or {}
end

local function resolve_config_value(value)
	if type(value) ~= "function" then
		return value
	end

	local ok, result = pcall(value)
	if ok then
		return result
	end

	debug_log("Trac cookie_file function failed")
	return nil
end

local function strip_cookie_header_prefix(cookie_data)
	return cookie_data:gsub("^%s*[Cc]ookie:%s*", ""):gsub("%s+$", "")
end

local function escape_curl_config_value(value)
	return value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", ""):gsub("\n", "")
end

local function classify_cookie_file(cookie_file)
	local ok, lines = pcall(vim.fn.readfile, cookie_file, "", 20)
	if not ok then
		debug_log("Failed to inspect Trac cookie file")
		return nil, nil, "cookie_unreadable"
	end

	for _, line in ipairs(lines) do
		line = line:gsub("\r$", "")
		if line ~= "" then
			if string.match(line, "^#HttpOnly_") and string.match(line, "\t") then
				return "file", nil, nil
			elseif string.match(line, "^#") then
				-- Comment/header lines are common in Netscape cookie jars.
			elseif string.match(line, "\t") or string.match(line, "^[Ss]et%-[Cc]ookie:") then
				return "file", nil, nil
			elseif string.match(line, "=") then
				return "raw", strip_cookie_header_prefix(line), nil
			else
				return nil, nil, "cookie_invalid_format"
			end
		end
	end

	return nil, nil, "cookie_invalid_format"
end

local function resolve_cookie_file()
	local trac_config = get_trac_config()
	local cookie_file = resolve_config_value(trac_config.cookie_file)

	if
		(cookie_file == nil or cookie_file == "")
		and type(trac_config.cookie_env) == "string"
		and trac_config.cookie_env ~= ""
	then
		cookie_file = vim.env[trac_config.cookie_env]
	end

	if type(cookie_file) == "string" and cookie_file ~= "" then
		cookie_file = vim.fn.expand(cookie_file)
		if vim.fn.filereadable(cookie_file) == 1 then
			local cookie_mode, cookie_data, cookie_status = classify_cookie_file(cookie_file)
			if cookie_status then
				debug_log("Trac cookie file has unsupported format")
				return nil, nil, cookie_status
			end

			debug_log("Using configured Trac cookie file")
			return cookie_file, cookie_data, nil, cookie_mode
		end

		debug_log("Trac cookie file is not readable")
		warn_once_cookie_file("Trac cookie file is not readable")
		return nil, nil, "cookie_unreadable"
	end

	if trac_config.auth_required == false then
		return nil, nil, nil
	end

	return nil, nil, "auth_missing"
end

local function build_curl_request(url)
	local args = {
		"curl",
		"-q",
		"-sS",
		"-w",
		"\n%{http_code}",
		"--connect-timeout",
		"5",
		"--max-time",
		"15",
		"--proto",
		"=https",
	}
	local opts = {}
	local cookie_file, cookie_data, cookie_status, cookie_mode = resolve_cookie_file()

	if cookie_status then
		return nil, cookie_status
	end

	if cookie_mode == "raw" and cookie_data then
		vim.list_extend(args, { "--config", "-" })
		opts.stdin = 'cookie = "' .. escape_curl_config_value(cookie_data) .. '"\n'
	elseif cookie_file then
		vim.list_extend(args, { "--cookie", cookie_file })
	end

	table.insert(args, url)
	return args, nil, opts
end

local function parse_curl_response(stdout)
	if not stdout then
		return nil, nil
	end

	local http_code = string.match(stdout, "\n(%d%d%d)$")
	if http_code then
		return string.gsub(stdout, "\n%d%d%d$", "", 1), http_code
	end

	http_code = string.match(stdout, "(%d%d%d)$")
	if http_code then
		return string.gsub(stdout, "%d%d%d$", "", 1), http_code
	end

	return stdout, nil
end

local function is_changeset_page(response_body, changeset_num)
	if not response_body then
		return false
	end

	if not string.match(response_body, "<dl[^>]-id=[\"']overview[\"']") then
		return false
	end

	return string.match(response_body, "<title>[^<]*Changeset%s+" .. changeset_num .. "[^%d]")
		or string.match(response_body, "<h1[^>]*>[^<]*Changeset%s+" .. changeset_num .. "[^%d]")
		or string.match(response_body, "/changeset/" .. changeset_num .. "[^%d]")
end

-- Decode common HTML entities
local function decode_html_entities(str)
	if not str then
		return nil
	end
	return str:gsub("&gt;", ">")
		:gsub("&lt;", "<")
		:gsub("&amp;", "&")
		:gsub("&quot;", '"')
		:gsub("&#39;", "'")
		:gsub("&apos;", "'")
end

local function clean_changeset_message(message)
	if not message then
		return nil
	end

	message = message:gsub("<[^>]+>", "")
	message = decode_html_entities(message)
	message = message:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%.+$", ".")

	if message == "" then
		return nil
	end

	return message
end

local function extract_changeset_message(response_body)
	local message_section =
		string.match(response_body, "<dt[^>]*property message[^>]*>.-</dt>%s*<dd[^>]*message[^>]*>(.-)</dd>")
	if message_section then
		local match = string.match(message_section, "<p[^>]*>%s*(.-)<br[ />]")
			or string.match(message_section, "<p[^>]*>%s*(.-)</p>")
			or message_section
		local message = clean_changeset_message(match)
		if message then
			return message
		end
	end

	local overview_match = string.match(response_body, "<dl[^>]-id=[\"']overview[\"'][^>]*>.-</dl>")
	if overview_match then
		local message_match = string.match(overview_match, "<dt>Message:</dt>%s*<dd[^>]*>%s*(.-)</dd>")
		local message = clean_changeset_message(message_match)
		if message then
			return message
		end
	end

	return nil
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

	local curl_args, request_status, curl_opts = build_curl_request(request.url)
	if not curl_args then
		debug_log("Skipping request: " .. request.url .. " (" .. request_status .. ")")
		vim.schedule(function()
			request.handler({ code = -1 }, nil, false, request_status)
			vim.defer_fn(function()
				is_processing = false
				process_queue()
			end, request_delay)
		end)
		return
	end

	vim.system(curl_args, curl_opts or {}, function(result)
		vim.schedule(function()
			local should_retry = false
			local http_code = nil
			local request_failure_status = nil

			-- Handle curl errors (network failures, timeouts)
			if result.code ~= 0 then
				debug_log("Curl error for " .. request.url .. ": exit code " .. result.code)
				should_retry = true
				request_failure_status = "network"
			else
				-- Extract HTTP status code
				_, http_code = parse_curl_response(result.stdout)

				if http_code then
					debug_log("Response: " .. request.url .. " → " .. http_code)

					local code_num = tonumber(http_code)
					-- Retry on rate limiting (429) or server errors (5xx)
					if code_num == 401 or code_num == 403 or (code_num >= 300 and code_num < 400) then
						debug_log("Trac auth error: " .. http_code)
						request_failure_status = "auth_failed"
					elseif code_num == 429 or (code_num >= 500 and code_num < 600) then
						debug_log("Retryable HTTP error: " .. http_code)
						should_retry = true
						request_failure_status = "network"
					end
				else
					debug_log("No HTTP code in response for " .. request.url)
					should_retry = true
					request_failure_status = "network"
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
			request.handler(result, http_code, should_retry and request.attempt >= max_retries, request_failure_status)

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
			req.handler = function(result, http_code, max_retries_exceeded, request_status)
				orig_handler(result, http_code, max_retries_exceeded, request_status)
				handler(result, http_code, max_retries_exceeded, request_status)
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
		callback(false, nil, "not_found")
		return
	end

	local cache_key = "ticket_" .. ticket_num

	-- Check cache first
	if is_cache_valid(cache[cache_key]) then
		debug_log("Cache hit: " .. cache_key)
		callback(cache[cache_key].exists, cache[cache_key].title, cache[cache_key].status)
		return
	end

	-- Clean cache periodically
	cleanup_cache()

	-- Make API request via queue
	local url = "https://core.trac.wordpress.org/ticket/" .. ticket_num .. "?format=csv"

	queue_request(url, function(result, http_code, max_retries_exceeded, request_status)
		local exists = false
		local title = nil

		if request_status then
			callback(nil, nil, request_status)
			return
		end

		-- If we exhausted retries due to network errors, don't cache
		if max_retries_exceeded then
			debug_log("Max retries exceeded for ticket " .. ticket_num .. ", not caching")
			callback(nil, nil, "network")
			return
		end

		-- Handle curl errors - don't cache network failures
		if result.code ~= 0 then
			debug_log("Network error for ticket " .. ticket_num .. ", not caching")
			callback(nil, nil, "network")
			return
		end

		if result.stdout and http_code then
			local response_body = parse_curl_response(result.stdout)
			local code_num = tonumber(http_code)

			-- Only parse and cache if we got a valid response
			if code_num and code_num >= 200 and code_num < 300 then
				-- Parse CSV response - if we get valid CSV data, ticket exists
				local lines = vim.split(response_body, "\n")
				if #lines >= 2 then
					local header_line = lines[1]
					-- Second line contains the ticket data
					local data_line = lines[2]
					if
						header_line
						and M.parse_csv_field(header_line, 1) == "id"
						and M.parse_csv_field(header_line, 2) == "summary"
						and data_line
						and data_line ~= ""
					then
						local response_ticket_num = M.parse_csv_field(data_line, 1)
						title = M.parse_csv_field(data_line, 2) -- Get second column (summary)
						if response_ticket_num == ticket_num and title and title ~= "" then
							exists = true
							title = decode_html_entities(title)
						end
					end
				end

				if not exists then
					debug_log("Unexpected ticket response for " .. ticket_num .. ", not caching")
					callback(nil, nil, "unexpected_response")
					return
				end

				-- Cache valid response
				cache[cache_key] = {
					exists = exists,
					title = title,
					status = "valid",
					timestamp = get_timestamp(),
				}
			elseif code_num == 404 then
				-- Ticket doesn't exist - cache this
				cache[cache_key] = {
					exists = false,
					title = nil,
					status = "not_found",
					timestamp = get_timestamp(),
				}
			elseif code_num == 401 or code_num == 403 or (code_num and code_num >= 300 and code_num < 400) then
				callback(nil, nil, "auth_failed")
				return
			else
				callback(nil, nil, "network")
				return
			end
			-- Don't cache 429, 5xx, or other error responses
		end

		callback(exists, title, exists and "valid" or "not_found")
	end)
end

-- Validate a changeset number exists
function M.validate_changeset(changeset_num, callback)
	-- Input validation
	if not changeset_num or changeset_num == "" or not string.match(changeset_num, "^%d+$") then
		callback(false, nil, "not_found")
		return
	end

	local cache_key = "changeset_" .. changeset_num

	-- Check cache first
	if is_cache_valid(cache[cache_key]) then
		debug_log("Cache hit: " .. cache_key)
		callback(cache[cache_key].exists, cache[cache_key].message, cache[cache_key].status)
		return
	end

	-- Clean cache periodically
	cleanup_cache()

	-- Make API request via queue
	local url = "https://core.trac.wordpress.org/changeset/" .. changeset_num

	queue_request(url, function(result, http_code, max_retries_exceeded, request_status)
		local exists = false
		local message = nil

		if request_status then
			callback(nil, nil, request_status)
			return
		end

		-- If we exhausted retries due to network errors, don't cache
		if max_retries_exceeded then
			debug_log("Max retries exceeded for changeset " .. changeset_num .. ", not caching")
			callback(nil, nil, "network")
			return
		end

		-- Handle curl errors - don't cache network failures
		if result.code ~= 0 then
			debug_log("Network error for changeset " .. changeset_num .. ", not caching")
			callback(nil, nil, "network")
			return
		end

		if result.stdout and http_code then
			local response_body = parse_curl_response(result.stdout)
			local code_num = tonumber(http_code)

			-- Only parse and cache if we got a valid response
			if code_num and code_num >= 200 and code_num < 300 then
				-- Check if we got a valid changeset page (not 404)
				if string.match(response_body, "No such changeset") then
					exists = false
				elseif is_changeset_page(response_body, changeset_num) then
					message = extract_changeset_message(response_body)
					if message then
						exists = true
					else
						debug_log("Changeset response missing message for " .. changeset_num .. ", not caching")
						callback(nil, nil, "unexpected_response")
						return
					end
				else
					debug_log("Unexpected changeset response for " .. changeset_num .. ", not caching")
					callback(nil, nil, "unexpected_response")
					return
				end

				-- Cache valid response
				cache[cache_key] = {
					exists = exists,
					message = message,
					status = exists and "valid" or "not_found",
					timestamp = get_timestamp(),
				}
			elseif code_num == 404 or string.match(response_body or "", "No such changeset") then
				-- Changeset doesn't exist - cache this
				cache[cache_key] = {
					exists = false,
					message = nil,
					status = "not_found",
					timestamp = get_timestamp(),
				}
			elseif code_num == 401 or code_num == 403 or (code_num and code_num >= 300 and code_num < 400) then
				callback(nil, nil, "auth_failed")
				return
			else
				callback(nil, nil, "network")
				return
			end
			-- Don't cache 429, 5xx, or other error responses
		end

		callback(exists, message, exists and "valid" or "not_found")
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
