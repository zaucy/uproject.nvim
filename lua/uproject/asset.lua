local remote = require("uproject.remote")

local M = {}

local PACKAGE_FILE_TAG = 0x9E2A83C1
local PACKAGE_FILE_TAG_SWAPPED = 0xC1832A9E
local PACKAGE_FILE_TAG_COOKED = 0xA1A2A3A4

--- Human readable format for byte sizes
--- @param bytes number
--- @return string
local function format_bytes(bytes)
	if bytes < 1024 then
		return string.format("%d B", bytes)
	elseif bytes < 1024 * 1024 then
		return string.format("%.1f KB", bytes / 1024)
	elseif bytes < 1024 * 1024 * 1024 then
		return string.format("%.2f MB", bytes / (1024 * 1024))
	else
		return string.format("%.2f GB", bytes / (1024 * 1024 * 1024))
	end
end

--- Byte reader helpers
local function read_u16(str, off)
	local b1, b2 = string.byte(str, off, off + 1)
	if not b1 or not b2 then
		return 0, off + 2
	end
	return b1 + b2 * 256, off + 2
end

local function read_u32(str, off)
	local b1, b2, b3, b4 = string.byte(str, off, off + 3)
	if not b1 or not b2 or not b3 or not b4 then
		return 0, off + 4
	end
	return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216, off + 4
end

local function read_i32(str, off)
	local val, next_off = read_u32(str, off)
	if val >= 2147483648 then
		val = val - 4294967296
	end
	return val, next_off
end

local function read_u64(str, off)
	local low, next_off = read_u32(str, off)
	local high
	high, next_off = read_u32(str, next_off)
	return low + high * 4294967296, next_off, low, high
end

--- Checks if a package has a PackageTrailer and whether any payloads are virtualized
--- @param filepath string
--- @param file_size number
--- @return table
local function check_virtualization(filepath, file_size)
	if not file_size or file_size < 20 then
		return { has_trailer = false, is_virtualized = false }
	end

	local f = io.open(filepath, "rb")
	if not f then
		return { has_trailer = false, is_virtualized = false }
	end

	f:seek("set", file_size - 20)
	local footer_bytes = f:read(20)
	f:close()

	if not footer_bytes or #footer_bytes < 20 then
		return { has_trailer = false, is_virtualized = false }
	end

	local tag, off, tag_low, tag_high = read_u64(footer_bytes, 1)
	local length
	length, off = read_u64(footer_bytes, off)

	-- FooterTag: 0x29BFCA045138DE76 (low: 0x5138DE76, high: 0x29BFCA04)
	if tag_low ~= 0x5138DE76 or tag_high ~= 0x29BFCA04 then
		return { has_trailer = false, is_virtualized = false }
	end

	if length <= 0 or length > file_size then
		return { has_trailer = true, is_virtualized = false }
	end

	f = io.open(filepath, "rb")
	if not f then
		return { has_trailer = true, is_virtualized = false }
	end

	f:seek("set", file_size - length)
	local header_bytes = f:read(math.min(length, 64 * 1024))
	f:close()

	if not header_bytes or #header_bytes < 28 then
		return { has_trailer = true, is_virtualized = false }
	end

	local h_tag, h_off, h_low, h_high = read_u64(header_bytes, 1)
	-- HeaderTag: 0xD1C43B2E80A5F697 (low: 0x80A5F697, high: 0xD1C43B2E)
	if h_low ~= 0x80A5F697 or h_high ~= 0xD1C43B2E then
		return { has_trailer = true, is_virtualized = false }
	end

	local h_ver
	h_ver, h_off = read_u32(header_bytes, h_off)
	local h_len
	h_len, h_off = read_u32(header_bytes, h_off)
	local h_payload_len
	h_payload_len, h_off = read_u64(header_bytes, h_off)
	local h_num_payloads
	h_num_payloads, h_off = read_u32(header_bytes, h_off)

	local num_virtualized = 0
	local num_local = 0
	local virtualized_raw_size = 0

	for p = 1, h_num_payloads do
		if h_off + 44 > #header_bytes then
			break
		end
		h_off = h_off + 20 -- skip 20-byte FIoHash
		local p_off
		p_off, h_off = read_u64(header_bytes, h_off)
		local p_comp_size
		p_comp_size, h_off = read_u64(header_bytes, h_off)
		local p_raw_size
		p_raw_size, h_off = read_u64(header_bytes, h_off)
		if h_ver >= 2 then
			h_off = h_off + 4 -- flags & filter flags
		end
		local access_mode = 0
		if h_ver >= 1 then
			access_mode = string.byte(header_bytes, h_off) or 0
			h_off = h_off + 1
		end

		-- EPayloadAccessMode: Local = 0, Referenced = 1, Virtualized = 2
		if access_mode == 2 or p_off == 18446744073709551615 or p_off == -1 then
			num_virtualized = num_virtualized + 1
			virtualized_raw_size = virtualized_raw_size + p_raw_size
		else
			num_local = num_local + 1
		end
	end

	return {
		has_trailer = true,
		trailer_version = h_ver,
		num_payloads = h_num_payloads,
		num_virtualized = num_virtualized,
		num_local = num_local,
		virtualized_raw_size = virtualized_raw_size,
		is_virtualized = num_virtualized > 0,
	}
