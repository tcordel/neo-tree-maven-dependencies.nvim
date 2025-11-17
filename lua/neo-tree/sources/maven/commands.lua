--This file should contain all commands meant to be used by mappings.
local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")
local log = require("neo-tree.log")

local vim = vim

local M = {}

M.refresh = function(state)
	manager.refresh("maven", state)
end

M.invalidate = function(state)
	require("neo-tree.sources.maven").load_dependencies()
	M.refresh(state)
end

M.open = function(state, toggle_directory)
	local tree = state.tree
	local success, node = pcall(tree.get_node, tree)
	if not (success and node) then
		log.debug("Could not get node.")
		return
	end
	-- if node.type == "file" and string.sub(node.path, 1, 3) ~= "jdt" then
	-- 	-- cc.open(state, toggle_directory)
	-- 	local content = vim.fn.system("unzip -p " .. node.extra.jar .. " " .. node.extra.file .. " | less")
	-- 	if not content then
	-- 		vim.notify("Impossible de lire " .. node.extra.file .. " depuis " .. node.extra.jar, vim.log.levels.ERROR)
	-- 		return
	-- 	end
	--
	-- 	-- créer un buffer
	-- 	local buf = vim.api.nvim_create_buf(true, false)
	--
	-- 	-- charger les lignes
	-- 	local lines = vim.split(content, "\n", { plain = true })
	-- 	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	-- 	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
	-- 	vim.api.nvim_set_option_value("readonly", true, { buf = buf })
	--
	-- 	-- optionnel : définir un nom de buffer virtuel
	-- 	-- vim.api.nvim_buf_set_name(buf, node.path)
	--
	-- 	-- afficher le buffer
	-- 	vim.api.nvim_set_current_buf(buf)
	--
	-- 	-- filetype optionnel selon extension
	-- 	-- local ext = internal_path:match("^.+%.(.+)$")
	-- 	-- if ext then
	-- 	-- 	vim.api.nvim_set_option_value("filetype", ext, { buf = buf })
	-- 	-- end
	-- else
	-- end
	cc.open(state, toggle_directory)
end
cc._add_common_commands(M)
return M
