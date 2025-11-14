local async = require("async")
local has_perforce, perforce = pcall(require, "perforce") -- optional zaucy/perforce.nvim

local M = {}

--- details for changelists that should be part
--- @async
function M.get_submit_changelists()
	async.await(vim.schedule)

	local result = { {
		cl = "default",
		desc = "create new changelist",
	} }

	if not has_perforce then
		return result
	end

	local change_cmd_result = async.await_all({
		async.run(function()
			return async.await(2, perforce.changes, {
				user = vim.env["P4USER"],
				status = "pending",
			})
		end),
		async.run(function()
			return async.await(2, perforce.changes, {
				user = vim.env["P4USER"],
				status = "shelved",
			})
		end),
	})

	--- @type PerforceChangeInfo[]
	local changes = {}
	for _, changes_list in pairs(change_cmd_result) do
		if changes_list then
			for _, entry in pairs(changes_list) do
				if vim.islist(entry) then
					for _, change in pairs(entry) do
						table.insert(changes, change)
					end
				end
			end
		end
	end

	for _, change in ipairs(changes) do
		table.insert(result, {
			cl = change.change,
			desc = change.desc or "(no description)",
		})
	end

	return result
end

return M