end

local function read_fstring(str, off)
	local len, next_off = read_i32(str, off)
	if len == 0 or len == nil then
		return "", next_off
	end
	if len > 0 then
		if next_off + len - 2 > #str then
			return "", #str + 1
		end
		local s = string.sub(str, next_off, next_off + len - 2)
		return s, next_off + len
	else
		local char_count = -len
		local byte_count = char_count * 2
		if next_off + byte_count - 1 > #str then
			return "", #str + 1
		end
		local chars = {}
		for i = 0, char_count - 2 do
			local c = string.byte(str, next_off + i * 2)
			if c and c > 0 then
				table.insert(chars, string.char(c))
			end
		end
		return table.concat(chars), next_off + byte_count
	end
end

--- Decodes package flags into string tags
--- @param flags number
--- @return string[]
local function decode_package_flags(flags)
	local flag_defs = {
		{ 0x00000001, "NewlyCreated" },
		{ 0x00000002, "ClientOptional" },
		{ 0x00000004, "ServerReverse" },
		{ 0x00000010, "CompiledIn" },
		{ 0x00000200, "Cooked" },
		{ 0x00002000, "UnversionedProperties" },
		{ 0x00008000, "ServerOnly" },
		{ 0x00010000, "Compiling" },
		{ 0x00020000, "ContainsMap" },
		{ 0x00100000, "PlayInEditor" },
		{ 0x01000000, "ContainsMapData" },
		{ 0x20000000, "DynamicImports" },
		{ 0x40000000, "RuntimeGenerated" },
		{ 0x80000000, "FilterEditorOnly" },
	}

	local active = {}
	for _, def in ipairs(flag_defs) do
		local bit_mask = def[1]
		local bit_name = def[2]
		if (flags % (bit_mask * 2)) >= bit_mask then
			table.insert(active, bit_name)
		end
	end
	return active
end

