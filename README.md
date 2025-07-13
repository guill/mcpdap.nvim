# mcpdap.nvim

A NeoVim plugin that exposes [nvim-dap](https://github.com/mfussenegger/nvim-dap) debugging functionality via the Model Context Protocol (MCP) through [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim).

This allows any chat plugin that supports MCP to control debugging sessions, set breakpoints, step through code, and evaluate expressions.

## Features

### Session Management
- `run` - Start a new debug session with full configuration (no user interaction)
- `continue` - Continue execution of a paused debug session
- `terminate` - Terminate the current debug session
- `disconnect` - Disconnect from the debug adapter
- `status` - Get current debug session status

### Breakpoint Management
- `set_breakpoint_at` - Set a breakpoint at a specific file and line number
- `remove_breakpoint_at` - Remove a specific breakpoint at file and line
- `clear_breakpoints` - Clear all breakpoints
- `list_breakpoints` - List all breakpoints and log points
- `get_breakpoints` - Get detailed information about all breakpoints and log points

### Step Control
- `step_over` - Step over the current line
- `step_into` - Step into the current function or method
- `step_out` - Step out of the current function or method
- `run_to` - Run execution to a specific file and line number

### Information & Evaluation
- `evaluate` - Evaluate expressions in debug context
- `get_program_output` - Get the output from the running/debugged program
- `get_current_location` - Get the current execution location in the debugger
- `wait_until_paused` - Wait until the debugger is paused

### Resources
- `dap://session` - Current debug session information
- `dap://stack` - Current stack trace information
- `dap://output` - Current program output (all categories combined)
- `dap://output/{category}` - Program output filtered by category (stdout, stderr, console)
- `dap://output/recent/{lines}` - Recent program output (specify number of lines)
- `mcpdap://breakpoints` - List all currently set breakpoints in JSON format

## Requirements

- [nvim-dap](https://github.com/mfussenegger/nvim-dap) - Debug Adapter Protocol client
- [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim) - MCP integration for Neovim

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "guill/mcpdap.nvim",
  dependencies = {
    "mfussenegger/nvim-dap",
    "ravitemer/mcphub.nvim"
  },
  config = function()
    -- Then setup mcpdap
    require('mcpdap').setup({})
  end
}
```

### Manual Setup

1. Install the dependencies:
   - nvim-dap
   - mcphub.nvim

2. Add this plugin to your configuration

3. In your init.lua, after setting up mcphub:

```lua
-- Setup mcphub first
require('mcphub').setup({
  -- your mcphub configuration
})

-- Then register the DAP MCP server
require('mcpdap').setup({})
```

## Usage

Once installed, the DAP tools will be available in any MCP-compatible chat plugin through mcphub.

### Example Commands

**Start debugging with full configuration:**
```
Use the run tool to start debugging:
- type: "python"
- request: "launch" 
- name: "Debug current file"
- program: "${file}"
```

**Start debugging a specific Python script:**
```
Run a debug session with type "python", request "launch", name "Debug main.py", program "/path/to/main.py", and args ["-v", "--debug"]
```

**Attach to a running process:**
```
Start a debug session to attach to a process:
- type: "python"
- request: "attach"
- name: "Attach to server"
- host: "localhost"
- port: 5678
```

**Continue a paused session:**
```
Use the continue tool to resume execution
```

**Set a breakpoint:**
```
Set a breakpoint at line 25 in file main.py
```

**Step through code:**
```
Step over the current line, then step into the next function call
```

**Evaluate expressions:**
```
Evaluate the expression "user.name" in the current debug context
```

**Get session info:**
```
Show me the current debug session status
```

## Configuration

The plugin works with your existing nvim-dap configuration. Make sure you have:

1. Debug adapters configured for your languages
2. Launch configurations set up
3. nvim-dap working properly

Example nvim-dap setup for Python:

```lua
local dap = require('dap')

-- Configure Python debug adapter
dap.adapters.python = {
  type = 'executable',
  command = 'python',
  args = { '-m', 'debugpy.adapter' },
}

-- Configure Python debug configurations
dap.configurations.python = {
  {
    type = 'python',
    request = 'launch',
    name = "Launch file",
    program = "${file}",
    pythonPath = function()
      return vim.fn.exepath('python3')
    end,
  },
}
```

## Troubleshooting

### Plugin not working
1. Ensure nvim-dap is properly installed and configured
2. Verify mcphub.nvim is set up correctly
3. Check that you're requiring mcpdap after mcphub.setup()

### Debug session issues
1. Make sure you have debug adapters configured for your language
2. Verify your launch configurations are correct
3. Test nvim-dap directly first to ensure it's working

### MCP tools not appearing
1. Check mcphub is running: `:MCPHub`
2. Verify the DAP server is connected in the mcphub UI
3. Look for error messages in `:messages`

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

MIT License - see LICENSE file for details.
