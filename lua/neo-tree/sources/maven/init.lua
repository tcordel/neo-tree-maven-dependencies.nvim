local Path = require("plenary.path")
local utils = require("neo-tree.utils")
local manager = require("neo-tree.sources.manager")
local events = require("neo-tree.events")
local renderer = require("neo-tree.ui.renderer")
local M = {
	name = "maven",
}
local resource_file_prefix = "jar://"

local register = function()
	if M.config.enabled == false then
		return {}
	end
	local deps = Path:new(M.config.maven_dependencies)
	if not deps:exists() then
		M.load_dependencies()
	end
	local items_data = deps:read()
	return vim.json.decode(items_data)
end
local open_jar_resource = function(jar_resource)
	local buf = vim.api.nvim_get_current_buf()
	local address = string.sub(jar_resource, #resource_file_prefix)
	local tokens = vim.split(address, "::")
	local jar = tokens[1]
	local resource = tokens[2]
	vim.bo[buf].modifiable = true
	vim.bo[buf].swapfile = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].filetype = "java"

	local content = vim.fn.system("unzip -p " .. jar .. " " .. resource .. " | less")
	if not content then
		return
	end

	-- charger les lignes
	local normalized = string.gsub(content, "\r\n", "\n")
	local source_lines = vim.split(normalized, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, source_lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
end

M.setup = function()
	M.config = {
		enabled = false,
	}
	local root_dir = vim.fs.root(0, { "pom.xml" })
	if root_dir ~= nil then
		local project_name = vim.fs.basename(root_dir)
		M.config = {
			enabled = true,
			root_dir = root_dir,
			project_name = project_name,
			maven_dependencies = vim.fn.stdpath("cache") .. "/maven/" .. project_name .. "_dependencies.json",
			m2_repository = os.getenv("HOME") .. "/.m2/repository/",
		}
		vim.api.nvim_create_user_command("MavenDependenciesInvalidate", function()
			M.load_dependencies()
		end, {})
	end

	local group = vim.api.nvim_create_augroup("maven", {})
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = group,
		pattern = resource_file_prefix .. "*",
		---@param args vim.api.keyset.create_autocmd.callback_args
		callback = function(args)
			open_jar_resource(args.match)
		end,
	})

	-- Configure event handler for follow_current_file option
	manager.subscribe(M.name, {
		event = events.VIM_BUFFER_ENTER,
		handler = M.follow,
	})
	manager.subscribe(M.name, {
		event = events.VIM_TERMINAL_ENTER,
		handler = M.follow,
	})
end

M.load_dependencies = function()
	vim.notify("Loading dependencies", vim.log.levels.INFO)
	M.init_project_modules()
	local items = M.fetch_dependencies()
	table.sort(items, function(a, b)
		return a.id < b.id
	end)
	local deps = Path:new(M.config.maven_dependencies)
	deps:write(vim.json.encode(items), "w")
	vim.notify("Dependencies loaded", vim.log.levels.INFO)
end

M.navigate = function(state, path)
	if path == nil then
		path = vim.fn.getcwd()
	end
	state.path = path
	local items = register()
	local renderer = require("neo-tree.ui.renderer")
	renderer.show_nodes(items, state)
end

M.init_project_modules = function()
	local out = vim.fn.system(
		string.format(
			"cd %s && mvn -Dexec.executable='echo' -Dexec.args='${project.groupId}:${project.artifactId}:${project.version}' exec:exec -q -o",
			M.config.root_dir
		)
	)
	M.modules = {}
	M.modules_hash_list = {}

	for _, line in pairs(vim.split(out, "\n")) do
		local tokens = vim.split(line, ":")
		if tokens and #tokens == 3 then
			local module = {
				group_id = tokens[1],
				artifact_id = tokens[2],
				version = tokens[3],
			}

			table.insert(M.modules, module)
			M.modules_hash_list[line] = true
		end
	end
end

local extract_metadata_from_uri = function(class)
	local packageName = ""
	local className = ""
	local packageTokens = {}

	local splitted = vim.split(class, "/")
	for k, work in pairs(splitted) do
		if k > 1 and k < #splitted then
			packageName = packageName .. "."
		end
		if k < #splitted then
			packageName = packageName .. work
			table.insert(packageTokens, work)
		else
			className = work
		end
	end
	return packageName, className, packageTokens
