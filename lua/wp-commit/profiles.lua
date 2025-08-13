local M = {}

-- Cache for profile validation results
local cache = {}
local cache_ttl = 600 -- 10 minutes (profiles change less frequently)
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
		callback(cache[cache_key].exists, cache[cache_key].full_name)
		return
	end

	-- Rate limiting - simple throttling
	local current_time = vim.loop.hrtime() / 1000000 -- Convert to milliseconds
	if (current_time - last_request_time) < min_request_interval then
		-- Delay the request slightly
		vim.defer_fn(function()
			M.validate_username(username, callback)
		end, min_request_interval)
		return
	end
	last_request_time = current_time

	-- Clean cache periodically
	cleanup_cache()

	-- Make full GET request to get profile title for full name
	local encoded_username = username:gsub("([^%w%-_])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	local url = "https://profiles.wordpress.org/" .. encoded_username .. "/"

	vim.system({ "curl", "-s", "-w", "%{http_code}", "--max-time", "10", url }, {}, function(result)
		local exists = false
		local full_name = nil

		-- Handle curl errors
		if result.code ~= 0 then
			-- Network error - cache as failed but don't show error to user
			cache[cache_key] = {
				exists = false,
				full_name = nil,
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
				exists = true
				-- Extract full name from title element
				local title_match = string.match(response_body, "<title>([^<]+)</title>")
				if title_match then
					-- Parse: "Jon Surrell (@jonsurrell) &#8211; WordPress user profile | WordPress.org"
					-- Decode HTML character references
					title_match = title_match
						:gsub("&gt;", ">")
						:gsub("&lt;", "<")
						:gsub("&amp;", "&")
						:gsub("&quot;", '"')
						:gsub("&#39;", "'")
						:gsub("&apos;", "'")
					local name_match = string.match(title_match, "^([^%(]+)%s*%(")
					if name_match then
						full_name = name_match:gsub("^%s+", ""):gsub("%s+$", "") -- trim whitespace
					end
				end
			end
		end

		-- Cache result
		cache[cache_key] = {
			exists = exists,
			full_name = full_name,
			timestamp = get_timestamp(),
		}

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

return M
