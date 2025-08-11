local M = {}

-- Cache for API results to avoid repeated requests
local cache = {}
local cache_ttl = 300 -- 5 minutes

-- Get current timestamp
local function get_timestamp()
  return os.time()
end

-- Check if cached result is still valid
local function is_cache_valid(cache_entry)
  return cache_entry and (get_timestamp() - cache_entry.timestamp) < cache_ttl
end

-- Validate a ticket number exists
function M.validate_ticket(ticket_num, callback)
  local cache_key = "ticket_" .. ticket_num
  
  -- Check cache first
  if is_cache_valid(cache[cache_key]) then
    callback(cache[cache_key].exists, cache[cache_key].title)
    return
  end
  
  -- Make API request
  local url = "https://core.trac.wordpress.org/ticket/" .. ticket_num .. "?format=csv"
  
  vim.system({"curl", "-s", url}, {}, function(result)
    local exists = false
    local title = nil
    
    if result.code == 0 and result.stdout then
      -- Parse CSV response - if we get valid CSV data, ticket exists
      local lines = vim.split(result.stdout, "\n")
      if #lines >= 2 then
        -- Second line contains the ticket data
        local data_line = lines[2]
        if data_line and data_line ~= "" then
          exists = true
          -- Extract title (second column after id)
          local cols = vim.split(data_line, ",")
          if #cols >= 2 then
            title = cols[2]:gsub('"', '') -- Remove quotes
          end
        end
      end
    end
    
    -- Cache result
    cache[cache_key] = {
      exists = exists,
      title = title,
      timestamp = get_timestamp()
    }
    
    callback(exists, title)
  end)
end

-- Validate a changeset number exists
function M.validate_changeset(changeset_num, callback)
  local cache_key = "changeset_" .. changeset_num
  
  -- Check cache first
  if is_cache_valid(cache[cache_key]) then
    callback(cache[cache_key].exists, cache[cache_key].message)
    return
  end
  
  -- Make API request
  local url = "https://core.trac.wordpress.org/changeset/" .. changeset_num
  
  vim.system({"curl", "-s", url}, {}, function(result)
    local exists = false
    local message = nil
    
    if result.code == 0 and result.stdout then
      -- Check if we got a valid changeset page (not 404)
      if not string.match(result.stdout, "No such changeset") then
        exists = true
        -- Extract commit message from #overview section
        local overview_match = string.match(result.stdout, '<dl id="overview".-</dl>')
        if overview_match then
          local message_match = string.match(overview_match, '<dt>Message:</dt>%s*<dd[^>]*>%s*([^<]+)')
          if message_match then
            message = message_match:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
          end
        end
      end
    end
    
    -- Cache result
    cache[cache_key] = {
      exists = exists,
      message = message,
      timestamp = get_timestamp()
    }
    
    callback(exists, message)
  end)
end

-- Clear cache (useful for testing or manual refresh)
function M.clear_cache()
  cache = {}
end

return M