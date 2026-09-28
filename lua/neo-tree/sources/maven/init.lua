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

-- This module never builds an eclipse.jdt.ls "jdt://" handle-identifier
-- itself: those are opaque, server-owned mementos. Class nodes instead get
-- our own tiny "mvnclass://groupId/artifactId/version/package/Class.class"
-- locator, resolved to a real jdt:// URI on demand via jdtls's own
-- `workspace/symbol` request (see resolve_maven_class below). `node_key`
-- gives both a maven coordinate + package/class tuple and a real jdt://
-- URI (whose maven.* query fields and path segment carry the same info)
-- a common identity to compare against, for both resolving and for
-- "reveal in tree" matching.
local node_key = function(group_id, artifact_id, version, package_name, class_name)
	return table.concat({ group_id, artifact_id, version, package_name, class_name }, "::")
end

local parse_mvnclass_id = function(id)
	if id == nil or not vim.startswith(id, "mvnclass://") then
		return nil
	end
	return id:match("^mvnclass://([^/]+)/([^/]+)/([^/]+)/([^/]+)/(.+)$")
end

local extract_maven_field = function(uri, field)
	return uri:match("maven%." .. field .. "=/([^=]+)")
end

local resolve_key = function(uri)
	if uri == nil then
		return nil
	end
	if vim.startswith(uri, "mvnclass://") then
		local group_id, artifact_id, version, package_name, class_name = parse_mvnclass_id(uri)
		if not group_id then
			return nil
		end
		return node_key(group_id, artifact_id, version, package_name, class_name)
	end
	if vim.startswith(uri, "jdt://") then
		local package_and_class = uri:match("^jdt://contents/[^/]+/(.-)%?")
		local group_id = extract_maven_field(uri, "groupId")
		local artifact_id = extract_maven_field(uri, "artifactId")
		local version = extract_maven_field(uri, "version")
		if not (package_and_class and group_id and artifact_id and version) then
			return nil
		end
		local package_name, class_name = package_and_class:match("^(.-)/([^/]+)$")
		if not package_name then
			return nil
		end
		return node_key(group_id, artifact_id, version, package_name, class_name:gsub("%.java$", ".class"))
	end
	return nil
end

-- Opens a jdt:// URI the way LSP's own jump_to_location does (vim.uri_to_bufnr
-- + bufload + nvim_win_set_buf), NOT `:edit <uri>`: fnameescape (used by
-- neo-tree's own escape_path_for_cmd, meant for real filesystem paths)
-- inserts backslashes before "%" and other punctuation, corrupting the URI
-- text nvim-jdtls forwards verbatim to eclipse.jdt.ls, which then can't
-- resolve it. `bufload` is what actually fires BufReadCmd for a fresh,
-- unloaded custom-scheme buffer.
local open_jdt_uri = function(uri, previous_buf)
	local new_buf = vim.uri_to_bufnr(uri)
	vim.bo[new_buf].buflisted = true
	vim.fn.bufload(new_buf)
	vim.api.nvim_win_set_buf(0, new_buf)
	if previous_buf and previous_buf ~= new_buf and vim.api.nvim_buf_is_valid(previous_buf) then
		pcall(vim.api.nvim_buf_delete, previous_buf, { force = true })
	end
end

local build_id_index = function(items)
	local index = {}
	local function walk(nodes)
		for _, node in pairs(nodes) do
			if node.id and vim.startswith(node.id, "mvnclass://") then
				local key = resolve_key(node.id)
				if key then
					index[key] = node.id
				end
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

local is_windows = function()
	return vim.fn.has("win32") == 1
end

--- Resolves the maven executable: an explicit `mvn_cmd` opt wins, otherwise a
--- wrapper script (mvnw / mvnw.cmd) in the project root is preferred over a
--- bare "mvn" resolved from PATH.
local resolve_mvn_cmd = function(root_dir, opts)
	if opts and opts.mvn_cmd then
		return opts.mvn_cmd
	end
	local wrapper_name = is_windows() and "mvnw.cmd" or "mvnw"
	local wrapper_path = root_dir .. "/" .. wrapper_name
	if vim.fn.filereadable(wrapper_path) == 1 then
		return wrapper_path
	end
	return "mvn"
end

--- Resolves the `jar` executable: an explicit `jar_cmd` opt wins, otherwise
--- prefer $JAVA_HOME/bin/jar (matches the JDK actually driving mvn/jdtls)
--- over a bare "jar" resolved from PATH.
local resolve_jar_cmd = function(opts)
	if opts and opts.jar_cmd then
		return opts.jar_cmd
	end
	local java_home = os.getenv("JAVA_HOME")
	if java_home then
		local bin_name = is_windows() and "jar.exe" or "jar"
		local jar_path = java_home .. "/bin/" .. bin_name
		if vim.fn.executable(jar_path) == 1 then
			return jar_path
		end
	end
	return "jar"
end

local home_dir = function()
	return (vim.uv or vim.loop).os_homedir() or os.getenv("HOME") or os.getenv("USERPROFILE")
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

	local extract_dir = vim.fn.tempname()
	vim.fn.mkdir(extract_dir, "p")
	M._system_async({ M.config.jar_cmd, "xf", vim.fn.fnamemodify(jar, ":p"), resource }, {
		text = true,
		cwd = extract_dir,
	}, function(result)
		if not vim.api.nvim_buf_is_valid(buf) then
			vim.fn.delete(extract_dir, "rf")
			return
		end
		vim.bo[buf].modifiable = true
		if result.code ~= 0 then
			local lines = vim.split("Failed to extract " .. resource .. " from " .. jar .. ":\n" .. (result.stderr or ""), "\n")
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
			vim.bo[buf].modifiable = false
			vim.fn.delete(extract_dir, "rf")
			return
		end

		local source_lines = vim.fn.readfile(extract_dir .. "/" .. resource)
		vim.fn.delete(extract_dir, "rf")
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, source_lines)
		vim.bo[buf].modifiable = false
		vim.bo[buf].readonly = true
	end)