--- Parses Unreal package metadata from a binary file
--- @param filepath string
--- @return table|nil, string|nil
function M.parse_package(filepath)
	local f = io.open(filepath, "rb")
	if not f then
		return nil, "Cannot open file: " .. filepath
	end

	local file_size = f:seek("end") or 0
	f:seek("set", 0)

	-- Read up to first 256KB to parse summary, name table, import/export maps
	local read_len = math.min(file_size, 256 * 1024)
	local data = f:read(read_len)
	f:close()

	if not data or #data < 32 then
		return nil, "File too small or corrupted"
	end

	local off = 1
	local tag
	tag, off = read_u32(data, off)

	local is_swapped = false
	if tag == PACKAGE_FILE_TAG_SWAPPED then
		is_swapped = true
		tag = PACKAGE_FILE_TAG
	end

	if tag ~= PACKAGE_FILE_TAG and tag ~= PACKAGE_FILE_TAG_COOKED then
		return {
			is_valid_package = false,
			tag = tag,
			file_size = file_size,
		}, nil
	end

	local legacy_ver
	legacy_ver, off = read_i32(data, off)
	local legacy_ue3 = 0
	if legacy_ver ~= -4 then
		legacy_ue3, off = read_i32(data, off)
	end

	local ue4_ver
	ue4_ver, off = read_i32(data, off)
	local ue5_ver = 0
	if legacy_ver <= -8 then
		ue5_ver, off = read_i32(data, off)
	end
	local licensee_ver
	licensee_ver, off = read_i32(data, off)

	local total_header_size = 0
	if ue5_ver >= 1016 then
		off = off + 20 -- FIoHash
		total_header_size, off = read_i32(data, off)
	end

	if legacy_ver <= -2 then
		local custom_count
		custom_count, off = read_i32(data, off)
		if legacy_ver < -5 and custom_count and custom_count > 0 then
			off = off + custom_count * 20
		end
	end

	if ue5_ver < 1016 then
		total_header_size, off = read_i32(data, off)
	end

	local folder_name
	folder_name, off = read_fstring(data, off)
	local package_flags
	package_flags, off = read_u32(data, off)
	local is_filter_editor = (package_flags % 4294967296) >= 2147483648
	local name_count
	name_count, off = read_i32(data, off)
	local name_offset
	name_offset, off = read_i32(data, off)

	if ue5_ver >= 1008 then
		off = off + 8 -- soft object paths
	end

	if not is_filter_editor and ue4_ver >= 516 then
		local loc_id
		loc_id, off = read_fstring(data, off)
	end

	if ue4_ver >= 459 then
		off = off + 8 -- gatherable text data
	end

	local export_count
	export_count, off = read_i32(data, off)
	local export_offset
	export_offset, off = read_i32(data, off)
	local import_count
	import_count, off = read_i32(data, off)
	local import_offset
	import_offset, off = read_i32(data, off)

	if ue5_ver >= 1015 then
		off = off + 16 -- verse cells
	end
	if ue5_ver >= 1014 then
		off = off + 4 -- metadata offset
	end

	local depends_offset
	depends_offset, off = read_i32(data, off)

	if ue4_ver >= 510 then
		off = off + 8 -- soft package references
	end
	if ue4_ver >= 513 then
		off = off + 4 -- searchable names offset
	end

	local thumbnail_offset
	thumbnail_offset, off = read_i32(data, off)

	if ue5_ver >= 1018 then
		off = off + 8 -- import type hierarchies
	end

	if ue5_ver < 1016 then
		off = off + 16 -- guid
	end

	if not is_filter_editor and ue4_ver >= 518 then
		off = off + 16 -- persistent guid
	end

	local gen_count
	gen_count, off = read_i32(data, off)
	if gen_count and gen_count > 0 and gen_count < 100 then
		off = off + gen_count * 8
	end

	-- SavedByEngineVersion
	local saved_major, saved_minor, saved_patch, saved_cl, saved_branch = 0, 0, 0, 0, ""
	if ue4_ver >= 336 and off + 10 <= #data then
		saved_major, off = read_u16(data, off)
		saved_minor, off = read_u16(data, off)
		saved_patch, off = read_u16(data, off)
		saved_cl, off = read_u32(data, off)
		saved_branch, off = read_fstring(data, off)
	end

	-- CompatibleWithEngineVersion
	local compat_major, compat_minor, compat_patch, compat_cl, compat_branch = 0, 0, 0, 0, ""
	if ue4_ver >= 444 and off + 10 <= #data then
		compat_major, off = read_u16(data, off)
		compat_minor, off = read_u16(data, off)
		compat_patch, off = read_u16(data, off)
		compat_cl, off = read_u32(data, off)
		compat_branch, off = read_fstring(data, off)
	end

	local compression_flags = 0
	if off + 4 <= #data then
		compression_flags, off = read_u32(data, off)
	end

	-- Name Table
	local names = {}
	if name_offset and name_count and name_count > 0 and name_offset < #data then
		local n_off = name_offset + 1
		for i = 0, name_count - 1 do
			if n_off > #data then
				break
			end
			local name_str
			name_str, n_off = read_fstring(data, n_off)
			n_off = n_off + 4 -- skip 2x uint16 hashes
			names[i] = name_str
		end
	end

	local function get_fname(cur_off)
		local idx
		idx, cur_off = read_i32(data, cur_off)
		local num
		num, cur_off = read_i32(data, cur_off)
		local base = names[idx] or ("Name_" .. tostring(idx))
		if num and num > 0 then
			return base .. "_" .. tostring(num - 1), cur_off
		end
		return base, cur_off
	end

	-- Imports Map
	local imports = {}
	if import_offset and import_count and import_count > 0 and import_offset < #data then
		local i_off = import_offset + 1
		for i = 0, import_count - 1 do
			if i_off + 16 > #data then
				break
			end
			local class_pkg
			class_pkg, i_off = get_fname(i_off)
			local class_name
			class_name, i_off = get_fname(i_off)
			local outer_idx
			outer_idx, i_off = read_i32(data, i_off)
			local obj_name
			obj_name, i_off = get_fname(i_off)
			if ue4_ver >= 516 then
				local pkg_name
				pkg_name, i_off = get_fname(i_off)
			end
			if ue5_ver >= 1003 then
				local opt
				opt, i_off = read_i32(data, i_off)
			end
			imports[i] = {
				class_package = class_pkg,
				class_name = class_name,
				object_name = obj_name,
			}
		end
	end

	-- Exports Map
	local exports = {}
	local primary_class = nil
	local primary_export = nil

	if export_offset and export_count and export_count > 0 and export_offset < #data then
		local stride = 112
		if depends_offset and depends_offset > export_offset then
			stride = math.floor((depends_offset - export_offset) / export_count)
		end

		for i = 0, export_count - 1 do
			local e_off = export_offset + 1 + i * stride
			if e_off + 20 > #data then
				break
			end
			local class_idx
			class_idx, e_off = read_i32(data, e_off)
			local super_idx
			super_idx, e_off = read_i32(data, e_off)
			local template_idx
			template_idx, e_off = read_i32(data, e_off)
			local outer_idx
			outer_idx, e_off = read_i32(data, e_off)
			local obj_name
			obj_name, e_off = get_fname(e_off)

			local class_str = "Class"
			if class_idx < 0 then
				local imp = imports[-class_idx - 1]
				if imp then
					class_str = imp.object_name
				end
			end

			local exp_entry = {
				object_name = obj_name,
				class_name = class_str,
				outer_index = outer_idx,
			}
			table.insert(exports, exp_entry)
		end

		-- Determine primary export:
		-- 1. Look for outer_index == 0 matching the file's basename
		local file_base = vim.fs.basename(filepath):gsub("%.%a+$", ""):lower()
		for _, exp in ipairs(exports) do
			if exp.outer_index == 0 and exp.object_name:lower() == file_base then
				primary_class = exp.class_name
				primary_export = exp.object_name
				break
			end
		end

		-- 2. If no exact basename match, look for outer_index == 0 that isn't MetaData, Model, or Polys
		if not primary_class then
			for _, exp in ipairs(exports) do
				if
					exp.outer_index == 0
					and exp.class_name ~= "MetaData"
					and exp.class_name ~= "Model"
					and exp.class_name ~= "Polys"
				then
					primary_class = exp.class_name
					primary_export = exp.object_name
					break
				end
			end
		end

		-- 3. Fallback to any outer_index == 0
		if not primary_class then
			for _, exp in ipairs(exports) do
				if exp.outer_index == 0 and exp.class_name ~= "MetaData" then
					primary_class = exp.class_name
					primary_export = exp.object_name
					break
				end
			end
		end
	end

	return {
		is_valid_package = true,
		file_size = file_size,
		tag = tag,
		legacy_ver = legacy_ver,
		ue4_ver = ue4_ver,
		ue5_ver = ue5_ver,
		licensee_ver = licensee_ver,
		total_header_size = total_header_size,
		package_name = folder_name,
		package_flags = package_flags,
		flags_list = decode_package_flags(package_flags),
		name_count = name_count,
		import_count = import_count,
		export_count = export_count,
		saved_engine_version = {
			major = saved_major,
			minor = saved_minor,
			patch = saved_patch,
			changelist = saved_cl,
			branch = saved_branch,
		},
		compatible_engine_version = {
			major = compat_major,
			minor = compat_minor,
			patch = compat_patch,
			changelist = compat_cl,
			branch = compat_branch,
		},
		primary_class = primary_class or (exports[1] and exports[1].class_name) or "Unknown",
		primary_export = primary_export or (exports[1] and exports[1].object_name) or vim.fs.basename(filepath),
		exports = exports,
		imports = imports,
		virtualization = check_virtualization(filepath, file_size),
	},
		nil
