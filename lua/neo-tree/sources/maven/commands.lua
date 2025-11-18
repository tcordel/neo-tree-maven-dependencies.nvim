--This file should contain all commands meant to be used by mappings.
local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")

local M = {}

M.refresh = function(state)
	manager.refresh("maven", state)
end

M.invalidate = function(state)
	require("neo-tree.sources.maven").load_dependencies()
	M.refresh(state)
end

cc._add_common_commands(M)
return M
