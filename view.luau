--!nonstrict
-- Node trees for the mise block. A fixed header (title, scope, tabs, filter, alerts) sits above one scrolling
-- body. The host hands in native inputs (`opts.filter`, `opts.task_filter`, dialog fields) so this file stays a
-- pure function of the store. Every click is an action `name` or `name=value`; Tern splits `=` into act/value.

local Store = require("./store")
local Model = require("./model")
local Plan = require("./plan")
local Locate = require("./locate")
local Redaction = require("./redaction")
local Cli = require("./misecli")
local Tasks = require("./tasks")

local ui = tern.ui
local View = {}

local MAX_ROWS = 200

local function role(name: string): string
	return "mise." .. name
end

local function with(node, props)
	local p = node.p or {}
	for k, v in props do p[k] = v end
	node.p = p
	return node
end

local function button(text: string, action: string?, props)
	local p = { actions = { click = action }, size = "sm", role = if action then role("btn:" .. action) else nil }
	for k, v in props or {} do p[k] = v end
	return ui.button(text, p)
end

local function hint(text: string)
	return with(ui.text(ui.span(text, "muted")), { role = role("hint") })
end

local function bounded(text: string?, limit: number): string
	local v = tostring(text or "")
	local n = utf8.len(v)
	if n == nil or n <= limit then return v end
	return string.sub(v, 1, (utf8.offset(v, limit + 1) :: number) - 1) .. "…"
end

local function base(path: string?): string
	return Model.basename(path)
end

local TONE = { ok = "success", warn = "warning", accent = "accent", muted = "muted", error = "error" }

local function badge(b)
	return ui.badge(b.text, TONE[b.tone] or b.tone)
end

local function mono(text: string)
	return ui.text(ui.span(text, "mono"))
end

local function ago(at: number?): string
	if not at then return "" end
	local d = os.time() - at
	if d < 5 then return "just now" end
	if d < 90 then return tostring(d) .. " s ago" end
	if d < 5400 then return tostring(math.floor(d / 60 + 0.5)) .. " min ago" end
	return os.date("%H:%M", at)
end

-- Errors ---------------------------------------------------------------------------------------------------------

local ERROR_TITLE = {
	NOT_FOUND = "mise was not found",
	TIMEOUT = "mise took too long",
	BAD_OUTPUT = "mise printed something unexpected",
	UNTRUSTED_CONFIG = "A config file is not trusted",
	TOOL_NOT_FOUND = "mise does not know that tool",
	NETWORK = "mise could not reach the network",
}

local function error_text(e): string
	local lines = { ERROR_TITLE[e.code] or "mise failed", "Code: " .. tostring(e.code), tostring(e.message or "") }
	if e.stderr_tail and e.stderr_tail ~= "" then table.insert(lines, Redaction.text(e.stderr_tail)) end
	return Redaction.text(table.concat(lines, "\n"))
end

local function error_card(e, key: string, extra)
	local body = { ui.text(Redaction.text(e.message or "The operation failed.")) }
	if e.stderr_tail and e.stderr_tail ~= "" then table.insert(body, ui.code(Redaction.text(e.stderr_tail))) end
	local actions = { button("Copy details", "copy=" .. error_text(e), { variant = "quiet", icon = "copy" }) }
	for _, a in extra or {} do table.insert(actions, a) end
	table.insert(body, ui.row(actions))
	return with(ui.card({ ui.span(ERROR_TITLE[e.code] or "mise failed", "strong") }, body, { icon = "warn", meta = { ui.span(tostring(e.code), "muted") } }), { key = key, tone = "error" })
end

-- Header ---------------------------------------------------------------------------------------------------------

local TABS = {
	{ "Tools", "tools" }, { "Tasks", "tasks" },
}
local MORE = { { "Overview", "overview" }, { "Config", "config" }, { "Activity", "activity" }, { "Settings", "settings" } }

local function toolbar(S)
	local folder = if S.cwd then base(S.cwd) else "no folder"
	local title = with(ui.badge(folder, if S.cwd then "accent" else "muted"), {
		title = (S.cwd or "No terminal is focused") .. (if S.pinned_cwd then "" else "\nFollows the focused terminal"),
		key = "folder",
	})
	local tools = ui.row({
		button("", "refresh", { icon = "refresh", variant = "quiet", title = "Read from mise again", key = "refresh" }),
		button("Add", "add", { icon = "plus", variant = "primary", title = "Add a tool to this project or globally", key = "add",
			disabled = if S.setup.status ~= "ok" then "mise is not available" else nil }),
	})
	local bar = with(ui.row({ with(ui.row({ title }), { role = role("title") }), with(tools, { role = role("tools") }) }), { role = role("bar"), key = "bar" })
	local nav = {}
	for _, t in TABS do
		table.insert(nav, button(t[1], "tab=" .. t[2], { variant = "quiet", on = S.tab == t[2], key = "tab-" .. t[2] }))
	end
	table.insert(nav, button("More", "more", { variant = "quiet", icon = if S.more then "chevron-down" else "chevron-right", on = S.more, key = "tab-more" }))
	local kids = { bar, with(ui.row(nav), { role = role("nav"), key = "nav" }) }
	if S.more then
		local more = {}
		for _, t in MORE do
			table.insert(more, button(t[1], "tab=" .. t[2], { variant = "quiet", on = S.tab == t[2], key = "tab-" .. t[2] }))
		end
		table.insert(kids, with(ui.row(more), { role = role("nav"), key = "nav2" }))
	end
	if S.tab == "tools" then
		local seg = {}
		for _, s in { { "Merged", "merged" }, { "Global", "global" }, { "Local", "local" } } do
			table.insert(seg, button(s[1], "scope=" .. s[2], { on = S.scope == s[2], variant = if S.scope == s[2] then "primary" else "default", key = "scope-" .. s[2] }))
		end
		table.insert(kids, with(ui.row(seg), { role = role("scope"), key = "scope" }))
	end
	return with(ui.col(kids), { role = role("header"), key = "header" })
end

-- Alerts: setup state, drift, untrusted, running change ------------------------------------------------------------

