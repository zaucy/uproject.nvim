# uproject.nvim

Plugin for using the Unreal Engine with neovim. I built it for my workflow, but maybe you'll get some use out of it!

:warning: only works on Windows at this time

## Install

Install with lazy

```lua
{
	"zaucy/uproject.nvim",
	dependencies = {
		'nvim-lua/plenary.nvim',
		"j-hui/fidget.nvim", -- optional
	},
	cmd = { "Uproject" },
	opts = {},
	-- uproject.nvim does not register any keymaps
	-- here are some recommended ones
	keys = {
		{ "<leader>uu", "<cmd>Uproject show_output<cr>",                            desc = "Show last output" },
		{ "<leader>uo", "<cmd>Uproject open<cr>",                                   desc = "Open Unreal Editor" },
		{ "<leader>uO", "<cmd>Uproject build  type_pattern=Editor wait open<cr>",   desc = "Build and open Unreal Editor" },
		{ "<leader>ur", "<cmd>Uproject reload show_output<cr>",                     desc = "Reload uproject" },
		{ "<leader>up", "<cmd>Uproject play log_cmds=Log\\ Log<cr>",                desc = "Play game" },
		{ "<leader>uP", "<cmd>Uproject play debug log_cmds=Log\\ Log<cr>",          desc = "Play game (debug)" },
		{ "<leader>uB", "<cmd>Uproject build type_pattern=Editor wait<cr>",         desc = "Build (keep open)" },
	},
}
```

## Automatically refresh compile_commands

```lua
-- reload when directory changes
vim.api.nvim_create_autocmd("DirChanged", {
	pattern = { "global" },
	callback = function(ev)
		require("uproject").uproject_reload(vim.v.event.cwd, {})
	end,
})
```
