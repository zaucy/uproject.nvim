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
		M.uproject_engine_install_dir(engine_association, function(install_dir)
			local engine_dir = vim.fs.joinpath(install_dir, "Engine")
			local ubt = vim.fs.joinpath(engine_dir, "Binaries", "DotNET", "UnrealBuildTool", "UnrealBuildTool.exe")

			vim.uv.spawn(ubt, {
				args = {
					'-mode=GenerateClangDatabase',
					'-project=' .. project_path:absolute(),
					'-game',
					'-engine',
					'-Target=UnrealEditor Development Win64',
				},
			}, function(code, _)
				local notify_level = vim.log.levels.INFO
				if code ~= 0 then
					notify_level = vim.log.levels.ERROR
				else
					vim.uv.fs_copyfile(
						vim.fs.joinpath(install_dir, 'compile_commands.json'),
						vim.fs.joinpath(tostring(vim.fs.dirname(project_path:absolute())), 'compile_commands.json')
					)
				end
				vim.schedule_wrap(vim.notify)(
					"uproject reload done (exit code " .. code .. ")",
					notify_level
				)
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
		if opts.args[1] == "reload" then
			M.uproject_reload(vim.fn.getcwd())
		end
	end, { nargs = 1, complete = function() return { "reload" } end })

	M.uproject_reload(vim.fn.getcwd())
end

return M