end
local ends_with = function(str, suffix)
	return suffix == "" or str:sub(-#suffix) == suffix
end
local render_node = function(module_artifact_id, group_id, artifact_id, version, scope)
	local fqdn = group_id .. ":" .. artifact_id .. ":" .. version
	local dependency = {
		id = fqdn,
		name = fqdn,
		type = "directory",
		stat_provider = "maven-custom",
		children = {},
		extra = {
			module = module_artifact_id,
			scope = scope,
		},
	}
	local jar_prefix = M.config.m2_repository
		.. string.gsub(group_id, "%.", "/")
		.. "/"
		.. artifact_id
		.. "/"
		.. version
		.. "/"
		.. artifact_id
		.. "-"
		.. version

	local jar = jar_prefix .. ".jar"
	local jar_javadoc = jar_prefix .. "-javadoc.jar"

	local javadoc_present = Path.new(jar_javadoc):exists()
	local java_doc_cmd = ""
	if javadoc_present == true then
		java_doc_cmd = string.format("=/=/javadoc_location=/jar:file:%s%%5C!%%5C/", jar_javadoc:gsub("/", "%%5C/"))
	end

	local cmd = "unzip -l "
		.. jar
		.. ' | tail -n +4 | head -n -2 | awk \'{for (i=4; i<=NF; i++) { printf("%s%s",( (i>4) ? " " : "" ), $i) } print ""}\' | sort'
	local content = vim.fn.system(cmd)

	for _, class in pairs(vim.split(content, "\n")) do
		if class ~= nil and class ~= "" then
			local packageName, className, packageTokens = extract_metadata_from_uri(class)

			if className ~= nil and className ~= "" then
				local name
				local filter = false
				-- jdt://contents/classmate-1.7.0.jar/com.fasterxml.classmate/TypeBindings.class?=demo/%5C/home%5C/tib%5C/.m2%5C/repository%5C/com%5C/fasterxml%5C/classmate%5C/1.7.0%5C/classmate-1.7.0.jar=/maven.pomderived=/true=/=/javadoc_location=/jar:file:%5C/home%5C/tib%5C/.m2%5C/repository%5C/com%5C/fasterxml%5C/classmate%5C/1.7.0%5C/classmate-1.7.0-javadoc.jar%5C!%5C/=/=/maven.groupId=/com.fasterxml=/=/maven.artifactId=/classmate=/=/maven.version=/1.7.0=/=/maven.scope=/compile=/=/maven.pomderived=/true=/%3Ccom.fasterxml.classmate(TypeBindings.class
				if ends_with(className, ".class") then
					filter = string.find(className, "%$") ~= nil
					name = string.format(
						"jdt://contents/%s-%s.jar/%s/%s?=%s/%s=/maven.pomderived=/true%s=/=/maven.groupId=/%s=/=/maven.artifactId=/%s=/=/maven.version=/%s=/=/maven.scope=/compile=/=/maven.pomderived=/true=/%%3C%s(%s",
						artifact_id,
						version,
						packageName,
						className,
						module_artifact_id,
						jar:gsub("/", "%%5C/"),
						java_doc_cmd,
						group_id,
						artifact_id,
						version,
						packageName,
						className
					)
				else
					name = resource_file_prefix .. jar .. "::" .. class
				end
				if not filter then
					local resource = {
						id = name,
						name = className,
						path = name,
						type = "file",
						stat_provider = "maven-custom",
					}
					local parent = dependency
					for _, token in pairs(packageTokens) do
						local selected = nil
						for _, directory in pairs(parent.children) do
							if directory.name == token then
								selected = directory
							end
						end
						if selected == nil then
							selected = {
								id = parent.id .. "." .. token,
								name = token,
								type = "directory",
								children = {},
							}
							table.insert(parent.children, selected)
						end

						parent = selected
					end
					table.insert(parent.children, resource)
				end
			end
		end
	end

	-- local flattening = true
	--
	-- while flattening do
	-- 	local children = dependency.children
	--
	-- 	if #children == 1 and children.children ~= nil and #children.children == 1 then
	-- 		local only_son = children[1]
	-- 		local new_son = children.children[1]
	-- 		new_son.name = only_son.name .. "." .. new_son.name
	-- 		dependency.children = children.children
	-- 	else
	-- 		flattening = false
	-- 	end
	-- end
	--
	if #dependency.children == 0 then
		dependency.children = nil
	end
	return dependency
end
M._explore_children = function(artifact_id, node, neotree_nodes, processed_nodes)
	if node.children then
		for _, child in pairs(node.children) do
			local key = string.format("%s:%s:%s", child.groupId, child.artifactId, child.version)
			local is_sub_module = M.modules_hash_list[key] ~= nil
			local is_processed = processed_nodes[key] ~= nil
			local invalid_scope = node.scope == "test" or node.scope == "provided"
			local discard = is_sub_module or is_processed or invalid_scope

			if not discard then
				local neotree_node =
					render_node(artifact_id, child.groupId, child.artifactId, child.version, child.scope)
				table.insert(neotree_nodes, neotree_node)
				processed_nodes[key] = true

				M._explore_children(artifact_id, child, neotree_nodes, processed_nodes)
			end
		end
	end
end

M.fetch_dependencies = function()
	local dependencies = {}
	local processed = {}
	for _, module in pairs(M.modules) do
		local temp_file_name = os.tmpname()
		vim.fn.system(
			string.format(
				"cd %s && mvn dependency:3.9.0:tree -DoutputType=json -pl :%s -DoutputFile=%s",
				M.config.root_dir,
				module.artifact_id,
				temp_file_name
			)
		)

		local path = Path:new(temp_file_name)
		local module_dependencies = vim.json.decode(path:read())
		M._explore_children(module.artifact_id, module_dependencies, dependencies, processed)

		vim.fn.delete(temp_file_name)
	end
	return dependencies
end

local get_state = function()
	return manager.get_state(M.name)
end
local follow_internal = function()
	if vim.bo.filetype == "neo-tree" or vim.bo.filetype == "neo-tree-popup" then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local path_to_reveal = manager.get_path_to_reveal(true) or tostring(bufnr)

	local state = get_state()
	if state.current_position == "float" then
		return false
	end
	if not state.path then
		return false
	end
	local window_exists = renderer.window_exists(state)
	if window_exists then
		local node = state.tree and state.tree:get_node()
		if node then
			if node:get_id() == path_to_reveal then
				-- already focused
				return false
			end
		end
		renderer.focus_node(state, path_to_reveal, true)
	end
end

M.follow = function()
	local bufname = vim.fn.bufname(0)
	if
		bufname == "COMMIT_EDITMSG"
		or not (vim.startswith(bufname, resource_file_prefix) or vim.startswith(bufname, "jdt://"))
	then
		return false
	end
	utils.debounce("neo-tree-maven-follow", function()
		return follow_internal()
	end, 100, utils.debounce_strategy.CALL_LAST_ONLY)
end

return M
