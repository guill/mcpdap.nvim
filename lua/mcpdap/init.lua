-- mcpdap.nvim - MCP Debug Adapter Protocol integration
-- Provides debugging tools via MCP for use with any chat plugin through mcphub.nvim

local M = {}

-- Check if required dependencies are available
local function check_dependencies()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return false, "nvim-dap is not installed or not available"
  end

  local ok_mcphub, mcphub = pcall(require, 'mcphub')
  if not ok_mcphub then
    return false, "mcphub.nvim is not installed or not available"
  end

  return true, { dap = dap, mcphub = mcphub }
end

-- Get current session info safely
local function get_session_info()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return nil, "nvim-dap not available"
  end

  local session = dap.session()
  if not session then
    return nil, "No active debug session"
  end

  return {
    id = session.id,
    status = dap.status(),
    adapter_type = session.config and session.config.type or "unknown"
  }
end

-- Shared description for wait_until_paused parameter
local WAIT_UNTIL_PAUSED_DESC =
"If true, wait until the debugger pauses (breakpoint hit, step completed, etc.) before returning. Useful for automation and ensuring operations complete before proceeding. Includes timeout protection to prevent infinite waiting."

-- Program output storage - stores output by session ID
local program_output = {}
local max_output_lines = 1000 -- Limit stored output to prevent memory issues

-- Initialize output capture for a session
local function init_output_capture(session_id)
  if not program_output[session_id] then
    program_output[session_id] = {
      stdout = {},
      stderr = {},
      console = {},
      all = {}, -- Combined output with timestamps
      start_time = vim.fn.localtime()
    }
  end
end

-- Add output to storage
local function store_output(session_id, category, output, source)
  if not program_output[session_id] then
    init_output_capture(session_id)
  end

  local storage = program_output[session_id]
  local timestamp = vim.fn.localtime()

  -- Store in category-specific array
  local lines = vim.split(output, '\n', { plain = true })
  for _, line in ipairs(lines) do
    if line ~= '' then -- Skip empty lines
      table.insert(storage[category], line)

      -- Also store in combined output with metadata
      table.insert(storage.all, {
        category = category,
        source = source or 'unknown',
        timestamp = timestamp,
        line = line
      })
    end
  end

  -- Limit storage size to prevent memory issues
  while #storage[category] > max_output_lines do
    table.remove(storage[category], 1)
  end

  while #storage.all > max_output_lines do
    table.remove(storage.all, 1)
  end
end

-- Clean up output storage when session ends
local function cleanup_output_storage(session_id)
  if program_output[session_id] then
    program_output[session_id] = nil
  end
end

-- Helper function to get code context around a specific line
local function get_code_context(file_path, target_line, context_lines)
  context_lines = context_lines or 5

  if not file_path or file_path == "<unknown>" then
    return nil, "Unknown file path"
  end

  -- Check if file exists
  if vim.fn.filereadable(file_path) == 0 then
    return nil, "File not readable: " .. file_path
  end

  local lines = {}
  local file = io.open(file_path, "r")
  if not file then
    return nil, "Could not open file: " .. file_path
  end

  local line_num = 1
  for line in file:lines() do
    lines[line_num] = line
    line_num = line_num + 1
  end
  file:close()

  local total_lines = #lines
  if target_line < 1 or target_line > total_lines then
    return nil, "Line " .. target_line .. " is out of range (1-" .. total_lines .. ")"
  end

  -- Calculate range
  local start_line = math.max(1, target_line - context_lines)
  local end_line = math.min(total_lines, target_line + context_lines)

  -- Build context output
  local context_output = {}
  table.insert(context_output, "\nCode context around breakpoint:")
  table.insert(context_output, string.rep("-", 60))

  for i = start_line, end_line do
    local line_content = lines[i] or ""
    local line_indicator = (i == target_line) and "> " or "  "
    local formatted_line = string.format("%s%4d │ %s", line_indicator, i, line_content)
    table.insert(context_output, formatted_line)
  end

  table.insert(context_output, string.rep("-", 60))

  return table.concat(context_output, "\n")
end

