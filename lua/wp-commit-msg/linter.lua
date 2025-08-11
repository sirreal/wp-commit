local M = {}
local trac = require("wp-commit-msg.trac")
local profiles = require("wp-commit-msg.profiles")

-- Attach linter to a buffer
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  
  -- Basic validation for now - we'll expand this
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      M.validate_buffer(bufnr)
    end,
  })
  
  -- Initial validation
  M.validate_buffer(bufnr)
end

-- Validate WordPress commit message format
function M.validate_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diagnostics = {}
  
  -- Validate summary line
  M.validate_summary_line(lines, diagnostics)
  
  -- Validate overall structure and ordering
  M.validate_structure(lines, diagnostics)
  
  -- Validate section content
  M.validate_sections(lines, diagnostics)
  
  -- Validate ticket and changeset references
  M.validate_references(lines, diagnostics)
  
  -- Set diagnostics
  vim.diagnostic.set(vim.api.nvim_create_namespace("wp-commit-msg"), bufnr, diagnostics)
end

-- Validate the first line (summary)
function M.validate_summary_line(lines, diagnostics)
  if #lines == 0 then
    table.insert(diagnostics, {
      lnum = 0, col = 0, end_col = 0,
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
      lnum = 0, col = 0, end_col = #summary_line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Summary line must start with 'Component: Brief summary.'",
      source = "wp-commit-msg",
    })
  end
  
  -- Check length (50-70 characters ideal)
  if #summary_line > 70 then
    table.insert(diagnostics, {
      lnum = 0, col = 50, end_col = #summary_line,
      severity = vim.diagnostic.severity.WARN,
      message = "Summary line should be 50-70 characters (currently " .. #summary_line .. ")",
      source = "wp-commit-msg",
    })
  end
  
  -- Check capitalization
  local component, summary = string.match(summary_line, "^([^:]+):%s*(.+)$")
  if summary and not string.match(summary, "^%u") then
    table.insert(diagnostics, {
      lnum = 0, col = #component + 2, end_col = #component + 3,
      severity = vim.diagnostic.severity.WARN,
      message = "Summary should start with capital letter",
      source = "wp-commit-msg",
    })
  end
  
  -- Check ending punctuation
  if summary and not string.match(summary, "%.$") then
    table.insert(diagnostics, {
      lnum = 0, col = #summary_line - 1, end_col = #summary_line,
      severity = vim.diagnostic.severity.WARN,
      message = "Summary should end with period",
      source = "wp-commit-msg",
    })
  end
end

-- Validate overall structure and blank line requirements
function M.validate_structure(lines, diagnostics)
  if #lines < 2 then return end
  
  -- Find sections and their line numbers
  local sections = {}
  for i, line in ipairs(lines) do
    local lnum = i - 1
    
    if string.match(line, "^Follow%-up to%s+") then
      table.insert(sections, {type = "followup", lnum = lnum, line = line})
    elseif string.match(line, "^Reviewed by%s+") then
      table.insert(sections, {type = "reviewed", lnum = lnum, line = line})
    elseif string.match(line, "^Merges%s+") then
      table.insert(sections, {type = "merges", lnum = lnum, line = line})
    elseif string.match(line, "^Props%s+") then
      table.insert(sections, {type = "props", lnum = lnum, line = line})
    elseif string.match(line, "^Fixes%s+") or string.match(line, "^See%s+") then
      table.insert(sections, {type = "tickets", lnum = lnum, line = line})
    end
  end
  
  -- Check section order (expected order at end of commit message)
  local expected_order = {"followup", "reviewed", "merges", "props", "tickets"}
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
        lnum = section.lnum, col = 0, end_col = #section.line,
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
        lnum = 1, col = 0, end_col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = "Blank line required after summary line",
        source = "wp-commit-msg",
      })
    end
  end
  
  -- Check blank lines before major sections
  for _, section in ipairs(sections) do
    if section.lnum > 0 and lines[section.lnum] ~= "" then
      table.insert(diagnostics, {
        lnum = section.lnum - 1, col = 0, end_col = 0,
        severity = vim.diagnostic.severity.WARN,
        message = "Blank line recommended before " .. section.type .. " section",
        source = "wp-commit-msg",
      })
    end
  end
end