end

--- Locates the companion asset for payload files (.uexp, .ubulk, .uptnl)
--- @param filepath string
--- @return string|nil companion_path, string ext
local function find_companion_package(filepath)
	local norm = vim.fs.normalize(filepath)
	local base = norm:gsub("%.%a+$", "")
	local uasset_path = base .. ".uasset"
	if vim.fn.filereadable(uasset_path) == 1 then
		return uasset_path, ".uasset"
	end
	local umap_path = base .. ".umap"
	if vim.fn.filereadable(umap_path) == 1 then
		return umap_path, ".umap"
	end
	return nil, ""
end

--- Renders the metadata buffer contents
--- @param bufnr number
--- @param filepath string
--- @param info table
--- @param game_path string
--- @param companion_info? { filepath: string, ext: string, size: number }
function M.render_buffer(bufnr, filepath, info, game_path, companion_info)
	local lines = {}
	local highlights = {}

	local function add_line(text, hl_group, col_start, col_end)
		table.insert(lines, text)
		if hl_group then
			table.insert(highlights, {
				line = #lines - 1,
				hl_group = hl_group,
				col_start = col_start or 0,
				col_end = col_end or #text,
			})
		end
	end

	local filename = vim.fs.basename(filepath)

	add_line(
		string.format(
			"  File:       %s  (%s)",
			filename,
			format_bytes(companion_info and companion_info.size or info.file_size or 0)
		),
		"Directory"
	)
	add_line(string.format("  Path:       %s", vim.fs.normalize(filepath)), "Comment")
	add_line(string.format("  Game Path:  %s", game_path), "Special")

	if companion_info then
		add_line(
			string.format(
				"  Companion:  %s (Linked package header: %s)",
				companion_info.ext,
				vim.fs.basename(companion_info.filepath)
			),
			"WarningMsg"
		)
	end

	if info.virtualization and info.virtualization.is_virtualized then
		add_line(
			string.format(
				"  ⚠ VIRTUAL ASSET: Payload(s) are virtualized in remote storage (%s)",
				format_bytes(info.virtualization.virtualized_raw_size)
			),
			"DiagnosticWarn"
		)
	end

	add_line("")
	add_line("  ● Editor Status: Checking connection...", "Comment") -- Line 9 (0-indexed line 8)
	local editor_status_line_idx = #lines - 1

	add_line("")
	add_line("  Actions:", "Title")
	add_line("    [o] / [<CR>]  Open in Unreal Editor (Remote Python)", "Keyword")
	add_line("    [y] / [yp]    Yank Unreal Game Path to clipboard", "Function")
	if info.virtualization and info.virtualization.is_virtualized then
		add_line("    [R]           Rehydrate Asset (UnrealVirtualizationTool)", "Keyword")
	end
	add_line("    [B]           View Raw Binary", "Function")
	add_line("    [r]           Refresh Metadata", "Function")
	add_line("")

	add_line(
		"──────────────────────────────────────────────────────────────────────────────",
		"Comment"
	)
	add_line("  Metadata Breakdown:", "Title")

	if info.is_valid_package then
		add_line(string.format("    Primary Class:    %s", info.primary_class or "Unknown"), "Type")
		add_line(string.format("    Primary Object:   %s", info.primary_export or "Unknown"), "Identifier")

		if info.virtualization then
			if info.virtualization.is_virtualized then
				add_line(
					string.format(
						"    Virtualization:   VIRTUALIZED (%d of %d payloads remote, %s)",
						info.virtualization.num_virtualized,
						info.virtualization.num_payloads,
						format_bytes(info.virtualization.virtualized_raw_size)
					),
					"DiagnosticWarn"
				)
			elseif info.virtualization.has_trailer and info.virtualization.num_payloads > 0 then
				add_line(
					string.format(
						"    Virtualization:   Hydrated / Local (%d payload%s in trailer)",
						info.virtualization.num_payloads,
						info.virtualization.num_payloads == 1 and "" or "s"
					),
					"DiagnosticOk"
				)
			elseif info.virtualization.has_trailer then
				add_line("    Virtualization:   Package Trailer Present (0 payloads)", "Comment")
			else
				add_line("    Virtualization:   Standard Package (no trailer)", "Comment")
			end
		end

		local saved_ver = info.saved_engine_version or {}
		if saved_ver.major and saved_ver.major > 0 then
			add_line(
				string.format(
					"    Engine Version:   %d.%d.%d-%d (%s)",
					saved_ver.major,
					saved_ver.minor,
					saved_ver.patch,
					saved_ver.changelist,
					saved_ver.branch or "Release"
				),
				"Number"
			)
		else
			add_line(
				string.format("    Package Version:  UE4=%d, UE5=%d", info.ue4_ver or 0, info.ue5_ver or 0),
				"Number"
			)
		end

		local compat_ver = info.compatible_engine_version or {}
		if compat_ver.major and compat_ver.major > 0 then
			add_line(
				string.format(
					"    Compatible With:  %d.%d.%d-%d",
					compat_ver.major,
					compat_ver.minor,
					compat_ver.patch,
					compat_ver.changelist
				),
				"Comment"
			)
		end

		if info.flags_list and #info.flags_list > 0 then
			add_line(string.format("    Package Flags:    %s", table.concat(info.flags_list, ", ")), "Special")
		end

		add_line(
			string.format(
				"    Header Size:      %s (%d bytes)",
				format_bytes(info.total_header_size or 0),
				info.total_header_size or 0
			),
			"Number"
		)
		add_line(string.format("    Name Table:       %d entries", info.name_count or 0), "Number")
		add_line(string.format("    Import Map:       %d entries", info.import_count or 0), "Number")
		add_line(string.format("    Export Map:       %d entries", info.export_count or 0), "Number")

		if info.exports and #info.exports > 0 then
			add_line("")
			add_line("  Exports (Top):", "Title")
			for i = 1, math.min(#info.exports, 12) do
				local exp = info.exports[i]
				local is_root = exp.outer_index == 0
				local prefix = is_root and "    ★ " or "      • "
				add_line(
					string.format("%s%s (%s)", prefix, exp.object_name, exp.class_name),
					is_root and "Identifier" or "Normal"
				)
			end
			if #info.exports > 12 then
				add_line(string.format("      ... and %d more exports", #info.exports - 12), "Comment")
			end
		end

		if info.imports and #info.imports > 0 then
			add_line("")
			add_line("  Imports (Top):", "Title")
			for i = 0, math.min(#info.imports, 8) do
				local imp = info.imports[i]
				if imp then
					add_line(
						string.format("      • %s (%s::%s)", imp.object_name, imp.class_package, imp.class_name),
						"Comment"
					)
				end
			end
			if #info.imports > 8 then
				add_line(string.format("      ... and %d more imports", #info.imports - 8), "Comment")
			end
		end
	else
		add_line("    Package Header:   Not a standard versioned Unreal package header", "WarningMsg")
		add_line(string.format("    File Size:        %s", format_bytes(info.file_size or 0)), "Number")
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- Apply highlights
	local ns = vim.api.nvim_create_namespace("uproject_asset")
	vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(bufnr, ns, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })

	return editor_status_line_idx
end

--- Updates the live editor status line in the buffer
--- @param bufnr number
--- @param status_line_idx number
--- @param status_text string
--- @param hl_group string
local function update_editor_status(bufnr, status_line_idx, status_text, hl_group)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_buf_set_lines(bufnr, status_line_idx, status_line_idx + 1, false, { status_text })
	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })

	local ns = vim.api.nvim_create_namespace("uproject_asset_status")
	vim.api.nvim_buf_clear_namespace(bufnr, ns, status_line_idx, status_line_idx + 1)
	vim.api.nvim_buf_add_highlight(bufnr, ns, hl_group, status_line_idx, 0, #status_text)
end

--- Loads raw binary contents into the buffer
--- @param bufnr number
--- @param filepath string
local function load_raw_binary(bufnr, filepath)
	vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
	vim.api.nvim_set_option_value("readonly", false, { buf = bufnr })
	vim.api.nvim_set_option_value("buftype", "", { buf = bufnr })

	local f = io.open(filepath, "rb")
	if f then
		local content = f:read("*a")
		f:close()
		local lines = vim.split(content or "", "\n", { plain = true })
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	end

	vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
	vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })

	vim.notify(
		"Loaded raw binary view for " .. vim.fs.basename(filepath) .. ". Press 'r' to return to metadata view.",
		vim.log.levels.INFO
	)
end

--- Handles the BufReadCmd event for Unreal binary files
--- @param bufnr number
--- @param filepath string
function M.on_buf_read_cmd(bufnr, filepath)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = bufnr })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = bufnr })
	vim.api.nvim_set_option_value("swapfile", false, { buf = bufnr })
	vim.api.nvim_set_option_value("filetype", "uasset", { buf = bufnr })

	local norm_path = vim.fs.normalize(filepath)
	local ext = norm_path:match("%.(%a+)$") or ""
	ext = "." .. ext:lower()

	local target_to_parse = norm_path
	local companion_info = nil

	if ext == ".uexp" or ext == ".ubulk" or ext == ".uptnl" then
		local comp_path, comp_ext = find_companion_package(norm_path)
		local stat = vim.uv.fs_stat(norm_path)
		companion_info = {
			filepath = comp_path or norm_path,
			ext = ext,
			size = stat and stat.size or 0,
		}
		if comp_path then
			target_to_parse = comp_path
		end
	end

	local game_path = remote.resolve_game_path(norm_path)
	local info, err = M.parse_package(target_to_parse)

	if not info then
		info = {
			is_valid_package = false,
			file_size = companion_info and companion_info.size or 0,
		}
	end

	local status_idx = M.render_buffer(bufnr, norm_path, info, game_path, companion_info)

	-- Check editor status in background
	remote.find_node_for_project(nil, function(find_err, node)
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		if node then
			local label = string.format(
				"  ● Editor Status: Connected (%s - UE %s)",
				node.project_name or "UnrealEditor",
				node.engine_version or "5.x"
			)
			update_editor_status(bufnr, status_idx, label, "DiagnosticOk")
		else
			local label = "  ○ Editor Status: Not connected (Python Remote Execution unavailable)"
			update_editor_status(bufnr, status_idx, label, "DiagnosticWarn")
		end
	end)

	-- Action: Open in Unreal Editor
	local function do_open_editor()
		update_editor_status(bufnr, status_idx, "  ◌ Editor Status: Opening in Unreal Editor...", "DiagnosticInfo")
		vim.notify("Sending request to open " .. game_path .. " in Unreal Editor...", vim.log.levels.INFO)

		remote.open_asset(game_path, {}, function(open_err, success)
			if not vim.api.nvim_buf_is_valid(bufnr) then
				return
			end
			if open_err or not success then
				local err_msg = open_err or "Failed to open asset"
				update_editor_status(bufnr, status_idx, "  ✕ Editor Status: " .. err_msg, "DiagnosticError")
				vim.notify(
					"Unreal Editor Remote: "
						.. err_msg
						.. "\n(Ensure Unreal Editor is running and Python Remote Execution is enabled in Project Settings)",
					vim.log.levels.WARN
				)
			else
				update_editor_status(bufnr, status_idx, "  ✓ Editor Status: Opened in Unreal Editor!", "DiagnosticOk")
				vim.notify("Successfully opened " .. game_path .. " in Unreal Editor", vim.log.levels.INFO)
			end
		end)
	end

	-- Action: Copy Game Path
	local function do_copy_path()
		vim.fn.setreg("+", game_path)
		vim.fn.setreg('"', game_path)
		vim.notify("Copied Unreal Game Path to clipboard: " .. game_path, vim.log.levels.INFO)
	end

	-- Action: Rehydrate Asset
	local function do_rehydrate()
		local Path = require("plenary.path")
		local uproject_init = require("uproject")
		local dir = vim.fs.dirname(norm_path)
		local p_file, p_root = uproject_init.uproject_path(dir)

		if not p_file then
			vim.notify("Cannot find .uproject for " .. norm_path, vim.log.levels.ERROR)
			return
		end

		local virt_tool = uproject_init.unreal_virtualization_tool(p_root or dir)
		if not virt_tool then
			vim.notify("UnrealVirtualizationTool.exe could not be found for project.", vim.log.levels.ERROR)
			return
		end

		-- Clear read-only if set so the tool can rewrite the asset
		pcall(function()
			vim.uv.fs_chmod(norm_path, 438) -- 0666 rw-rw-rw-
		end)

		update_editor_status(
			bufnr,
			status_idx,
			"  ◌ Editor Status: Rehydrating with UnrealVirtualizationTool...",
			"DiagnosticInfo"
		)
		vim.notify(
			"Running UnrealVirtualizationTool to rehydrate " .. vim.fs.basename(norm_path) .. "...",
			vim.log.levels.INFO
		)

		local output_buf = uproject_init.spawn_output_buffer({
			cmd = virt_tool,
			args = { p_file, "-Mode=Rehydrate", "-Package=" .. norm_path },
			project_root = Path:new(p_root or dir),
			type = "rehydrate",
			name = vim.fs.basename(norm_path),
		}, function(code)
			if code == 0 then
				vim.notify("Successfully rehydrated " .. vim.fs.basename(norm_path), vim.log.levels.INFO)
				if vim.api.nvim_buf_is_valid(bufnr) then
					M.on_buf_read_cmd(bufnr, norm_path)
				end
			else
				vim.notify(
					"UnrealVirtualizationTool exited with code " .. code .. " (check output buffer)",
					vim.log.levels.ERROR
				)
				if vim.api.nvim_buf_is_valid(bufnr) then
					update_editor_status(
						bufnr,
						status_idx,
						"  ✕ Editor Status: Rehydration failed with code " .. code,
						"DiagnosticError"
					)
				end
			end
		end)

		if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
			vim.api.nvim_win_set_buf(0, output_buf)
		end
	end

	-- Register Buffer Keymaps
	local keymap_opts = { buffer = bufnr, silent = true, noremap = true }

	vim.keymap.set(
		"n",
		"<CR>",
		do_open_editor,
		vim.tbl_extend("force", keymap_opts, { desc = "Open in Unreal Editor" })
	)
	vim.keymap.set("n", "o", do_open_editor, vim.tbl_extend("force", keymap_opts, { desc = "Open in Unreal Editor" }))
	vim.keymap.set("n", "y", do_copy_path, vim.tbl_extend("force", keymap_opts, { desc = "Copy Unreal Game Path" }))
	vim.keymap.set("n", "yp", do_copy_path, vim.tbl_extend("force", keymap_opts, { desc = "Copy Unreal Game Path" }))
	if info.virtualization and info.virtualization.is_virtualized then
		vim.keymap.set("n", "R", do_rehydrate, vim.tbl_extend("force", keymap_opts, { desc = "Rehydrate Asset" }))
	else
		pcall(vim.keymap.del, "n", "R", { buffer = bufnr })
	end
	vim.keymap.set("n", "B", function()
		load_raw_binary(bufnr, norm_path)
	end, vim.tbl_extend("force", keymap_opts, { desc = "View Raw Binary" }))
	vim.keymap.set("n", "r", function()
		M.on_buf_read_cmd(bufnr, norm_path)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Refresh Asset Metadata" }))
end

return M
