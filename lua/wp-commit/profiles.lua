local M = {}

-- Cache for profile validation results
local cache = {}
local cache_ttl = 600 -- 10 minutes (profiles change less frequently)
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
			vim.notify("[wp-commit:profiles] " .. msg, vim.log.levels.DEBUG)
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

-- Validate a WordPress.org username exists and get full name
function M.validate_username(username, callback)
	-- Input validation
	if not username or username == "" then
		callback(false, nil)
		return
	end

	local cache_key = "profile_" .. username

	-- Check cache first
	if is_cache_valid(cache[cache_key]) then
		debug_log("Cache hit: " .. cache_key)
		callback(cache[cache_key].exists, cache[cache_key].full_name)
		return
	end

	-- Clean cache periodically
	cleanup_cache()

	-- Make full GET request to get profile title for full name
	local encoded_username = username:gsub("([^%w%-_])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local url = "https://profiles.wordpress.org/" .. encoded_username .. "/"

	queue_request(url, function(result, http_code, max_retries_exceeded)
		local exists = false
		local full_name = nil

		-- If we exhausted retries due to network errors, don't cache
		if max_retries_exceeded then
			debug_log("Max retries exceeded for profile " .. username .. ", not caching")
			callback(false, nil)
			return
		end

		-- Handle curl errors - don't cache network failures
		if result.code ~= 0 then
			debug_log("Network error for profile " .. username .. ", not caching")
			callback(false, nil)
			return
		end

		if result.stdout and http_code then
			local response_body = string.gsub(result.stdout, "%d+$", "")
			local code_num = tonumber(http_code)

			-- Only parse and cache if we got a valid response
			if code_num and code_num >= 200 and code_num < 300 then
				exists = true
				-- Extract full name from title element
				local title_match = string.match(response_body, "<title>([^<]+)</title>")
				if title_match then
					-- Parse: "Jon Surrell (@jonsurrell) &#8211; WordPress user profile | WordPress.org"
					title_match = decode_html_entities(title_match)
					local name_match = string.match(title_match, "^([^%(]+)%s*%(")
					if name_match then
						full_name = name_match:gsub("^%s+", ""):gsub("%s+$", "") -- trim whitespace
					end
				end

				-- Cache valid response
				cache[cache_key] = {
					exists = exists,
					full_name = full_name,
					timestamp = get_timestamp(),
				}
			elseif code_num == 404 then
				-- Profile doesn't exist - cache this
				cache[cache_key] = {
					exists = false,
					full_name = nil,
					timestamp = get_timestamp(),
				}
			end
			-- Don't cache 429, 5xx, or other error responses
		end

		callback(exists, full_name)
	end)
end

-- Validate multiple usernames (for Props lines)
function M.validate_usernames(usernames, callback)
	local results = {}
	local completed = 0
	local total = #usernames

	if total == 0 then
		callback(results)
		return
	end

	for _, username in ipairs(usernames) do
		M.validate_username(username, function(exists, full_name)
			results[username] = { exists = exists, full_name = full_name }
			completed = completed + 1

			if completed == total then
				callback(results)
			end
		end)
	end
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
