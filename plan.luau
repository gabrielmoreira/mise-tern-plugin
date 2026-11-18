--!nonstrict
-- Action plans: every mutation is described before it runs (spec 5.6). A plan is pure data:
--   { id, verb, title, argv (without the executable), cwd, danger, effects = {text}, where = {{label,value}},
--     dry = { argv }?, target = path? }
-- The store shows the plan, runs `dry` for a prediction, and executes `argv` only after confirmation.

local Plan = {}

-- Quotes one argument for display; the real run never goes through a shell string.
function Plan.quote(arg: string): string
	if arg == "" then return '""' end
	if string.find(arg, "[%s\"'&|<>()^]") then
		return '"' .. string.gsub(arg, '"', '\\"') .. '"'
	end
	return arg
end

function Plan.command_text(exe: string?, argv: { string }): string
	local out = { Plan.quote(exe and (string.match(exe, "([^/\\]+)$") or exe) or "mise") }
	for _, a in argv do table.insert(out, Plan.quote(a)) end
	return table.concat(out, " ")
end

local function with_dry(argv: { string }, flag: string): { string }
	local out = {}
	local inserted = false
	for _, a in argv do
		table.insert(out, a)
		if not inserted then
			table.insert(out, flag)
			inserted = true
		end
	end
	return out
end

local function dry_of(argv: { string }, supported: boolean?): any
	if not supported then return nil end
	return { argv = with_dry(argv, "--dry-run") }
end

-- Install what the configs here request but is not installed yet, or the named requests.
function Plan.install(cwd: string, tools: { string }?, caps: any): any
	local argv = { "install" }
	for _, t in tools or {} do table.insert(argv, t) end
	return {
		id = "install", verb = "Install", cwd = cwd, argv = argv,
		title = if tools and #tools > 0 then ("Install " .. table.concat(tools, ", ")) else "Install missing tools",
		effects = {
			"Downloads and installs into mise's install directory.",
			"Does not change any config file.",
		},
		where = { { "Folder", cwd } },
		dry = dry_of(argv, caps and caps.install_dry_run),
	}
end

-- Add a request to a config with `mise use`. target = "project" | "global".
function Plan.use(cwd: string, spec: string, target: string, opts: any, caps: any): any
	opts = opts or {}
	local argv = { "use" }
	if target == "global" then table.insert(argv, "--global") end
	if opts.path then
		table.insert(argv, "--path")
		table.insert(argv, opts.path)
	end
	if opts.pin and caps and caps.use_pin then table.insert(argv, "--pin") end
	table.insert(argv, spec)
	return {
		id = "use", verb = "Add", cwd = cwd, argv = argv,
		title = "Add " .. spec .. (if target == "global" then " globally" else " to this project"),
		effects = {
			"Installs the tool if it is missing.",
			if target == "global" then "Writes the global config." else "Writes the project's mise.toml in this folder.",
		},
		where = { { "Folder", cwd }, { "Writes to", if target == "global" then "global config" else "project config (confirm below)" } },
		dry = dry_of(argv, caps and caps.use_dry_run),
		target_kind = target,
		spec = spec,
	}
end

-- Upgrade named tools (or all in scope). keep_old adds --no-prune.
function Plan.upgrade(cwd: string, tools: { string }, opts: any, caps: any): any
	opts = opts or {}
	local argv = { "upgrade" }
	if opts.bump then table.insert(argv, "--bump") end
	if opts.keep_old and caps and caps.upgrade_no_prune then table.insert(argv, "--no-prune") end
	if opts.min_age and caps and caps.upgrade_min_age then
		table.insert(argv, "--minimum-release-age")
		table.insert(argv, opts.min_age)
	end
	for _, t in tools do table.insert(argv, t) end
	local n = #tools
	local effects = {
		"Installs the newer version of each selected tool.",
		if opts.bump then "Rewrites the requested versions in the config files that declare them." else "Keeps each request as written; only the installed version moves.",
	}
	if opts.keep_old then
		table.insert(effects, "Keeps the replaced versions installed (--no-prune).")
	else
		table.insert(effects, "The replaced version is removed after the upgrade.prune_after grace period unless a config still uses it.")
	end
	if opts.min_age then table.insert(effects, "Uses a release age of " .. opts.min_age .. " for this run only; no setting is written.") end
	return {
		id = "upgrade", verb = "Upgrade", cwd = cwd, argv = argv,
		title = "Upgrade " .. tostring(n) .. (if n == 1 then " tool" else " tools"),
		effects = effects,
		where = { { "Folder", cwd }, { "Tools", table.concat(tools, ", ") } },
		dry = dry_of(argv, caps and caps.upgrade_dry_run),
	}
