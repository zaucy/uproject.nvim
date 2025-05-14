local M = {}

local function file_exists(path)
	local stat = vim.loop.fs_stat(path)
	return stat and stat.type == "file"
end

local function normalize_slash(path)
	return string.gsub(path, "\\", "/")
end

--- @param filepath string
--- @param prefixes string[]
--- @return string
local function get_module_name_from_filepath(filepath, prefixes)
	for _, prefix in ipairs(prefixes) do
		local idx = string.find(filepath, prefix, 0, true)
		if idx ~= nil then
			local dir = string.sub(filepath, 0, idx - 1)
			local dir_segments = vim.split(dir, "/", { plain = true })
			local module_name = dir_segments[#dir_segments]
			if module_name == "Source" then
				module_name = dir_segments[#dir_segments - 1]
			end
			return module_name
		end
	end

	local filepath_segments = vim.split(filepath, "/", { plain = true })
	return filepath_segments[#filepath_segments - 1]
end


local function get_module_root_from_filepath(filepath, prefixes)
	for _, prefix in ipairs(prefixes) do
		local idx = string.find(filepath, prefix, 0, true)
		if idx ~= nil then
			local dir = string.sub(filepath, 0, idx - 1)
			local dir_segments = vim.split(dir, "/", { plain = true })
			local module_name = dir_segments[#dir_segments]
			if module_name == "Source" then
				module_name = dir_segments[#dir_segments - 1]
			end
			return dir, string.sub(filepath, idx + #prefix)
		end
	end

	local filepath_segments = vim.split(filepath, "/", { plain = true })
	local filename = filepath_segments[#filepath_segments]
	return string.sub(filepath, 1, #filepath - #filename - 1), filename
end

---@param path string
---@return boolean, string?
function M.is_source_path(path)
	if type(path) ~= "string" then
		return false, "expected string"
	end

	if not vim.endswith(path, ".cpp") then
		return false, "must end with .cpp"
	end

	if not file_exists(path) then
		return false, "path doesn't exist"
	end

	return true
end

---@param path string
---@return boolean, string?
function M.is_header_path(path)
	if type(path) ~= "string" then
		return false, "expected string"
	end

	if not vim.endswith(path, ".h") then
		return false, "must end with .h"
	end

	if not file_exists(path) then
		return false, "path doesn't exist"
	end

	return true
end

---@param source_path string
---@return string|nil
function M.get_header_from_source(source_path)
	vim.validate('source_path', source_path, M.is_source_path, "unreal source file path")
	source_path = normalize_slash(source_path)
	local root, extra = get_module_root_from_filepath(source_path, { "/Private/", "/Internal/" })
	local rel_header = string.sub(extra, 1, #extra - 4) .. ".h"
	local header = vim.fs.joinpath(root, rel_header)
	local public_header = vim.fs.joinpath(root, "Public", rel_header)
	local classes_header = vim.fs.joinpath(root, "Classes", rel_header)

	if file_exists(header) then return header end
	if file_exists(public_header) then return public_header end
	if file_exists(classes_header) then return classes_header end
	return nil
end

---@param header_path string
---@return string|nil
function M.get_source_from_header(header_path)
	vim.validate('header_path', header_path, M.is_header_path, "unreal header file path")
	header_path = normalize_slash(header_path)
	local root, extra = get_module_root_from_filepath(header_path, { "/Public/", "/Classes/" })
	local rel_source = string.sub(extra, 1, #extra - 2) .. ".cpp"
	local source = vim.fs.joinpath(root, rel_source)
	local private_source = vim.fs.joinpath(root, "Private", rel_source)
	local internal_source = vim.fs.joinpath(root, "Internal", rel_source)

	if file_exists(source) then return source end
	if file_exists(private_source) then return private_source end
	if file_exists(internal_source) then return internal_source end
	return nil
end

---@param header_path string
---@return string|nil
function M.get_module_name_from_header(header_path)
	vim.validate('header_path', header_path, M.is_header_path, "unreal header file path")
	header_path = normalize_slash(header_path)
	return get_module_name_from_filepath(header_path, { "/Public/", "/Classes/" }) or nil
end

---@param source_path string
---@return string|nil
function M.get_module_name_from_source(source_path)
	vim.validate('source_path', source_path, M.is_header_path, "unreal source file path")
	source_path = normalize_slash(source_path)
	return get_module_name_from_filepath(source_path, { "/Private/", "/Internal/" }) or nil
end

return M