end

-- Resolves a "mvnclass://groupId/artifactId/version/package/Class.class"
-- locator to a real jdt:// URI via `workspace/symbol`, then hands off to
-- jdtls entirely by re-editing that URI. The maven coordinate +
-- package/class are already known exactly (they came from our own
-- dependency tree), so the match must be exact and unambiguous, not a
-- user-facing pick list.
local show_buf_error = function(buf, message)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(message, "\n"))
	vim.bo[buf].modifiable = false
end

local resolve_maven_class = function(group_id, artifact_id, version, package_name, class_name, buf)
	local client = vim.lsp.get_clients({ name = "jdtls" })[1]
	if not client then
		local message = "No active jdtls client to resolve " .. class_name
		vim.notify(message, vim.log.levels.ERROR)
		show_buf_error(buf, message)
		return
	end

	local wanted_key = node_key(group_id, artifact_id, version, package_name, class_name)
	local simple_name = class_name:gsub("%.class$", ""):gsub("^.*%$", "")

	client:request("workspace/symbol", { query = simple_name }, function(err, result)
		if err or not result then
			local message = "workspace/symbol failed for " .. simple_name .. ": " .. vim.inspect(err)
			vim.notify(message, vim.log.levels.ERROR)
			show_buf_error(buf, message)
			return
		end
		for _, symbol in ipairs(result) do
			local uri = symbol.location and symbol.location.uri
			if uri and vim.startswith(uri, "jdt://") and resolve_key(uri) == wanted_key then
				open_jdt_uri(uri, buf)
				return
			end
		end
		local message = "Could not resolve " .. wanted_key .. " via workspace/symbol"
		vim.notify(message, vim.log.levels.ERROR)
		show_buf_error(buf, message)
	end, buf)
end

local open_mvn_class = function(match)
	local group_id, artifact_id, version, package_name, class_name = parse_mvnclass_id(match)
	if not group_id then
		vim.notify("Invalid maven class locator: " .. match, vim.log.levels.ERROR)
		return
	end

	local buf = vim.api.nvim_get_current_buf()
	vim.bo[buf].swapfile = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].buflisted = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Resolving " .. class_name .. " via workspace/symbol..." })
	vim.bo[buf].modifiable = false

	resolve_maven_class(group_id, artifact_id, version, package_name, class_name, buf)
