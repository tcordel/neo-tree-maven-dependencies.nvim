local Path = require("plenary.path")
local utils = require("neo-tree.utils")
local manager = require("neo-tree.sources.manager")
local events = require("neo-tree.events")
local renderer = require("neo-tree.ui.renderer")
local M = {
	name = "maven",
}
local resource_file_prefix = "jar://"

local loading_node = {
	id = "__maven_loading__",
	name = "Loading Maven dependencies...",
	type = "file",
	stat_provider = "maven-custom",
}
M.loading_node = loading_node

local error_node = function(message)
	return {
		id = "__maven_error__",
		name = message,
		type = "file",
		stat_provider = "maven-custom",
	}
end
M.error_node = error_node

local get_state = function()
	return manager.get_state(M.name)
end

-- jdt:// ids embed the reactor module that first claimed the dependency
-- (eg. "?=eie-agent-service/..."), but a class opened via jdtls's own
-- go-to-definition may resolve through a *different* module that also
-- depends on the same jar, producing a URI that differs only in that
-- segment. Strip it so the two can be matched for "reveal in tree".
local normalize_jdt_id = function(id)
	if id == nil then
		return id
	end
	return (id:gsub("^(jdt://[^?]*%?=)[^/]+/", "%1"))
end

local build_id_index = function(items)
	local index = {}
	local function walk(nodes)
		for _, node in pairs(nodes) do
			if node.id and vim.startswith(node.id, "jdt://") then
				index[normalize_jdt_id(node.id)] = node.id
			end
			if node.children then
				walk(node.children)
			end
		end
	end
	walk(items)
	return index
end

local has_notify = function()
	local ok = pcall(require, "notify")
	return ok
end

M._progress = function(message, level)
	level = level or vim.log.levels.INFO
	if has_notify() then
		M._notif = vim.notify(message, level, {
			title = "Maven dependencies",
			replace = M._notif and M._notif.id,
		})
	else
		vim.notify(message, level, { title = "Maven dependencies" })
	end
end

--- Runs a command asynchronously and invokes callback(result) on the main loop.
--- `cmd` is an argv table (preferred) or a table already shaped for vim.system.
M._system_async = function(cmd, opts, callback)
	vim.system(cmd, opts, function(result)
		vim.schedule(function()
			callback(result)
		end)
	end)
end

local register = function(state, callback)
	if M.config.enabled == false then
		callback({})
		return
	end
	local deps = Path:new(M.config.maven_dependencies)
	if deps:exists() then
		local ok, items_data = pcall(function()
			return deps:read()
		end)
		local decoded
		if ok then
			ok, decoded = pcall(vim.json.decode, items_data)
		end
		if not ok then
			vim.notify("Maven dependencies cache is corrupted, reloading", vim.log.levels.WARN)
			renderer.show_nodes({ loading_node }, state)
			M.load_dependencies(callback)
			return
		end
		callback(decoded)
		return
	end
	renderer.show_nodes({ loading_node }, state)
	M.load_dependencies(callback)
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

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Loading..." })
	vim.bo[buf].modifiable = false

	M._system_async({ "sh", "-c", "unzip -p " .. vim.fn.shellescape(jar) .. " " .. vim.fn.shellescape(resource) }, {
		text = true,
	}, function(result)
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.bo[buf].modifiable = true
		if result.code ~= 0 then
			local lines = vim.split("Failed to extract " .. resource .. " from " .. jar .. ":\n" .. (result.stderr or ""), "\n")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].modifiable = false
			return
		end

		local content = result.stdout or ""
		local normalized = string.gsub(content, "\r\n", "\n")
		local source_lines = vim.split(normalized, "\n", { plain = true })
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, source_lines)
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
	end)
end

M.setup = function()
	M.config = {
		enabled = false,
	}
	if vim.fn.has("nvim-0.10") == 0 then
		vim.notify("neo-tree-maven-dependencies requires Neovim >= 0.10 (uses vim.system)", vim.log.levels.ERROR)
		return
	end
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
			local state = get_state()
			if state and state.tree then
				renderer.show_nodes({ loading_node }, state)
			end
			M.load_dependencies(function(items)
				if items == nil then
					if state and state.tree then
						renderer.show_nodes({ error_node("Failed to load dependencies (see :messages)") }, state)
					end
					return
				end
				manager.refresh("maven", state)
			end)
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

