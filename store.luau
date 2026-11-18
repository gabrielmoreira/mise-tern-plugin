--!nonstrict
-- Navigator state and effects. One store per block; the view only reads `S`, the host block only calls
-- `Store.dispatch`. Reads go through request epochs so an answer for a folder or scope the user already left is
-- dropped; mutations go through a reviewed plan (plan.luau) and are recorded in the Activity history.

local Cli = require("./misecli")
local Model = require("./model")
local Plan = require("./plan")
local Locate = require("./locate")
local Tasks = require("./tasks")
local Redaction = require("./redaction")

local Store = {}

local READ_GAP_MS = 60
local HISTORY_MAX = 100
local TAIL_MAX = 16 * 1024
local OUTPUT_LINES = 200
local LOCK_STALE_S = 15 * 60

-- Dataset definitions: how each read is made and parsed. `cwd` datasets follow the folder shown.
local DS = {
	current = { op = "ls", input = function(S) return { scope = "merged", cwd = S.cwd } end, parse = Model.parse_ls, cwd = true },
	global = { op = "ls", input = function(S) return { scope = "global" } end, parse = Model.parse_ls },
	["local"] = { op = "ls", input = function(S) return { scope = "local", cwd = S.cwd } end, parse = Model.parse_ls, cwd = true },
	all = { op = "ls", input = function(S) return { scope = "all", cwd = S.cwd } end, parse = Model.parse_ls, cwd = true },
	outdated_merged = { op = "outdated", input = function(S) return { scope = "merged", cwd = S.cwd } end, parse = Model.parse_outdated, cwd = true, net = true },
	outdated_global = { op = "outdated", input = function(S) return { scope = "global" } end, parse = Model.parse_outdated, net = true },
	outdated_local = { op = "outdated", input = function(S) return { scope = "local", cwd = S.cwd } end, parse = Model.parse_outdated, cwd = true, net = true },
	tasks = { op = "tasks", input = function(S) return { cwd = S.cwd } end, parse = Model.parse_tasks, cwd = true },
	config = { op = "config", input = function(S) return { cwd = S.cwd } end, parse = Model.parse_config, cwd = true },
	doctor = { op = "doctor", input = function(S) return { cwd = S.cwd } end, parse = function(v) return v end, cwd = true },
	settings = { op = "settings", input = function(S) return { cwd = S.cwd } end, parse = function(v) return v or {} end, cwd = true },
}
Store.DS = DS

local function now_s(): number
	return os.time()
end

local function windows(): boolean
	return tern.runtime.os == "windows"
end

-- Construction ------------------------------------------------------------------------------------------------

function Store.new(opts: { redraw: (any) -> (), effect: (any, string, any) -> (), surface: string? }): any
	local S = {
		surface = opts.surface or "block",
		redraw_fn = opts.redraw,
		effect_fn = opts.effect,
		tab = "tools",
		scope = tern.kv.get("mise.scope") or "merged",
		more = false,
		filter = "",
		status_filter = nil,
		cursor = nil,
		selected = nil,
		cwd = nil,
		setup = { status = "idle" },
		ds = {},
		epoch = 0,
		dialog = nil,
		history = {},
		windows = windows(),
		reads_paused = tern.kv.get("mise.readsPaused") == true,
		network_reads = tern.kv.get("mise.networkReads") or "on-view",
		task_query = "",
		recent = {},
		revealed = {},
		toast = nil,
	}
	if S.scope ~= "global" and S.scope ~= "local" and S.scope ~= "merged" then S.scope = "merged" end
	return S
end

local function redraw(S)
	if S.redraw_fn then S.redraw_fn(S) end
end

local function effect(S, kind: string, data: any)
	if S.effect_fn then S.effect_fn(S, kind, data) end
end

-- Datasets -----------------------------------------------------------------------------------------------------

function Store.state(S, key: string): any
	return S.ds[key] or { status = "idle" }
end

-- Rows or nil.
function Store.data(S, key: string): any
	local d = S.ds[key]
	return d and d.value
end

local function invalidate(S, cwd_only: boolean?)
	S.epoch += 1
	for key, def in DS do
		if not cwd_only or def.cwd then S.ds[key] = nil end
	end
end

local scheduled = 0

local function load(S, key: string, force: boolean?)
	local def = DS[key]
	local d = S.ds[key]
	if not force and d and (d.status == "loading" or d.status == "ok") then return end
	if S.reads_paused and not force and d == nil then
		S.ds[key] = { status = "paused" }
		return
	end
	if def.cwd and not S.cwd then
		S.ds[key] = { status = "nocwd" }
		return
	end
	local epoch = S.epoch
	local previous = d and d.value
	S.ds[key] = { status = "loading", value = previous, stale = previous ~= nil }
	-- Reads are spaced so opening a tab never starts a burst of mise processes.
	local delay = scheduled * READ_GAP_MS
	scheduled += 1
	tern.timer(delay, function()
		scheduled = math.max(0, scheduled - 1)
		if S.epoch ~= epoch then return end
		Cli.run(def.op, def.input(S), function(result)
			if S.epoch ~= epoch then return end
			if result.ok then
				S.ds[key] = { status = "ok", value = def.parse(result.value), at = now_s(), took_ms = result.took_ms }
				if result.error == nil and result.stderr and key == "current" then
					S.stderr_current = result.stderr
				end
			else
				S.ds[key] = { status = "error", error = result.error, value = previous, stale = previous ~= nil }
				if result.error.code == "UNTRUSTED_CONFIG" then S.untrusted = result.error.untrusted_path or S.untrusted or true end
			end
			Store.publish(S, key)
			redraw(S)
		end)
	end)
