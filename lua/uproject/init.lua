local Path = require("plenary.path")

local M = {}
local commands = {
	reload = function()
		M.uproject_reload(vim.fn.getcwd())
	end,
	open = function()
		M.uproject_open(vim.fn.getcwd())
	end,
	play = function()
		M.uproject_play(vim.fn.getcwd())
	end,
	build = function()
		M.uproject_build(vim.fn.getcwd())
	end,
}

local function uproject_command(opts)
	local command = commands[opts.args]
	if command == nil then
		return
	end

	command(opts)
end

local function select_target(dir)

end

local function make_output_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
	vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
	vim.api.nvim_win_set_buf(0, bufnr)
	-- vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, {})
	return bufnr
end

local function append_output_buffer(bufnr, lines)
	assert(lines ~= nil)
	assert(#lines > 0)
	local bufwin = vim.api.nvim_call_function("bufwinid", { bufnr })
	local was_at_end = false
	if bufwin ~= nil then
		local cursor_line = vim.api.nvim_win_get_cursor(bufwin)[1]
		local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
		was_at_end = cursor_line == buf_line_count
	end

	vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, lines)
	vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
	vim.api.nvim_set_option_value("modified", false, { buf = bufnr })

	if bufwin ~= -1 and was_at_end then
		local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
		vim.api.nvim_win_set_cursor(bufwin, { buf_line_count, 0 })
	end
end

local function spawn_show_output(cmd, args)
	local output = nil
	local output_append = vim.schedule_wrap(function(lines)
		if output == nil then
			output = make_output_buffer()
		end

		append_output_buffer(output, lines)
	end)

	local stdout = vim.uv.new_pipe()
	local stderr = vim.uv.new_pipe()

	vim.uv.spawn(cmd, {
		stdio = { nil, stdout, stderr },
		args = args,
	}, function(code, _)
		output_append({
			"",
			cmd .. " exited with code " .. code,
		})
	end)

	vim.uv.read_start(stdout, function(err, data)
		if data ~= nil then
			output_append(vim.split(data, "\r\n", { trimempty = true }))
		end
	end)

	vim.uv.read_start(stderr, function(err, data)
		if data ~= nil then
			output_append(vim.split(data, "\r\n", { trimempty = true }))
		end
	end)
end

local function str_ends_with(str, suffix)
	return str:sub(- #suffix) == suffix
end

function M.uproject_path(dir)
	assert(dir ~= nil, "uproject_path first param must be a directory")

	for entry, _ in vim.fs.dir(dir) do
		if str_ends_with(entry, ".uproject") then
			return entry
		end
	end

	return nil
end

function M.uproject_engine_association(dir)
	local p = M.uproject_path(dir)
	if p == nil then
		return nil
	end

	local info = vim.fn.json_decode(vim.fn.readfile(p))
	return info["EngineAssociation"]
end

function M.uproject_engine_install_dir(engine_association, cb)
	local stdout = vim.uv.new_pipe()
	local stdout_str = ""
	local spawn_opts = {
		stdio = { nil, stdout, nil },
		args = {
			'query',
			'HKLM\\SOFTWARE\\EpicGames\\Unreal Engine\\' .. engine_association,
			'/v', 'InstalledDirectory',
		},
	}
	vim.uv.spawn('reg', spawn_opts, function(_, _)
		local lines = vim.split(stdout_str, '\r\n', { trimempty = true })
		local value = vim.split(lines[2], '%s+', { trimempty = true })[3]
		cb(value)
	end)

	vim.uv.read_start(stdout, function(err, data)
		assert(not err, err)

		if data then
			stdout_str = stdout_str .. data
		end
	end)
end

function M.uproject_open(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		return
	end

	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association == nil then
		return
	end

	M.uproject_engine_install_dir(engine_association, function(install_dir)
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local ue = vim.fs.joinpath(
			engine_dir, "Binaries", "Win64", "UnrealEditor.exe")

		vim.uv.spawn(ue, {
			detached = true,
			hide = true,
			args = {
				project_path:absolute(),
			},
		}, function(code, _)
		end)
	end)
end

function M.uproject_play(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		return
	end

	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association == nil then
		return
	end

	M.uproject_engine_install_dir(engine_association, function(install_dir)
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local ue = vim.fs.joinpath(
			engine_dir, "Binaries", "Win64", "UnrealEditor.exe")

		spawn_show_output(ue, {
			project_path:absolute(),
			"-game",
		})
	end)
end

function M.uproject_reload(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		return
	end

	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association ~= nil then
		local has_fidget, fidget = pcall(require, 'fidget')
		local fidget_progress = nil

		if has_fidget then
			fidget_progress = fidget.progress.handle.create({
				key = "UProjectReload",
				title = "Reload Uproject",
				message = "",
				lsp_client = { name = "ubt" },
				percentage = 0,
				cancellable = true,
			})
		end

		local function notify_info(msg)
			if has_fidget then
				---@diagnostic disable-next-line: need-check-nil
				fidget_progress.message = msg
			end
		end

		local function notify_error(msg)
			if has_fidget then
				---@diagnostic disable-next-line: need-check-nil
				fidget_progress.message = msg
				---@diagnostic disable-next-line: need-check-nil
				fidget_progress:cancel()
			else
				vim.schedule_wrap(vim.notify)(msg, vim.log.levels.ERROR)
			end
		end

		M.uproject_engine_install_dir(engine_association, function(install_dir)
			local engine_dir = vim.fs.joinpath(install_dir, "Engine")
			local ubt = vim.fs.joinpath(engine_dir, "Binaries", "DotNET", "UnrealBuildTool", "UnrealBuildTool.exe")

			notify_info("Generating compile_commands.json")

			vim.uv.spawn(ubt, {
				args = {
					'-mode=GenerateClangDatabase',
					'-project=' .. project_path:absolute(),
					'-game',
					'-engine',
					'-Target=UnrealEditor Development Win64',
				},
			}, function(code, _)
				if code ~= 0 then
					notify_error("Failed to reload uproject (exit code " .. code .. ")")
				else
					notify_info("Copying compile_commands.json to project root")
					vim.uv.fs_copyfile(
						vim.fs.joinpath(install_dir, 'compile_commands.json'),
						vim.fs.joinpath(tostring(vim.fs.dirname(project_path:absolute())), 'compile_commands.json'),
						function(err)
							if err then
								notify_error(err)
							else
								notify_info("Done")
								if fidget_progress ~= nil then
									fidget_progress:finish()
								end
							end
						end
					)
				end
			end)
		end)
	end
end

function M.uproject_build(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		return
	end

	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association == nil then
		return
	end
	M.uproject_engine_install_dir(engine_association, function(install_dir)
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local build_bat = vim.fs.joinpath(
			engine_dir, "Build", "BatchFiles", "Build.bat")

		spawn_show_output(build_bat, {
			"-Project=" .. project_path:absolute(),
			"-Target=GrabemEditor Win64 Development",
		})
	end)
end

function M.setup(opts)
	vim.api.nvim_create_autocmd("DirChanged", {
		pattern = { "global" },
		callback = function(ev)
			M.uproject_reload(vim.v.event.cwd)
		end,
	})

	vim.api.nvim_create_user_command("Uproject", uproject_command, {
		nargs = 1,
		complete = function()
			return vim.tbl_keys(commands)
		end,
	})

	M.uproject_reload(vim.fn.getcwd())
end

return M