M.load_dependencies = function(on_done)
	on_done = on_done or function() end
	if M._loading then
		return
	end
	M._loading = true
	M._notif = nil
	M._progress("Listing project modules...")

	M.init_project_modules(function(ok)
		if not ok then
			M._loading = false
			M._progress("Failed to list project modules", vim.log.levels.ERROR)
			on_done(nil)
			return
		end

		M.fetch_dependencies(function(items)
			table.sort(items, function(a, b)
				return a.id < b.id
			end)
			local deps = Path:new(M.config.maven_dependencies)
			deps:parent():mkdir({ parents = true, exists_ok = true })
			deps:write(vim.json.encode(items), "w")
			M._loading = false
			M._progress("Dependencies loaded")
			on_done(items)
		end)
	end)
end

M.navigate = function(state, path)
	if path == nil then
		path = vim.fn.getcwd()
	end
	state.path = path
	register(state, function(items)
		if items == nil then
			renderer.show_nodes({ error_node("Failed to load dependencies (see :messages)") }, state)
			return
		end
		M._jdt_id_index = build_id_index(items)
		renderer.show_nodes(items, state)
	end)
end

M.init_project_modules = function(callback)
	M._system_async({
		"mvn",
		"-Dexec.executable=echo",
		"-Dexec.args=${project.groupId}:${project.artifactId}:${project.version}",
		"org.codehaus.mojo:exec-maven-plugin:1.6.0:exec",
		"-q",
		"-o",
	}, { cwd = M.config.root_dir, text = true }, function(result)
		if result.code ~= 0 then
			vim.notify(
				string.format(
					"mvn exec:exec failed (exit %d):\n%s\n%s",
					result.code,
					result.stdout or "",
					result.stderr or ""
				),
				vim.log.levels.ERROR
			)
			callback(false)
			return
		end

		M.modules = {}
		M.modules_hash_list = {}

		for _, line in pairs(vim.split(result.stdout or "", "\n")) do
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
		callback(true)
	end)
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