end
Store.load = load

-- Datasets the current screen needs.
function Store.needs(S): { string }
	local tab = S.tab
	if tab == "tools" then
		local out
		if S.scope == "global" then out = { "global", "all" }
		elseif S.scope == "local" then out = { "local", "all", "config", "global" }
		else out = { "current", "global", "local", "all", "config" } end
		return out
	elseif tab == "tasks" then return { "tasks", "config", "global" }
	elseif tab == "overview" then return { "current", "all", "config", "doctor" }
	elseif tab == "config" then return { "config" }
	elseif tab == "settings" then return { "settings" }
	end
	return {}
end

local function outdated_key(S): string
	return "outdated_" .. S.scope
end

-- Fills in whatever the screen shows and has not loaded. Network reads run only while their view is open.
function Store.ensure(S)
	if not Cli.exe then return end
	for _, key in Store.needs(S) do load(S, key) end
	if S.tab == "tools" and S.network_reads == "on-view" then load(S, outdated_key(S)) end
end

function Store.refresh(S)
	invalidate(S)
	Store.ensure(S)
	redraw(S)
end

-- Publishes what the widget and status line show, read from kv by the window half (never from mise there).
-- Per folder: { cwd, at, merged = {tools}, localtools = {tools}, updates = { merged, ["local"] } }; global: one key.
local function tool_list(records: { any }): { any }
	local out = {}
	for _, r in records do
		table.insert(out, { tool = r.tool, version = r.version, requested = r.requested, installed = r.installed, active = r.active, source = r.source_path })
	end
	return out
end
Store.tool_list = tool_list

local function update_count(map: any): number
	local n = 0
	for _, e in map or {} do if e.update then n += 1 end end
	return n
end

Store.GLOBAL_SNAPSHOT = "mise.snap.global"

function Store.publish(S, key: string?)
	if key == nil then return end
	if key == "global" or key == "outdated_global" then
		local snap = tern.kv.get(Store.GLOBAL_SNAPSHOT) or {}
		if key == "global" then
			local d = S.ds.global
			if not d or d.status ~= "ok" then return end
			snap.tools = tool_list(d.value)
		else
			local d = S.ds.outdated_global
			if not d or d.status ~= "ok" then return end
			snap.updates = update_count(d.value)
		end
		snap.at = now_s()
		tern.kv.set(Store.GLOBAL_SNAPSHOT, snap)
		return
	end
	if not S.cwd then return end
	local skey = Store.snapshot_key(S.cwd)
	local snap = tern.kv.get(skey) or {}
	snap.cwd, snap.at = S.cwd, now_s()
	snap.untrusted = S.untrusted and true or nil
	snap.unavailable, snap.error = nil, nil
	if key == "current" then
		local d = S.ds.current
		if not d or d.status ~= "ok" then return end
		snap.merged = tool_list(d.value)
	elseif key == "local" then
		local d = S.ds["local"]
		if not d or d.status ~= "ok" then return end
		snap.localtools = tool_list(d.value)
	elseif key == "outdated_merged" or key == "outdated_local" then
		local d = S.ds[key]
		if not d or d.status ~= "ok" then return end
		snap.updates = snap.updates or {}
		snap.updates[if key == "outdated_local" then "local" else "merged"] = update_count(d.value)
	else
		return
	end
	tern.kv.set(skey, snap)
end

function Store.snapshot_key(cwd: string): string
	return "mise.snap." .. Model.hash(string.lower(string.gsub(cwd, "\\", "/")))
end

-- A change another surface made (a window's focus, another block's action): reload when the stamp moved.
function Store.follow(S)
	local focus = tern.kv.get("mise.focus")
	local cwd = focus and focus.cwd
	if cwd and cwd ~= S.cwd and not S.pinned_cwd then
		Store.set_cwd(S, cwd)
	end
	local stamp = tern.kv.get("mise.changed")
	if stamp ~= S.seen_stamp then
		local first = S.seen_stamp == nil
		S.seen_stamp = stamp
		if not first and not (S.running) then Store.refresh(S) end
	end
end

function Store.set_cwd(S, cwd: string)
	if cwd == S.cwd then return end
	S.cwd = cwd
	S.untrusted = nil
	S.cursor, S.selected = nil, nil
	invalidate(S, true)
	Store.ensure(S)
	redraw(S)
end

-- Startup -------------------------------------------------------------------------------------------------------

function Store.start(S, done: (() -> ())?)
	S.setup = { status = "loading" }
	redraw(S)
	local override = tern.kv.get("mise.executable")
	Cli.setup(if type(override) == "string" and override ~= "" then override else nil, function(info)
		S.setup = if info.ok then { status = "ok", info = info } else { status = "missing", info = info }
		local focus = tern.kv.get("mise.focus")
		if S.cwd == nil and focus and focus.cwd then S.cwd = focus.cwd end
		if info.ok then Store.ensure(S) end
		Store.drift(S)
		S.recent = tern.kv.get("mise.recent") or {}
		S.history = tern.kv.get("mise.history") or {}
		redraw(S)
		if done then done() end
	end)
end

-- What the drift banner is about, so "hide" lasts until the values change.
function Store.drift_signature(S): string
	local parts = {}
	for _, d in S.drift or {} do table.insert(parts, d.name .. "=" .. d.saved .. "|" .. tostring(d.live)) end
	return table.concat(parts, ";")
end

