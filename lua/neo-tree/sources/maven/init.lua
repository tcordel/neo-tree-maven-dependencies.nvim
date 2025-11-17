local Path = require("plenary.path")
local M = {
	name = "maven",
}
local resource_file_prefix = "jar://"

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
local explore_jar = function(group_id, artifact_id, version)
	local fqdn = group_id .. ":" .. artifact_id .. ":" .. version
	local dependency = {
		id = fqdn,
		name = fqdn,
		type = "directory",
		stat_provider = "maven-custom",
		children = {},
	}
	local jar_prefix = M.config.m2_reprository
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
		java_doc_cmd = string.format("=/=/javadoc_location=/jar:file:%s", jar_javadoc:gsub("/", "%%5C/"))
	end

	local cmd = "unzip -l " .. jar .. " | awk '{print $4}' "
	local content = vim.fn.system(cmd)

	for _, class in pairs(vim.split(content, "\n")) do
		if class ~= nil and class ~= "" then
			local packageName, className, packageTokens = extract_metadata_from_uri(class)

			if className ~= nil and className ~= "" then
				local name
				-- jdt://contents/classmate-1.7.0.jar/com.fasterxml.classmate/TypeBindings.class?=demo/%5C/home%5C/tib%5C/.m2%5C/repository%5C/com%5C/fasterxml%5C/classmate%5C/1.7.0%5C/classmate-1.7.0.jar=/maven.pomderived=/true=/=/javadoc_location=/jar:file:%5C/home%5C/tib%5C/.m2%5C/repository%5C/com%5C/fasterxml%5C/classmate%5C/1.7.0%5C/classmate-1.7.0-javadoc.jar%5C!%5C/=/=/maven.groupId=/com.fasterxml=/=/maven.artifactId=/classmate=/=/maven.version=/1.7.0=/=/maven.scope=/compile=/=/maven.pomderived=/true=/%3Ccom.fasterxml.classmate(TypeBindings.class
				if ends_with(className, ".class") then
					name = string.format(
						"jdt://contents/%s-%s.jar/%s/%s?=demo/%s=/maven.pomderived=/true%s%%5C!%%5C/=/=/maven.groupId=/%s=/=/maven.artifactId=/%s=/=/maven.version=/%s=/=/maven.scope=/compile=/=/maven.pomderived=/true=/%%3C%s(%s",
						artifact_id,
						version,
						packageName,
						className,
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
		vim.notify("Impossible de lire " .. resource .. " depuis " .. jar, vim.log.levels.ERROR)
		return
	end

	-- charger les lignes
    local normalized = string.gsub(content, '\r\n', '\n')
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
			m2_reprository = os.getenv("HOME") .. "/.m2/repository/",
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
end

M.load_dependencies = function()
	vim.notify("Loading dependencies", vim.log.levels.INFO)
	local temp_file = M.config.maven_dependencies .. ".tmp"
	vim.fn.system(
		"cd "
			.. M.config.root_dir
			.. " && mvn -o dependency:list -DincludeScope=compile -Dsort -DoutputFile="
			.. temp_file
	)

	local f = assert(io.open(temp_file, "rb"))
	local lines = f:lines()
	local items = {}
	for line in lines do
		if string.find(line, "") then
			line = string.gsub(line, "%s*", "")
			local split = vim.split(line, ":")
			local group_id = split[1]
			local artifact_id = split[2]
			local version = split[4]

			local dependency = explore_jar(group_id, artifact_id, version)
			table.insert(items, dependency)
		end
	end
	f:close()
	vim.fn.delete(temp_file)
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

function M.on_enter_directory(state)
	local node = state.tree:get_node()
	vim.notify(node.name, vim.log.levels.WARN)
	if not node or node.type ~= "directory" then
		return
	end

	local path = node:get_id()
	if M.saved_dirs[path] then
		-- Résout les fils automatiquement
		local fs_commands = require("neo-tree.sources.filesystem.commands")
		fs_commands.expand_node(state)
	end
end

return M
