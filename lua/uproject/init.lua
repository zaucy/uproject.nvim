local Path = require("plenary.path")
local util = require("uproject.util")
local async = require("async")
local perforce = require("uproject.perforce")

local spawn_async = async.wrap(3, vim.uv.spawn)
local fs_copyfile_async = async.wrap(3, vim.uv.fs_copyfile)
local ui_select_async = async.wrap(3, vim.ui.select)

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
		return M.uproject_reload(vim.fn.getcwd(), args)
	end,
	open = function(opts)
		local args = parse_fargs(opts.fargs, { "log_cmds", "debug" })
		return M.uproject_open(vim.fn.getcwd(), args)
	end,
	play = function(opts)
		local args = parse_fargs(opts.fargs, { "log_cmds", "debug", "use_last_target" })
		return M.uproject_play(vim.fn.getcwd(), args)
	end,
	build = function(opts)
		local args = parse_fargs(opts.fargs, {
			"wait",
			"ignore_junk",
			"type_pattern",
			"configuration_pattern",
			"close_output_on_success",
			"open",
			"hide_output",
			"no_ubt_makefiles",
			"skip_rules_compile",
			"skip_pre_build_targets",
			"clean",
			"use_last_target",
			"use_precompiled",
			"uba_force_remote",
			"disable_unity",
			"static_analyzer",
			"no_uba",
		})
		return M.uproject_build(vim.fn.getcwd(), args)
	end,
	submit = function(opts)
		local args = parse_fargs(opts.fargs, {})
		return M.uproject_submit(vim.fn.getcwd(), args)
	end,
	clean = function(opts)
		local args = parse_fargs(opts.fargs, {
			"type_pattern",
			"use_last_target",
		})
		return M.uproject_clean(vim.fn.getcwd(), args)
	end,
	build_plugins = function(opts)
		local args = parse_fargs(opts.fargs, { "wait", "ignore_junk", "type_pattern", "close_output_on_success" })
		return M.uproject_build_plugins(vim.fn.getcwd(), args)
	end,
	show_output = function(opts)
		local args = parse_fargs(opts.fargs, {})
		return M.show_last_output_buffer()
	end,
	unlock_build_dirs = function(opts)
		return M.uproject_unlock_build_dirs(vim.fn.getcwd())
	end,
}

local function uproject_command(opts)
	local task = async.run(function()
		local command = commands[opts.fargs[1]]
		if command == nil then
			return async.await(vim.schedule)
		end

		return command(opts)
	end)

	task:raise_on_error()
end

--- @param cb fun(platforms: string[])
local function get_available_platforms(cb)
	-- TODO: actually check
	vim.schedule(function()
		cb({ "Win64" })
	end)
end

--- @param target any
--- @param platform string
--- @param cb fun(configurations: string[])
local function get_available_target_configurations(target, platform, cb)
	-- TODO: actually check
	vim.schedule(function()
		if target.Type == "Editor" then
			cb({ "Debug", "Development" })
		else
			cb({ "Debug", "DebugGame", "Development", "Test", "Shipping" })
		end
	end)
end

--- @class uproject.SelectedTarget
--- @field Name string
--- @field Platform string
--- @field Configuration "Debug"|"DebugGame"|"Development"|"Test"|"Shipping"
--- @field Type string

local _last_selected_target = nil
local _last_selected_project_by_directory = {}