-- Helper function to identify section lines
function M.is_section_line(line)
  return string.match(line, "^Props%s+") or
         string.match(line, "^Fixes%s+") or
         string.match(line, "^See%s+") or
         string.match(line, "^Follow%-up to%s+") or
         string.match(line, "^Reviewed by%s+") or
         string.match(line, "^Merges%s+")
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
    
    -- Check Follow-up section format
    if string.match(line, "^Follow%-up to%s+") then
      M.validate_followup_line(line, lnum, diagnostics)
    end
    
    -- Check Reviewed by section format
    if string.match(line, "^Reviewed by%s+") then
      M.validate_reviewed_line(line, lnum, diagnostics)
    end
    
    -- Check Merges section format
    if string.match(line, "^Merges%s+") then
      M.validate_merges_line(line, lnum, diagnostics)
    end
  end
end

-- Validate Props line: "Props username, another, third."
function M.validate_props_line(line, lnum, diagnostics)
  -- Check capitalization first
  if not string.match(line, "^Props%s+") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = 5,
      severity = vim.diagnostic.severity.ERROR,
      message = "Should be 'Props' (capitalized)",
      source = "wp-commit-msg",
    })
  end
  
  -- Check basic format
  if not string.match(line, "^Props%s+[a-zA-Z0-9_%-]") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Props format should be 'Props username, another.'",
      source = "wp-commit-msg",
    })
    return
  end
  
  -- Check ending period
  if not string.match(line, "%.$") then
    table.insert(diagnostics, {
      lnum = lnum, col = #line - 1, end_col = #line,
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
          lnum = lnum, col = 0, end_col = #line,
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
      lnum = lnum, col = 0, end_col = 5,
      severity = vim.diagnostic.severity.ERROR,
      message = "Should be 'Fixes' (capitalized)",
      source = "wp-commit-msg",
    })
  end
  
  -- Check basic format - must have ticket numbers
  if not string.match(line, "#%d+") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Fixes line must contain ticket numbers like #12345",
      source = "wp-commit-msg",
    })
  end
  
  -- Check ending period
  if not string.match(line, "%.$") then
    table.insert(diagnostics, {
      lnum = lnum, col = #line - 1, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Fixes line must end with period",
      source = "wp-commit-msg",
    })
  end
  
  -- Validate ticket number format and existence
  local bufnr = vim.api.nvim_get_current_buf()
  for ticket_match in string.gmatch(line, "(#%d+)") do
    local ticket_num = string.match(ticket_match, "#(%d+)")
    trac.validate_ticket(ticket_num, function(exists, title)
      M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title)
    end)
  end
end

-- Validate See line: "See #12345, #67890."
function M.validate_see_line(line, lnum, diagnostics)
  -- Check capitalization first  
  if not string.match(line, "^See%s+") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = 3,
      severity = vim.diagnostic.severity.ERROR,
      message = "Should be 'See' (capitalized)",
      source = "wp-commit-msg",
    })
  end
  
  -- Check basic format - must have ticket numbers
  if not string.match(line, "#%d+") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "See line must contain ticket numbers like #12345",
      source = "wp-commit-msg",
    })
  end
  
  -- Check ending period
  if not string.match(line, "%.$") then
    table.insert(diagnostics, {
      lnum = lnum, col = #line - 1, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "See line must end with period",
      source = "wp-commit-msg",
    })
  end
  
  -- Validate ticket number format and existence
  local bufnr = vim.api.nvim_get_current_buf()
  for ticket_match in string.gmatch(line, "(#%d+)") do
    local ticket_num = string.match(ticket_match, "#(%d+)")
    trac.validate_ticket(ticket_num, function(exists, title)
      M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title)
    end)
  end
end

-- Validate Follow-up line: "Follow-up to [12345], [67890]."
function M.validate_followup_line(line, lnum, diagnostics)
  -- Check basic format - must have changeset numbers
  if not string.match(line, "%[%d+%]") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Follow-up line must contain changeset numbers like [12345]",
      source = "wp-commit-msg",
    })
  end
  
  -- Check ending period
  if not string.match(line, "%.$") then
    table.insert(diagnostics, {
      lnum = lnum, col = #line - 1, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Follow-up line must end with period",
      source = "wp-commit-msg",
    })
  end
  
  -- Validate changeset number format and existence
  local bufnr = vim.api.nvim_get_current_buf()
  for changeset_match in string.gmatch(line, "(%[%d+%])") do
    local changeset_num = string.match(changeset_match, "%[(%d+)%]")
    trac.validate_changeset(changeset_num, function(exists, message)
      M.update_changeset_virtual_text(bufnr, lnum, changeset_num, exists, message)
    end)
  end
