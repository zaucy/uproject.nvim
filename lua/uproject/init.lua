local Path = require("plenary.path")
local util = require("uproject.util")

local M = {}
---@param arg string
---@param arg_name string
---@return string|nil
local function arg_eq_parse(arg, arg_name)
	local prefix = arg_name .. "="
	if arg:find("^" .. prefix) ~= nil then
		return arg:sub(#prefix + 1)
	end

	return nil
end

---@param fargs string[]
---@param valid_args_list string[]
---@return Map<string, string>
local function parse_fargs(fargs, valid_args_list)
	local args_table = {}
	for i, arg in ipairs(fargs) do
		for _, valid_arg in ipairs(valid_args_list) do
			if arg == valid_arg then
				args_table[valid_arg] = true
			else
				local v = arg_eq_parse(arg, valid_arg)
				if v ~= nil then
					args_table[valid_arg] = v
				end
			end
		end
	end

	return args_table
end

local commands = {
	reload = function(opts)
		local args = parse_fargs(opts.fargs, { "show_output" })
		M.uproject_reload(vim.fn.getcwd(), args)
	end,
	open = function(opts)
		local args = parse_fargs(opts.fargs, { "log_cmds", "debug" })
		M.uproject_open(vim.fn.getcwd(), args)
	end,
	play = function(opts)
		local args = parse_fargs(opts.fargs, { "log_cmds", "debug" })
		M.uproject_play(vim.fn.getcwd(), args)
	end,
	build = function(opts)
		local args = parse_fargs(opts.fargs, {
			"wait",
			"ignore_junk",
			"type_pattern",
			"close_output_on_success",
			"open",
			"hide_output",
			"no_ubt_makefiles",
			"skip_rules_compile",
			"skip_pre_build_targets",
			"clean",
		})
		M.uproject_build(vim.fn.getcwd(), args)
	end,
	clean = function(opts)
		local args = parse_fargs(opts.fargs, {
			"type_pattern",
		})
		M.uproject_clean(vim.fn.getcwd(), args)
	end,
	build_plugins = function(opts)
		local args = parse_fargs(opts.fargs, { "wait", "ignore_junk", "type_pattern", "close_output_on_success" })
		M.uproject_build_plugins(vim.fn.getcwd(), args)
	end,
	show_output = function(opts)
		local args = parse_fargs(opts.fargs, {})
		M.show_last_output_buffer()
	end,
}

local function uproject_command(opts)
	local command = commands[opts.fargs[1]]
	if command == nil then
		return
	end

	command(opts)
end

local function select_target(dir, opts, cb)
	opts = vim.tbl_extend('force', { type_pattern = ".*", include_engine_targets = false }, opts)
	local target_info_path = vim.fs.joinpath(dir, "Intermediate", "TargetInfo.json")
	local target_info = vim.fn.json_decode(vim.fn.readfile(target_info_path))

	local targets = vim.tbl_filter(function(target)
		local index = target.Type:find(opts.type_pattern)
		return index ~= nil
	end, target_info.Targets)

	if not opts.include_engine_targets then
		local target_info_dir = vim.fs.dirname(target_info_path)
		targets = vim.tbl_filter(function(target)
			local target_path = target.Path
			if vim.fn.isabsolutepath(target_path) == 0 then
				target_path = vim.fs.normalize(vim.fs.joinpath(target_info_dir, target_path))
			end
			return target_path:sub(1, #dir) == dir
		end, targets)
	end

	if #targets == 0 then
		if opts.type_pattern then
			vim.notify("no uproject targets with type pattern '" .. opts.type_pattern .. "' found in " .. dir,
				vim.log.levels.ERROR)
		else
			vim.notify("no uproject targets found in " .. dir, vim.log.levels.ERROR)
		end
		return
	end

	if #targets == 1 then
		cb(targets[1])
		return
	end

	vim.ui.select(targets, {
		prompt = "Select Uproject Target",
		format_item = function(target)
			return target.Name .. " (" .. target.Type .. ")"
		end
	}, cb)
end

local _last_output_buffer = nil

---@param first_line string|nil
---@return number
local function make_output_buffer(first_line)
	local bufnr = vim.api.nvim_create_buf(false, true)
	if first_line ~= nil then
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, true, { first_line })
	end
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	_last_output_buffer = bufnr
	return bufnr
end

---@param line string
---@return boolean
local function is_error_line(line)
	return false
		or line:find("error", 0, true) ~= nil
		or line:find("Error:", 0, true) ~= nil
		or vim.startswith(line, "Unable to instantiate module")
end

local function is_comment_line(line)
	return false
		or vim.startswith(line, "(")
		or line:find("------", 0, true) ~= nil
		or line:find("^%[uproject%.nvim%] info:") ~= nil
end

local function is_warn_line(line)
	return false
		or line:find("warning", 0, true) ~= nil
		or line:find("Warning:", 0, true) ~= nil
end

---@param bufnr number
---@param lines string[]
local function append_output_buffer(bufnr, lines)
	assert(lines ~= nil)
	assert(#lines > 0)
	local bufwin = vim.api.nvim_call_function("bufwinid", { bufnr })
	local was_at_end = false
	if bufwin ~= nil and bufwin ~= -1 then
		local cursor_line = vim.api.nvim_win_get_cursor(bufwin)[1]
		local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
		was_at_end = cursor_line == buf_line_count
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, -1, -1, true, lines)

	local buf_line_count = vim.api.nvim_buf_line_count(bufnr)

	for i, line in ipairs(lines) do
		local line_no = buf_line_count - i
		local col_start = 0
		local col_end = #line

		if is_error_line(line) then
			vim.api.nvim_buf_add_highlight(bufnr, 0, "ErrorMsg", line_no, col_start, col_end)
		elseif is_comment_line(line) then
			vim.api.nvim_buf_add_highlight(bufnr, 0, "Comment", line_no, col_start, col_end)
		elseif is_warn_line(line) then
			vim.api.nvim_buf_add_highlight(bufnr, 0, "WarningMsg", line_no, col_start, col_end)
		end
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	if bufwin ~= -1 and was_at_end then
		vim.api.nvim_win_set_cursor(bufwin, { buf_line_count, 0 })
	end
end


---@param lines string[]
---@param project_root Path
local function transform_output_lines(lines, project_root)
	---@param line string
	return vim.tbl_map(function(line)
		line = string.gsub(line, project_root:absolute() .. "\\", "")
		line = string.gsub(line, "%((%d+)%)%:", ":%1:")
		return line
	end, lines)
end

--- @class SpawnOutputBufferOptions
--- @field cmd string
--- @field args string[]
--- @field project_root Path
--- @field progress ProgressHandle|nil
--- @field env table<string, any>? environment variables passed to spawned process

--- @param opts SpawnOutputBufferOptions
--- @param cb fun(code: number)|nil
--- @return number bufnr the created buffer number
local function spawn_output_buffer(opts, cb)
	local cmd = opts.cmd
	local args = opts.args
	local project_root = opts.project_root
	local progress = opts.progress

	local output = make_output_buffer(
		vim.fn.shellescape(cmd) .. " " ..
		vim.fn.join(
			vim.tbl_map(function(v) return vim.fn.shellescape(v) end, args),
			" "
		)
	)
	local output_append = vim.schedule_wrap(function(lines)
		if progress then
			for _, line in ipairs(lines) do
				if vim.startswith(line, "[") then
					local prog, total, whole_prog = string.match(line, "%[(%d+)/(%d+)%]")
					if prog and total then
						local prog_num = tonumber(prog)
						local total_num = tonumber(total)

						progress.percentage = (prog_num / total_num) * 100
						progress.message = string.sub(line, (string.find(line, "]", 1, true) or 0) + 1)
					end
				end
			end
		end
		append_output_buffer(output, transform_output_lines(lines, project_root))
	end)

	local stdout = vim.uv.new_pipe()
	local stderr = vim.uv.new_pipe()

	vim.uv.spawn(cmd, {
		stdio = { nil, stdout, stderr },
		args = args,
		env = opts.env,
	}, function(code, _)
		output_append({
			"",
			cmd .. " exited with code " .. code,
		})

		if cb then
			vim.schedule_wrap(cb)(code)
		end
	end)

	vim.uv.read_start(stdout, function(err, data)
		if data ~= nil then
			local lines = vim.split(data, "\r\n", { trimempty = true })
			if #lines > 0 then
				output_append(vim.split(data, "\r\n", { trimempty = true }))
			end
		end
	end)

	vim.uv.read_start(stderr, function(err, data)
		if data ~= nil then
			local lines = vim.split(data, "\r\n", { trimempty = true })
			if #lines > 0 then
				output_append(vim.split(data, "\r\n", { trimempty = true }))
			end
		end
	end)

	return output
end

function M.uproject_path(dir)
	assert(dir ~= nil, "uproject_path first param must be a directory")
	local matcher = function(name) return name:match('%.uproject$') ~= nil end
	local root = vim.fs.root(dir, matcher)
	if not root then
		return nil, nil
	end
	local path = vim.fs.find(matcher, { path = root, type = 'file' })
	if #path == 1 then
		return path[1], root
	end
	return nil, nil
end

--- @class NoEngineAssociation
--- @field kind "none"

--- @class SystemEngineAssociation
--- @field kind "system"
--- @field version string

--- @class LocalEngineAssociation
--- @field kind "local"
--- @field path string

--- @alias EngineAssociation
--- | NoEngineAssociation
--- | SystemEngineAssociation
--- | LocalEngineAssociation

--- @param dir string
--- @return EngineAssociation
function M.uproject_engine_association(dir)
	local p = M.uproject_path(dir)
	if p == nil then
		return { kind = "none" }
	end

	--- TODO: add configurable local engine installs or some more common locations
	local local_engine_dir = vim.fs.joinpath(dir, "..", "InstalledEngine")
	if vim.fn.isdirectory(local_engine_dir) == 1 then
		return {
			kind = "local",
			path = local_engine_dir,
		}
	end

	local info = vim.fn.json_decode(vim.fn.readfile(p))
	return {
		kind = "system",
		version = info["EngineAssociation"]
	}
end

--- @param engine_association EngineAssociation|string
function M.unreal_engine_install_dir(engine_association, cb)
	if engine_association.kind == "none" then
		cb(nil)
		return
	end

	if engine_association.kind == "local" then
		cb(engine_association.path)
		return
	end


	local stdout = vim.uv.new_pipe()
	local stdout_str = ""
	local spawn_opts = {
		stdio = { nil, stdout, nil },
		args = {
			'query',
			'HKLM\\SOFTWARE\\EpicGames\\Unreal Engine\\' .. engine_association.version,
			'/v', 'InstalledDirectory',
		},
	}
	vim.uv.spawn('reg', spawn_opts, function(_, _)
		local lines = vim.split(stdout_str, '\r\n', { trimempty = true })
		if #lines == 0 then
			vim.notify("cannot find unreal " .. engine_association.version .. " install directory", vim.log.levels.ERROR)
			vim.schedule_wrap(cb)(nil)
			return
		end
		local value = vim.split(lines[2], '%s+', { trimempty = true })[3]
		vim.schedule_wrap(cb)(value)
	end)

	vim.uv.read_start(stdout, function(err, data)
		assert(not err, err)

		if data then
			stdout_str = stdout_str .. data
		end
	end)
end

--- @class UprojectOpenOptions
--- @field debug boolean|nil
--- @field log_cmds string|nil
--- @field env table<string, any>|nil environment variables used when spawning

--- @param dir string|nil
--- @param opts UprojectOpenOptions
function M.uproject_open(dir, opts)
	opts = vim.tbl_extend('force', {
		debug = false,
		env = nil,
		log_cmds = nil,
	}, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	dir = vim.fs.dirname(project_path)

	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return
	end

	M.unreal_engine_install_dir(engine_association, function(install_dir)
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local ue = vim.fs.joinpath(
			engine_dir, "Binaries", "Win64", "UnrealEditor.exe")

		local args = {
			project_path:absolute(),
		}

		if opts.log_cmds then
			table.insert(args, "-LogCmds=" .. opts.log_cmds)
		end

		if opts.debug then
			table.insert(args, 1, ue)
			table.insert(args, 1, "launch")
			vim.uv.spawn("dbg", {
				detached = true,
				hide = true,
				args = args,
				env = opts.env,
			}, function(code, _)
			end)
		else
			vim.uv.spawn(ue, {
				detached = true,
				hide = true,
				args = args,
				env = opts.env,
			}, function(code, _)
			end)
		end
	end)
end

function M.uproject_play(dir, opts)
	opts = vim.tbl_extend('force', {}, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	dir = vim.fs.dirname(project_path)

	local project_root = Path:new(vim.fs.dirname(project_path))
	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return
	end

	local args = {
		project_path:absolute(),
		"-Stdout",
		"-FullStdOutLogOutput",
		"-Game",
	}

	if opts.log_cmds then
		table.insert(args, "-LogCmds=" .. opts.log_cmds)
	end

	M.unreal_engine_install_dir(engine_association, function(install_dir)
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local ue = vim.fs.joinpath(
			engine_dir, "Binaries", "Win64", "UnrealEditor-Cmd.exe")
		if opts.debug then
			table.insert(args, 1, ue)
			table.insert(args, 1, "launch")
			local output = spawn_output_buffer({
				cmd = "dbg",
				args = args,
				project_root = project_root,
			})
			vim.api.nvim_win_set_buf(0, output)
		else
			local output = spawn_output_buffer({
				cmd = ue,
				args = args,
				project_root = project_root,
			})
			vim.api.nvim_win_set_buf(0, output)
		end
	end)
end

function M.uproject_plugin_paths(dir, cb)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		cb({})
		return
	end
	dir = vim.fs.dirname(project_path)

	local plugins_dir = vim.fs.joinpath(dir, "Plugins")
	local plugin_dirs = vim.fn.readdir(vim.fs.joinpath(dir, "Plugins"))
	local plugins = {}
	for _, plugin_dir in ipairs(plugin_dirs) do
		local plugin_file = vim.fs.joinpath(plugins_dir, vim.fs.basename(plugin_dir),
			vim.fs.basename(plugin_dir) .. ".uplugin")
		if vim.fn.exists(plugin_file) then
			table.insert(plugins, plugin_file)
		end
	end

	cb(plugins)
end

function M.get_ubt(dir, cb)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		cb(nil)
		return
	end

	dir = vim.fs.dirname(project_path)
	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		cb(nil)
		return
	end

	M.unreal_engine_install_dir(engine_association, function(install_dir)
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local ubt = vim.fs.joinpath(engine_dir, "Binaries", "DotNET", "UnrealBuildTool", "UnrealBuildTool.exe")
		cb(ubt)
	end)
end

--- @class UprojectEngineInfo
--- @field engine_association LocalEngineAssociation|SystemEngineAssociation
--- @field install_dir string
--- @field project_dir string

--- @param dir string
--- @param cb fun(info: UprojectEngineInfo|nil)
function M.get_project_engine_info(dir, cb)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		cb(nil)
		return
	end

	dir = vim.fs.dirname(project_path)
	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		cb(nil)
		return
	end

	M.unreal_engine_install_dir(engine_association, function(install_dir)
		cb({
			engine_association = engine_association,
			install_dir = install_dir,
			project_dir = dir,
		})
	end)
end

local function collect_public_headers(dir)
	local all_headers = {}

	for type, subdir in vim.fs.dir(dir, { depth = nil }) do
		if type == "directory" then
			local public_dir = vim.fs.joinpath(subdir, "Public")
			vim.list_extend(
				all_headers,
				vim.fs.find("*.h", { type = "file", path = public_dir, limit = math.huge })
			)
		end
	end

	return all_headers
end

function M.get_unreal_headers(dir, cb)
	M.get_project_engine_info(dir, function(info)
		if info == nil then
			cb(nil)
			return
		end

		local engine_dir = vim.fs.joinpath(info.install_dir, "Engine")
		local source_dir = vim.fs.joinpath(engine_dir, "Source")

		local all_headers = {}

		vim.list_extend(
			all_headers,
			collect_public_headers(vim.fs.joinpath(source_dir, "Developer"))
		)

		vim.list_extend(
			all_headers,
			collect_public_headers(vim.fs.joinpath(source_dir, "Editor"))
		)

		vim.list_extend(
			all_headers,
			collect_public_headers(vim.fs.joinpath(source_dir, "Runtime"))
		)

		-- TODO: plugins
		local plugins_dir = vim.fs.joinpath(engine_dir, "Plugins")
		cb(all_headers)
	end)
end

function M.get_unreal_modules(dir, cb)
	M.get_ubt(dir, function(ubt)
		local stdio = { nil, vim.uv.new_pipe(), vim.uv.new_pipe() }
		local project_path = Path:new(M.uproject_path(dir))

		vim.uv.spawn(ubt, {
			stdio = stdio,
			args = {
				'-Mode=Query',
				-- '-RulesType=Module',
				'-project=' .. project_path:absolute(),
				'-stdout',
				-- '-game',
				-- '-engine',
				-- '-Target=UnrealEditor Development Win64',
			},
		}, function(code, _)
			vim.notify("end exit code=" .. tostring(code))
		end)

		vim.uv.read_start(stdio[2], function(err, data)
			if data ~= nil then
				vim.schedule(function()
					vim.notify(data)
				end)
			end
		end)

		vim.uv.read_start(stdio[3], function(err, data)
			if data ~= nil then
				vim.schedule(function()
					vim.notify(data)
				end)
			end
		end)
	end)
end

function M.uproject_reload(dir, opts)
	opts = vim.tbl_extend('force', { show_output = false }, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		if opts.show_output then
			vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		end
		return
	end
	dir = vim.fs.dirname(project_path)

	local output = nil

	if opts.show_output then
		output = make_output_buffer()
		vim.api.nvim_win_set_buf(0, output)
	end

	local project_root = Path:new(vim.fs.dirname(project_path))
	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local output_append_immediate = function(lines)
		if output == nil then
			return
		end

		append_output_buffer(
			output,
			transform_output_lines(lines, project_root)
		)
	end

	local output_append = vim.schedule_wrap(function(lines)
		if output == nil then
			return
		end

		append_output_buffer(
			output,
			transform_output_lines(lines, project_root)
		)
	end)


	local engine_association = M.uproject_engine_association(dir)

	if engine_association.kind == "none" then
		output_append({ "[uproject.nvim] error: cannot find ureal engine association in " .. dir })
		return
	end

	if engine_association ~= nil then
		local has_fidget, fidget = pcall(require, 'fidget')
		local fidget_progress = nil

		if has_fidget then
			fidget_progress = fidget.progress.handle.create({
				key = "UProjectReload",
				title = "󰦱 Reload ",
				message = "",
				lsp_client = { name = "uproject.nvim" },
				percentage = 0,
				cancellable = true,
			})
		end

		local function notify_info(msg, immediate)
			if has_fidget then
				---@diagnostic disable-next-line: need-check-nil
				fidget_progress.message = msg
			end

			if immediate then
				output_append_immediate({ "[uproject.nvim] info: " .. msg })
			else
				output_append({ "[uproject.nvim] info: " .. msg })
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

			output_append({ "[uproject.nvim] error: " .. msg })
		end

		M.unreal_engine_install_dir(engine_association, function(install_dir)
			if not install_dir then
				notify_error("Cannot find install directory for Unreal Engine " .. engine_association)
				return
			end
			local engine_dir = vim.fs.joinpath(install_dir, "Engine")
			local ubt = vim.fs.joinpath(engine_dir, "Binaries", "DotNET", "UnrealBuildTool", "UnrealBuildTool.exe")
			local build_bat = vim.fs.joinpath(
				engine_dir, "Build", "BatchFiles", "Build.bat")

			local uat_bat = vim.fs.joinpath(
				engine_dir, "Build", "BatchFiles", "RunUAT.bat")

			local stdio = { nil, nil, nil }

			local steps = {
				function(step_done)
					notify_info("Querying project targets", true)
					vim.uv.spawn(build_bat, {
						stdio = stdio,
						args = {
							"-Mode=QueryTargets",
							"-Project=" .. project_path:absolute(),
						},
					}, step_done)
				end,
				function(step_done)
					notify_info("Generating compile_commands.json", true)
					local args = {
						'-mode=GenerateClangDatabase',
						'-project=' .. project_path:absolute(),
						'-game',
						'-engine',
						'-Target=UnrealEditor Development Win64',
					}
					output_append({ ubt .. " " .. vim.fn.join(args, " ") })
					vim.uv.spawn(ubt, {
						stdio = stdio,
						args = args,
					}, function(code, _)
						if code ~= 0 then
							notify_error("Failed to reload uproject (exit code " .. code .. ")")
						else
							notify_info("Copying compile_commands.json to project root")
							vim.uv.fs_copyfile(
								vim.fs.joinpath(install_dir, 'compile_commands.json'),
								vim.fs.joinpath(tostring(vim.fs.dirname(project_path:absolute())),
									'compile_commands.json'),
								function(err)
									if err then
										notify_error(err)
									else
										if fidget_progress ~= nil then
											fidget_progress:finish()
										end
									end
								end
							)
						end
						step_done()
					end)
				end
			}

			local current_step_index = 1
			local function do_step()
				if opts.show_output then
					stdio[2] = vim.uv.new_pipe()
					stdio[3] = vim.uv.new_pipe()
				end

				steps[current_step_index](vim.schedule_wrap(function()
					if opts.show_output then
						vim.uv.read_start(stdio[2], function(err, data)
							if data ~= nil then
								local lines = vim.split(data, "\r\n", { trimempty = true })
								if #lines > 0 then
									output_append(lines)
								end
							end
						end)

						vim.uv.read_start(stdio[3], function(err, data)
							if data ~= nil then
								local lines = vim.split(data, "\r\n", { trimempty = true })
								if #lines > 0 then
									output_append(lines)
								end
							end
						end)
					end

					current_step_index = current_step_index + 1
					if steps[current_step_index] ~= nil then
						do_step()
					end
				end))
			end

			do_step()
		end)
	end
end

--- @class UprojectBuildOptions
--- @field ignore_junk boolean|nil
--- @field type_pattern string|nil
--- @field close_output_on_success boolean|nil
--- @field wait boolean|nil
--- @field open boolean|nil
--- @field hide_output boolean|nil
--- @field no_ubt_makefiles boolean|nil
--- @field skip_rules_compile boolean|nil
--- @field skip_pre_build_targets boolean|nil
--- @field env table<string, any>|nil environment variables used when spawning UnrealBuildTool

--- @param dir string|nil
--- @param opts UprojectBuildOptions
function M.uproject_build(dir, opts)
	opts = vim.tbl_extend('force', {
		ignore_junk = false,
		type_pattern = nil,
		close_output_on_success = false,
		wait = false,
		open = false,
		hide_output = false,
		no_ubt_makefiles = false,
		skip_rules_compile = false,
		skip_pre_build_targets = false,
		env = nil,
	}, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	dir = vim.fs.dirname(project_path)

	local project_root = Path:new(vim.fs.dirname(project_path))
	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return
	end


	local has_fidget, fidget = pcall(require, 'fidget')
	local fidget_progress = nil

	if has_fidget then
		fidget_progress = fidget.progress.handle.create({
			key = "UProjectBuild",
			title = "󰦱 Build ",
			message = "",
			lsp_client = { name = "uproject.nvim" },
			percentage = 0,
			cancellable = true,
		})
	end

	local function cancel_fidget(reason)
		if has_fidget then
			---@diagnostic disable-next-line: need-check-nil
			fidget_progress.message = reason
			---@diagnostic disable-next-line: need-check-nil
			fidget_progress:cancel()
		end
	end

	M.unreal_engine_install_dir(engine_association, function(install_dir)
		if not install_dir then
			cancel_fidget("cannot find engine install directory")
			return
		end

		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local build_bat = vim.fs.joinpath(
			engine_dir, "Build", "BatchFiles", "Build.bat")

		vim.schedule_wrap(select_target)(dir, { type_pattern = opts.type_pattern }, function(target)
			if target == nil then
				cancel_fidget("no target selected")
				return
			end

			local args = {
				"-Project=" .. project_path:absolute(),
				"-Target=" .. target.Name .. " Win64 Development",
			}

			if opts.wait then
				table.insert(args, "-WaitMutex")
			end

			if opts.ignore_junk then
				table.insert(args, "-IgnoreJunk")
			end

			if opts.no_ubt_makefiles then
				table.insert(args, "-NoUBTMakefiles")
			end

			if opts.skip_rules_compile then
				table.insert(args, "-SkipRulesCompile")
			end

			if opts.skip_pre_build_targets then
				table.insert(args, "-SkipPreBuildTargets")
			end

			local output_bufnr = -1
			local on_spawn_done = function(exit_code)
				if opts.close_output_on_success and exit_code == 0 then
					vim.schedule_wrap(vim.api.nvim_buf_delete)(output_bufnr, { force = true })
				end

				if opts.open and exit_code == 0 then
					M.uproject_open(dir, {})
				end

				if exit_code ~= 0 then
					vim.notify("󰦱 Build failed with exit code " .. tostring(exit_code), vim.log.levels.ERROR)
				end

				if fidget_progress ~= nil then
					if exit_code ~= 0 then
						fidget_progress.percentage = nil
						fidget_progress.message = "build failed with exit code " .. tostring(exit_code)
						fidget_progress:cancel()
					else
						fidget_progress:finish()
					end
				end
			end
			output_bufnr = spawn_output_buffer({
				cmd = build_bat,
				args = args,
				project_root = project_root,
				progress = fidget_progress,
				env = opts.env,
			}, on_spawn_done)
			if not opts.hide_output then
				vim.api.nvim_win_set_buf(0, output_bufnr)
			end
		end)
	end)
end

--- @class UprojectCleanOptions
--- @field type_pattern string|nil
--- @field env table<string, any>|nil environment variables used when spawning UnrealBuildTool

--- @param dir string|nil
--- @param opts UprojectCleanOptions
function M.uproject_clean(dir, opts)
	opts = vim.tbl_extend('force', {
		env = nil,
		type_pattern = nil,
	}, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	dir = vim.fs.dirname(project_path)

	local project_root = Path:new(vim.fs.dirname(project_path))
	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return
	end


	local has_fidget, fidget = pcall(require, 'fidget')
	local fidget_progress = nil

	if has_fidget then
		fidget_progress = fidget.progress.handle.create({
			key = "UProjectBuild",
			title = "󰦱 Build ",
			message = "",
			lsp_client = { name = "uproject.nvim" },
			percentage = 0,
			cancellable = true,
		})
	end

	local function cancel_fidget(reason)
		if has_fidget then
			---@diagnostic disable-next-line: need-check-nil
			fidget_progress.message = reason
			---@diagnostic disable-next-line: need-check-nil
			fidget_progress:cancel()
		end
	end

	M.unreal_engine_install_dir(engine_association, function(install_dir)
		if not install_dir then
			cancel_fidget("cannot find engine install directory")
			return
		end

		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local clean_bat = vim.fs.joinpath(
			engine_dir, "Build", "BatchFiles", "Clean.bat")

		vim.schedule_wrap(select_target)(dir, { type_pattern = opts.type_pattern }, function(target)
			if target == nil then
				cancel_fidget("no target selected")
				return
			end

			local args = {
				"-Project=" .. project_path:absolute(),
				"-Target=" .. target.Name .. " Win64 Development",
			}

			local output_bufnr = -1
			local on_spawn_done = function(exit_code)
				if opts.close_output_on_success and exit_code == 0 then
					vim.schedule_wrap(vim.api.nvim_buf_delete)(output_bufnr, { force = true })
				end

				if opts.open and exit_code == 0 then
					M.uproject_open(dir, {})
				end

				if exit_code ~= 0 then
					vim.notify("󰦱 Clean failed with exit code " .. tostring(exit_code), vim.log.levels.ERROR)
				end

				if fidget_progress ~= nil then
					if exit_code ~= 0 then
						fidget_progress.percentage = nil
						fidget_progress.message = "clean failed with exit code " .. tostring(exit_code)
						fidget_progress:cancel()
					else
						fidget_progress:finish()
					end
				end
			end
			output_bufnr = spawn_output_buffer({
				cmd = clean_bat,
				args = args,
				project_root = project_root,
				progress = fidget_progress,
				env = opts.env,
			}, on_spawn_done)
			if not opts.hide_output then
				vim.api.nvim_win_set_buf(0, output_bufnr)
			end
		end)
	end)
end

function M.uproject_build_plugins(dir, opts)
	opts = vim.tbl_extend('force',
		{ ignore_junk = false, type_pattern = nil, close_output_on_success = false, wait = false }, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	dir = vim.fs.dirname(project_path)

	local project_root = Path:new(vim.fs.dirname(project_path))
	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)

	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return
	end
	M.unreal_engine_install_dir(engine_association, function(install_dir)
		if not install_dir then
			return
		end
		local engine_dir = vim.fs.joinpath(install_dir, "Engine")
		local build_bat = vim.fs.joinpath(
			engine_dir, "Build", "BatchFiles", "Build.bat")


		vim.schedule_wrap(select_target)(dir, { type_pattern = opts.type_pattern }, function(target)
			M.uproject_plugin_paths(dir, function(plugins)
				for _, plugin in ipairs(plugins) do
					local plugin_info = vim.fn.json_decode(vim.fn.readfile(plugin))
					local args = {
						"-Project=" .. project_path:absolute(),
						"-Target=" .. target.Name .. " Win64 Development",
					}

					if opts.wait then
						table.insert(args, "-WaitMutex")
					end

					for _, mod in ipairs(plugin_info["Modules"]) do
						table.insert(args, "-Module=" .. mod["Name"])
					end

					local output_bufnr = -1
					local on_spawn_done = function(exit_code)
						if opts.close_output_on_success and exit_code == 0 then
							vim.schedule_wrap(vim.api.nvim_buf_delete)(output_bufnr, { force = true })
						end
					end
					output_bufnr = spawn_output_buffer({
						cmd = build_bat,
						args = args,
						project_root = project_root,
					}, on_spawn_done)
					vim.api.nvim_win_set_buf(0, output_bufnr)
				end
			end)
		end)
	end)
end

function M.show_last_output_buffer()
	if _last_output_buffer and vim.api.nvim_buf_is_valid(_last_output_buffer) then
		vim.api.nvim_win_set_buf(0, _last_output_buffer)
	end
end

function M.setup(opts)
	vim.filetype.add({
		extension = {
			uproject = "json",
			uplugin = "json",
		},
	})

	vim.api.nvim_create_user_command("Uproject", uproject_command, {
		nargs = '+',
		desc = "Build, play or open an Unreal project",
		complete = function()
			return vim.tbl_keys(commands)
		end,
	})
end

return M