--- @param cb fun(target: uproject.SelectedTarget)
local function select_target(dir, opts, cb)
	opts = vim.tbl_extend(
		"force",
		{ type_pattern = ".*", configuration_pattern = ".*", include_engine_targets = false, use_last_target = false },
		opts
	)

	if opts.use_last_target and _last_selected_target then
		local target = vim.deepcopy(_last_selected_target, true)
		vim.schedule(function()
			cb(target)
		end)
		return
	end

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
			vim.notify(
				"no uproject targets with type pattern '" .. opts.type_pattern .. "' found in " .. dir,
				vim.log.levels.ERROR
			)
		else
			vim.notify("no uproject targets found in " .. dir, vim.log.levels.ERROR)
		end
		return
	end

	local select_options = {}
	local finished_callbacks = 0
	local expected_num_callbacks = 0

	local function check_done()
		if finished_callbacks ~= expected_num_callbacks then
			return
		end

		select_options = vim.tbl_filter(function(target)
			local index = target.Configuration:find(opts.configuration_pattern)
			return index ~= nil
		end, select_options)

		if #targets == 0 then
			if opts.configuration_pattern then
				vim.notify(
					"no uproject targets with configuration pattern '"
						.. opts.configuration_pattern
						.. "' found in "
						.. dir,
					vim.log.levels.ERROR
				)
			else
				vim.notify("no uproject targets found in " .. dir, vim.log.levels.ERROR)
			end
			return
		end

		if #select_options == 1 then
			_last_selected_target = select_options[1]
			cb(select_options[1])
			return
		end

		local max_prefix = 0
		for _, target in ipairs(select_options) do
			max_prefix =
				math.max(max_prefix, #string.format("%s %s %s", target.Name, target.Platform, target.Configuration))
		end

		vim.ui.select(select_options, {
			prompt = "Select Uproject Target",
			format_item = function(target)
				return string.format(
					"%s %s %-" .. max_prefix .. "s Type=%s",
					target.Name,
					target.Platform,
					target.Configuration,
					target.Type
				)
			end,
		}, function(selected)
			_last_selected_target = selected
			cb(selected)
		end)
	end

	expected_num_callbacks = expected_num_callbacks + 1
	get_available_platforms(function(platforms)
		finished_callbacks = finished_callbacks + 1
		for _, platform in ipairs(platforms) do
			for _, target in ipairs(targets) do
				local target_option = vim.deepcopy(target, true)
				target_option.Platform = platform
				expected_num_callbacks = expected_num_callbacks + 1
				get_available_target_configurations(target, platform, function(configurations)
					finished_callbacks = finished_callbacks + 1
					for _, configuration in ipairs(configurations) do
						local target_option_with_config = vim.deepcopy(target_option, true)
						target_option_with_config.Configuration = configuration
						table.insert(select_options, target_option_with_config)
					end

					check_done()
				end)
			end
		end

		check_done()
	end)
end

local select_target_async = async.wrap(3, select_target)

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
	return false or line:find("warning", 0, true) ~= nil or line:find("Warning:", 0, true) ~= nil
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

	local output = make_output_buffer(vim.fn.shellescape(cmd) .. " " .. vim.fn.join(
		vim.tbl_map(function(v)
			return vim.fn.shellescape(v)
		end, args),
		" "
	))
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

--- @async
function M.uproject_path(dir)
	assert(dir ~= nil, "uproject_path first param must be a directory")
	local matcher = function(name)
		return name:match("%.uproject$") ~= nil
	end
	local root = vim.fs.root(dir, matcher)
	if root then
		local path = vim.fs.find(matcher, { path = root, type = "file" })
		if #path == 1 then
			return path[1], root
		end
	end

	local default_uprojectdirs_path = vim.fs.joinpath(dir, "Default.uprojectdirs")
	if vim.fn.filereadable(default_uprojectdirs_path) == 0 then
		return nil, nil
	end
	local project_dir_paths = vim.fn.readfile(default_uprojectdirs_path)
	local project_paths = {}

	for _, search_path in ipairs(project_dir_paths) do
		search_path = vim.trim(search_path)
		if not vim.startswith(search_path, ";") then
			search_path = vim.fs.joinpath(vim.fs.dirname(default_uprojectdirs_path), search_path)
			local project_roots = vim.fs.dir(search_path, {})

			for project_root in project_roots do
				project_root = vim.fs.joinpath(search_path, project_root)
				local project_file = vim.fs.joinpath(project_root, vim.fs.basename(project_root) .. ".uproject")
				if vim.fn.filereadable(project_file) == 1 then
					table.insert(project_paths, vim.fs.relpath(dir, vim.fs.normalize(project_file)))
				end
			end
		end
	end

	if #project_paths == 0 then
		return nil, nil
	end

	if #project_paths == 1 then
		return project_paths[1], vim.fs.dirname(project_paths[1])
	end

	local selected_project = ui_select_async(project_paths, {
		prompt = "Select project",
	})

	return selected_project, vim.fs.dirname(selected_project)
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
	local p, root = M.uproject_path(dir)
	if p == nil then
		return { kind = "none" }
	end

	local info = vim.fn.json_decode(vim.fn.readfile(p))

	local local_engine_dir = vim.fs.joinpath(root, info["EngineAssociation"])
	if vim.fn.isdirectory(local_engine_dir) == 1 then
		return {
			kind = "local",
			path = local_engine_dir,
		}
	end

	return {
		kind = "system",
		version = info["EngineAssociation"],
	}
end

--- @async
--- @param engine_association EngineAssociation|string
function M.unreal_engine_install_dir(engine_association)
	async.await(vim.schedule)

	if engine_association.kind == "none" then
		return nil
	end

	if engine_association.kind == "local" then
		return engine_association.path
	end

	local stdout = vim.uv.new_pipe()
	local stdout_str = ""
	local spawn_opts = {
		stdio = { nil, stdout, nil },
		args = {
			"query",
			"HKLM\\SOFTWARE\\EpicGames\\Unreal Engine\\" .. engine_association.version,
			"/v",
			"InstalledDirectory",
		},
	}

	---@diagnostic disable-next-line: param-type-mismatch
	vim.uv.read_start(stdout, function(err, data)
		assert(not err, err)

		if data then
			stdout_str = stdout_str .. data
		end
	end)

	spawn_async("reg", spawn_opts)
	async.await(vim.schedule)

	local lines = vim.split(stdout_str, "\r\n", { trimempty = true })
	if #lines == 0 then
		vim.notify("cannot find unreal " .. engine_association.version .. " install directory", vim.log.levels.ERROR)
		return nil
	end
	local value = vim.split(lines[2], "%s+", { trimempty = true })[3]
	return value
end

--- @class UprojectOpenOptions
--- @field debug boolean|nil
--- @field log_cmds string|nil
--- @field env table<string, any>|nil environment variables used when spawning

--- @async
--- @param dir string|nil
--- @param opts UprojectOpenOptions
function M.uproject_open(dir, opts)
	opts = vim.tbl_extend("force", {
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

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if install_dir == nil then
		return
	end

	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local ue = vim.fs.joinpath(engine_dir, "Binaries", "Win64", "UnrealEditor.exe")

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
		}, function(code, _) end)
	else
		local project_root = Path:new(dir)
		local output = spawn_output_buffer({
			cmd = ue,
			args = args,
			project_root = project_root,
		})
		vim.api.nvim_win_set_buf(0, output)
		-- vim.uv.spawn(ue, {
		-- 	detached = true,
		-- 	hide = true,
		-- 	args = args,
		-- 	env = opts.env,
		-- }, function(code, _) end)
	end
end

---Convert a .umap file path to Unreal's /Game/ style path
---@param filepath string Full path or relative path to a .umap
---@return string|nil asset_path The converted Unreal asset path, or nil if not a .umap
local function umap_to_game_path(filepath)
	if not filepath:match("%.umap$") then
		return nil
	end

	-- Normalize slashes
	local path = filepath:gsub("\\", "/")

	-- Strip up to and including "Content/"
	path = path:gsub(".*Content/", "/Game/")

	-- Remove the .umap extension
	path = path:gsub("%.umap$", "")

	return path
end

--- @async
function M.uproject_play(dir, opts)
	async.await(vim.schedule)

	opts = vim.tbl_extend("force", {}, opts)

	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	dir = vim.fs.dirname(project_path)

	local project_root = Path:new(vim.fs.dirname(project_path))
	---@diagnostic disable-next-line: redefined-local
	local project_path = Path:new(project_path)
	local content_dir = vim.fs.joinpath(project_root.filename, "Content")

	local umap_files = vim.fs.find(function(name, path)
		return vim.endswith(name, ".umap")
	end, { type = "file", path = content_dir, limit = math.huge })
	table.insert(umap_files, 1, "")

	local umap_file, umap_file_index = ui_select_async(umap_files, {
		prompt = "umap (optional)",
		format_item = function(file)
			if file == "" then
				return "(startup map)"
			end

			return umap_to_game_path(file) or "(invalid path)"
		end,
	})

	async.await(vim.schedule)

	if umap_file_index == nil then
		return
	end

	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return
	end

	local args = {
		project_path:absolute(),
	}

	if umap_file_index ~= nil then
		table.insert(args, umap_file)
	end

	table.insert(args, "-Stdout")
	table.insert(args, "-FullStdOutLogOutput")
	table.insert(args, "-Game")

	if opts.log_cmds then
		table.insert(args, "-LogCmds=" .. opts.log_cmds)
	end

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if install_dir == nil then
		return
	end

	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local ue = vim.fs.joinpath(engine_dir, "Binaries", "Win64", "UnrealEditor-Cmd.exe")
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
		local plugin_file =
			vim.fs.joinpath(plugins_dir, vim.fs.basename(plugin_dir), vim.fs.basename(plugin_dir) .. ".uplugin")
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

--- @async
--- @param dir string
--- @return UprojectEngineInfo|nil
function M.get_project_engine_info(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		return nil
	end

	dir = vim.fs.dirname(project_path)
	local engine_association = M.uproject_engine_association(dir)
	if engine_association.kind == "none" then
		return nil
	end

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		return nil
	end

	return {
		engine_association = engine_association,
		install_dir = install_dir,
		project_dir = dir,
	}
end

local function collect_public_headers(dir)
	local all_headers = {}

	for type, subdir in vim.fs.dir(dir, { depth = nil }) do
		if type == "directory" then
			local public_dir = vim.fs.joinpath(subdir, "Public")
			vim.list_extend(all_headers, vim.fs.find("*.h", { type = "file", path = public_dir, limit = math.huge }))
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

		vim.list_extend(all_headers, collect_public_headers(vim.fs.joinpath(source_dir, "Developer")))

		vim.list_extend(all_headers, collect_public_headers(vim.fs.joinpath(source_dir, "Editor")))

		vim.list_extend(all_headers, collect_public_headers(vim.fs.joinpath(source_dir, "Runtime")))

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
				"-Mode=Query",
				-- '-RulesType=Module',
				"-project=" .. project_path:absolute(),
				"-stdout",
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

--- @async
function M.uproject_reload(dir, opts)
	opts = vim.tbl_extend("force", { show_output = false }, opts)
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

		append_output_buffer(output, transform_output_lines(lines, project_root))
	end

	local output_append = vim.schedule_wrap(function(lines)
		if output == nil then
			return
		end

		append_output_buffer(output, transform_output_lines(lines, project_root))
	end)

	local engine_association = M.uproject_engine_association(dir)

	if engine_association.kind == "none" or engine_association == nil then
		output_append({ "[uproject.nvim] error: cannot find ureal engine association in " .. dir })
		return
	end

	local has_fidget, fidget = pcall(require, "fidget")
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

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		notify_error("Cannot find install directory for Unreal Engine " .. engine_association)
		return
	end
	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local ubt = vim.fs.joinpath(engine_dir, "Binaries", "DotNET", "UnrealBuildTool", "UnrealBuildTool.exe")
	local build_bat = vim.fs.joinpath(engine_dir, "Build", "BatchFiles", "Build.bat")

	local stdio = { nil, nil, nil }

	async.await(vim.schedule)
	notify_info("Querying project targets", true)
	spawn_async(build_bat, {
		stdio = stdio,
		args = {
			"-Mode=QueryTargets",
			"-Project=" .. project_path:absolute(),
		},
	})

	async.await(vim.schedule)
	notify_info("Generating compile_commands.json", true)

	local ubt_args = {
		"-mode=GenerateClangDatabase",
		"-project=" .. project_path:absolute(),
		"-game",
		"-engine",
		"-Target=UnrealEditor Development Win64",
	}

	output_append({ ubt .. " " .. vim.fn.join(ubt_args, " ") })

	local ubt_exit_code = spawn_async(ubt, {
		stdio = stdio,
		args = ubt_args,
	})

	if ubt_exit_code ~= 0 then
		notify_error("Failed to reload uproject (exit code " .. ubt_exit_code .. ")")
	else
		notify_info("Copying compile_commands.json to project root")
		local err = fs_copyfile_async(
			vim.fs.joinpath(install_dir, "compile_commands.json"),
			vim.fs.joinpath(tostring(vim.fs.dirname(project_path:absolute())), "compile_commands.json")
		)
		if err then
			notify_error(err)
		else
			if fidget_progress ~= nil then
				fidget_progress:finish()
			end
		end
	end

	async.await(vim.schedule)
end

local function any_project_binary_is_ro(project_dir)
	local project_binaries_dir = vim.fs.joinpath(project_dir, "Binaries")
	local function scan_dir(d)
		local fs = vim.uv.fs_scandir(d)
		if not fs then
			return nil
		end
		while true do
			local name, t = vim.uv.fs_scandir_next(fs)
			if not name then
				break
			end
			local full_path = d .. "/" .. name
			if t == "file" then
				if not vim.uv.fs_access(full_path, "W") then
					return true
				end
			elseif t == "directory" then
				local result = scan_dir(full_path)
				if result then
					return result
				end
			end
		end
		return false
	end
	return scan_dir(project_binaries_dir)
end

--- @class UprojectBuildOptions
--- @field ignore_junk boolean|nil
--- @field type_pattern string|nil
--- @field configuration_pattern string|nil
--- @field close_output_on_success boolean|nil
--- @field wait boolean|nil
--- @field open boolean|nil
--- @field hide_output boolean|nil
--- @field no_ubt_makefiles boolean|nil
--- @field skip_rules_compile boolean|nil
--- @field skip_pre_build_targets boolean|nil
--- @field use_last_target boolean|nil
--- @field unlock "never"|"always"|"auto"|nil|boolean
--- @field env table<string, any>|nil environment variables used when spawning UnrealBuildTool

--- @async
--- @param dir string|nil
--- @param opts UprojectBuildOptions
function M.uproject_build(dir, opts)
	async.await(vim.schedule)
	opts = vim.tbl_extend("force", {
		ignore_junk = false,
		type_pattern = nil,
		configuration_pattern = nil,
		close_output_on_success = false,
		wait = false,
		open = false,
		play = false,
		hide_output = false,
		no_ubt_makefiles = false,
		skip_rules_compile = false,
		skip_pre_build_targets = false,
		env = nil,
		use_last_target = false,
		use_precompiled = false,
		uba_force_remote = false,
		disable_unity = false,
		static_analyzer = "",
		no_uba = false,
		unlock = "never",
	}, opts)

	assert(
		type(opts.unlock) == "boolean" or opts.unlock == "never" or opts.unlock == "auto" or opts.unlock == "always",
		string.format("unexpected unlock value: %s", vim.inspect(opts.unlock))
	)

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

	local has_fidget, fidget = pcall(require, "fidget")
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

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		cancel_fidget("cannot find engine install directory")
		return
	end

	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local build_bat = vim.fs.joinpath(engine_dir, "Build", "BatchFiles", "Build.bat")

	local select_target_options = {
		type_pattern = opts.type_pattern,
		configuration_pattern = opts.configuration_pattern,
		use_last_target = opts.use_last_target,
	}

	async.await(vim.schedule)
	local target = select_target_async(dir, select_target_options)
	if target == nil then
		cancel_fidget("no target selected")
		return
	end

	if opts.unlock == "always" then
		M.uproject_unlock_build_dirs(dir)
	elseif opts.unlock == "auto" or opts.unlock == true then
		if any_project_binary_is_ro(dir) then
			M.uproject_unlock_build_dirs(dir)
		end
	end

	async.await(vim.schedule)

	if fidget_progress then
		fidget_progress.title = string.format("󰦱 %s %s %s ", target.Name, target.Platform, target.Configuration)
	end

	local args = {
		"-Project=" .. project_path:absolute(),
		string.format("-Target=%s %s %s", target.Name, target.Platform, target.Configuration),
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

	if opts.use_precompiled then
		table.insert(args, "-UsePrecompiled")
	end

	if opts.uba_force_remote then
		table.insert(args, "-UBAForceRemote")
	end

	if opts.disable_unity then
		table.insert(args, "-DisableUnity")
		table.insert(args, '-UBTArgs="-DisableUnity"')
	end

	if opts.static_analyzer and opts.static_analyzer ~= "" then
		table.insert(args, "-StaticAnalyzer=" .. opts.static_analyzer)
	end

	if opts.no_uba then
		table.insert(args, "-NoUba")
	end

	local output_bufnr = -1
	local on_spawn_done = function(exit_code)
		if opts.close_output_on_success and exit_code == 0 then
			vim.schedule_wrap(vim.api.nvim_buf_delete)(output_bufnr, { force = true })
		end

		if opts.open and exit_code == 0 then
			M.uproject_open(dir, {})
		elseif opts.play and exit_code == 0 then
			M.uproject_play(dir, {})
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
	-- async.await(vim.schedule)
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

	async.await(vim.schedule)
	async.await(vim.schedule)
end

function M.uproject_submit(dir, opts)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	local project_dir = vim.fs.dirname(project_path)

	local engine_association = M.uproject_engine_association(project_dir)
	if engine_association.kind == "none" then
		return
	end

	local has_fidget, fidget = pcall(require, "fidget")
	local fidget_progress = nil

	if has_fidget then
		fidget_progress = fidget.progress.handle.create({
			key = "UProjectSubmit",
			title = "󰦱 Running Submit Tool ",
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

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		cancel_fidget("cannot find engine install directory")
		return
	end

	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local submit_tool_executable = vim.fs.joinpath(engine_dir, "Binaries", "Win64", "SubmitTool.exe")

	if vim.fn.filereadable(submit_tool_executable) == 0 then
		cancel_fidget("cannot find submit tool")
		return
	end

	local project_dir = vim.fs.dirname(project_path)
	local project_root = Path:new(project_dir)

	local changes = perforce.get_submit_changelists()
	local cl = ui_select_async(changes, {
		prompt = "changelist",
		format_item = function(item)
			return string.format("%s: %s", item.cl, item.desc)
		end,
	})

	if not cl then
		cancel_fidget("no changelist selected")
		return
	end

	local submit_tool_output_buf = spawn_output_buffer({
		cmd = submit_tool_executable,
		args = {
			"-server",
			vim.env["P4PORT"],
			"-client",
			vim.env["P4CLIENT"],
			"-user",
			vim.env["P4USER"],
			"-cl",
			cl.cl,
			"-root-dir",
			project_dir,
		},
		project_root = project_root,
	})
	vim.api.nvim_win_set_buf(0, submit_tool_output_buf)

	async.await(vim.schedule)
	async.await(vim.schedule)
end

--- @class UprojectCleanOptions
--- @field type_pattern string|nil
--- @field env table<string, any>|nil environment variables used when spawning UnrealBuildTool

--- @param dir string|nil
--- @param opts UprojectCleanOptions
function M.uproject_clean(dir, opts)
	opts = vim.tbl_extend("force", {
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

	local has_fidget, fidget = pcall(require, "fidget")
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

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		cancel_fidget("cannot find engine install directory")
		return
	end

	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local clean_bat = vim.fs.joinpath(engine_dir, "Build", "BatchFiles", "Clean.bat")

	local select_target_options = {
		type_pattern = opts.type_pattern,
		configuration_pattern = opts.configuration_pattern,
		use_last_target = opts.use_last_target,
	}
	local target = select_target_async(dir, select_target_options)
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
end

function M.uproject_build_plugins(dir, opts)
	opts = vim.tbl_extend(
		"force",
		{ ignore_junk = false, type_pattern = nil, close_output_on_success = false, wait = false },
		opts
	)
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
	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		return
	end
	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local build_bat = vim.fs.joinpath(engine_dir, "Build", "BatchFiles", "Build.bat")

	local select_target_options = {
		type_pattern = opts.type_pattern,
		configuration_pattern = opts.configuration_pattern,
		use_last_target = opts.use_last_target,
	}
	local target = select_target_async(dir, select_target_options)
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
end

local function walk_build_dirs(dir, cb)
	vim.uv.fs_scandir(dir, function(err, handle)
		while true do
			local name, type = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end

			local full_path = dir .. "/" .. name
			if type == "directory" then
				if name == "Intermediate" or name == "Binaries" then
					cb(full_path)
				else
					walk_build_dirs(full_path, cb)
				end
			end
		end
	end)
end

local function unlock_dir(build_dir, opts, cb)
	local function update_with_prefix(prefix)
		vim.api.nvim_set_option_value("modifiable", true, { buf = opts.output })
		vim.api.nvim_buf_set_lines(opts.output, opts.index, opts.index + 1, true, {
			string.format("%s %s", prefix, build_dir),
		})
		vim.api.nvim_set_option_value("modifiable", false, { buf = opts.output })
		vim.cmd.redraw()
	end

	local has_fidget, fidget = pcall(require, "fidget")
	local timer = vim.uv.new_timer()

	if timer and has_fidget and fidget then
		local anim = fidget.spinner.animate("dots", 1)
		local time = 1
		local update_anim = vim.schedule_wrap(function()
			time = time + 1
			update_with_prefix(anim(time) .. " ")
		end)
		timer:start(0, 100, update_anim)
	else
		update_with_prefix(" ")
	end

	local callbacks_done = 0
	local expected_callbacks_done = 2

	local function check_done(code)
		callbacks_done = callbacks_done + 1

		if callbacks_done ~= expected_callbacks_done then
			return
		end

		if timer then
			vim.uv.timer_stop(timer)
		end

		if code == 0 then
			vim.schedule(function()
				update_with_prefix("✔ ")
				cb()
			end)
		else
			vim.schedule(function()
				update_with_prefix(" ")
				cb()
			end)
		end
	end

	vim.uv.spawn("icacls", {
		args = {
			vim.fs.abspath(build_dir) .. "\\*",
			"/grant",
			"Everyone:F",
			"/T",
			"/C",
		},
	}, check_done)

	vim.uv.spawn("attrib", {
		args = {
			"-R",
			vim.fs.abspath(build_dir) .. "\\*",
			"/S",
		},
	}, check_done)
end

local function get_all_build_dirs(dir, cb)
	local build_dirs = {}
	local finished_unlocks = 0
	local wanted_unlocked = 0

	local do_unlocks = async.wrap(1, function(cb)
		local function add_build_dir(build_dir)
			build_dir = vim.fs.normalize(vim.fn.fnamemodify(build_dir, ":."))
			table.insert(build_dirs, build_dir)
		end

		add_build_dir(vim.fs.joinpath(project_dir, "Binaries"))
		add_build_dir(vim.fs.joinpath(project_dir, "Intermediate"))
		add_build_dir(vim.fs.joinpath(engine_dir, "Intermediate"))

		walk_build_dirs(project_plugins_dir, add_build_dir)
		walk_build_dirs(engine_plugins_dir, add_build_dir)
	end)
end

--- possibly not useful for most people, but when using perforce and submitted
--- intermediate/binaries this can be useful for unlocking files needed to
--- build that you don't intend to submit.
--- @async
function M.uproject_unlock_build_dirs(dir)
	local project_path = M.uproject_path(dir)
	if project_path == nil then
		vim.notify("cannot find uproject in " .. dir, vim.log.levels.ERROR)
		return
	end
	local project_dir = vim.fs.dirname(project_path)

	local engine_association = M.uproject_engine_association(project_dir)
	if engine_association.kind == "none" then
		return
	end

	local output = make_output_buffer("unlocking project and engine build directories...")
	vim.api.nvim_win_set_buf(0, output)

	local has_fidget, fidget = pcall(require, "fidget")
	local fidget_progress = nil

	if has_fidget then
		fidget_progress = fidget.progress.handle.create({
			key = "UProjectUnlockBuildDirs",
			title = "󰦱 Unlocking Build Directories ",
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

	local install_dir = M.unreal_engine_install_dir(engine_association)
	if not install_dir then
		cancel_fidget("cannot find engine install directory")
		return
	end

	local engine_dir = vim.fs.joinpath(install_dir, "Engine")
	local engine_plugins_dir = vim.fs.joinpath(engine_dir, "Plugins")
	local project_plugins_dir = vim.fs.joinpath(project_dir, "Plugins")

	local build_dirs = {}
	local finished_unlocks = 0
	local wanted_unlocked = 0
	local active_unlocks = 0
	local pending_unlock_dir_indices = {}
	local MAX_ACTIVE_UNLOCKS = 4

	local do_unlocks = async.wrap(1, function(cb)
		--- @type fun(build_dir: string, index: number)
		local start_unlock = nil

		local function check_done()
			if fidget_progress then
				fidget_progress.percentage = (finished_unlocks / #build_dirs) * 100
			end

			if finished_unlocks ~= wanted_unlocked then
				if active_unlocks < MAX_ACTIVE_UNLOCKS and #pending_unlock_dir_indices > 0 then
					local index = table.remove(pending_unlock_dir_indices, 1)
					local build_dir = build_dirs[index]
					start_unlock(build_dir, index)
				end
				return
			end

			if fidget_progress then
				fidget_progress:finish()
			end

			cb()
		end

		start_unlock = function(build_dir, index)
			active_unlocks = active_unlocks + 1
			vim.schedule(function()
				append_output_buffer(output, { "  " .. build_dir })
				vim.schedule(function()
					unlock_dir(build_dir, { output = output, index = index }, function()
						finished_unlocks = finished_unlocks + 1
						fidget_progress.message = build_dir

						active_unlocks = active_unlocks - 1
						check_done()
					end)
				end)
				vim.cmd.redraw()
			end)
		end

		local function add_build_dir(build_dir)
			build_dir = vim.fs.normalize(vim.fn.fnamemodify(build_dir, ":."))
			table.insert(build_dirs, build_dir)
			local index = #build_dirs
			wanted_unlocked = wanted_unlocked + 1

			table.insert(pending_unlock_dir_indices, index)
			check_done()
		end

		add_build_dir(vim.fs.joinpath(project_dir, "Binaries"))
		add_build_dir(vim.fs.joinpath(project_dir, "Intermediate"))
		add_build_dir(vim.fs.joinpath(engine_dir, "Intermediate"))

		walk_build_dirs(project_plugins_dir, add_build_dir)
		walk_build_dirs(engine_plugins_dir, add_build_dir)
	end)

	local unlock_start = vim.loop.hrtime()
	do_unlocks()
	local unlock_stop = vim.loop.hrtime()
	local unlock_duration = (unlock_stop - unlock_start) / 1e6

	append_output_buffer(output, { "", ("Done in %.2fms"):format(unlock_duration) })
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
		nargs = "+",
		desc = "Build, play or open an Unreal project",
		complete = function()
			return vim.tbl_keys(commands)
		end,
	})
end

return M