end

-- Validate Reviewed by line: "Reviewed by username, another."
function M.validate_reviewed_line(line, lnum, diagnostics)
  -- Check basic format
  if not string.match(line, "^Reviewed by%s+[a-zA-Z0-9_%-]") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Reviewed by format should be 'Reviewed by username, another.'",
      source = "wp-commit-msg",
    })
  end
  
  -- Check ending period
  if not string.match(line, "%.$") then
    table.insert(diagnostics, {
      lnum = lnum, col = #line - 1, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Reviewed by line must end with period",
      source = "wp-commit-msg",
    })
  end
end

-- Validate Merges line: "Merges [12345] to the 6.4 branch."
function M.validate_merges_line(line, lnum, diagnostics)
  -- Check format with changeset and branch
  if not string.match(line, "^Merges%s+%[%d+%]%s+to%s+the%s+[%d%.]+%s+branch%.$") then
    table.insert(diagnostics, {
      lnum = lnum, col = 0, end_col = #line,
      severity = vim.diagnostic.severity.ERROR,
      message = "Merges format should be 'Merges [12345] to the x.x branch.'",
      source = "wp-commit-msg",
    })
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
        lnum = lnum, col = 0, end_col = #line,
        severity = vim.diagnostic.severity.WARN,
        message = "Unpaired backticks - code should be wrapped in `backticks`",
        source = "wp-commit-msg",
      })
    end
  end
end

-- Virtual text functions for API validation results

-- Namespace for virtual text
local virt_ns = vim.api.nvim_create_namespace("wp-commit-msg-virtual")

-- Update virtual text for Props usernames
function M.update_props_virtual_text(bufnr, lnum, usernames, results)
  vim.schedule(function()
    -- Clear existing virtual text for this line first
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, virt_ns, {lnum, 0}, {lnum, -1}, {})
    for _, extmark in ipairs(extmarks) do
      vim.api.nvim_buf_del_extmark(bufnr, virt_ns, extmark[1])
    end
    
    local virt_text = {}
    for _, username in ipairs(usernames) do
      local status = results[username] and "✓" or "✗"
      local hl = results[username] and "DiagnosticOk" or "DiagnosticError"
      table.insert(virt_text, {status .. " " .. username, hl})
      table.insert(virt_text, {" ", "Normal"})
    end
    
    vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, 0, {
      virt_text = virt_text,
      virt_text_pos = "eol"
    })
  end)
end

-- Update virtual text for ticket validation
function M.update_ticket_virtual_text(bufnr, lnum, ticket_num, exists, title)
  vim.schedule(function()
    -- Clear existing virtual text for this line first
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, virt_ns, {lnum, 0}, {lnum, -1}, {})
    for _, extmark in ipairs(extmarks) do
      vim.api.nvim_buf_del_extmark(bufnr, virt_ns, extmark[1])
    end
    
    local virt_text = {}
    if exists and title then
      table.insert(virt_text, {"→ " .. title, "DiagnosticInfo"})
    elseif exists then
      table.insert(virt_text, {"→ Ticket #" .. ticket_num .. " exists", "DiagnosticOk"})
    else
      table.insert(virt_text, {"→ Ticket #" .. ticket_num .. " not found", "DiagnosticError"})
    end
    
    vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, 0, {
      virt_text = virt_text,
      virt_text_pos = "eol"
    })
  end)
end

-- Update virtual text for changeset validation
function M.update_changeset_virtual_text(bufnr, lnum, changeset_num, exists, message)
  vim.schedule(function()
    -- Clear existing virtual text for this line first
    local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, virt_ns, {lnum, 0}, {lnum, -1}, {})
    for _, extmark in ipairs(extmarks) do
      vim.api.nvim_buf_del_extmark(bufnr, virt_ns, extmark[1])
    end
    
    local virt_text = {}
    if exists and message then
      table.insert(virt_text, {"→ " .. message, "DiagnosticInfo"})
    elseif exists then
      table.insert(virt_text, {"→ Changeset [" .. changeset_num .. "] exists", "DiagnosticOk"})
    else
      table.insert(virt_text, {"→ Changeset [" .. changeset_num .. "] not found", "DiagnosticError"})
    end
    
    vim.api.nvim_buf_set_extmark(bufnr, virt_ns, lnum, 0, {
      virt_text = virt_text,
      virt_text_pos = "eol"
    })
  end)
end

return M