local M = {}

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
  
  if #lines > 0 then
    local summary_line = lines[1]
    
    -- Check if summary line has component prefix
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
    
    -- Check summary line length (50-70 characters)
    if #summary_line > 70 then
      table.insert(diagnostics, {
        lnum = 0,
        col = 50,
        end_col = #summary_line,
        severity = vim.diagnostic.severity.WARN,
        message = "Summary line should be 50-70 characters (currently " .. #summary_line .. ")",
        source = "wp-commit-msg",
      })
    elseif #summary_line < 1 then
      table.insert(diagnostics, {
        lnum = 0,
        col = 0,
        end_col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = "Summary line is required",
        source = "wp-commit-msg",
      })
    end
  end
  
  -- Set diagnostics
  vim.diagnostic.set(vim.api.nvim_create_namespace("wp-commit-msg"), bufnr, diagnostics)
end

return M