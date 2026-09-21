local Path = require("plenary.path")

local M = {}

local PROTOCOL_VERSION = 1
local PROTOCOL_MAGIC = "ue_py"
local DEFAULT_MULTICAST_GROUP = "239.0.0.1"
local DEFAULT_MULTICAST_PORT = 6766
local DEFAULT_BIND_ADDRESS = "127.0.0.1"
local DEFAULT_TIMEOUT_MS = 3000

--- Generates a unique node ID (UUID-like hex string)
--- @return string
local function generate_uuid()
	local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
	local time_seed = tostring(vim.uv.hrtime())
	local random_seed = tostring(math.random(100000, 999999))
	local hash = vim.fn.sha256(time_seed .. random_seed)
	local idx = 1
	return string.gsub(template, "[xy]", function(c)
		local byte_val = tonumber(hash:sub(idx, idx), 16) or math.random(0, 15)
		idx = idx + 1
		local v = (c == "x") and byte_val or ((byte_val % 4) + 8)
		return string.format("%x", v)
	end)
end

--- Serializes a message object to a UTF-8 JSON string
--- @param msg_type string
--- @param source_id string
--- @param dest_id string|nil
--- @param data table|nil
--- @return string
local function serialize_message(msg_type, source_id, dest_id, data)
	local payload = {
		version = PROTOCOL_VERSION,
		magic = PROTOCOL_MAGIC,
		type = msg_type,
		source = source_id,
	}
	if dest_id then
		payload.dest = dest_id
	end
	if data then
		payload.data = data
	end
	return vim.fn.json_encode(payload)
end

--- @class uproject.RemoteNode
--- @field node_id string
--- @field engine_version string?
--- @field project_name string?
--- @field project_root string?
--- @field instance_id string?
--- @field raw table

--- Discovers running Unreal Editor nodes via UDP multicast
--- @param opts? { timeout_ms?: number, multicast_group?: string, multicast_port?: number, bind_address?: string }
--- @param cb fun(err: string|nil, nodes: uproject.RemoteNode[])
function M.discover(opts, cb)
	opts = opts or {}
	local timeout_ms = opts.timeout_ms or DEFAULT_TIMEOUT_MS
	local mcast_group = opts.multicast_group or DEFAULT_MULTICAST_GROUP
	local mcast_port = opts.multicast_port or DEFAULT_MULTICAST_PORT
	local bind_addr = opts.bind_address or DEFAULT_BIND_ADDRESS

	local client_id = generate_uuid()
	local discovered_nodes = {}
	local seen_ids = {}

	local udp = vim.uv.new_udp()
	if not udp then
		cb("Failed to create UDP socket", {})
		return
	end

	local timer = vim.uv.new_timer()
	local closed = false

	local function cleanup()
		if closed then
			return
		end
		closed = true
		if timer then
			timer:stop()
			timer:close()
		end
		if udp then
			udp:recv_stop()
			pcall(function()
				udp:set_membership(mcast_group, bind_addr, "leave")
			end)
			udp:close()
		end
	end

	-- Bind with reuseaddr
	local bind_ok, bind_err = pcall(function()
		udp:bind("0.0.0.0", mcast_port, { reuseaddr = true })
		udp:set_multicast_loop(true)
		udp:set_multicast_ttl(0)
		udp:set_membership(mcast_group, bind_addr, "join")
	end)

	if not bind_ok then
		-- Fallback to binding ephemeral port if port 6766 bind failed
		pcall(function()
			udp:close()
			udp = vim.uv.new_udp()
			udp:bind(bind_addr, 0)
			udp:set_multicast_loop(true)
			udp:set_multicast_ttl(0)
		end)
	end

	udp:recv_start(function(err, data, addr, flags)
		if err or not data then
			return
		end
		local decode_ok, msg = pcall(vim.fn.json_decode, data)
		if not decode_ok or type(msg) ~= "table" then
			return
		end

		if msg.magic == PROTOCOL_MAGIC and msg.type == "pong" and msg.source and msg.source ~= client_id then
			if not seen_ids[msg.source] then
				seen_ids[msg.source] = true
				local node_data = msg.data or {}
				table.insert(discovered_nodes, {
					node_id = msg.source,
					engine_version = node_data.engine_version,
					project_name = node_data.project_name,
					project_root = node_data.project_root,
					instance_id = node_data.instance_id,
					raw = node_data,
				})
			end
		end
	end)

	-- Send ping message
	local ping_payload = serialize_message("ping", client_id)
	udp:send(ping_payload, mcast_group, mcast_port, function(send_err)
		if send_err then
			vim.schedule(function()
				cleanup()
				cb("Failed to broadcast UDP ping: " .. tostring(send_err), {})
			end)
			return
		end
	end)

	-- Timeout to collect responses
	timer:start(timeout_ms, 0, function()
		vim.schedule(function()
			cleanup()
			cb(nil, discovered_nodes)
		end)
	end)