end

-- Remove a request from one config file; installed files stay.
function Plan.unuse(cwd: string, tool: string, request: string, path: string, caps: any): any
	local spec = tool .. "@" .. request
	local argv = { "unuse" }
	if caps and caps.unuse_no_prune then table.insert(argv, "--no-prune") end
	table.insert(argv, "--path")
	table.insert(argv, path)
	table.insert(argv, spec)
	return {
		id = "unuse", verb = "Remove", cwd = cwd, argv = argv,
		title = "Remove " .. spec .. " from configuration",
		effects = { "Edits " .. path .. ".", "Keeps the installed files.", "Another config may now win; the list refreshes afterwards." },
		where = { { "Config file", path }, { "Request", spec } },
		target = path,
	}
end

-- Uninstall exactly one installed version.
function Plan.uninstall(cwd: string, tool: string, version: string, caps: any): any
	local argv = { "uninstall", tool .. "@" .. version }
	return {
		id = "uninstall", verb = "Uninstall", cwd = cwd, argv = argv, danger = true,
		title = "Uninstall " .. tool .. " " .. version,
		effects = { "Deletes this installed version from disk.", "Does not edit any config file.", "Other projects that request it will see it as missing." },
		where = { { "Version", tool .. "@" .. version } },
		dry = dry_of(argv, caps and caps.uninstall_dry_run),
	}
end

function Plan.trust(cwd: string, path: string): any
	return {
		id = "trust", verb = "Trust", cwd = cwd, argv = { "trust", path },
		title = "Trust " .. (string.match(path, "([^/\\]+)$") or path),
		effects = { "Marks this config as trusted so mise may run its hooks and templates.", "Review the file first (Open definition)." },
		where = { { "Config file", path } },
		target = path,
	}
end

-- Prune unused tool versions only (never `--configs`: that forgets tracked config paths).
function Plan.prune(cwd: string, caps: any): any
	local argv = { "prune", "--tools" }
	return {
		id = "prune", verb = "Prune", cwd = cwd, argv = argv, danger = true,
		title = "Prune unused versions",
		effects = { "Deletes installed versions that no tracked config requests.", "Leaves tracked config files alone." },
		where = { { "Folder", cwd } },
		dry = dry_of(argv, caps and caps.prune_dry_run),
	}
end

-- Persist a mise setting in the global config.
function Plan.setting(cwd: string, key: string, value: string): any
	return {
		id = "setting", verb = "Save", cwd = cwd, argv = { "settings", "set", key, value },
		title = "Set " .. key .. " to " .. value,
		effects = { "Writes the global mise config.", "Installs and upgrades nothing." },
		where = { { "Setting", key }, { "New value", value } },
	}
end

function Plan.setting_unset(cwd: string, key: string): any
	return {
		id = "setting", verb = "Reset", cwd = cwd, argv = { "settings", "unset", key },
		title = "Use inherited value for " .. key,
		effects = { "Removes the key from the global mise config.", "mise falls back to its built-in value." },
		where = { { "Setting", key } },
	}
end