-- Read-only drift check: a directory variable persisted in the user environment but absent from this process.
function Store.drift(S)
	if not Locate.persisted_argv("MISE_DATA_DIR") then
		S.drift = {}
		return
	end
	S.drift = nil
	Locate.drift(function(name, cb)
		local argv = Locate.persisted_argv(name)
		local ok = pcall(tern.process.run, argv, { timeout_ms = 5000 }, function(r)
			cb(if r.status == 0 then Locate.parse_persisted(r.stdout or "") else nil)
		end)
		if not ok then cb(nil) end
	end, function(list)
		S.drift = list
		redraw(S)
	end)
end

-- View model ----------------------------------------------------------------------------------------------------

-- The tool rows for the current scope, grouped and filtered: { requested = {...}, also = {...} } or nil while loading.
function Store.tool_rows(S): any
	local scope = S.scope
	local key = if scope == "merged" then "current" else scope
	local recs = Store.data(S, key)
	if recs == nil then return nil end
	local all = Store.data(S, "all") or {}
	local od = Store.data(S, outdated_key(S))
	local groups = Model.rows(recs, all, od)
	if scope == "merged" then
		local merged = Model.merge(recs, Store.data(S, "global"), Store.data(S, "local"), S.cwd, S.windows)
		for i, row in groups.requested do
			row.winner = merged[i] and merged[i].winner
			row.global_request = merged[i] and merged[i].global_request
			row.local_request = merged[i] and merged[i].local_request
			row.merge_badges = merged[i] and merged[i].merge_badges
		end
	end
	local function keep(row)
		if S.status_filter == "missing" and row.status.text ~= "Missing" then return false end
		if S.status_filter == "updates" and row.status.text ~= "Update" then return false end
		return Model.matches(row, S.filter)
	end
	local out = { requested = {}, also = {}, outdated = od }
	for _, r in groups.requested do if keep(r) then table.insert(out.requested, r) end end
	for _, r in groups.also do if S.status_filter == nil and keep(r) then table.insert(out.also, r) end end
	return out
end

function Store.order(S): { string }
	local ids = {}
	if S.tab == "tools" then
		local rows = Store.tool_rows(S)
		if rows then
			for _, r in rows.requested do table.insert(ids, r.id) end
			for _, r in rows.also do table.insert(ids, r.id) end
		end
	elseif S.tab == "tasks" then
		for _, t in Store.task_list(S) do table.insert(ids, "task:" .. t.name) end
	end
	return ids
end

function Store.find_row(S, id: string): any
	local rows = Store.tool_rows(S)
	if not rows then return nil end
	for _, r in rows.requested do if r.id == id then return r end end
	for _, r in rows.also do if r.id == id then return r end end
	return nil
end

-- Config files that belong to the global scope, judged from the global read (never from computed locations).
function Store.global_paths(S): { [string]: boolean }
	local out = {}
	for _, r in Store.data(S, "global") or {} do
		if r.source_path then out[Model.path_key(r.source_path, S.windows)] = true end
	end
	return out
end

-- "global config", "this folder", "parent folder: <dir>" or "<dir>" for a config file path.
function Store.where_label(S, path: string?): string
	if not path then return "no config file" end
	if Store.global_paths(S)[Model.path_key(path, S.windows)] then return "global config" end
	local dir = Model.dirname(path)
	if S.cwd and Model.same_path(dir, S.cwd, S.windows) then return Model.basename(path) .. " in this folder" end
	return Model.basename(path) .. " in " .. (string.match(dir, "([^/\\]+)$") or dir) .. " (parent)"
end

-- Tasks: recent (up to three still present) first, then all alphabetically; one entry per task name.
function Store.task_list(S): { any }
	local tasks = Store.data(S, "tasks") or {}
	local q = S.task_query or ""
	local by_name = {}
	for _, t in tasks do by_name[t.name] = t end
	local out, used = {}, {}
	local recent = (S.recent and S.cwd and S.recent[Store.project_key(S.cwd)]) or {}
	if q == "" then
		for _, name in recent do
			local t = by_name[name]
			if t and not used[name] then
				used[name] = true
				table.insert(out, { name = t.name, description = t.description, source = t.source, dir = t.dir, group = "Recent in this project" })
			end
		end
	end
	for _, t in tasks do
		if not used[t.name] and Model.matches(t, q) then
			table.insert(out, { name = t.name, description = t.description, source = t.source, dir = t.dir, group = if q == "" then "All tasks" else "Results" })
		end
	end
	return out
end

function Store.project_key(cwd: string): string
	return if windows() then string.lower(string.gsub(cwd, "\\", "/")) else cwd
end

function Store.task(S, name: string): any
	for _, t in Store.data(S, "tasks") or {} do
		if t.name == name then return t end
	end
	return nil
end

-- History ------------------------------------------------------------------------------------------------------

local function history_add(S, entry: any)
	table.insert(S.history, 1, entry)
	while #S.history > HISTORY_MAX do table.remove(S.history) end
	tern.kv.set("mise.history", S.history)
end

-- Mutation lock shared by every window: one running change at a time.
local function lock_free(S): boolean
	local lock = tern.kv.get("mise.lock")
	if type(lock) ~= "table" then return true end
	if now_s() - (lock.at or 0) > LOCK_STALE_S then return true end
	return lock.owner == S
end

local function take_lock(S, op: string)
	tern.kv.set("mise.lock", { op = op, at = now_s() })
end

local function drop_lock()
	tern.kv.set("mise.lock", nil)
end

-- Plans and dialogs ----------------------------------------------------------------------------------------------