end

--- Finds an active Unreal Editor node matching a project directory
--- @param project_dir? string
--- @param cb fun(err: string|nil, node: uproject.RemoteNode|nil)
function M.find_node_for_project(project_dir, cb)
	project_dir = project_dir or vim.fn.getcwd()
	local uproject_init = require("uproject")
	local p_file, p_root = uproject_init.uproject_path(project_dir)

	local expected_project_name = nil
	if p_file then
		expected_project_name = vim.fs.basename(p_file):gsub("%.uproject$", "")
	end

	M.discover({ timeout_ms = 1500 }, function(err, nodes)
		if err then
			cb(err, nil)
			return
		end

		if #nodes == 0 then
			cb("No running Unreal Editor instances found", nil)
			return
		end

		-- Try matching by project name or project root
		if expected_project_name then
			for _, node in ipairs(nodes) do
				if node.project_name and node.project_name:lower() == expected_project_name:lower() then
					cb(nil, node)
					return
				end
			end
		end

		if p_root then
			local norm_p_root = vim.fs.normalize(p_root):lower()
			for _, node in ipairs(nodes) do
				if node.project_root and vim.fs.normalize(node.project_root):lower() == norm_p_root then
					cb(nil, node)
					return
				end
			end
		end

		-- If only one editor is running, use it
		if #nodes == 1 then
			cb(nil, nodes[1])
			return
		end

		-- Multiple nodes found and none strictly matched project
		cb(
			"Multiple Unreal Editor instances found, but none matched project '" .. (expected_project_name or "") .. "'",
			nil
		)
	end)
end

--- Executes Python code in a running Unreal Editor instance
--- @param command string Python statement or script
--- @param opts? { node?: uproject.RemoteNode, project_dir?: string, exec_mode?: "ExecuteStatement"|"ExecuteFile"|"EvaluateStatement", unattended?: boolean, timeout_ms?: number }
--- @param cb fun(err: string|nil, result: table|nil)
function M.run_python(command, opts, cb)
	opts = opts or {}
	local exec_mode = opts.exec_mode or "ExecuteStatement"
	local unattended = opts.unattended ~= false
	local timeout_ms = opts.timeout_ms or 10000

	local function execute_on_node(target_node)
		local client_id = generate_uuid()
		local mcast_group = DEFAULT_MULTICAST_GROUP
		local mcast_port = DEFAULT_MULTICAST_PORT
		local bind_addr = DEFAULT_BIND_ADDRESS

		local tcp_server = vim.uv.new_tcp()
		local udp_socket = vim.uv.new_udp()
		local timer = vim.uv.new_timer()
		local client_channel = nil
		local is_cleaned_up = false
		local incoming_buffer = ""

		local function cleanup()
			if is_cleaned_up then
				return
			end
			is_cleaned_up = true
			if timer then
				timer:stop()
				timer:close()
			end
			if client_channel then
				client_channel:read_stop()
				client_channel:close()
			end
			if tcp_server then
				tcp_server:close()
			end
			if udp_socket then
				pcall(function()
					local close_msg = serialize_message("close_connection", client_id, target_node.node_id)
					udp_socket:send(close_msg, mcast_group, mcast_port, function()
						udp_socket:close()
					end)
				end)
			end
		end

		-- Bind TCP server on ephemeral port (port 0)
		local tcp_ok, tcp_err = pcall(function()
			tcp_server:bind(bind_addr, 0)
		end)

		if not tcp_ok or not tcp_server then
			cleanup()
			cb("Failed to bind TCP command server: " .. tostring(tcp_err), nil)
			return
		end

		local bound_port = tcp_server:getsockname().port

		-- Bind UDP socket
		local udp_ok = pcall(function()
			udp_socket:bind(bind_addr, 0)
			udp_socket:set_multicast_loop(true)
			udp_socket:set_multicast_ttl(0)
		end)

		if not udp_ok then
			cleanup()
			cb("Failed to initialize UDP socket for command session", nil)
			return
		end

		-- Listen for incoming TCP connection from Unreal Editor
		tcp_server:listen(1, function(listen_err)
			if listen_err or is_cleaned_up then
				return
			end

			client_channel = vim.uv.new_tcp()
			tcp_server:accept(client_channel)

			client_channel:read_start(function(read_err, chunk)
				if read_err or not chunk then
					return
				end

				incoming_buffer = incoming_buffer .. chunk

				-- Attempt to parse command result JSON
				local parse_ok, result_msg = pcall(vim.fn.json_decode, incoming_buffer)
				if parse_ok and type(result_msg) == "table" and result_msg.type == "command_result" then
					vim.schedule(function()
						cleanup()
						local data = result_msg.data or {}
						if data.success == false then
							cb(data.result or "Remote Python execution failed", data)
						else
							cb(nil, data)
						end
					end)
				end
			end)

			-- Send command message over TCP
			local cmd_payload = serialize_message("command", client_id, target_node.node_id, {
				command = command,
				unattended = unattended,
				exec_mode = exec_mode,
			})
			client_channel:write(cmd_payload)
		end)

		-- Broadcast open_connection over UDP
		local open_conn_payload = serialize_message("open_connection", client_id, target_node.node_id, {
			command_ip = bind_addr,
			command_port = bound_port,
		})

		udp_socket:send(open_conn_payload, mcast_group, mcast_port, function(send_err)
			if send_err then
				vim.schedule(function()
					cleanup()
					cb("Failed to send open_connection UDP message: " .. tostring(send_err), nil)
				end)
			end
		end)

		-- Timeout safeguard
		timer:start(timeout_ms, 0, function()
			vim.schedule(function()
				cleanup()
				cb("Connection to Unreal Editor timed out (ensure Python Remote Execution is enabled)", nil)
			end)
		end)
	end

	if opts.node then
		execute_on_node(opts.node)
	else
		M.find_node_for_project(opts.project_dir, function(err, node)
			if err or not node then
				cb(err or "No active Unreal Editor found for this project", nil)
				return
			end
			execute_on_node(node)
		end)
	end
