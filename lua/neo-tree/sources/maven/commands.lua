--This file should contain all commands meant to be used by mappings.
local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")
local renderer = require("neo-tree.ui.renderer")

local M = {}

M.refresh = function(state)
	manager.refresh("maven", state)
end

M.invalidate = function(state)
	local maven = require("neo-tree.sources.maven")
	renderer.show_nodes({ maven.loading_node }, state)
	maven.load_dependencies(function(items)
		if items == nil then
			renderer.show_nodes({ maven.error_node("Failed to load dependencies (see :messages)") }, state)
			return
		end
		M.refresh(state)
	end)
end

cc._add_common_commands(M)
return M