-- Shared wait until paused functionality
local function wait_until_paused_impl(timeout_ms, check_interval_ms)
  timeout_ms = timeout_ms or 30000
  check_interval_ms = check_interval_ms or 100

  local ok, dap = pcall(require, 'dap')
  if not ok then
    return false, "nvim-dap not available"
  end

  local session = dap.session()
  if not session then
    return false, "No active debug session"
  end

  -- Track if we've seen a state change indicating pause
  local pause_detected = false
  local pause_reason = "unknown"
  local pause_location = nil
  local location_updated = false
  local pause_start_time = nil

  -- Set up a temporary listener for stopped events
  local listener_key = "wait_until_paused_" .. tostring(math.random(1000000))

  dap.listeners.after['event_stopped'][listener_key] = function(session_obj, body)
    pause_detected = true
    pause_reason = body.reason or "unknown"
    pause_start_time = vim.fn.localtime() * 1000 -- milliseconds

    -- Get the thread ID from the stopped event
    local thread_id = body.threadId
    if not thread_id then
      -- Fallback to the first available thread
      if session_obj.threads then
        for tid, _ in pairs(session_obj.threads) do
          thread_id = tid
          break
        end
      end
    end

    -- Request stack trace to get current location
    if thread_id and session_obj.request then
      session_obj:request('stackTrace', {
        threadId = thread_id,
        startFrame = 0,
        levels = 1 -- We only need the top frame
      }, function(err, result)
        if not err and result and result.stackFrames and #result.stackFrames > 0 then
          local frame = result.stackFrames[1]
          pause_location = {
            file = (frame.source and frame.source.path) or "<unknown>",
            line = frame.line or 0,
            function_name = frame.name or "<unknown>"
          }
        else
          -- Fallback if stack trace request fails
          pause_location = {
            file = "<unknown>",
            line = 0,
            function_name = "<unknown>"
          }
        end
        location_updated = true

        -- Focus the frame after getting location
        pcall(dap.focus_frame)
      end)
    else
      -- No thread ID available, set default location
      pause_location = {
        file = "<unknown>",
        line = 0,
        function_name = "<unknown>"
      }
      location_updated = true
      pcall(dap.focus_frame)
    end

    -- Return true to remove this listener after first use
    return true
  end

  -- Also listen for terminated/disconnected events to handle early termination
  local termination_detected = false
  local termination_reason = ""

  dap.listeners.after['event_terminated'][listener_key] = function(session_obj, body)
    termination_detected = true
    termination_reason = "session terminated"
    return true
  end

  dap.listeners.after['event_exited'][listener_key] = function(session_obj, body)
    termination_detected = true
    termination_reason = "debuggee exited with code " .. (body.exitCode or "unknown")
    return true
  end

  -- Wait for the pause condition with vim.wait
  local success = vim.wait(timeout_ms, function()
    -- Check if session was terminated
    if termination_detected then
      return true
    end

    local ok_dap, current_dap = pcall(require, 'dap')
    if not ok_dap then
      return false
    end

    -- Check if session is no longer active
    local current_session = current_dap.session()
    if not current_session or current_session.id ~= session.id then
      termination_detected = true
      termination_reason = "session ended"
      return true
    end

    -- Check if we received a stopped event AND location has been updated
    if pause_detected and location_updated then
      return true
    end

    -- Fallback: if we've been paused for more than 2 seconds but location
    -- update hasn't completed, proceed anyway to avoid hanging
    if pause_detected then
      local time_since_pause = vim.fn.localtime() * 1000 - (pause_start_time or 0)
      if time_since_pause > 2000 then -- 2 second timeout for location update
        if not location_updated then
          -- Set fallback location and proceed
          pause_location = {
            file = "<unknown>",
            line = 0,
            function_name = "<unknown>"
          }
          location_updated = true
        end
        return true
      end
    end

    return false
  end, check_interval_ms)

  -- Clean up any remaining listeners
  dap.listeners.after['event_stopped'][listener_key] = nil
  dap.listeners.after['event_terminated'][listener_key] = nil
  dap.listeners.after['event_exited'][listener_key] = nil

  -- Handle results
  if termination_detected then
    return false, "Debug session ended while waiting: " .. termination_reason
  end

  if not success then
    return false, string.format("Timeout after %dms waiting for debugger to pause", timeout_ms)
  end

  if pause_detected then
    local output = string.format("Debugger paused due to: %s", pause_reason)

    if pause_location then
      output = output .. string.format("\nLocation: %s:%d in %s",
        pause_location.file,
        pause_location.line or 0,
        pause_location.function_name)

      -- Add code context around the pause location
      local code_context, context_err = get_code_context(pause_location.file, pause_location.line, 5)
      if code_context then
        output = output .. code_context
      elseif context_err then
        output = output .. "\n\nNote: Could not retrieve code context: " .. context_err
      end
    end

    -- Get current status for additional info
    local ok_status, status_dap = pcall(require, 'dap')
    if ok_status then
      local current_status = status_dap.status()
      if current_status and current_status ~= "" then
        output = output .. "\nStatus: " .. current_status
      end
    end

    return true, output
  end

  -- Fallback case (shouldn't reach here normally)
  return false, "Unknown wait condition result"
end

-- Smart buffer management for DAP operations
local function smart_buffer_management(target_file, target_line)
  -- Resolve relative paths
  local resolved_file = target_file
  if not vim.startswith(resolved_file, "/") then
    resolved_file = vim.fn.getcwd() .. "/" .. resolved_file
  end

  -- Check if file exists
  if vim.fn.filereadable(resolved_file) == 0 then
    return nil, "File not found: " .. resolved_file
  end

  -- Function to check if a buffer is "special" (temporary, chat, etc.)
  local function is_special_buffer(bufnr)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local filetype = vim.bo[bufnr].filetype
    local buftype = vim.bo[bufnr].buftype

    -- Check for special buffer types
    if buftype ~= "" and buftype ~= "acwrite" then
      return true
    end

    -- Check for chat/AI related filetypes
    local special_filetypes = {
      "codecompanion", "avante", "chatgpt", "copilot-chat",
      "dap-repl", "dapui_scopes", "dapui_breakpoints",
      "dapui_stacks", "dapui_watches", "dapui_console"
    }

    for _, ft in ipairs(special_filetypes) do
      if filetype == ft then
        return true
      end
    end

    -- Check for unnamed/scratch buffers
    if name == "" then
      return true
    end

    -- Check for specific patterns in buffer names
    local special_patterns = {
      "^term://", "^fugitive://", "^oil://",
      "^%[.*%]$", -- Buffers with names like [No Name], [Scratch]
      --"^Chat", "^AI", "^Assistant"
    }

    for _, pattern in ipairs(special_patterns) do
      if string.match(name, pattern) then
        return true
      end
    end

    return false
  end

  -- Step 1: Check if target file is already open in any buffer
  local target_bufnr = nil
  local target_winnr = nil

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local buf_name = vim.api.nvim_buf_get_name(bufnr)
      if buf_name == resolved_file then
        target_bufnr = bufnr

        -- Check if this buffer is visible in any window
        for _, winnr in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(winnr) == bufnr then
            target_winnr = winnr
            break
          end
        end
        break
      end
    end
  end

  -- Step 2: If file is already visible, use that window
  if target_bufnr and target_winnr then
    vim.api.nvim_set_current_win(target_winnr)
    if target_line then
      vim.api.nvim_win_set_cursor(target_winnr, { target_line, 0 })
    end
    return target_bufnr, target_winnr
  end

  -- Step 3: Find a suitable window to use (avoid special buffers)
  local suitable_winnr = nil
  local current_winnr = vim.api.nvim_get_current_win()

  -- First, try windows other than current
  for _, winnr in ipairs(vim.api.nvim_list_wins()) do
    if winnr ~= current_winnr then
      local bufnr = vim.api.nvim_win_get_buf(winnr)
      if not is_special_buffer(bufnr) then
        suitable_winnr = winnr
        break
      end
    end
  end

  -- If no suitable window found and current window is not special, use it
  if not suitable_winnr then
    local current_bufnr = vim.api.nvim_win_get_buf(current_winnr)
    if not is_special_buffer(current_bufnr) then
      suitable_winnr = current_winnr
    end
  end

  -- Step 4: If we have a suitable window, use it
  if suitable_winnr then
    vim.api.nvim_set_current_win(suitable_winnr)

    if target_bufnr then
      -- File is loaded but not visible, switch to it
      vim.api.nvim_win_set_buf(suitable_winnr, target_bufnr)
    else
      -- Open the file in the suitable window
      vim.cmd("edit " .. vim.fn.fnameescape(resolved_file))
      target_bufnr = vim.api.nvim_get_current_buf()
    end

    if target_line then
      vim.api.nvim_win_set_cursor(suitable_winnr, { target_line, 0 })
    end

    return target_bufnr, suitable_winnr
  end

  -- Step 5: No suitable window found, create a new split
  -- Use vertical split if window is wide enough, otherwise horizontal
  local width = vim.api.nvim_win_get_width(0)
  local split_cmd = width > 120 and "vsplit" or "split"

  vim.cmd(split_cmd .. " " .. vim.fn.fnameescape(resolved_file))

  target_bufnr = vim.api.nvim_get_current_buf()
  target_winnr = vim.api.nvim_get_current_win()

  if target_line then
    vim.api.nvim_win_set_cursor(target_winnr, { target_line, 0 })
  end

  return target_bufnr, target_winnr
end

-- Setup the MCP DAP server
function M.setup()
  local ok, deps = check_dependencies()
  if not ok then
    vim.notify("mcpdap: " .. deps, vim.log.levels.ERROR)
    return false
  end

  local dap = deps.dap
  local mcphub = deps.mcphub

  -- Set up global output event listener
  -- Note: Using 'event_output' as per DAP protocol specification
  dap.listeners.after['event_output']['mcpdap_output_capture'] = function(session, body)
    if session and session.id and body and body.output then
      local category = 'console' -- Default category

      -- Determine output category based on DAP output event properties
      if body.category then
        if body.category == 'stdout' then
          category = 'stdout'
        elseif body.category == 'stderr' then
          category = 'stderr'
        elseif body.category == 'console' then
          category = 'console'
        end
      end

      store_output(session.id, category, body.output, body.source or body.category)
    end
  end

  -- Clean up output storage when sessions end
  dap.listeners.after['event_terminated']['mcpdap_output_cleanup'] = function(session, body)
    if session and session.id then
      cleanup_output_storage(session.id)
    end
  end

  dap.listeners.after['event_exited']['mcpdap_output_cleanup'] = function(session, body)
    if session and session.id then
      cleanup_output_storage(session.id)
    end
  end

  -- Session Management Tools
  mcphub.add_tool("dap", {
    name = "continue",
    description = "Continue execution of a paused debug session (requires active session)",
    inputSchema = {
      type = "object",
      properties = {
        force_new = {
          type = "boolean",
          description = "Force starting a new session even if one exists",
          default = false
        },
        wait_until_paused = {
          type = "boolean",
          description = WAIT_UNTIL_PAUSED_DESC,
          default = false
        },
        wait_timeout_ms = {
          type = "integer",
          description = "Timeout for waiting until paused in milliseconds (default: 30000ms/30s)",
          default = 30000
        }
      }
    },
    handler = function(req, res)
      local opts = req.params.force_new and { new = true } or {}

      local continue_ok, continue_err = pcall(dap.continue, opts)
      if not continue_ok then
        return res:error("Failed to continue: " .. tostring(continue_err))
      end

      local result_msg = "Debug session continued or started"

      if req.params.wait_until_paused then
        local wait_success, wait_result = wait_until_paused_impl(req.params.wait_timeout_ms)
        if not wait_success then
          return res:error(wait_result)
        end
        result_msg = result_msg .. "\n\n" .. wait_result
      end

      return res:text(result_msg):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "run",
    description =
    "Start a new debug session with specified configuration. Note that you may want to set breakpoints before starting debugging (since the program may finish before you can set them otherwise).",
    inputSchema = {
      type = "object",
      properties = {
        type = {
          type = "string",
          description = "Debug adapter type (e.g., 'python', 'node2', 'cppdbg')"
        },
        request = {
          type = "string",
          description = "Request type: 'launch' or 'attach'",
          enum = { "launch", "attach" },
        },
        name = {
          type = "string",
          description = "Configuration name"
        },
        program = {
          type = "string",
          description = "Program to debug (for launch requests)"
        },
        args = {
          type = "array",
          items = { type = "string" },
          description = "Program arguments"
        },
        cwd = {
          type = "string",
          description = "Working directory"
        },
        env = {
          type = "object",
          description = "Environment variables"
        },
        console = {
          type = "string",
          description = "Console type: 'internalConsole', 'integratedTerminal', or 'externalTerminal'"
        },
        host = {
          type = "string",
          description = "Host to connect to (for attach requests)"
        },
        port = {
          type = "integer",
          description = "Port to connect to (for attach requests)"
        },
        processId = {
          type = "integer",
          description = "Process ID to attach to (for attach requests)"
        },
        additional_config = {
          type = "object",
          description = "Additional adapter-specific configuration options"
        },
        force_new = {
          type = "boolean",
          description = "Force starting a new session even if one exists",
          default = false
        },
        wait_until_paused = {
          type = "boolean",
          description = WAIT_UNTIL_PAUSED_DESC,
          default = false
        },
        wait_timeout_ms = {
          type = "integer",
          description = "Timeout for waiting until paused in milliseconds (default: 30000ms/30s)",
          default = 30000
        }
      },
      required = { "type", "request", "name" }
    },
    handler = function(req, res)
      -- Build the configuration
      local config = {
        type = req.params.type,
        request = req.params.request,
        name = req.params.name
      }

      -- Add common properties
      if req.params.program then config.program = req.params.program end
      if req.params.args then config.args = req.params.args end
      if req.params.cwd then config.cwd = req.params.cwd end
      if req.params.env then config.env = req.params.env end
      if req.params.console then config.console = req.params.console end

      -- Add attach-specific properties
      if req.params.host then config.host = req.params.host end
      if req.params.port then config.port = req.params.port end
      if req.params.processId then config.processId = req.params.processId end

      -- Add any additional configuration
      if req.params.additional_config then
        for k, v in pairs(req.params.additional_config) do
          config[k] = v
        end
      end

      -- Handle variable substitution for common cases
      if config.program == "${file}" then
        config.program = vim.api.nvim_buf_get_name(0)
      elseif config.program == "${workspaceFolder}" then
        config.program = vim.fn.getcwd()
      end

      if config.cwd == "${workspaceFolder}" then
        config.cwd = vim.fn.getcwd()
      end

      local opts = req.params.force_new and { new = true } or {}

      local run_ok, run_err = pcall(dap.run, config, opts)
      if not run_ok then
        return res:error("Failed to start debug session: " .. tostring(run_err))
      end

      local result_msg = string.format("Started debug session '%s' with adapter '%s'", config.name, config.type)

      if req.params.wait_until_paused then
        local wait_success, wait_result = wait_until_paused_impl(req.params.wait_timeout_ms)
        if not wait_success then
          return res:error(wait_result)
        end
        result_msg = result_msg .. "\n\n" .. wait_result
      end

      return res:text(result_msg):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "terminate",
    description = "Terminate the current debug session",
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local terminate_ok, terminate_err = pcall(dap.terminate)
      if not terminate_ok then
        return res:error("Failed to terminate session: " .. tostring(terminate_err))
      end

      return res:text("Debug session terminated"):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "disconnect",
    description = "Disconnect from the debug adapter",
    inputSchema = {
      type = "object",
      properties = {
        terminate_debuggee = {
          type = "boolean",
          description = "Whether to terminate the debuggee process",
          default = true
        }
      }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local opts = {
        terminateDebuggee = req.params.terminate_debuggee
      }

      local disconnect_ok, disconnect_err = pcall(dap.disconnect, opts)
      if not disconnect_ok then
        return res:error("Failed to disconnect: " .. tostring(disconnect_err))
      end

      return res:text("Disconnected from debug adapter"):send()
    end
  })

  -- Breakpoint Management Tools
  --[[
  mcphub.add_tool("dap", {
    name = "toggle_breakpoint",
    description = "Toggle a breakpoint at the current line or specified line",
    inputSchema = {
      type = "object",
      properties = {
        line = {
          type = "integer",
          description = "Line number (defaults to current cursor line)"
        },
        condition = {
          type = "string",
          description = "Optional condition for the breakpoint"
        },
        hit_condition = {
          type = "string",
          description = "Optional hit condition (e.g., '5' to break on 5th hit)"
        },
        log_message = {
          type = "string",
          description = "Optional log message (creates a log point instead of breakpoint)"
        }
      }
    },
    handler = function(req, res)
      local line = req.params.line
      if line then
        -- Move cursor to specified line
        vim.api.nvim_win_set_cursor(0, { line, 0 })
      end

      local toggle_ok, toggle_err = pcall(dap.toggle_breakpoint,
        req.params.condition,
        req.params.hit_condition,
        req.params.log_message
      )

      if not toggle_ok then
        return res:error("Failed to toggle breakpoint: " .. tostring(toggle_err))
      end

      local current_line = line or vim.api.nvim_win_get_cursor(0)[1]
      local msg = req.params.log_message and "log point" or "breakpoint"
      return res:text(string.format("Toggled %s at line %d", msg, current_line)):send()
    end
  })
  ]]

  mcphub.add_tool("dap", {
    name = "set_breakpoint_at",
    description = "Set a breakpoint at a specific file and line number",
    inputSchema = {
      type = "object",
      properties = {
        filename = {
          type = "string",
          description = "Path to the file (absolute or relative to workspace)"
        },
        line = {
          type = "integer",
          description = "Line number for the breakpoint"
        },
        condition = {
          type = "string",
          description = "Optional condition for the breakpoint"
        },
        hit_condition = {
          type = "string",
          description = "Optional hit condition (e.g., '5' to break on 5th hit)"
        },
        log_message = {
          type = "string",
          description = "Optional log message (creates a log point instead of breakpoint)"
        }
      },
      required = { "filename", "line" }
    },
    handler = function(req, res)
      local filename = req.params.filename
      local line = req.params.line

      local bufnr, winnr = smart_buffer_management(filename, line)
      if not bufnr then
        return res:error(tostring(winnr)) -- winnr contains error message in this case
      end

      -- We can't reliably check for existing breakpoints without access to internal state
      -- So we'll just toggle the breakpoint (which will remove if exists, add if not)
      -- Set/update the breakpoint (toggle will handle existing breakpoints)
      local set_ok, set_err = pcall(dap.set_breakpoint,
        req.params.condition,
        req.params.hit_condition,
        req.params.log_message
      )

      if not set_ok then
        return res:error("Failed to set breakpoint: " .. tostring(set_err))
      end

      local msg = req.params.log_message and "log point" or "breakpoint"
      return res:text(string.format("Set %s at %s:%d", msg, filename, line)):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "clear_breakpoints",
    description = "Clear all breakpoints",
    handler = function(req, res)
      local clear_ok, clear_err = pcall(dap.clear_breakpoints)
      if not clear_ok then
        return res:error("Failed to clear breakpoints: " .. tostring(clear_err))
      end

      return res:text("All breakpoints cleared"):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "list_breakpoints",
    description = "List all breakpoints and log points",
    handler = function(req, res)
      local list_ok, list_err = pcall(dap.list_breakpoints)
      if not list_ok then
        return res:error("Failed to list breakpoints: " .. tostring(list_err))
      end

      return res:text("Breakpoints listed in quickfix window"):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "get_breakpoints",
    description = "Get detailed information about all breakpoints and log points",
    handler = function(req, res)
      -- Get breakpoint information from signs since nvim-dap uses signs to display breakpoints
      local breakpoints = {}

      -- Get all buffers and check for DAP signs
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          local filename = vim.api.nvim_buf_get_name(bufnr)
          if filename and filename ~= "" then
            -- Get signs for this buffer
            local signs = vim.fn.sign_getplaced(bufnr, { group = "*" })[1]
            if signs and signs.signs then
              for _, sign in ipairs(signs.signs) do
                -- Check for DAP breakpoint signs
                if sign.name == "DapBreakpoint" or
                    sign.name == "DapBreakpointCondition" or
                    sign.name == "DapLogPoint" or
                    sign.name == "DapBreakpointRejected" then
                  table.insert(breakpoints, {
                    file = filename,
                    line = sign.lnum,
                    type = sign.name,
                    verified = sign.name ~= "DapBreakpointRejected",
                    sign_id = sign.id
                  })
                end
              end
            end
          end
        end
      end

      if #breakpoints == 0 then
        return res:text("No breakpoints found"):send()
      end

      local output = "Breakpoints:\n"
      for i, bp in ipairs(breakpoints) do
        local type_desc = bp.type:gsub("Dap", ""):lower()
        local status = bp.verified and "verified" or "rejected"
        output = output .. string.format("%d. %s:%d [%s, %s]\n",
          i, bp.file, bp.line, type_desc, status)
      end

      return res:text(output):send()
    end
  })

  -- Step Control Tools
  mcphub.add_tool("dap", {
    name = "step_over",
    description = "Step over the current line",
    inputSchema = {
      type = "object",
      properties = {
        wait_until_paused = {
          type = "boolean",
          description = WAIT_UNTIL_PAUSED_DESC,
          default = false
        },
        wait_timeout_ms = {
          type = "integer",
          description = "Timeout for waiting until paused in milliseconds (default: 30000ms/30s)",
          default = 30000
        }
      }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local step_over_ok, step_over_err = pcall(dap.step_over)
      if not step_over_ok then
        return res:error("Failed to step over: " .. tostring(step_over_err))
      end

      local result_msg = "Stepped over"

      if req.params.wait_until_paused then
        local wait_success, wait_result = wait_until_paused_impl(req.params.wait_timeout_ms)
        if not wait_success then
          return res:error(wait_result)
        end
        result_msg = result_msg .. "\n\n" .. wait_result
      end

      return res:text(result_msg):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "step_into",
    description = "Step into the current function or method",
    inputSchema = {
      type = "object",
      properties = {
        ask_for_targets = {
          type = "boolean",
          description = "Ask user to choose step-in target if multiple options exist",
          default = false
        },
        wait_until_paused = {
          type = "boolean",
          description = WAIT_UNTIL_PAUSED_DESC,
          default = false
        },
        wait_timeout_ms = {
          type = "integer",
          description = "Timeout for waiting until paused in milliseconds (default: 30000ms/30s)",
          default = 30000
        }
      }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local opts = req.params.ask_for_targets and { askForTargets = true } or {}

      local step_into_ok, step_into_err = pcall(dap.step_into, opts)
      if not step_into_ok then
        return res:error("Failed to step into: " .. tostring(step_into_err))
      end

      local result_msg = "Stepped into"

      if req.params.wait_until_paused then
        local wait_success, wait_result = wait_until_paused_impl(req.params.wait_timeout_ms)
        if not wait_success then
          return res:error(wait_result)
        end
        result_msg = result_msg .. "\n\n" .. wait_result
      end

      return res:text(result_msg):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "step_out",
    description = "Step out of the current function or method",
    inputSchema = {
      type = "object",
      properties = {
        wait_until_paused = {
          type = "boolean",
          description = WAIT_UNTIL_PAUSED_DESC,
          default = false
        },
        wait_timeout_ms = {
          type = "integer",
          description = "Timeout for waiting until paused in milliseconds (default: 30000ms/30s)",
          default = 30000
        }
      }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local step_out_ok, step_out_err = pcall(dap.step_out)
      if not step_out_ok then
        return res:error("Failed to step out: " .. tostring(step_out_err))
      end

      local result_msg = "Stepped out"

      if req.params.wait_until_paused then
        local wait_success, wait_result = wait_until_paused_impl(req.params.wait_timeout_ms)
        if not wait_success then
          return res:error(wait_result)
        end
        result_msg = result_msg .. "\n\n" .. wait_result
      end

      return res:text(result_msg):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "run_to",
    description = "Run execution to a specific file and line number",
    inputSchema = {
      type = "object",
      properties = {
        filename = {
          type = "string",
          description = "Path to the file (absolute or relative to workspace)"
        },
        line = {
          type = "integer",
          description = "Line number to run to"
        },
        wait_until_paused = {
          type = "boolean",
          description = WAIT_UNTIL_PAUSED_DESC,
          default = false
        },
        wait_timeout_ms = {
          type = "integer",
          description = "Timeout for waiting until paused in milliseconds (default: 30000ms/30s)",
          default = 30000
        }
      },
      required = { "filename", "line" }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local filename = req.params.filename
      local line = req.params.line

      local bufnr, winnr = smart_buffer_management(filename, line)
      if not bufnr then
        return res:error(tostring(winnr)) -- winnr contains error message in this case
      end

      local run_to_ok, run_to_err = pcall(dap.run_to_cursor)
      if not run_to_ok then
        return res:error("Failed to run to cursor: " .. tostring(run_to_err))
      end

      local result_msg = string.format("Running to %s:%d", filename, line)

      if req.params.wait_until_paused then
        local wait_success, wait_result = wait_until_paused_impl(req.params.wait_timeout_ms)
        if not wait_success then
          return res:error(wait_result)
        end
        result_msg = result_msg .. "\n\n" .. wait_result
      end

      return res:text(result_msg):send()
    end
  })

  -- Information Gathering Tools
  mcphub.add_tool("dap", {
    name = "status",
    description = "Get the current debug session status",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session"):send()
      end

      local status = dap.status()
      local session_info = {
        status = status,
        id = session.id,
        adapter_type = session.config and session.config.type or "unknown",
        name = session.config and session.config.name or "unnamed"
      }

      return res:text(vim.inspect(session_info)):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "evaluate",
    description = "Evaluate an expression in the current debug context",
    inputSchema = {
      type = "object",
      properties = {
        expression = {
          type = "string",
          description = "Expression to evaluate"
        },
        context = {
          type = "string",
          description = "Evaluation context",
          enum = { "watch", "repl", "hover", "clipboard" },
          default = "hover"
        },
        frame_id = {
          type = "integer",
          description = "Specific frame ID to evaluate in (optional)"
        }
      },
      required = { "expression" }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local expression = req.params.expression
      if not expression or expression == "" then
        return res:error("Expression is required")
      end

      local session = dap.session()
      if not session then
        return res:error("No active session")
      end

      -- Synchronous evaluation using vim.wait
      local eval_result = nil
      local eval_error = nil
      local completed = false

      session:request("evaluate", {
        expression = expression,
        context = req.params.context or "hover",
        frameId = req.params.frame_id or session.current_frame and session.current_frame.id or nil
      }, function(eval_err, result)
        eval_error = eval_err
        eval_result = result
        completed = true
      end)

      -- Wait for completion with timeout
      local success = vim.wait(5000, function()
        return completed
      end, 100)

      if not success then
        return res:error("Evaluation timed out")
      end

      if eval_error then
        return res:error("Evaluation failed: " .. (eval_error.message or "Unknown error"))
      end

      if not eval_result then
        return res:error("No evaluation result received")
      end

      local output = string.format("%s = %s", expression, eval_result.result or "<no result>")
      if eval_result.type then
        output = output .. " (" .. eval_result.type .. ")"
      end

      if eval_result.memoryReference then
        output = output .. " [memory: " .. eval_result.memoryReference .. "]"
      end

      return res:text(output):send()
    end
  })

  -- REPL Tools
  --[[
  mcphub.add_tool("dap", {
    name = "repl_open",
    description = "Open the debug REPL console",
    handler = function(req, res)
      local repl_open_ok, repl_open_err = pcall(function()
        dap.repl.open()
      end)

      if not repl_open_ok then
        return res:error("Failed to open REPL: " .. tostring(repl_open_err))
      end

      return res:text("Debug REPL opened"):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "repl_close",
    description = "Close the debug REPL console",
    handler = function(req, res)
      local repl_close_ok, repl_close_err = pcall(function()
        dap.repl.close()
      end)

      if not repl_close_ok then
        return res:error("Failed to close REPL: " .. tostring(repl_close_err))
      end

      return res:text("Debug REPL closed"):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "repl_toggle",
    description = "Toggle the debug REPL console",
    handler = function(req, res)
      local repl_toggle_ok, repl_toggle_err = pcall(function()
        dap.repl.toggle()
      end)

      if not repl_toggle_ok then
        return res:error("Failed to toggle REPL: " .. tostring(repl_toggle_err))
      end

      return res:text("Debug REPL toggled"):send()
    end
  })
  ]]

  -- Resources for debugging information
  mcphub.add_resource("dap", {
    name = "session_info",
    uri = "dap://session",
    description = "Current debug session information",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session", "text/plain"):send()
      end

      local info = {
        id = session.id,
        status = dap.status(),
        adapter_type = session.config and session.config.type or "unknown",
        name = session.config and session.config.name or "unnamed",
        request = session.config and session.config.request or "unknown"
      }

      return res:text(vim.inspect(info), "text/plain"):send()
    end
  })

  mcphub.add_resource("dap", {
    name = "stack_trace",
    uri = "dap://stack",
    description = "Current stack trace information",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session", "text/plain"):send()
      end

      -- Be defensive about session structure
      if not session.current_frame then
        return res:text("No current frame available", "text/plain"):send()
      end

      local frames_info = {}
      -- Safely access session properties
      if session.threads and session.stopped_thread_id and session.threads[session.stopped_thread_id] then
        local thread = session.threads[session.stopped_thread_id]
        if thread and thread.frames then
          for i, frame in ipairs(thread.frames) do
            local frame_info = {
              id = frame.id or 0,
              name = frame.name or "<unknown>",
              line = frame.line or 0,
              column = frame.column or 0,
              source = (frame.source and frame.source.path) or "<unknown>"
            }
            if i == 1 then
              frame_info.current = true
            end
            table.insert(frames_info, frame_info)
          end
        end
      end

      if #frames_info == 0 then
        return res:text("No stack frame information available", "text/plain"):send()
      end

      return res:text(vim.inspect(frames_info), "text/plain"):send()
    end
  })

  --[[
  mcphub.add_resource("dap", {
    name = "variables",
    uri = "dap://variables",
    description = "Current scope variables",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session", "text/plain"):send()
      end

      -- Be defensive about session structure
      if not session.current_frame then
        return res:text("No current frame available", "text/plain"):send()
      end

      local current_frame = session.current_frame
      -- This is a simplified version - real implementation would need
      -- to make async requests to get scopes and variables
      local info = {
        frame_id = current_frame.id or 0,
        note = "Use the 'evaluate' tool to inspect specific variables",
        suggestion = "Try: dap.evaluate with expressions like 'variableName' or 'self.property'"
      }

      return res:text(vim.inspect(info), "text/plain"):send()
    end
  })
  ]]

  mcphub.add_tool("dap", {
    name = "get_program_output",
    description = "Get the output from the running/debugged program",
    inputSchema = {
      type = "object",
      properties = {
        category = {
          type = "string",
          description = "Output category to retrieve",
          enum = { "all", "stdout", "stderr", "console" },
          default = "all"
        },
        lines = {
          type = "integer",
          description = "Number of recent lines to retrieve (default: 50, max: 1000)",
          default = 50
        },
        include_metadata = {
          type = "boolean",
          description = "Include timestamps and source information",
          default = false
        }
      }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local session_id = session_info.id
      local category = req.params.category or "all"
      local lines_requested = math.min(req.params.lines or 50, 1000)
      local include_metadata = req.params.include_metadata or false

      if not program_output[session_id] then
        return res:text("No output captured for current session"):send()
      end

      local storage = program_output[session_id]
      local output_lines = {}

      if category == "all" then
        -- Get combined output with metadata
        local all_output = storage.all
        local start_idx = math.max(1, #all_output - lines_requested + 1)

        for i = start_idx, #all_output do
          local entry = all_output[i]
          if include_metadata then
            local time_str = os.date("%H:%M:%S", entry.timestamp)
            table.insert(output_lines, string.format("[%s][%s] %s", time_str, entry.category, entry.line))
          else
            table.insert(output_lines, entry.line)
          end
        end
      else
        -- Get category-specific output
        if not storage[category] then
          return res:error("Invalid category: " .. category)
        end

        local cat_output = storage[category]
        local start_idx = math.max(1, #cat_output - lines_requested + 1)

        for i = start_idx, #cat_output do
          table.insert(output_lines, cat_output[i])
        end
      end

      if #output_lines == 0 then
        return res:text("No output available for category: " .. category):send()
      end

      local result = table.concat(output_lines, "\n")
      local header = string.format("Program output (%s, last %d lines):\n%s\n",
        category, #output_lines, string.rep("-", 50))

      return res:text(header .. result):send()
    end
  })
  mcphub.add_tool("dap", {
    name = "get_current_location",
    description = "Get the current execution location in the debugger",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:error("No active debug session")
      end

      -- Be defensive about session structure
      local current_frame = session.current_frame
      if not current_frame then
        return res:text("No current execution location available"):send()
      end

      local location = {
        file = (current_frame.source and current_frame.source.path) or "<unknown>",
        line = current_frame.line or 0,
        column = current_frame.column or 0,
        function_name = current_frame.name or "<unknown>"
      }

      local output = string.format("Currently stopped at:\n  File: %s\n  Line: %d\n  Column: %d\n  Function: %s",
        location.file, location.line, location.column, location.function_name)

      -- Add code context around the current location
      local code_context, context_err = get_code_context(location.file, location.line, 5)
      if code_context then
        output = output .. code_context
      elseif context_err then
        output = output .. "\n\nNote: Could not retrieve code context: " .. context_err
      end

      return res:text(output):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "wait_until_paused",
    description =
    "Wait until the debugger is paused (breakpoint hit, step completed, etc.). This tool blocks until the debugger stops or times out.",
    inputSchema = {
      type = "object",
      properties = {
        timeout_ms = {
          type = "integer",
          description = "Maximum time to wait in milliseconds (default: 30000ms/30s)",
          default = 30000
        },
        check_interval_ms = {
          type = "integer",
          description = "How often to check if paused in milliseconds (default: 100ms)",
          default = 100
        }
      }
    },
    handler = function(req, res)
      local session_info, err = get_session_info()
      if not session_info then
        return res:error(err or "Unknown error")
      end

      local timeout_ms = req.params.timeout_ms or 30000
      local check_interval_ms = req.params.check_interval_ms or 100

      local wait_success, wait_result = wait_until_paused_impl(timeout_ms, check_interval_ms)
      if not wait_success then
        return res:error(wait_result)
      end

      return res:text(wait_result):send()
    end
  })

  mcphub.add_tool("dap", {
    name = "remove_breakpoint_at",
    description = "Remove a specific breakpoint at file and line",
    inputSchema = {
      type = "object",
      properties = {
        filename = {
          type = "string",
          description = "Path to the file (absolute or relative to workspace)"
        },
        line = {
          type = "integer",
          description = "Line number of the breakpoint to remove"
        }
      },
      required = { "filename", "line" }
    },
    handler = function(req, res)
      local filename = req.params.filename
      local line = req.params.line

      -- Resolve relative paths for buffer search
      local resolved_file = filename
      if not vim.startswith(resolved_file, "/") then
        resolved_file = vim.fn.getcwd() .. "/" .. resolved_file
      end

      -- Find the buffer for this file
      local bufnr = nil
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(buf) == resolved_file then
          bufnr = buf
          break
        end
      end

      if not bufnr then
        return res:error("File not loaded in any buffer: " .. filename)
      end

      -- We cannot reliably check if a specific breakpoint exists without internal API access
      -- So we'll just attempt to remove the breakpoint at this location
      local remove_ok, remove_err = pcall(dap.toggle_breakpoint)
      if not remove_ok then
        return res:error("Failed to toggle breakpoint: " .. tostring(remove_err))
      end

      return res:text(string.format("Toggled breakpoint at %s:%d (removed if existed)", filename, line)):send()
    end
  })

  -- Add output-related resources
  mcphub.add_resource("dap", {
    name = "program_output",
    uri = "dap://output",
    description = "Current program output (all categories combined)",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session", "text/plain"):send()
      end

      local session_id = session.id
      if not program_output[session_id] then
        return res:text("No output captured for current session", "text/plain"):send()
      end

      local storage = program_output[session_id]
      local output_lines = {}

      for _, entry in ipairs(storage.all) do
        local time_str = os.date("%H:%M:%S", entry.timestamp)
        table.insert(output_lines, string.format("[%s][%s] %s", time_str, entry.category, entry.line))
      end

      if #output_lines == 0 then
        return res:text("No output available", "text/plain"):send()
      end

      return res:text(table.concat(output_lines, "\n"), "text/plain"):send()
    end
  })

  mcphub.add_resource_template("dap", {
    name = "output_by_category",
    uriTemplate = "dap://output/{category}",
    description = "Program output filtered by category (stdout, stderr, console)",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session", "text/plain"):send()
      end

      local session_id = session.id
      local category = req.params.category

      if not program_output[session_id] then
        return res:text("No output captured for current session", "text/plain"):send()
      end

      local storage = program_output[session_id]
      if not storage[category] then
        return res:error("Invalid category: " .. category .. ". Valid categories: stdout, stderr, console, all")
      end

      local output_lines = storage[category]
      if #output_lines == 0 then
        return res:text("No " .. category .. " output available", "text/plain"):send()
      end

      local header = string.format("%s output (%d lines):\n%s\n",
        string.upper(category), #output_lines, string.rep("-", 40))

      return res:text(header .. table.concat(output_lines, "\n"), "text/plain"):send()
    end
  })

  mcphub.add_resource_template("dap", {
    name = "output_recent",
    uriTemplate = "dap://output/recent/{lines}",
    description = "Recent program output (specify number of lines)",
    handler = function(req, res)
      local session = dap.session()
      if not session then
        return res:text("No active debug session", "text/plain"):send()
      end

      local session_id = session.id
      local lines_requested = tonumber(req.params.lines) or 50
      lines_requested = math.min(lines_requested, 1000) -- Cap at 1000 lines

      if not program_output[session_id] then
        return res:text("No output captured for current session", "text/plain"):send()
      end

      local storage = program_output[session_id]
      local all_output = storage.all
      local output_lines = {}

      local start_idx = math.max(1, #all_output - lines_requested + 1)
      for i = start_idx, #all_output do
        local entry = all_output[i]
        local time_str = os.date("%H:%M:%S", entry.timestamp)
        table.insert(output_lines, string.format("[%s][%s] %s", time_str, entry.category, entry.line))
      end

      if #output_lines == 0 then
        return res:text("No output available", "text/plain"):send()
      end

      local header = string.format("Recent program output (last %d lines):\n%s\n",
        #output_lines, string.rep("-", 50))

      return res:text(header .. table.concat(output_lines, "\n"), "text/plain"):send()
    end
  })

  -- Add breakpoints resource
  mcphub.add_resource("dap", {
    name = "breakpoints",
    uri = "mcpdap://breakpoints",
    description = "List all currently set breakpoints in JSON format",
    handler = function(req, res)
      local ok, dap = pcall(require, "dap")
      if not ok then
        return res:error("nvim-dap not available")
      end

      -- Get breakpoint information from signs since nvim-dap uses signs to display breakpoints
      local breakpoints = {}

      -- Get all buffers and check for DAP signs
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
          local filename = vim.api.nvim_buf_get_name(bufnr)
          if filename and filename ~= "" then
            -- Get signs for this buffer
            local signs = vim.fn.sign_getplaced(bufnr, { group = "*" })[1]
            if signs and signs.signs then
              for _, sign in ipairs(signs.signs) do
                -- Check for DAP breakpoint signs
                if sign.name == "DapBreakpoint" or
                    sign.name == "DapBreakpointCondition" or
                    sign.name == "DapLogPoint" or
                    sign.name == "DapBreakpointRejected" then
                  table.insert(breakpoints, {
                    file = filename,
                    line = sign.lnum,
                    type = sign.name,
                    verified = sign.name ~= "DapBreakpointRejected",
                    sign_id = sign.id,
                    -- Note: Conditions and hit conditions are not accessible via signs
                    condition = nil,
                    hit_condition = nil,
                    log_message = sign.name == "DapLogPoint" and "<log point>" or nil
                  })
                end
              end
            end
          end
        end
      end

      return res:text(vim.fn.json_encode(breakpoints), "application/json"):send()
    end
  })

  return true
end

return M
