local M = {}

-- Cache for profile validation results
local cache = {}
local cache_ttl = 600 -- 10 minutes (profiles change less frequently)

-- Get current timestamp
local function get_timestamp()
  return os.time()
end

-- Check if cached result is still valid
local function is_cache_valid(cache_entry)
  return cache_entry and (get_timestamp() - cache_entry.timestamp) < cache_ttl
end

-- Validate a WordPress.org username exists
function M.validate_username(username, callback)
  local cache_key = "profile_" .. username
  
  -- Check cache first
  if is_cache_valid(cache[cache_key]) then
    callback(cache[cache_key].exists)
    return
  end
  
  -- Make HEAD request to check if profile exists
  local url = "https://profiles.wordpress.org/" .. username
  
  vim.system({"curl", "-s", "-I", url}, {}, function(result)
    local exists = false
    
    if result.code == 0 and result.stdout then
      -- Check HTTP status code in response headers
      local status_match = string.match(result.stdout, "HTTP/[%d%.]+%s+(%d+)")
      if status_match then
        local status_code = tonumber(status_match)
        -- 2xx status codes mean the profile exists
        exists = status_code >= 200 and status_code < 300
      end
    end
    
    -- Cache result
    cache[cache_key] = {
      exists = exists,
      timestamp = get_timestamp()
    }
    
    callback(exists)
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
    M.validate_username(username, function(exists)
      results[username] = exists
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