end

-- `M.setup()` runs once, very early — depending on the plugin manager's load
-- timing it can fire before any real buffer exists (e.g. lazy.nvim calling
-- `setup()` ahead of the argument files finishing loading), so detecting
-- `pom.xml` against buffer 0 here can miss the project entirely and leave
-- the source permanently disabled for the session. Re-run detection lazily
-- from `M.navigate`/`M.invalidate` too, against whatever buffer is current
-- at that point, so a late/lazy setup still finds the project once the
-- tree is actually opened.
local ensure_config = function()
	if M.config.enabled then
		return
	end
	local root_dir = vim.fs.root(0, { "pom.xml" })
	if root_dir == nil then
		return
	end
	local project_name = vim.fs.basename(root_dir)
	M.config = {
		enabled = true,
		root_dir = root_dir,
		project_name = project_name,
		maven_dependencies = vim.fn.stdpath("cache") .. "/maven/" .. project_name .. "_dependencies.json",
		m2_repository = home_dir() .. "/.m2/repository/",
		mvn_cmd = resolve_mvn_cmd(root_dir, M._user_opts),
		jar_cmd = resolve_jar_cmd(M._user_opts),
	}
	if not M._invalidate_cmd_created then
		M._invalidate_cmd_created = true
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
end

M.setup = function(opts)
	M._user_opts = opts or {}
	M.config = {
		enabled = false,
	}
	if vim.fn.has("nvim-0.10") == 0 then
		vim.notify("neo-tree-maven-dependencies requires Neovim >= 0.10 (uses vim.system)", vim.log.levels.ERROR)
		return
	end

	ensure_config()

	vim.api.nvim_set_hl(0, "NeoTreeMavenModuleLabel", { link = "@label", default = true })
	vim.api.nvim_set_hl(0, "NeoTreeMavenScopeLabel", { link = "@keyword", default = true })

	local group = vim.api.nvim_create_augroup("maven", {})
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = group,
		pattern = resource_file_prefix .. "*",
		---@param args vim.api.keyset.create_autocmd.callback_args
		callback = function(args)
			open_jar_resource(args.match)
		end,
	})
	vim.api.nvim_create_autocmd("BufReadCmd", {
		group = group,
		pattern = "mvnclass://*",
		---@param args vim.api.keyset.create_autocmd.callback_args
		callback = function(args)
			open_mvn_class(args.match)
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
	ensure_config()
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
		M.config.mvn_cmd,
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

	for _, class in pairs(vim.split(content, "\n")) do
		if class ~= nil and class ~= "" then
			local packageName, className, packageTokens = extract_metadata_from_uri(class)

			if className ~= nil and className ~= "" then
				local name
				local filter = false
				if ends_with(className, ".class") then
					filter = string.find(className, "%$") ~= nil
					name = string.format("mvnclass://%s/%s/%s/%s/%s", group_id, artifact_id, version, packageName, className)
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

	M._system_async({ M.config.jar_cmd, "tf", jar }, { text = true }, function(result)
		if result.code ~= 0 then
			vim.notify(
				string.format("Failed to list jar %s (exit %d): %s", jar, result.code, result.stderr or ""),
				vim.log.levels.WARN
			)
			callback(nil)
			return
		end
		local entries = vim.split(result.stdout or "", "\n")
		table.sort(entries)
		local ok, dependency = pcall(
			build_dependency_tree,
			module_artifact_id,
			group_id,
			artifact_id,
			version,
			scope,
			jar,
			table.concat(entries, "\n")
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
			M.config.mvn_cmd,
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
		local resolved = M._jdt_id_index[resolve_key(path_to_reveal)]
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
		or not (
			vim.startswith(bufname, resource_file_prefix)
			or vim.startswith(bufname, "jdt://")
			or vim.startswith(bufname, "mvnclass://")
		)
	then
		return false
	end
	utils.debounce("neo-tree-maven-follow", function()
		return follow_internal()
	end, 100, utils.debounce_strategy.CALL_LAST_ONLY)
end

return M