end

--- Resolves a filesystem path into an Unreal Game / Package path
--- @param file_path string
--- @param project_dir? string
--- @return string package_path, boolean is_map
function M.resolve_game_path(file_path, project_dir)
	project_dir = project_dir or vim.fn.getcwd()
	local norm_path = vim.fs.normalize(file_path)
	local is_map = vim.endswith(norm_path:lower(), ".umap")

	-- Strip extension
	local without_ext = norm_path:gsub("%.%a+$", "")

	-- Check for Content folder in path
	-- Case 1: .../Content/... -> /Game/...
	-- Case 2: .../Plugins/<PluginName>/Content/... -> /<PluginName>/...
	-- Case 3: .../Engine/Content/... -> /Engine/...
	-- Case 4: .../Engine/Plugins/<PluginName>/Content/... -> /<PluginName>/...

	local plugin_content_match = without_ext:match(".*/[Pp]lugins/([^/]+)/[Cc]ontent/(.+)$")
	if plugin_content_match then
		local plugin_name, sub_path = without_ext:match(".*/[Pp]lugins/([^/]+)/[Cc]ontent/(.+)$")
		return "/" .. plugin_name .. "/" .. sub_path, is_map
	end

	local engine_content_match = without_ext:match(".*/[Ee]ngine/[Cc]ontent/(.+)$")
	if engine_content_match then
		return "/Engine/" .. engine_content_match, is_map
	end

	local game_content_match = without_ext:match(".*/[Cc]ontent/(.+)$")
	if game_content_match then
		return "/Game/" .. game_content_match, is_map
	end

	local basename = vim.fs.basename(without_ext)
	return "/Game/" .. basename, is_map
end

--- Opens an asset or map in the active Unreal Editor instance via Python
--- @param asset_or_file_path string
--- @param opts? { project_dir?: string }
--- @param cb fun(err: string|nil, success: boolean)
function M.open_asset(asset_or_file_path, opts, cb)
	opts = opts or {}
	local game_path, is_map
	if vim.startswith(asset_or_file_path, "/") then
		game_path = asset_or_file_path
		is_map = game_path:lower():find("/maps/") ~= nil
	else
		game_path, is_map = M.resolve_game_path(asset_or_file_path, opts.project_dir)
	end

	local python_script
	if is_map then
		python_script = string.format(
			[[
import unreal
path = "%s"
opened = False
try:
    les = unreal.get_editor_subsystem(unreal.LevelEditorSubsystem)
    if les:
        opened = les.load_level(path)
except Exception:
    pass
if not opened:
    try:
        eas = unreal.get_editor_subsystem(unreal.EditorAssetSubsystem)
        if eas:
            eas.open_editor_for_assets([path])
            opened = True
    except Exception:
        pass
print("OPEN_RESULT:" + str(opened))
]],
			game_path
		)
	else
		python_script = string.format(
			[[
import unreal
path = "%s"
opened = False
try:
    eas = unreal.get_editor_subsystem(unreal.EditorAssetSubsystem)
    if eas:
        eas.open_editor_for_assets([path])
        opened = True
except Exception:
    pass
print("OPEN_RESULT:" + str(opened))
]],
			game_path
		)
	end

	M.run_python(python_script, {
		project_dir = opts.project_dir,
		exec_mode = "ExecuteFile",
		unattended = false,
	}, function(err, res)
		if err then
			cb(err, false)
			return
		end

		cb(nil, true)
	end)
end

return M