local build_dependency_tree = function(module_artifact_id, group_id, artifact_id, version, scope, jar, content)
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

	local jar_javadoc = jar:gsub("%.jar$", "-javadoc.jar")
	local javadoc_present = Path.new(jar_javadoc):exists()
	local java_doc_cmd = ""
	if javadoc_present == true then
		java_doc_cmd = string.format("=/=/javadoc_location=/jar:file:%s%%5C!%%5C/", jar_javadoc:gsub("/", "%%5C/"))
	end

	for _, class in pairs(vim.split(content, "\n")) do
		if class ~= nil and class ~= "" then
			local packageName, className, packageTokens = extract_metadata_from_uri(class)

			if className ~= nil and className ~= "" then
				local name
				local filter = false
				if ends_with(className, ".class") then
					filter = string.find(className, "%$") ~= nil
					local javaName = className:sub(0, -7)
					name = string.format(
						"jdt://contents/%s-%s.jar/%s/%s?=%s/%s=/maven.pomderived=/true%s=/=/maven.groupId=/%s=/=/maven.artifactId=/%s=/=/maven.version=/%s=/=/maven.scope=/compile=/=/maven.pomderived=/true=/%%3C%s%%28%s",
						artifact_id,
						version,
						packageName,
						javaName .. ".java",
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

	if #dependency.children == 0 then
		dependency.children = nil
	end
	return dependency
end

local render_node = function(module_artifact_id, group_id, artifact_id, version, scope, callback)
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

	local cmd = "unzip -l "
		.. vim.fn.shellescape(jar)
		.. ' | tail -n +4 | head -n -2 | awk \'{for (i=4; i<=NF; i++) { printf("%s%s",( (i>4) ? " " : "" ), $i) } print ""}\' | sort'

	M._system_async({ "sh", "-c", cmd }, { text = true }, function(result)
		if result.code ~= 0 then
			vim.notify(
				string.format("Failed to list jar %s (exit %d): %s", jar, result.code, result.stderr or ""),
				vim.log.levels.WARN
			)
			callback(nil)
			return
		end
		local ok, dependency = pcall(
			build_dependency_tree,
			module_artifact_id,
			group_id,
			artifact_id,
			version,
			scope,
			jar,
			result.stdout or ""
		)
		if not ok then
			vim.notify("Failed to build dependency tree for " .. jar .. ": " .. tostring(dependency), vim.log.levels.WARN)
			callback(nil)
			return
		end
		callback(dependency)
	end)
end

M._explore_children = function(artifact_id, node, neotree_nodes, processed_nodes, callback)
	local pending_calls = {}

	local function collect(current_node)
		if current_node.children then
			for _, child in pairs(current_node.children) do
				local key = string.format("%s:%s:%s", child.groupId, child.artifactId, child.version)
				local is_sub_module = M.modules_hash_list[key] ~= nil
				local is_processed = processed_nodes[key] ~= nil
				local invalid_scope = current_node.scope == "test" or current_node.scope == "provided"
				local discard = is_sub_module or is_processed or invalid_scope

				if not discard then
					processed_nodes[key] = true
					table.insert(pending_calls, {
						group_id = child.groupId,
						artifact_id = child.artifactId,
						version = child.version,
						scope = child.scope,
					})
					collect(child)
				end
			end
		end
	end
	collect(node)

	local total = #pending_calls
	if total == 0 then
		callback(neotree_nodes)
		return
	end

	local remaining = total
	local report_step = math.max(1, math.floor(total / 10))
	for _, call in ipairs(pending_calls) do
		render_node(artifact_id, call.group_id, call.artifact_id, call.version, call.scope, function(dependency)
			if dependency ~= nil then
				table.insert(neotree_nodes, dependency)
			end
			remaining = remaining - 1
			local done = total - remaining
			if done % report_step == 0 or remaining == 0 then
				M._progress(string.format("Indexing jars (%d/%d)...", done, total))
			end
			if remaining == 0 then
				callback(neotree_nodes)
			end
		end)
	end
end

M.fetch_dependencies = function(callback)
	local dependencies = {}
	local processed = {}
	local total_modules = #M.modules

	local function process_module(index)
		if index > total_modules then
			callback(dependencies)
			return
		end

		local module = M.modules[index]
		M._progress(
			string.format("Resolving dependencies (module %d/%d: %s)...", index, total_modules, module.artifact_id)
		)

		local temp_file_name = os.tmpname()
		M._system_async({
			"mvn",
			"dependency:3.9.0:tree",
			"-DoutputType=json",
			"-pl",
			":" .. module.artifact_id,
			"-DoutputFile=" .. temp_file_name,
		}, { cwd = M.config.root_dir, text = true }, function(result)
			if result.code ~= 0 then
				vim.notify(
					string.format(
						"mvn dependency:tree failed for %s (exit %d):\n%s\n%s",
						module.artifact_id,
						result.code,
						result.stdout or "",
						result.stderr or ""
					),
					vim.log.levels.WARN
				)
				vim.fn.delete(temp_file_name)
				process_module(index + 1)
				return
			end

			local ok, module_dependencies = pcall(function()
				return vim.json.decode(Path:new(temp_file_name):read())
			end)
			vim.fn.delete(temp_file_name)
			if not ok then
				vim.notify("Failed to parse dependency tree for " .. module.artifact_id, vim.log.levels.WARN)
				process_module(index + 1)
				return
			end

			M._explore_children(module.artifact_id, module_dependencies, dependencies, processed, function()
				process_module(index + 1)
			end)
		end)
	end

	process_module(1)
end

local follow_internal = function()
	if vim.bo.filetype == "neo-tree" or vim.bo.filetype == "neo-tree-popup" then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local path_to_reveal = manager.get_path_to_reveal(true) or tostring(bufnr)
	if M._jdt_id_index then
		local resolved = M._jdt_id_index[normalize_jdt_id(path_to_reveal)]
		if resolved then
			path_to_reveal = resolved
		end
	end

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
