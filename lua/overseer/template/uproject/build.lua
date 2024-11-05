return {
	cache_key = function(_)
		return require('uproject').uproject_path(vim.uv.cwd())
	end,
	condition = {
		callback = function(_)
			local project_dir = require('uproject').uproject_path(vim.uv.cwd())
			return project_dir ~= nil
		end,
	},
	generator = function(_, callback)
		local Path = require("plenary.path")
		local uproject = require('uproject')
		local project_path = uproject.uproject_path(vim.uv.cwd())
		if project_path == nil then
			callback({})
			return
		end

		local project_root = Path:new(vim.fs.dirname(project_path))
		---@diagnostic disable-next-line: redefined-local
		local project_path = Path:new(project_path)

		local engine_association = uproject.uproject_engine_association(project_root:absolute())
		if engine_association == nil then
			callback({})
			return
		end


		uproject.unreal_engine_install_dir(engine_association, function(install_dir)
			local engine_dir = vim.fs.joinpath(install_dir, "Engine")
			local build_bat = vim.fs.joinpath(
				engine_dir, "Build", "BatchFiles", "Build.bat")

			local target_info_path = vim.fs.joinpath(project_root:absolute(), "Intermediate", "TargetInfo.json")
			local target_info = vim.fn.json_decode(vim.fn.readfile(target_info_path))
			local templates = {}

			for i, target in ipairs(target_info.Targets) do
				templates[i] = {
					name = target.Name .. " (" .. target.Type .. ")",
					params = {
						Platform = {
							default = "Win64",
							type = "enum",
							choices = {
								"Win64",
								"Linux",
								"Mac",
								"IOS",
								"Android",
							},
						},
						ConfigState = {
							type = "enum",
							describe =
							"https://dev.epicgames.com/documentation/en-us/unreal-engine/compiling-game-projects-in-unreal-engine-using-cplusplus",
							default = "Development",
							choices = {
								"Debug",
								"DebugGame",
								"Development",
								"Shipping",
								"Test",
							},
						},
						ConfigTarget = {
							type = "enum",
							describe =
							"https://dev.epicgames.com/documentation/en-us/unreal-engine/compiling-game-projects-in-unreal-engine-using-cplusplus",
							default = "Editor",
							choices = {
								"Game",
								"Editor",
								"Client",
								"Server",
							},
						},
					},
					builder = function(params)
						local target_options = {
							target.Name,
							params.Platform,
							params.ConfigState,
							params.ConfigTarget,
						}

						return {
							cmd = {
								build_bat,
								"-Project=" .. project_path:absolute(),
								"-Target=" .. table.concat(target_options, " "),
							},
						}
					end,
				}
			end

			callback(templates)
		end)
	end,
}
