local Path = require("plenary.path")

local M = {}

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

function M.uproject_reload(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		return
	end

	project_path = Path:new(project_path)

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

			notify_info("generating compile_commands.json")

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
					notify_error("failed to reload uproject (exit code " .. code .. ")")
				else
					notify_info("copying compile_commands.json to project root")
					vim.uv.fs_copyfile(
						vim.fs.joinpath(install_dir, 'compile_commands.json'),
						vim.fs.joinpath(tostring(vim.fs.dirname(project_path:absolute())), 'compile_commands.json'),
						function(err)
							if err then
								notify_error(err)
							else
								notify_info("uproject reload done")
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
	local engine_association = M.uproject_engine_association(dir)
	if engine_association ~= nil then
		M.uproject_engine_install_dir(engine_association, function(install_dir)
			local engine_dir = vim.fs.joinpath(install_dir, "Engine")
			local build_bat = vim.fs.joinpath(engine_dir, "Build", "BatchFiles", "Build.bat")
		end)
	end
end

function M.setup(opts)
	vim.api.nvim_create_autocmd("DirChanged", {
		pattern = { "global" },
		callback = function(ev)
			M.uproject_reload(vim.v.event.cwd)
		end,
	})

	vim.api.nvim_create_user_command("Uproject", function(opts)
		if opts.args == "reload" then
			M.uproject_reload(vim.fn.getcwd())
		end
	end, { nargs = 1, complete = function() return { "reload" } end })

	M.uproject_reload(vim.fn.getcwd())
end

return M