local function alerts(S)
	local out = {}
	if S.setup.status == "loading" then
		table.insert(out, with(ui.progress(nil, "Looking for mise…"), { key = "setup" }))
	elseif S.setup.status == "missing" then
		local steps = {}
		for _, st in (S.setup.info and S.setup.info.steps) or {} do
			table.insert(steps, { ui.span(tostring(st.label or st.where or st[1] or ""), "muted"), ui.span(tostring(st.result or st.status or st[2] or ""), "mono") })
		end
		local body = { ui.text("The plugin runs mise to read and change your tools. It looked here and found nothing:") }
		if #steps > 0 then table.insert(body, ui.kv(steps)) end
		table.insert(body, ui.row({ button("Choose mise…", "exe.choose", { variant = "primary", icon = "folder" }), button("Try again", "refresh", { variant = "quiet" }) }))
		table.insert(out, with(ui.card({ ui.span("mise was not found", "strong") }, body, { icon = "warn" }), { key = "missing", tone = "warning" }))
	end
	if S.drift and #S.drift > 0 and tern.kv.get("mise.driftHidden") ~= Store.drift_signature(S) then
		local rows = {}
		for _, d in S.drift do
			table.insert(rows, { ui.span(d.name, "mono"), ui.span((d.live or "unset here") .. "  ←  saved: " .. d.saved, "muted") })
		end
		table.insert(out, with(ui.card({ ui.span("Environment differs from your saved settings", "strong") }, {
			ui.text("These variables are saved for your user but Tern was started without them, so mise here may look in other folders than your shell does. Restart Tern after changing them."),
			ui.kv(rows),
			ui.row({ button("Hide until it changes", "drift.hide", { variant = "quiet", key = "drift-hide", title = "Shown again if the saved values change" }) }),
		}, { icon = "warn" }), { key = "drift", tone = "warning" }))
	end
	if S.untrusted then
		local path = if type(S.untrusted) == "string" then S.untrusted else nil
		local body = { ui.text(if path then ("mise will not read " .. path .. " until you trust it.") else "mise refused to read a config file here until you trust it.") }
		local acts = {}
		if path then
			table.insert(acts, button("Open file", "open=" .. path, { icon = "file", variant = "quiet" }))
			table.insert(acts, button("Trust…", "trust=" .. path, { variant = "primary" }))
		end
		table.insert(body, ui.row(acts))
		table.insert(out, with(ui.card({ ui.span("Untrusted config", "strong") }, body, { icon = "warn" }), { key = "untrusted", tone = "warning" }))
	end
	if S.running then
		table.insert(out, with(ui.progress(nil, S.running.plan.title .. "…"), { key = "running" }))
	end
	return out
end

-- Tools ----------------------------------------------------------------------------------------------------------

local function source_chip(row, scope: string): string?
	if scope == "merged" and row.winner then return row.winner end
	return nil
end

local function tool_row(S, row, scope: string)
	local selected = S.selected == row.id
	local cursor = S.cursor == row.id
	local mark = if cursor and selected then "row-cursor-selected" elseif cursor then "row-cursor" elseif selected then "row-selected" else "row"
	local ver = if row.installed then row.version elseif row.requested then row.requested else row.version
	local top = ui.row({
		with(ui.row({
			with(ui.text(ui.span(bounded(row.tool, 36), "strong")), { role = role("name") }),
			with(ui.text(ui.span(ver, "mono")), { role = role("ver") }),
		}), { role = role("row-title") }),
		with(ui.row({ ui.badge(row.status.text, TONE[row.status.tone] or row.status.tone) }), { role = role("row-badges") }),
	})
	local sub = {}
	if row.not_requested then
		table.insert(sub, "installed, not requested by a config here")
	else
		if row.requested and row.requested ~= row.version then table.insert(sub, "requests " .. row.requested) end
		table.insert(sub, Store.where_label(S, row.source_path))
	end
	if row.update_to then table.insert(sub, "→ " .. row.update_to) end
	local kids = { with(top, { role = role("row-top") }), with(ui.text(ui.span(table.concat(sub, " · "), "muted")), { role = role("row-sub") }) }
	local chips = {}
	local chip = source_chip(row, scope)
	if chip then table.insert(chips, ui.badge(chip, "muted")) end
	for _, b in row.merge_badges or {} do table.insert(chips, badge(b)) end
	if #chips > 0 then table.insert(kids, with(ui.row(chips), { role = role("row-chips") })) end
	if selected then
		local facts = {}
		if row.requested then table.insert(facts, { ui.span("Requested", "muted"), ui.span(row.requested) }) end
		if row.global_request then table.insert(facts, { ui.span("Global request", "muted"), ui.span(row.global_request) }) end
		if row.local_request then table.insert(facts, { ui.span("Local request", "muted"), ui.span(row.local_request) }) end
		if row.source_path then table.insert(facts, { ui.span("Config", "muted"), ui.span(row.source_path, "mono") }) end
		if row.install_path then table.insert(facts, { ui.span("Installed at", "muted"), ui.span(row.install_path, "mono") }) end
		if row.bump_to then table.insert(facts, { ui.span("Bump would write", "muted"), ui.span(row.bump_to) }) end
		if #facts > 0 then table.insert(kids, ui.kv(facts)) end
		local acts = {}
		if row.status.text == "Missing" then table.insert(acts, button("Install", "install.missing", { variant = "primary", icon = "download" })) end
		if row.status.text == "Update" then table.insert(acts, button("Upgrade…", "upgrade.review=" .. row.tool, { variant = "primary", icon = "arrow-up" })) end
		if row.source_path then
			table.insert(acts, button("Open definition", "open=" .. row.source_path, { icon = "file", variant = "quiet" }))
			table.insert(acts, button("Copy path", "copy=" .. row.source_path, { icon = "copy", variant = "quiet" }))
		end
		table.insert(acts, button("Remove…", "remove.open=" .. row.id, { variant = "quiet", icon = "trash" }))
		table.insert(kids, ui.row(acts))
	end
	return with(ui.col(kids), { key = "t:" .. row.id, role = role(mark), actions = { click = "select=" .. row.id },
		title = row.tool .. " " .. row.version .. (if row.source_path then "\n" .. row.source_path else "") })