-- `mise tasks add`: writes a [tasks.<name>] table to the nearest config (or a script with `as_file`).
-- `typed` is { values = {key -> text}, bools = {key -> bool} } as the form holds it.
function Plan.task_add(cwd: string, name: string, typed: any, as_file: boolean, split_list: (string) -> { string }): any
	local argv = { "tasks", "add" }
	local v, b = typed.values or {}, typed.bools or {}
	local function flag(name_: string, text: string?)
		if text and text ~= "" then
			table.insert(argv, name_)
			table.insert(argv, text)
		end
	end
	flag("--description", v.description)
	for _, d in split_list(v.depends or "") do flag("--depends", d) end
	for _, d in split_list(v.depends_post or "") do flag("--depends-post", d) end
	for _, d in split_list(v.wait_for or "") do flag("--wait-for", d) end
	flag("--dir", v.dir)
	for _, a in split_list(v.alias or "") do flag("--alias", a) end
	for _, s in split_list(v.sources or "") do flag("--sources", s) end
	for _, s in split_list(v.outputs or "") do flag("--outputs", s) end
	flag("--shell", v.shell)
	if not as_file then flag("--run-windows", v.run_windows) end
	if b.hide then table.insert(argv, "--hide") end
	if b.quiet then table.insert(argv, "--quiet") end
	if b.silent then table.insert(argv, "--silent") end
	if b.raw then table.insert(argv, "--raw") end
	if as_file then table.insert(argv, "--file") end
	table.insert(argv, name)
	if v.run and v.run ~= "" then
		table.insert(argv, "--")
		table.insert(argv, v.run)
	end
	return {
		id = "task_add", verb = "Create", cwd = cwd, argv = argv,
		title = "Create task " .. name,
		effects = if as_file then {
			"Creates an executable script in the project's task directory.",
			"Does not change any config file.",
		} else {
			"mise writes a [tasks." .. name .. "] table to the nearest project config and marks that file as trusted.",
			"Nothing is run.",
		},
		where = { { "Folder", cwd }, { "Task", name } },
	}
end

-- A direct edit of the lines that define a task. mise has no non-interactive task edit, so the plugin rewrites the
-- file itself, then asks mise to read it back and restores the file if mise cannot.
-- kind: "create" (appends a table; before_text is "" for a file that does not exist yet), "edit" or "delete".
function Plan.file_edit(cwd: string, path: string, name: string, kind: string, before_text: string, after_text: string, diff: { string }, new_file: boolean?): any
	local deleting = kind == "delete"
	local file = string.match(path, "([^/\\]+)$") or path
	local effects
	if kind == "create" then
		effects = {
			if new_file then "Creates " .. file .. " in this folder and trusts it." else "Appends the table shown below to the end of " .. file .. ". Nothing else in the file changes.",
			"mise reads the file back afterwards; if it cannot, the file is restored.",
			"Nothing is run.",
		}
	else
		effects = {
			"Rewrites only the lines shown below in " .. file .. ". Comments, other keys and other tables stay as they are.",
			"mise reads the file back afterwards; if it cannot, the file is restored.",
		}
	end
	return {
		id = "task_" .. kind, verb = if deleting then "Delete" elseif kind == "create" then "Create" else "Save", cwd = cwd, argv = {}, danger = deleting,
		display = (if deleting then "delete [tasks." elseif kind == "create" then "add [tasks." else "edit [tasks.") .. name .. "] in " .. path,
		title = (if deleting then "Delete task " elseif kind == "create" then "Create task " else "Save task ") .. name,
		effects = effects,
		where = { { "File", path }, { "Task", name } },
		file_edit = { path = path, name = name, kind = kind, before = before_text, after = after_text, diff = diff, new_file = new_file },
	}
end

-- The file a dry run says it would write: "mise would update <path> (add: x)".
function Plan.parse_dry_target(text: string): string?
	return string.match(text, "would update (.-) %(") or string.match(text, "would update ([^\r\n]+)")
end

-- Guards for uninstall: `rows` are the tool's records in the current merged view.
function Plan.uninstall_guard(rows: { any }, tool: string, version: string): string?
	for _, r in rows do
		if r.tool == tool and r.version == version and r.active and r.source_path then
			return "This version is active here (requested by " .. (string.match(r.source_path, "([^/\\]+)$") or r.source_path) .. "). Remove the request first or change it."
		end
	end
	return nil
end

return Plan