local function open_plan(S, plan: any, from: any?)
	local prev = S.dialog
	S.dialog = { kind = "plan", plan = plan, phase = "review", output = {}, from = from, keep_old = false,
		return_to = if prev and prev.kind == "taskform" then prev else nil }
	if plan.dry then
		S.dialog.dry = { status = "loading" }
		local dialog = S.dialog
		Cli.run("use_dry", { argv = plan.dry.argv, cwd = plan.cwd }, function(result)
			if S.dialog ~= dialog then return end
			if result.ok then
				local text = Redaction.text((result.text or "") .. (if result.stderr and result.stderr ~= "" then "\n" .. result.stderr else ""))
				dialog.dry = { status = "ok", text = text }
				local target = Plan.parse_dry_target(result.text or "")
				if target then dialog.target = target end
			else
				dialog.dry = { status = "error", text = (result.error.stderr_tail or result.error.message) }
			end
			redraw(S)
		end)
	end
	redraw(S)
end
Store.open_plan = open_plan

local function close_dialog(S)
	if S.dialog and S.dialog.phase == "running" then return end
	S.dialog = nil
	redraw(S)
end

local function finish_run(S, dialog: any, status: number, took_ms: number, stderr_tail: string)
	local ok = status == 0
	dialog.phase = if ok then "done" else "failed"
	dialog.status, dialog.took_ms = status, took_ms
	dialog.stderr_tail = stderr_tail
	if not ok then
		local kind = Model.error_kind(stderr_tail)
		dialog.error_kind = kind
		if kind == "UNTRUSTED_CONFIG" then dialog.untrusted_path = Model.untrusted_path(stderr_tail) end
	end
	drop_lock()
	S.running = nil
	local tail = table.concat(dialog.output, "\n")
	if #tail > TAIL_MAX then tail = "…" .. string.sub(tail, -TAIL_MAX) end
	history_add(S, {
		id = tostring(now_s()) .. "-" .. tostring(#S.history),
		at = now_s(), op = dialog.plan.id, title = dialog.plan.title,
		argv = dialog.plan.display or Plan.command_text(Cli.exe, dialog.plan.argv), cwd = dialog.plan.cwd, scope = S.scope,
		status = if ok then "ok" else "failed", exit = status, took_ms = took_ms, output_tail = Redaction.text(tail),
	})
	-- Whatever happened, the inventory may differ now: read it again rather than infer it.
	if S.selected and string.sub(S.selected, 1, 5) == "task:" then S.selected, S.task_src = nil, nil end
	invalidate(S)
	tern.kv.set("mise.changed", tern.now())
	S.seen_stamp = tern.kv.get("mise.changed")
	Store.ensure(S)
	if dialog.plan.id == "setting" then S.settings_epoch = (S.settings_epoch or 0) + 1 end
	redraw(S)
end

local function run_plan(S)
	local dialog = S.dialog
	if not dialog or dialog.kind ~= "plan" or dialog.phase ~= "review" then return end
	local plan = dialog.plan
	if plan.danger and not dialog.confirm then
		dialog.confirm = true
		redraw(S)
		return
	end
	if not lock_free(S) then
		dialog.warning = "Another mise change is running in a Tern window. Wait for it to finish."
		redraw(S)
		return
	end
	if plan.file_edit then
		Store.run_file_edit(S, dialog)
		return
	end
	local argv = table.clone(plan.argv)
	if plan.id == "upgrade" then
		-- Rebuild so the keep-old toggle in the dialog decides the final flags.
		local rebuilt = Plan.upgrade(plan.cwd, plan.tools or {}, { bump = plan.bump, keep_old = dialog.keep_old, min_age = plan.min_age }, Cli.caps)
		argv = rebuilt.argv
		plan.argv = argv
	end
	dialog.phase = "running"
	dialog.output = {}
	S.running = dialog
	take_lock(S, plan.id)
	redraw(S)
	dialog.handle = Cli.exec(argv, { cwd = plan.cwd }, {
		line = function(text: string)
			local clean = Redaction.text(text)
			table.insert(dialog.output, clean)
			if #dialog.output > OUTPUT_LINES then table.remove(dialog.output, 1) end
			redraw(S)
		end,
		exit = function(status: number, took_ms: number, stderr_tail: string)
			finish_run(S, dialog, status, took_ms, stderr_tail)
		end,
	})
end

-- Writes a reviewed task edit, has mise read the result back, restores the file when mise cannot.
function Store.run_file_edit(S, dialog: any)
	local plan = dialog.plan
	local fe = plan.file_edit
	dialog.phase = "running"
	dialog.output = {}
	S.running = dialog
	take_lock(S, plan.id)
	redraw(S)
	local started = tern.now()
	local function done(ok: boolean, message: string)
		table.insert(dialog.output, message)
		finish_run(S, dialog, if ok then 0 else 1, tern.now() - started, if ok then "" else message)
	end
	local ok, current = pcall(tern.fs.read, fe.path)
	if fe.new_file then
		if ok then
			done(false, fe.path .. " appeared since you reviewed this. Close and create the task again.")
			return
		end
	elseif not ok or current ~= fe.before then
		done(false, "The file changed since you reviewed it. Close this and open the task again.")
		return
	end
	local wrote, why = pcall(tern.fs.write, fe.path, fe.after)
	if not wrote then
		done(false, "Could not write " .. fe.path .. ": " .. tostring(why))
		return
	end
	local function check_back()
	Cli.run("tasks_check", { cwd = plan.cwd }, function(result)
		local present = false
		if result.ok then
			for _, t in Model.list(result.value) do
				if type(t) == "table" and t.name == fe.name then present = true end
			end
		end
		local wanted = fe.kind ~= "delete"
		if result.ok and present == wanted then
			done(true, (if fe.kind == "create" then "Created " elseif wanted then "Saved " else "Deleted ") .. fe.name .. ". mise reads it back fine.")
		else
			pcall(tern.fs.write, fe.path, fe.before)
			local reason = if result.ok then "mise does not list the task after the change" else (result.error.stderr_tail or result.error.message)
			done(false, "mise could not read the result, so the file was restored. " .. tostring(reason))
		end
	end)
	end
	if fe.new_file then
		-- A config mise has not seen is untrusted until it is told otherwise; the user reviewed the content above.
		Cli.run("trust_path", { cwd = plan.cwd, path = fe.path }, function(trusted)
			if not trusted.ok then
				pcall(tern.fs.write, fe.path, "")
				done(false, "mise would not trust the new file, so it was emptied. " .. tostring(trusted.error.stderr_tail or trusted.error.message))
				return
			end
			check_back()
		end)
	else
		check_back()
	end
end

local function cancel_run(S)
	local dialog = S.dialog
	if dialog and dialog.phase == "running" and dialog.handle then
		dialog.handle.kill()
		dialog.cancelled = true
	end
end

-- Tool selection helpers ------------------------------------------------------------------------------------------

-- Tools that can be upgraded in the current scope: { tool, installed, to, source }.
function Store.upgrade_candidates(S): { any }
	local rows = Store.tool_rows(S)
	local out = {}
	if not rows then return out end
	local seen = {}
	for _, r in rows.requested do
		if r.status.text == "Update" and not seen[r.tool] then
			seen[r.tool] = true
			table.insert(out, { tool = r.tool, installed = r.version, to = r.update_to, bump = r.bump_to, request = r.requested, source = r.source_path })
		end
	end
	return out
end

local function missing_here(S): { any }
	local rows = Store.tool_rows(S)
	local out = {}
	for _, r in (rows and rows.requested) or {} do if r.status.text == "Missing" then table.insert(out, r) end end
	return out
end
Store.missing_here = missing_here

-- Actions -----------------------------------------------------------------------------------------------------------

local function recent_add(S, name: string)
	if not S.cwd then return end
	local key = Store.project_key(S.cwd)
	local list = S.recent[key] or {}
	local out = { name }
	for _, n in list do
		if n ~= name and #out < 3 then table.insert(out, n) end
	end
	S.recent[key] = out
	tern.kv.set("mise.recent", S.recent)
end

local function open_add(S)
	S.dialog = { kind = "add", target = if S.scope == "global" then "global" else "project", pin = false, error = nil }
	if not Store.data(S, "registry") and not S.registry_loading then
		S.registry_loading = true
		Cli.run("registry", {}, function(result)
			S.registry_loading = false
			if result.ok then
				local names = {}
				for _, e in Model.list(result.value) do
					if type(e) == "table" and type(e.short) == "string" then
						table.insert(names, { short = e.short, backends = Model.list(e.backends), description = e.description })
					end
				end
				table.sort(names, function(a, b) return a.short < b.short end)
				S.ds.registry = { status = "ok", value = names }
			else
				S.ds.registry = { status = "error", error = result.error }
			end
			redraw(S)
		end)
	end
	redraw(S)
end

-- A tool reference typed in the Add field -> a `use` plan (the reference is passed through unchanged).
local function submit_add(S, text: string)
	local spec = string.match(text, "^%s*(.-)%s*$")
	if spec == "" then
		S.dialog.error = "Enter a tool name or reference, like node@22 or github:owner/tool."
		redraw(S)
		return
	end
	if string.find(spec, "%s") then
		S.dialog.error = "A tool reference has no spaces."
		redraw(S)
		return
	end
	local target = S.dialog.target
	if not S.cwd and target == "project" then
		S.dialog.error = "No folder is in focus; choose Global or focus a terminal."
		redraw(S)
		return
	end
	local plan = Plan.use(S.cwd or Cli.neutral_cwd(), spec, target, { pin = S.dialog.pin }, Cli.caps)
	open_plan(S, plan, "add")
end

local function open_upgrade(S, preselect: string?)
	local cands = Store.upgrade_candidates(S)
	local picked = {}
	for _, c in cands do picked[c.tool] = preselect == nil or preselect == c.tool end
	S.dialog = { kind = "upgrade", picked = picked, bump = false, keep_old = false }
	if S.tab ~= "tools" then S.tab = "tools" end
	redraw(S)
end

local function build_upgrade(S)
	local tools = {}
	for _, c in Store.upgrade_candidates(S) do
		if S.dialog.picked[c.tool] then table.insert(tools, c.tool) end
	end
	if #tools == 0 then
		S.dialog.error = "Select at least one tool."
		redraw(S)
		return
	end
	local plan = Plan.upgrade(S.cwd or Cli.neutral_cwd(), tools, { bump = S.dialog.bump, keep_old = S.dialog.keep_old }, Cli.caps)
	plan.tools, plan.bump = tools, S.dialog.bump
	open_plan(S, plan, "upgrade")
	S.dialog.keep_old = S.dialog.from_keep or false
end

local function task_run_data(S, name: string, args: string)
	return { name = name, args = args, cwd = S.cwd, exe = Cli.exe }
end

-- Splits typed arguments into separate argv entries; double or single quotes group words.
function Store.split_args(text: string): { string }
	local out, cur, quote = {}, nil, nil
	for ch in string.gmatch(text, utf8.charpattern) do
		if quote then
			if ch == quote then quote = nil else cur = (cur or "") .. ch end
		elseif ch == '"' or ch == "'" then
			quote = ch
			cur = cur or ""
		elseif string.find(ch, "^%s$") then
			if cur then table.insert(out, cur) cur = nil end
		else
			cur = (cur or "") .. ch
		end
	end
	if cur then table.insert(out, cur) end
	return out
end

local function select_row(S, id: string?)
	S.cursor = id
	S.selected = if S.selected == id then nil else id
end

function Store.dispatch(S, act: string, value: string?)
	local dialog = S.dialog
	if act == "tab" then
		S.tab = value or "tools"
		-- Choosing Tools or Tasks closes the More row; choosing one of its pages keeps it open.
		S.more = S.tab == "overview" or S.tab == "config" or S.tab == "activity" or S.tab == "settings"
		S.cursor, S.selected = nil, nil
		Store.ensure(S)
	elseif act == "drift.hide" then
		tern.kv.set("mise.driftHidden", Store.drift_signature(S))
	elseif act == "more" then
		S.more = not S.more
		-- Closing the row while on one of its pages goes back to Tools: the page would otherwise lose its menu.
		if not S.more and (S.tab == "overview" or S.tab == "config" or S.tab == "activity" or S.tab == "settings") then
			Store.dispatch(S, "tab", "tools")
		end
	elseif act == "scope" then
		if value == "global" or value == "local" or value == "merged" then
			S.scope = value
			tern.kv.set("mise.scope", value)
			S.cursor, S.selected = nil, nil
			Store.ensure(S)
		end
	elseif act == "status_filter" then
		S.status_filter = if S.status_filter == value then nil else value
	elseif act == "refresh" then
		Store.refresh(S)
		return
	elseif act == "select" and value then
		select_row(S, value)
	elseif act == "close" or act == "dialog.close" then
		if dialog and dialog.kind == "plan" and dialog.phase == "running" then cancel_run(S) else close_dialog(S) end
		return
	elseif act == "add" then
		open_add(S)
		return
	elseif act == "add.target" and dialog and dialog.kind == "add" then
		dialog.target = value
	elseif act == "add.pin" and dialog and dialog.kind == "add" then
		dialog.pin = not dialog.pin
	elseif act == "add.pick" and dialog and dialog.kind == "add" and value then
		dialog.picked_text = value
	elseif act == "install.missing" then
		local rows = missing_here(S)
		local plan = Plan.install(S.cwd or Cli.neutral_cwd(), nil, Cli.caps)
		open_plan(S, plan, "tools")
		return
	elseif act == "upgrade.review" then
		open_upgrade(S, value)
		return
	elseif act == "upgrade.pick" and dialog and dialog.kind == "upgrade" and value then
		dialog.picked[value] = not dialog.picked[value]
	elseif act == "upgrade.all" and dialog and dialog.kind == "upgrade" then
		local all_on = true
		for _, c in Store.upgrade_candidates(S) do if not dialog.picked[c.tool] then all_on = false end end
		for _, c in Store.upgrade_candidates(S) do dialog.picked[c.tool] = not all_on end
	elseif act == "upgrade.bump" and dialog and dialog.kind == "upgrade" then
		dialog.bump = not dialog.bump
		if dialog.bump then
			-- Bump candidates need the bump-aware outdated read.
			S.bump_loading = true
			Cli.run("outdated", { scope = S.scope, cwd = S.cwd, bump = true }, function(result)
				S.bump_loading = false
				if result.ok then
					S.ds[outdated_key(S)] = { status = "ok", value = Model.parse_outdated(result.value), at = now_s() }
				end
				redraw(S)
			end)
		end
	elseif act == "upgrade.keep" and dialog and (dialog.kind == "upgrade" or dialog.kind == "plan") then
		dialog.keep_old = not dialog.keep_old
	elseif act == "upgrade.preview" and dialog and dialog.kind == "upgrade" then
		build_upgrade(S)
		return
	elseif act == "remove.open" and value then
		local row = Store.find_row(S, value)
		if row then S.dialog = { kind = "remove", row = row } end
	elseif act == "remove.config" and dialog and dialog.kind == "remove" then
		local r = dialog.row
		if not r.source_path then
			dialog.error = "This request does not come from an editable config file."
		else
			open_plan(S, Plan.unuse(S.cwd or Cli.neutral_cwd(), r.tool, r.requested or r.version, r.source_path, Cli.caps), "remove")
		end
		return
	elseif act == "remove.uninstall" and dialog and dialog.kind == "remove" then
		local r = dialog.row
		local guard = Plan.uninstall_guard(Store.data(S, "current") or {}, r.tool, r.version)
		if guard then
			dialog.error = guard
		else
			open_plan(S, Plan.uninstall(S.cwd or Cli.neutral_cwd(), r.tool, r.version, Cli.caps), "remove")
		end
		return
	elseif act == "trust" and value then
		open_plan(S, Plan.trust(S.cwd or Cli.neutral_cwd(), value), "trust")
		return
	elseif act == "prune" then
		open_plan(S, Plan.prune(S.cwd or Cli.neutral_cwd(), Cli.caps), "prune")
		return
	elseif act == "plan.run" then
		run_plan(S)
		return
	elseif act == "plan.back" and dialog and dialog.kind == "plan" and dialog.phase == "review" then
		local from = dialog.from
		S.dialog = nil
		if dialog.return_to then S.dialog = dialog.return_to
		elseif from == "add" then open_add(S) elseif from == "upgrade" then open_upgrade(S) end
		redraw(S)
		return
	elseif act == "plan.copy" and dialog and dialog.kind == "plan" then
		effect(S, "copy", { text = Plan.command_text(Cli.exe, dialog.plan.argv) })
		return
	elseif act == "open" and value then
		local path, line = string.match(value, "^(.*)&line=(%d+)$")
		effect(S, "edit", { path = path or value, line = line })
		return
	elseif act == "task.open" and value then
		S.dialog = { kind = "task", name = value, args_error = nil }
		redraw(S)
		return
	elseif act == "task.select" and value then
		Store.select_task(S, value)
	elseif act == "task.new" then
		Store.open_taskform(S, "create", nil)
		return
	elseif act == "task.edit" and value then
		Store.open_taskform(S, "edit", value)
		return
	elseif act == "task.delete" and value then
		Store.delete_task(S, value)
		return
	elseif act == "taskform.adv" and dialog and dialog.kind == "taskform" then
		dialog.advanced = not dialog.advanced
	elseif act == "taskform.bool" and dialog and dialog.kind == "taskform" and value then
		dialog.bools[value] = not dialog.bools[value]
	elseif act == "taskform.file" and dialog and dialog.kind == "taskform" then
		dialog.as_file = not dialog.as_file
	elseif act == "taskform.source" and dialog and dialog.kind == "taskform" then
		dialog.show_source = not dialog.show_source
	elseif act == "widget.mode" and value then
		tern.kv.set("mise.widgetMode", value)
	elseif act == "widget.show" and value then
		tern.kv.set("mise.widgetShow", value)
	elseif act == "tool.versions" then
		-- reserved
	elseif act == "setting.edit" and value then
		S.dialog = { kind = "setting", key = value }
	elseif act == "setting.reset" and value then
		open_plan(S, Plan.setting_unset(S.cwd or Cli.neutral_cwd(), value), "settings")
		return
	elseif act == "reveal" and value then
		S.revealed[value] = not S.revealed[value]
	elseif act == "exe.choose" then
		effect(S, "choose_exe", {})
		return
	elseif act == "pause" then
		S.reads_paused = not S.reads_paused
		tern.kv.set("mise.readsPaused", S.reads_paused)
		if not S.reads_paused then Store.refresh(S) return end
	elseif act == "net" then
		S.network_reads = if S.network_reads == "on-view" then "manual" else "on-view"
		tern.kv.set("mise.networkReads", S.network_reads)
	elseif act == "load.outdated" then
		load(S, outdated_key(S), true)
	elseif act == "doctor.run" then
		load(S, "doctor", true)
	elseif act == "history.open" and value then
		S.selected = value
	end
	redraw(S)
end

-- Tasks as text -------------------------------------------------------------------------------------------------------

local function read_file(path: string): string?
	local ok, text = pcall(tern.fs.read, path)
	return if ok then text else nil
end

-- Loads the lines that define a task: { path, text, block } or { path, reason }.
function Store.task_definition(S, name: string): any
	local task = Store.task(S, name)
	if not task then return { reason = "The task is no longer defined here." } end
	if not task.toml then
		return { path = task.file or task.source, reason = "script", task = task }
	end
	local text = read_file(task.source)
	if not text then return { path = task.source, reason = "Could not read " .. tostring(task.source), task = task } end
	local block = Tasks.find(text, name)
	if not block then return { path = task.source, reason = "Could not find [tasks." .. name .. "] in the file.", task = task } end
	if block.kind == "inline" then return { path = task.source, reason = "inline", text = text, block = block, task = task } end
	return { path = task.source, text = text, block = block, task = task }
end

function Store.select_task(S, name: string)
	local id = "task:" .. name
	S.cursor = id
	if S.selected == id then
		S.selected, S.task_src = nil, nil
		return
	end
	S.selected = id
	S.task_src = Store.task_definition(S, name)
end

local TASK_TEXT_KEYS = {}
for _, k in Tasks.KEYS do if k.kind ~= "bool" then table.insert(TASK_TEXT_KEYS, k.key) end end
Store.TASK_TEXT_KEYS = TASK_TEXT_KEYS

-- mode: "create" | "edit". The fields are prefilled from the file; empty ones stay out of the TOML.
function Store.open_taskform(S, mode: string, name: string?)
	local d = { kind = "taskform", mode = mode, name = name, bools = {}, prefill = {}, advanced = false }
	if mode == "edit" and name then
		local def = Store.task_definition(S, name)
		if def.reason or not def.block or def.block.kind ~= "table" then
			S.dialog = { kind = "taskinfo", name = name, def = def }
			redraw(S)
			return
		end
		d.def = def
		d.form = Tasks.form(def.block)
		for key, text in d.form.values do d.prefill["f_t_" .. key] = text end
		for key, on in d.form.bools do d.bools[key] = on end
		for _, key in { "alias", "dir", "shell", "sources", "outputs", "hide", "quiet", "silent", "raw", "depends_post", "wait_for", "run_windows" } do
			if d.form.values[key] or d.form.bools[key] then d.advanced = true end
		end
	end
	S.dialog = d
	redraw(S)
end

local function typed_from(S, fields: { [string]: string }): any
	local d = S.dialog
	local typed = { values = {}, bools = table.clone(d.bools) }
	for _, key in TASK_TEXT_KEYS do typed.values[key] = fields["f_t_" .. key] or "" end
	return typed
end
Store.typed_from = typed_from

-- What saving the open form would write: { lines, diff } for edit, { lines } for create. nil when invalid.
function Store.taskform_preview(S, fields: { [string]: string }): any
	local d = S.dialog
	local typed = typed_from(S, fields)
	if d.mode == "create" then
		local name = string.match(fields.f_t_name or "", "^%s*(.-)%s*$")
		return { lines = Tasks.new_block(if name == "" then "name" else name, typed), typed = typed }
	end
	local changes = Tasks.changes(d.form, typed)
	local lines, err = Tasks.apply(d.def.block, changes)
	if not lines then return { error = err, typed = typed } end
	return { lines = lines, diff = Tasks.diff(d.def.block.lines, lines), changes = changes, typed = typed }
end

-- Where a new task is written: the config in the focused folder (mise.toml first), else a new mise.toml there.
-- Returns the path and its text (nil when the file does not exist yet).
function Store.create_target(S): (string, string?)
	local best
	for _, c in Store.data(S, "config") or {} do
		if S.cwd and Model.same_path(Model.dirname(c.path), S.cwd, S.windows) and not Store.global_paths(S)[Model.path_key(c.path, S.windows)] then
			local base_name = string.lower(Model.basename(c.path))
			if base_name == "mise.toml" then best = c.path break end
			if best == nil and (base_name == ".mise.toml" or base_name == "mise.local.toml") then best = c.path end
		end
	end
	if best then return best, read_file(best) or "" end
	local sep = if S.cwd and string.find(S.cwd, "\\", 1, true) then "\\" else "/"
	local path = (string.gsub(S.cwd or "", "[/\\]$", "")) .. sep .. "mise.toml"
	local existing = read_file(path)
	return path, existing
end

function Store.delete_task(S, name: string)
	local def = Store.task_definition(S, name)
	if def.reason or not def.block or def.block.kind ~= "table" then
		S.dialog = { kind = "taskinfo", name = name, def = def }
		redraw(S)
		return
	end
	local after = Tasks.splice(def.block, nil)
	local diff = {}
	for _, l in def.block.lines do table.insert(diff, "- " .. l) end
	local plan = Plan.file_edit(S.cwd or Cli.neutral_cwd(), def.path, name, "delete", def.text, after, diff)
	open_plan(S, plan, "tasks")
end

local function submit_taskform(S, fields: { [string]: string })
	local d = S.dialog
	local preview = Store.taskform_preview(S, fields)
	if preview.error then
		d.error = preview.error
		redraw(S)
		return
	end
	if d.mode == "create" then
		local name = string.match(fields.f_t_name or "", "^%s*(.-)%s*$")
		if name == "" then d.error = "Give the task a name." redraw(S) return end
		if string.find(name, "%s") then d.error = "A task name has no spaces. Use - or : to separate words." redraw(S) return end
		if Store.task(S, name) then d.error = "A task named " .. name .. " already exists here." redraw(S) return end
		if not S.cwd then d.error = "No folder is in focus." redraw(S) return end
		local run = preview.typed.values.run
		if (run == nil or run == "") and not d.as_file then d.error = "Enter the command to run." redraw(S) return end
		if d.as_file then
			open_plan(S, Plan.task_add(S.cwd, name, preview.typed, true, Tasks.split_list), "taskform")
			return
		end
		-- mise's `tasks add` shell-quotes the command, which breaks anything with &&, quotes or several lines. The
		-- table is written to the file directly instead, and mise reads it back.
		local path, text = Store.create_target(S)
		local eol = if text and string.find(text, "\r\n", 1, true) then "\r\n" else "\n"
		local block = table.concat(preview.lines, eol)
		local body = if text == nil or string.match(text, "^%s*$") then block .. eol else string.gsub(text, "%s+$", "") .. eol .. eol .. block .. eol
		local diff = {}
		for _, l in preview.lines do table.insert(diff, "+ " .. l) end
		local plan = Plan.file_edit(S.cwd, path, name, "create", text or "", body, diff, text == nil)
		open_plan(S, plan, "taskform")
		return
	end
	if #preview.changes == 0 then
		d.error = "Nothing changed."
		redraw(S)
		return
	end
	local newtext = Tasks.splice(d.def.block, preview.lines)
	local plan = Plan.file_edit(S.cwd or Cli.neutral_cwd(), d.def.path, d.name, "edit", d.def.text, newtext, preview.diff)
	open_plan(S, plan, "taskform")
end

-- Submit handlers called by the host with the dialog's field text.
function Store.submit(S, fields: { [string]: string })
	local dialog = S.dialog
	if not dialog then return false end
	if dialog.kind == "add" then
		submit_add(S, fields.f_add or "")
		return true
	elseif dialog.kind == "task" then
		local task = Store.task(S, dialog.name)
		if not task then
			dialog.args_error = "This task is no longer defined in this folder."
			redraw(S)
			return true
		end
		local args = fields.f_args or ""
		recent_add(S, dialog.name)
		effect(S, "task.run", task_run_data(S, dialog.name, args))
		S.dialog = nil
		redraw(S)
		return true
	elseif dialog.kind == "taskform" then
		submit_taskform(S, fields)
		return true
	elseif dialog.kind == "setting" then
		local v = string.match(fields.f_value or "", "^%s*(.-)%s*$")
		if v == "" then
			dialog.error = "Enter a value."
			redraw(S)
			return true
		end
		open_plan(S, Plan.setting(S.cwd or Cli.neutral_cwd(), dialog.key, v), "settings")
		return true
	elseif dialog.kind == "plan" and dialog.phase == "review" then
		run_plan(S)
		return true
	end
	return false
end

-- One setting from the extended listing; dotted keys ("upgrade.prune_after") are nested objects there.
function Store.setting(S, key: string): any
	local node = Store.data(S, "settings")
	for part in string.gmatch(key, "[^%.]+") do
		if type(node) ~= "table" then return nil end
		node = node[part]
	end
	return node
end

-- Overview: stat tiles from the loaded data.
function Store.stats(S): { [string]: any }
	local current = Store.data(S, "current") or {}
	local all = Store.data(S, "all") or {}
	local missing, active = 0, 0
	for _, r in current do
		if not r.installed then missing += 1 end
		if r.active then active += 1 end
	end
	local installed = 0
	for _, r in all do if r.installed then installed += 1 end end
	local od = Store.data(S, "outdated_merged")
	local updates
	if od then
		updates = 0
		for _, e in od do if e.update then updates += 1 end end
	end
	return { installed = installed, requested = #current, active = active, missing = missing, updates = updates }
end

return Store