end

local function placeholder_rows(S, key: string, label: string): { any }?
	local d = Store.state(S, key)
	if d.status == "nocwd" then
		return { hint("No folder is in focus. Click a terminal, or use Global.") }
	elseif d.status == "paused" then
		return { hint("Reading is paused."), button("Resume", "pause", { variant = "primary" }) }
	elseif d.status == "error" and d.value == nil then
		local extra = {}
		if d.error.code == "UNTRUSTED_CONFIG" and d.error.untrusted_path then
			table.insert(extra, button("Trust…", "trust=" .. d.error.untrusted_path, { variant = "primary" }))
		end
		table.insert(extra, button("Try again", "refresh", { variant = "quiet" }))
		return { error_card(d.error, "err-" .. key, extra) }
	elseif d.status == "loading" and d.value == nil then
		return { ui.progress(nil, label) }
	elseif d.status == nil or d.status == "idle" then
		return { ui.progress(nil, label) }
	end
	return nil
end

-- Which folder and which config files the chosen scope is about; the same names appear in each row.
local function scope_context(S)
	local rows = {}
	local function row(label: string, value: string, tip: string?)
		table.insert(rows, { ui.span(label, "muted"), ui.span(value, "mono") })
	end
	local gpaths = Store.global_paths(S)
	local configs = Store.data(S, "config") or {}
	local global_files, local_files = {}, {}
	for _, c in configs do
		if gpaths[Model.path_key(c.path, S.windows)] then table.insert(global_files, c.path) else table.insert(local_files, c.path) end
	end
	if S.scope == "global" then
		local paths = {}
		for p in gpaths do table.insert(paths, p) end
		local shown = {}
		for _, r in Store.data(S, "global") or {} do
			if r.source_path and not table.find(shown, r.source_path) then table.insert(shown, r.source_path) end
		end
		if #shown == 0 then
			local predicted = Locate.predicted().config
			row("Global config", predicted .. "/config.toml  (predicted, not created yet)")
		else
			for _, p in shown do row("Global config", p) end
		end
		row("Applies to", "every folder (a project can override it)")
	else
		row("Folder", S.cwd or "none")
		if S.scope == "local" then
			if #local_files == 0 then row("Config files", "none found from here up (a mise.toml is created in this folder on Add)")
			else for i, p in local_files do row(if i == 1 then "Config files" else "", p) end end
			row("Not included", "global config" .. (if #global_files > 0 then ": " .. global_files[1] else ""))
		else
			for i, p in local_files do row(if i == 1 then "Local configs" else "", p) end
			for i, p in global_files do row(if i == 1 then "Global config" else "", p) end
		end
	end
	return with(ui.kv(rows), { key = "scope-context", role = role("scope-context") })
end

local function tools_body(S)
	local scope = S.scope
	local key = if scope == "merged" then "current" else scope
	local early = placeholder_rows(S, key, "Reading " .. scope .. " tools…")
	if early then
		table.insert(early, 1, scope_context(S))
		return early
	end
	local out = { scope_context(S) }
	local d = Store.state(S, key)
	if d.status == "error" then table.insert(out, error_card(d.error, "err-" .. key, { button("Try again", "refresh", { variant = "quiet" }) })) end
	if d.stale and d.status == "loading" then table.insert(out, ui.progress(nil, "Refreshing…")) end
	local rows = Store.tool_rows(S)
	if not rows then return out end
	-- Quick filters
	local missing, updates = 0, 0
	for _, r in rows.requested do
		if r.status.text == "Missing" then missing += 1 elseif r.status.text == "Update" then updates += 1 end
	end
	local chips = {
		button("Missing " .. missing, "status_filter=missing", { on = S.status_filter == "missing", variant = "quiet", key = "f-missing" }),
		button("Updates " .. updates, "status_filter=updates", { on = S.status_filter == "updates", variant = "quiet", key = "f-updates" }),
	}
	if missing > 0 then table.insert(chips, button("Install missing", "install.missing", { icon = "download", variant = "quiet", key = "inst-missing" })) end
	if updates > 0 then table.insert(chips, button("Upgrade…", "upgrade.review", { icon = "arrow-up", variant = "quiet", key = "upg-all" })) end
	table.insert(out, with(ui.row(chips), { role = role("chips"), key = "chips" }))
	local od = Store.state(S, "outdated_" .. scope)
	if od.status == "error" then
		table.insert(out, hint("Could not check for updates: " .. (od.error.message or "") .. (if od.error.code == "NETWORK" then " (offline?)" else "")))
	elseif S.network_reads ~= "on-view" and od.status == nil then
		table.insert(out, ui.row({ hint("Update checks are manual."), button("Check now", "load.outdated", { variant = "quiet" }) }))
	elseif od.status == "loading" then
		table.insert(out, hint("Checking for updates…"))
	end
	if #rows.requested == 0 and #rows.also == 0 then
		table.insert(out, hint(if S.filter ~= "" or S.status_filter then "Nothing matches." else "No tools are requested here. Use Add."))
		return out
	end
	local shown = 0
	if #rows.requested > 0 then
		table.insert(out, with(ui.row({ ui.text({ ui.span("REQUESTED HERE", "muted strong"), ui.span("  " .. #rows.requested, "muted") }) }), { role = role("section"), key = "sec-req" }))
		for _, r in rows.requested do
			shown += 1
			if shown > MAX_ROWS then break end
			table.insert(out, tool_row(S, r, scope))
		end
	end
	if #rows.also > 0 then
		table.insert(out, with(ui.row({ ui.text({ ui.span("ALSO INSTALLED", "muted strong"), ui.span("  " .. #rows.also, "muted") }) }), { role = role("section"), key = "sec-also" }))
		for _, r in rows.also do
			shown += 1
			if shown > MAX_ROWS then break end
			table.insert(out, tool_row(S, r, scope))
		end
	end
	if shown > MAX_ROWS then table.insert(out, hint("Showing the first " .. MAX_ROWS .. ". Filter to narrow.")) end
	local prunable = Store.data(S, "all")
	return out
end

-- Tasks ----------------------------------------------------------------------------------------------------------

local function task_detail(S, t)
	local src = S.task_src
	local kids = {}
	if not src then return kids end
	if src.reason == "script" then
		table.insert(kids, hint("A script file task: " .. tostring(src.path)))
		table.insert(kids, ui.row({ button("Open script", "open=" .. tostring(src.path), { icon = "file", key = "os:" .. t.name }), button("Run…", "task.open=" .. t.name, { variant = "primary", icon = "play", key = "rr:" .. t.name }) }))
		return kids
	elseif src.reason == "inline" then
		table.insert(kids, hint("Written as `" .. t.name .. " = …` under [tasks]. The form cannot edit that shape; edit it in the file."))
		table.insert(kids, ui.row({ button("Open file", "open=" .. tostring(src.path) .. "&line=" .. tostring(src.block.line), { icon = "file", key = "of:" .. t.name }), button("Run…", "task.open=" .. t.name, { variant = "primary", icon = "play", key = "rr:" .. t.name }) }))
		return kids
	elseif src.reason or not src.block then
		table.insert(kids, hint(src.reason or "No source available."))
		return kids
	end
	table.insert(kids, ui.code(table.concat(src.block.lines, "\n"), "toml"))
	table.insert(kids, hint(src.path .. " · line " .. src.block.first))
	table.insert(kids, ui.row({
		button("Run…", "task.open=" .. t.name, { variant = "primary", icon = "play", key = "rr:" .. t.name }),
		button("Edit…", "task.edit=" .. t.name, { icon = "pencil", key = "ed:" .. t.name }),
		button("Edit source", "open=" .. src.path .. "&line=" .. src.block.first, { icon = "file", variant = "quiet", key = "es:" .. t.name }),
		button("Delete…", "task.delete=" .. t.name, { icon = "trash", variant = "quiet", key = "dl:" .. t.name }),
	}))
	return kids
end

local function tasks_body(S)
	local early = placeholder_rows(S, "tasks", "Reading tasks…")
	if early then return early end
	local out = {}
	table.insert(out, ui.row({
		button("New task", "task.new", { icon = "plus", variant = "primary", key = "task-new", disabled = if S.cwd then nil else "No folder is in focus" }),
		hint("Create or edit a task without opening the file."),
	}))
	local list = Store.task_list(S)
	if #list == 0 then
		table.insert(out, hint(if S.task_query ~= "" then "No task matches." else "No tasks are defined in this folder."))
		return out
	end
	local group
	for _, t in list do
		if t.group ~= group then
			group = t.group
			table.insert(out, with(ui.row({ ui.text(ui.span(string.upper(group), "muted strong")) }), { role = role("section"), key = "sec-" .. group }))
		end
		local id = "task:" .. t.name
		local selected = S.selected == id
		local cursor = S.cursor == id
		local mark = if cursor and selected then "row-cursor-selected" elseif cursor then "row-cursor" elseif selected then "row-selected" else "row"
		local full = Store.task(S, t.name) or t
		local kids = {
			with(ui.row({
				with(ui.text(ui.span(t.name, "strong")), { role = role("name") }),
				button("Run…", "task.open=" .. t.name, { variant = "quiet", icon = "play", key = "run:" .. t.name }),
			}), { role = role("row-top") }),
			with(ui.text(ui.span(t.description or base(t.source), "muted")), { role = role("row-sub") }),
		}
		if selected then for _, n in task_detail(S, full) do table.insert(kids, n) end end
		table.insert(out, with(ui.col(kids), { key = id, role = role(mark), actions = { click = "task.select=" .. t.name }, title = t.name .. " · " .. tostring(t.source or "") }))
	end
	return out
end

-- Overview ---------------------------------------------------------------------------------------------------------

local function overview_body(S)
	local out = {}
	local info = S.setup.info
	local stats = Store.stats(S)
	table.insert(out, ui.stats({
		{ label = "Installed", value = tostring(stats.installed) },
		{ label = "Requested here", value = tostring(stats.requested) },
		{ label = "Missing", value = tostring(stats.missing), tone = if stats.missing > 0 then "warning" else nil },
		{ label = "Updates", value = if stats.updates then tostring(stats.updates) else "–" },
	}))
	if info then
		table.insert(out, ui.kv({
			{ ui.span("mise", "muted"), ui.span(tostring(info.version or "?")) },
			{ ui.span("Executable", "muted"), ui.span(tostring(info.path), "mono") },
			{ ui.span("Found via", "muted"), ui.span(tostring(info.source or "")) },
			{ ui.span("Installed with", "muted"), ui.span(tostring(info.method or "unknown")) },
		}))
		table.insert(out, ui.row({ button("Choose a different mise…", "exe.choose", { variant = "quiet", icon = "folder" }), button("Copy path", "copy=" .. tostring(info.path), { variant = "quiet", icon = "copy" }) }))
	end
	local doctor = Store.state(S, "doctor")
	local reported = doctor.value and doctor.value.dirs
	local rows = {}
	for _, r in Locate.directory_rows(reported) do
		local value = { ui.span(tostring(r.value), "mono"), ui.span("  " .. r.source, "muted") }
		table.insert(rows, { ui.span(r.key, "muted"), value })
		if r.predicted then table.insert(rows, { ui.span("", "muted"), { ui.span("predicted " .. r.predicted .. " (differs)", "muted") } }) end
	end
	table.insert(out, with(ui.row({ ui.text(ui.span("FOLDERS", "muted strong")) }), { role = role("section"), key = "sec-dirs" }))
	table.insert(out, ui.kv(rows))
	table.insert(out, with(ui.row({ ui.text(ui.span("HEALTH", "muted strong")), button(if doctor.status == "ok" then "Run again" else "Run mise doctor", "doctor.run", { variant = "quiet", icon = "refresh", busy = doctor.status == "loading" }) }), { role = role("section"), key = "sec-doctor" }))
	if doctor.status == "error" then
		table.insert(out, error_card(doctor.error, "err-doctor"))
	elseif doctor.value then
		local v = doctor.value
		local problems = {}
		for _, e in Model.list(v.errors) do table.insert(problems, { "error", tostring(e) }) end
		for _, w in Model.list(v.warnings) do table.insert(problems, { "warning", tostring(w) }) end
		if #problems == 0 then
			table.insert(out, ui.badge("No problems reported", "success"))
		else
			for i, p in problems do
				table.insert(out, with(ui.card({ ui.span(p[1], "strong") }, { ui.text(Redaction.text(bounded(p[2], 400))) }, { icon = "warn" }), { key = "prob" .. i, tone = if p[1] == "error" then "error" else "warning" }))
			end
		end
		table.insert(out, ui.kv({
			{ ui.span("Activated in a shell", "muted"), ui.span(if v.activated then "yes" else "no") },
			{ ui.span("Shims on PATH", "muted"), ui.span(if v.shims_on_path then "yes" else "no") },
		}))
	else
		table.insert(out, hint("Runs `mise doctor` on demand; it can take a few seconds."))
	end
	table.insert(out, with(ui.row({ ui.text(ui.span("CLEANUP", "muted strong")) }), { role = role("section"), key = "sec-clean" }))
	table.insert(out, ui.row({ button("Prune unused versions…", "prune", { variant = "quiet", icon = "trash" }) }))
	return out
end

-- Config -----------------------------------------------------------------------------------------------------------

local function config_body(S)
	local early = placeholder_rows(S, "config", "Reading the config stack…")
	if early then return early end
	local out = { hint("mise reads these files, nearest first. Later files only fill in what earlier ones leave open.") }
	local list = Store.data(S, "config") or {}
	if #list == 0 then table.insert(out, hint("No config files apply to this folder.")) end
	for i, c in list do
		local tools = {}
		for _, t in c.tools do table.insert(tools, tostring(t)) end
		table.insert(out, with(ui.col({
			with(ui.row({ with(ui.text(ui.span(base(c.path), "strong")), { role = role("name") }), if c.override then ui.badge("override", "accent") else ui.text("") }), { role = role("row-top") }),
			with(ui.text(ui.span(c.path, "muted")), { role = role("row-sub") }),
			with(ui.text(ui.span(if #tools > 0 then table.concat(tools, ", ") else "no tools", "muted")), { role = role("row-sub") }),
			ui.row({ button("Open", "open=" .. c.path, { variant = "quiet", icon = "file" }), button("Copy path", "copy=" .. c.path, { variant = "quiet", icon = "copy" }) }),
		}), { key = "cfg" .. i, role = role("row") }))
	end
	return out
end

-- Activity ---------------------------------------------------------------------------------------------------------

local function activity_body(S)
	local out = {}
	if #S.history == 0 then return { hint("Changes you make with this plugin are listed here, with their output.") } end
	for _, h in S.history do
		local open = S.selected == "h:" .. h.id
		local kids = {
			with(ui.row({
				with(ui.text(ui.span(h.title, "strong")), { role = role("name") }),
				ui.badge(h.status, if h.status == "ok" then "success" else "error"),
			}), { role = role("row-top") }),
			with(ui.text(ui.span(os.date("%Y-%m-%d %H:%M", h.at) .. " · " .. string.format("%.1f s", (h.took_ms or 0) / 1000), "muted")), { role = role("row-sub") }),
		}
		if open then
			table.insert(kids, ui.code(h.argv, "sh"))
			table.insert(kids, ui.kv({ { ui.span("Folder", "muted"), ui.span(tostring(h.cwd), "mono") }, { ui.span("Exit", "muted"), ui.span(tostring(h.exit)) } }))
			if h.output_tail and h.output_tail ~= "" then table.insert(kids, ui.code(h.output_tail)) end
			table.insert(kids, ui.row({ button("Copy command", "copy=" .. h.argv, { variant = "quiet", icon = "copy" }) }))
		end
		table.insert(out, with(ui.col(kids), { key = "h:" .. h.id, role = role(if open then "row-selected" else "row"), actions = { click = "history.open=" .. (if open then "" else "h:" .. h.id) } }))
	end
	return out
end

-- Settings ---------------------------------------------------------------------------------------------------------

View.SETTINGS = { "minimum_release_age", "auto_install", "upgrade.prune_after", "upgrade.auto_prune", "cache_prune_age", "prereleases", "experimental" }

local function settings_body(S)
	local early = placeholder_rows(S, "settings", "Reading settings…")
	if early then return early end
	local out = {}
	local mode = tern.kv.get("mise.widgetMode")
	if not table.find(Model.WIDGET_MODES, mode) then mode = "local" end
	local show = tern.kv.get("mise.widgetShow")
	if not table.find(Model.WIDGET_SHOWS, show) then show = "counters" end
	local LABEL = { ["local"] = "Local", global = "Global", mixed = "Mixed", merged = "Merged", counters = "Counters", tools = "Tool names" }
	table.insert(out, with(ui.row({ ui.text(ui.span("WIDGET AND STATUS LINE", "muted strong")) }), { role = role("section"), key = "sec-widget" }))
	table.insert(out, hint("What the widget counts. Each tab shows its own folder, so Local changes when you change tab."))
	local modes = {}
	for _, m in Model.WIDGET_MODES do
		table.insert(modes, button(LABEL[m], "widget.mode=" .. m, { on = mode == m, variant = if mode == m then "primary" else "default", key = "wm-" .. m }))
	end
	table.insert(out, with(ui.row(modes), { role = role("chips"), key = "widget-modes" }))
	local shows = {}
	for _, m in Model.WIDGET_SHOWS do
		table.insert(shows, button(LABEL[m], "widget.show=" .. m, { on = show == m, variant = if show == m then "primary" else "default", key = "ws-" .. m }))
	end
	table.insert(out, with(ui.row(shows), { role = role("chips"), key = "widget-shows" }))
	table.insert(out, hint(({ ["local"] = "Tools requested by this folder's configs, not the global one.", global = "Tools in your global config, the same in every tab.", mixed = "Local and global counts side by side.", merged = "What is active in this folder after global and local combine." })[mode]))
	table.insert(out, with(ui.row({ ui.text(ui.span("MISE SETTINGS", "muted strong")) }), { role = role("section"), key = "sec-mise-settings" }))
	table.insert(out, hint("Written to the global mise config. Nothing is installed or upgraded by changing these."))
	for _, key in View.SETTINGS do
		local e = Store.setting(S, key)
		local value = if e then e.value else nil
		local shown = if value == nil then "unset" elseif type(value) == "table" then tern.json.encode(value) else tostring(value)
		table.insert(out, with(ui.col({
			with(ui.row({ with(ui.text(ui.span(key, "strong")), { role = role("name") }), ui.text(ui.span(shown, "mono")) }), { role = role("row-top") }),
			if e and e.description then with(ui.text(ui.span(bounded(e.description, 160), "muted")), { role = role("row-sub") }) else ui.text(""),
			ui.row({ button("Change…", "setting.edit=" .. key, { variant = "quiet", icon = "pencil", key = "edit:" .. key }), button("Reset", "setting.reset=" .. key, { variant = "quiet", key = "reset:" .. key }) }),
		}), { key = "set:" .. key, role = role("row") }))
	end
	return out
end

-- Entry points ---------------------------------------------------------------------------------------------------------

function View.order(S): { string }
	return Store.order(S)
end

function View.render(S, opts)
	opts = opts or {}
	local kids = { toolbar(S) }
	if S.tab == "tools" and opts.filter then table.insert(kids, opts.filter) end
	if S.tab == "tasks" and opts.task_filter then table.insert(kids, opts.task_filter) end
	local a = alerts(S)
	if #a > 0 then table.insert(kids, with(ui.col(a), { role = role("alerts"), key = "alerts" })) end
	local body
	if S.setup.status ~= "ok" then body = {}
	elseif S.tab == "tools" then body = tools_body(S)
	elseif S.tab == "tasks" then body = tasks_body(S)
	elseif S.tab == "overview" then body = overview_body(S)
	elseif S.tab == "config" then body = config_body(S)
	elseif S.tab == "activity" then body = activity_body(S)
	elseif S.tab == "settings" then body = settings_body(S)
	else body = {} end
	table.insert(kids, with(ui.col(body), { role = role("body"), key = "body" }))
	local main = with(ui.col(kids), { role = role("root"), key = "root" })
	local foot = { ui.span("mise " .. tostring(Cli.version or "?"), "muted") }
	local d = S.ds.current
	if d and d.at then table.insert(foot, ui.span("  · read " .. ago(d.at), "muted")) end
	if S.reads_paused then table.insert(foot, ui.span("  · paused", "warning")) end
	return main, with(ui.row({ ui.text(foot) }), { role = role("dock") })
end

-- Dialogs ---------------------------------------------------------------------------------------------------------

local function plan_body(S, d)
	local plan = d.plan
	local out = {}
	if plan.file_edit then
		table.insert(out, ui.code(table.concat(plan.file_edit.diff, "\n"), "diff"))
	else
		table.insert(out, ui.code(Plan.command_text(Cli.exe, plan.argv), "sh"))
	end
	local facts = {}
	for _, w in plan.where do table.insert(facts, { ui.span(w[1], "muted"), ui.span(tostring(w[2]), "mono") }) end
	if d.target then table.insert(facts, { ui.span("Will write to", "muted"), ui.span(d.target, "mono") }) end
	table.insert(out, ui.kv(facts))
	table.insert(out, with(ui.row({ ui.text(ui.span("WHAT HAPPENS", "muted strong")) }), { role = role("section"), key = "sec-what" }))
	for i, e in plan.effects do table.insert(out, with(ui.text(e), { key = "eff" .. i })) end
	if plan.dry then
		table.insert(out, with(ui.row({ ui.text(ui.span("PREVIEW (dry run)", "muted strong")) }), { role = role("section"), key = "sec-dry" }))
		if d.dry.status == "loading" then table.insert(out, ui.progress(nil, "Asking mise what it would do…"))
		elseif d.dry.status == "ok" then table.insert(out, ui.code(if d.dry.text == "" then "mise reports nothing to do." else d.dry.text))
		else table.insert(out, hint("Preview failed: " .. tostring(d.dry.text))) end
	end
	if plan.id == "upgrade" and Cli.caps.upgrade_no_prune then
		table.insert(out, button(if d.keep_old then "✓ Keep the old versions installed" else "Keep the old versions installed", "upgrade.keep", { on = d.keep_old, key = "keep" }))
	end
	if d.warning then table.insert(out, with(ui.text(ui.span(d.warning, "warning")), { key = "warn" })) end
	if plan.danger and d.confirm then table.insert(out, with(ui.text(ui.span("This cannot be undone. Press Confirm to continue.", "warning")), { key = "danger" })) end
	return out
end

local function run_body(S, d)
	local out = {}
	if d.phase == "running" then table.insert(out, ui.progress(nil, d.plan.title .. "…")) end
	if #d.output > 0 then table.insert(out, ui.code(table.concat(d.output, "\n"))) end
	if d.phase == "done" then
		table.insert(out, ui.badge("Done in " .. string.format("%.1f s", (d.took_ms or 0) / 1000), "success"))
	elseif d.phase == "failed" then
		table.insert(out, ui.badge(if d.cancelled then "Cancelled" else ("Failed · exit " .. tostring(d.status)), "error"))
		if d.stderr_tail and d.stderr_tail ~= "" then table.insert(out, ui.code(d.stderr_tail)) end
		if d.error_kind == "UNTRUSTED_CONFIG" and d.untrusted_path then
			table.insert(out, ui.row({ button("Trust…", "trust=" .. d.untrusted_path, { variant = "primary" }) }))
		end
	end
	return out
end

-- Returns { title, children, foot = {nodes}, fields = {key=true} } for the open dialog, or nil.
-- The text fields a task form shows (host uses it for focus and key routing).
-- Text fields that hold more than a line, with how many lines the editor shows before it scrolls.
View.MULTILINE = { f_t_run = 6, f_t_description = 3, f_t_run_windows = 4 }

function View.taskform_fields(d): { [string]: boolean }
	local out = {}
	local function on(key: string)
		if not (d.form and d.form.locked[key]) then out["f_t_" .. key] = true end
	end
	if d.mode == "create" then out.f_t_name = true end
	if not (d.mode == "create" and d.as_file) then on("run") end
	on("description")
	on("depends")
	if d.advanced then
		for _, k in { "dir", "alias", "sources", "outputs", "depends_post", "wait_for", "shell", "run_windows" } do on(k) end
	end
	return out
end

function View.dialog(S, input, text_of)
	local d = S.dialog
	if not d then return nil end
	if d.kind == "plan" then
		local foot = {}
		if d.phase == "review" then
			table.insert(foot, button("Cancel", "dialog.close", { variant = "quiet", key = "cancel" }))
			table.insert(foot, button("Copy command", "plan.copy", { variant = "quiet", icon = "copy", key = "copy" }))
			if d.from == "add" or d.from == "upgrade" or d.from == "taskform" then table.insert(foot, button("Back", "plan.back", { variant = "quiet", key = "back" })) end
			local label = if d.plan.danger then (if d.confirm then "Confirm " .. d.plan.verb else d.plan.verb .. "…") else d.plan.verb
			table.insert(foot, button(label, "plan.run", { variant = if d.plan.danger then "danger" else "primary", key = "run" }))
			return { title = d.plan.title, children = plan_body(S, d), foot = foot }
		end
		table.insert(foot, button(if d.phase == "running" then "Cancel run" else "Close", "dialog.close", { variant = if d.phase == "running" then "danger" else "primary", key = "close2" }))
		return { title = d.plan.title, children = run_body(S, d), foot = foot }
	elseif d.kind == "add" then
		local kids = {
			ui.text("Tool name or reference, like node@22, python, or github:owner/tool."),
			input("f_add", "node@22", "Tool to add"),
		}
		if d.error then table.insert(kids, with(ui.text(ui.span(d.error, "error")), { key = "err" })) end
		table.insert(kids, ui.row({
			button("This project", "add.target=project", { on = d.target == "project", variant = if d.target == "project" then "primary" else "default", key = "tp" }),
			button("Global", "add.target=global", { on = d.target == "global", variant = if d.target == "global" then "primary" else "default", key = "tg" }),
		}))
		if Cli.caps.use_pin then table.insert(kids, button(if d.pin then "✓ Pin the exact version" else "Pin the exact version", "add.pin", { on = d.pin, key = "pin" })) end
		local reg = Store.data(S, "registry")
		local q = string.lower(text_of("f_add") or "")
		if reg and q ~= "" and not string.find(q, "[@:]") then
			local hits = {}
			for _, e in reg do
				if string.find(e.short, q, 1, true) then
					table.insert(hits, button(e.short, "add.pick=" .. e.short, { variant = "quiet", key = "pick:" .. e.short, title = e.description }))
					if #hits >= 8 then break end
				end
			end
			if #hits > 0 then table.insert(kids, with(ui.row(hits), { role = role("chips"), key = "hits" })) end
		elseif S.registry_loading then
			table.insert(kids, hint("Loading the tool registry…"))
		end
		return { title = "Add a tool", children = kids, foot = {
			button("Cancel", "dialog.close", { variant = "quiet", key = "cancel" }),
			button("Review…", "add.submit", { variant = "primary", key = "review" }),
		}, fields = { f_add = true } }
	elseif d.kind == "upgrade" then
		local kids = {}
		local cands = Store.upgrade_candidates(S)
		if #cands == 0 then table.insert(kids, hint("Everything here is up to date.")) end
		for _, c in cands do
			local on = d.picked[c.tool]
			local target = if d.bump and c.bump then c.bump else c.to
			table.insert(kids, with(ui.row({
				button(if on then "✓" else "", "upgrade.pick=" .. c.tool, { on = on, key = "pk:" .. c.tool }),
				ui.text({ ui.span(c.tool, "strong"), ui.span("  " .. tostring(c.installed) .. " → " .. tostring(target), "mono") }),
			}), { key = "up:" .. c.tool, role = role("plan-row") }))
		end
		table.insert(kids, ui.row({
			button("Select all", "upgrade.all", { variant = "quiet", key = "all" }),
			button(if d.bump then "✓ Also rewrite requested versions" else "Also rewrite requested versions", "upgrade.bump", { on = d.bump, key = "bump" }),
		}))
		if d.error then table.insert(kids, with(ui.text(ui.span(d.error, "error")), { key = "err" })) end
		return { title = "Upgrade tools", children = kids, foot = {
			button("Cancel", "dialog.close", { variant = "quiet", key = "cancel" }),
			button("Review…", "upgrade.preview", { variant = "primary", key = "review" }),
		} }
	elseif d.kind == "remove" then
		local r = d.row
		local kids = {
			ui.text({ ui.span(r.tool .. " " .. r.version, "strong") }),
			ui.text("Choose what to remove. Both options show a preview first."),
		}
		if r.source_path then
			table.insert(kids, ui.col({
				ui.text(ui.span("Remove from configuration", "strong")),
				hint("Deletes the request from " .. base(r.source_path) .. ". The installed files stay."),
				button("Remove request…", "remove.config", { key = "rc", icon = "file" }),
			}))
		end
		table.insert(kids, ui.col({
			ui.text(ui.span("Uninstall this version", "strong")),
			hint("Deletes the files. Configs are not edited."),
			button("Uninstall…", "remove.uninstall", { key = "ru", icon = "trash", variant = "danger" }),
		}))
		if d.error then table.insert(kids, with(ui.text(ui.span(d.error, "error")), { key = "err" })) end
		return { title = "Remove " .. r.tool, children = kids, foot = { button("Close", "dialog.close", { variant = "quiet", key = "cancel" }) } }
	elseif d.kind == "task" then
		local t = Store.task(S, d.name)
		local kids = {
			ui.text({ ui.span(d.name, "strong"), ui.span(if t and t.description then "  " .. t.description else "", "muted") }),
			ui.text("Arguments (optional). Quote words that contain spaces."),
			input("f_args", "e.g. --release", "Task arguments"),
			hint("Runs in a new terminal pane in " .. tostring(S.cwd) .. "."),
		}
		if d.args_error then table.insert(kids, with(ui.text(ui.span(d.args_error, "error")), { key = "err" })) end
		return { title = "Run task", children = kids, foot = {
			button("Cancel", "dialog.close", { variant = "quiet", key = "cancel" }),
			button("Run", "task.run", { variant = "primary", key = "run", icon = "play" }),
		}, fields = { f_args = true } }
	elseif d.kind == "taskinfo" then
		local def = d.def or {}
		local kids = { ui.text({ ui.span(d.name, "strong") }) }
		table.insert(kids, hint(if def.reason == "script" then "This task is a script file; edit it as a file." elseif def.reason == "inline" then "This task is written inline under [tasks]; the form cannot edit that shape." else (def.reason or "No source available.")))
		local acts = {}
		if def.path then table.insert(acts, button("Open file", "open=" .. def.path, { icon = "file", variant = "primary", key = "of" })) end
		table.insert(acts, button("Close", "dialog.close", { variant = "quiet", key = "cl" }))
		table.insert(kids, ui.row(acts))
		return { title = "Edit task", children = kids, foot = {} }
	elseif d.kind == "taskform" then
		local function label(text: string, key: string) return with(ui.text(ui.span(text, "muted strong")), { key = "lb-" .. key }) end
		local kids = {}
		local function field(key: string, title: string, placeholder: string)
			local locked = d.form and d.form.locked[key]
			table.insert(kids, label(title, key))
			if locked then
				table.insert(kids, with(hint("Not editable here (" .. locked .. "). Use Edit source."), { key = "lk-" .. key }))
			else
				table.insert(kids, input("f_t_" .. key, placeholder, title, View.MULTILINE["f_t_" .. key]))
			end
		end
		if d.mode == "create" then
			table.insert(kids, label("Name", "name"))
			table.insert(kids, input("f_t_name", "build", "Task name"))
		else
			table.insert(kids, ui.text({ ui.span(d.name, "strong"), ui.span("  " .. Model.basename(d.def.path), "muted") }))
		end
		if d.mode == "create" and d.as_file then
			table.insert(kids, hint("A script file is created in the project's task directory; write the commands in it."))
		else
			field("run", "Command", "bun run build")
		end
		field("description", "Description", "What this task does")
		field("depends", "Runs after (comma separated)", "lint, generate")
		table.insert(kids, button(if d.advanced then "▾ More options" else "▸ More options", "taskform.adv", { variant = "quiet", key = "adv" }))
		if d.advanced then
			field("dir", "Directory", "web")
			field("alias", "Aliases (comma separated)", "b")
			field("sources", "Sources (globs)", "src/**/*")
			field("outputs", "Outputs (globs)", "dist/**/*")
			field("depends_post", "Runs afterwards (comma separated)", "")
			field("wait_for", "Waits for (comma separated)", "")
			field("shell", "Shell", "bash -c")
			field("run_windows", "Command on Windows", "")
			local toggles = {}
			for _, k in { "hide", "quiet", "silent", "raw" } do
				local on = d.bools[k] == true
				table.insert(toggles, button((if on then "✓ " else "") .. k, "taskform.bool=" .. k, { on = on, key = "tg-" .. k }))
			end
			table.insert(kids, with(ui.row(toggles), { role = role("chips"), key = "toggles" }))
			if d.mode == "create" then
				table.insert(kids, button(if d.as_file then "✓ As a script file" else "As a script file", "taskform.file", { on = d.as_file == true, key = "asfile" }))
			end
		end
		if d.error then table.insert(kids, with(ui.text(ui.span(d.error, "error")), { key = "err" })) end
		table.insert(kids, button(if d.show_source then "▾ Source" else "▸ Source", "taskform.source", { variant = "quiet", key = "src" }))
		if d.show_source then
			local fields = {}
			for _, key in Store.TASK_TEXT_KEYS do fields["f_t_" .. key] = text_of("f_t_" .. key) end
			fields.f_t_name = text_of("f_t_name")
			local preview = Store.taskform_preview(S, fields)
			if preview.error then
				table.insert(kids, hint(preview.error))
			else
				table.insert(kids, ui.code(table.concat(preview.lines, "\n"), "toml"))
				if preview.diff and #preview.diff > 0 then
					table.insert(kids, ui.code(table.concat(preview.diff, "\n"), "diff"))
				end
				if d.mode == "create" then table.insert(kids, hint("This table is added to the end of the config file. mise reads it back to check it.")) end
			end
			if d.mode == "edit" then
				table.insert(kids, button("Open file at this task", "open=" .. d.def.path .. "&line=" .. d.def.block.first, { variant = "quiet", icon = "file", key = "openfile" }))
			end
		end
		local fieldset = View.taskform_fields(d)
		return { title = if d.mode == "create" then "New task" else "Edit task", children = kids, foot = {
			button("Cancel", "dialog.close", { variant = "quiet", key = "cancel" }),
			button("Review…", "taskform.submit", { variant = "primary", key = "review" }),
		}, fields = fieldset }
	elseif d.kind == "setting" then
		local kids = {
			ui.text({ ui.span(d.key, "strong") }),
			input("f_value", "value", "New value"),
			hint("Written to the global mise config after a review."),
		}
		if d.error then table.insert(kids, with(ui.text(ui.span(d.error, "error")), { key = "err" })) end
		return { title = "Change setting", children = kids, foot = {
			button("Cancel", "dialog.close", { variant = "quiet", key = "cancel" }),
			button("Review…", "setting.submit", { variant = "primary", key = "review" }),
		}, fields = { f_value = true } }
	end
	return nil
end

View.button, View.with, View.role, View.hint = button, with, role, hint

return View
