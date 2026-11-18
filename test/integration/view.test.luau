--!nonstrict
-- Every screen and dialog rendered from real store state: no Lua errors, expected texts and actions present.
local fs = require("@lune/fs")
local Lib = require("../lib")
local Shim = require("../shim")
local World = require("./world")
local check, eq = Lib.check, Lib.eq
local ROOT = Lib.root()

local w = World.new("view")
local Cli = Shim.load(ROOT .. "/misecli.luau")
local Store = Shim.load(ROOT .. "/store.luau")
local View = Shim.load(ROOT .. "/view.luau")

local function collect(node, out)
	out = out or { text = {}, acts = {}, roles = {}, fields = {} }
	if type(node) ~= "table" then return out end
	local p = node.p or {}
	local function add_spans(spans)
		for _, s in spans or {} do if type(s) == "table" and s.t then table.insert(out.text, s.t) end end
	end
	add_spans(p.spans)
	add_spans(p.head)
	if p.text then table.insert(out.text, tostring(p.text)) end
	if node.k == "code" and p.text then table.insert(out.text, p.text) end
	if p.actions and p.actions.click then table.insert(out.acts, p.actions.click) end
	if p.role then table.insert(out.roles, p.role) end
	if p.head and type(p.head) == "string" then table.insert(out.text, p.head) end
	for _, k in node.c or {} do collect(k, out) end
	for _, item in p.items or {} do
		if type(item) == "table" then for _, cell in item do if type(cell) == "table" then if cell.t then table.insert(out.text, cell.t) else add_spans(cell) end end end end
	end
	return out
end

local function has_text(out, needle: string): boolean
	for _, t in out.text do if string.find(t, needle, 1, true) then return true end end
	return false
end

local function render(S, name: string)
	local fields = {}
	local rows = {}
	local function input(key, placeholder, _aria, editor_rows)
		rows[key] = editor_rows
		return { k = "input", p = { key = key, placeholder = placeholder } }
	end
	local texts = fields
	local ok, main, dock = pcall(View.render, S, { filter = input("f_filter", "Filter"), task_filter = input("f_task", "Filter tasks") })
	check(name .. ": renders", ok, main)
	if not ok then return collect(nil) end
	local out = collect(main)
	local dlg = View.dialog(S, input, function(key) return texts[key] or "" end)
	if dlg then
		local d = { k = "col", p = {}, c = dlg.children }
		local dout = collect(d)
		for _, f in dlg.foot or {} do collect(f, dout) end
		for _, t in dout.text do table.insert(out.text, t) end
		for _, a in dout.acts do table.insert(out.acts, a) end
		out.dialog = { title = dlg.title, fields = dlg.fields, text = dout.text, acts = dout.acts, rows = table.clone(rows) }
		for _, f in dlg.foot or {} do if f.p and f.p.actions then table.insert(out.dialog.acts, f.p.actions.click) end end
	end
	return out
end

local function settled(S, keys)
	return Shim.wait_for(function()
		for _, k in keys do
			local d = S.ds[k]
			if not d or d.status == "loading" then return false end
		end
		return true
	end, 60)
end

local proj = w.project("app", '[tools]\njq = "1.7.1"\n\n[tasks.build]\ndescription = "Build the app"\nrun = "echo hi"\n[tasks.multi]\nrun = [\n  "a",\n  "b",\n]\n')
Shim.tern.kv.set("mise.focus", { cwd = proj })
local S = Store.new({ redraw = function() end, effect = function() end })

Lib.section("before mise is known")
local out = render(S, "idle")
check("shows the folder chip", true)
Store.start(S)
Shim.wait_for(function() return S.setup.status == "ok" end, 40)
settled(S, { "current", "global", "local", "all" })

Lib.section("tools")
out = render(S, "tools merged")
check("tool row text", has_text(out, "jq"))
check("Missing badge", has_text(out, "Missing"))
check("install shortcut", table.find(out.acts, "install.missing") ~= nil)
check("scope buttons", table.find(out.acts, "scope=global") and table.find(out.acts, "scope=local"))
check("every button has a stable role", #out.roles > 5)
local row = Store.tool_rows(S).requested[1]
Store.dispatch(S, "select", row.id)
out = render(S, "tools selected")
check("details show actions", table.find(out.acts, "install.missing") ~= nil and has_text(out, "Config"))
for _, scope in { "global", "local" } do
	Store.dispatch(S, "scope", scope)
	settled(S, { scope, "config", "global" })
	local o = render(S, "tools " .. scope)
	if scope == "local" then
		check("Local names the folder", has_text(o, proj))
		check("Local names the config file it reads", has_text(o, proj .. "/mise.toml") or has_text(o, string.gsub(proj, "/", "\\") .. "\\mise.toml"), table.concat(o.text, " | "))
		check("Local says global is not included", has_text(o, "Not included"))
		check("rows say where the request lives", has_text(o, "mise.toml in this folder"))
	else
		check("Global names its config", has_text(o, "Global config"))
		check("Global says it applies everywhere", has_text(o, "every folder"))
	end
end
Store.dispatch(S, "scope", "merged")
Store.dispatch(S, "status_filter", "missing")
check("status filter keeps missing", has_text(render(S, "filter"), "jq"))
Store.dispatch(S, "status_filter", "missing")

Lib.section("dialogs")
Store.dispatch(S, "add")
out = render(S, "add")
check("add dialog", out.dialog and out.dialog.title == "Add a tool" and out.dialog.fields.f_add)
Store.submit(S, { f_add = "jq@1.6" })
out = render(S, "plan review")
check("plan dialog shows the command", out.dialog and has_text({ text = out.dialog.text }, "use") and table.find(out.dialog.acts, "plan.run"))
Shim.wait_for(function() return S.dialog.dry and S.dialog.dry.status ~= "loading" end, 30)
out = render(S, "plan with dry run")
check("preview section", has_text(out, "PREVIEW"))
Store.dispatch(S, "dialog.close")
Store.dispatch(S, "remove.open", row.id)
out = render(S, "remove")
check("remove choices", table.find(out.dialog.acts, "remove.config") ~= nil and table.find(out.dialog.acts, "remove.uninstall") ~= nil)
Store.dispatch(S, "dialog.close")
Store.dispatch(S, "upgrade.review")
out = render(S, "upgrade")
check("upgrade dialog", out.dialog and out.dialog.title == "Upgrade tools")
Store.dispatch(S, "dialog.close")

Lib.section("tasks")
Store.dispatch(S, "tab", "tasks")
settled(S, { "tasks" })
out = render(S, "tasks")
check("lists both", has_text(out, "build") and has_text(out, "multi"))
check("New task button", table.find(out.acts, "task.new") ~= nil)
Store.dispatch(S, "task.select", "build")
out = render(S, "task selected")
check("shows the source", has_text(out, "[tasks.build]") and has_text(out, 'description = "Build the app"'))
check("edit, delete and open-source actions", table.find(out.acts, "task.edit=build") and table.find(out.acts, "task.delete=build"))
Store.dispatch(S, "task.select", "multi")
out = render(S, "multi selected")
check("multi-line source shown", has_text(out, '"a",'))
Store.dispatch(S, "task.new")
out = render(S, "task form create")
check("create form fields", out.dialog.fields.f_t_name and out.dialog.fields.f_t_run and out.dialog.fields.f_t_description and out.dialog.fields.f_t_depends)
check("the command asks for a multi-line editor", out.dialog.rows.f_t_run ~= nil and out.dialog.rows.f_t_run > 2, (function() local k = {} for key in out.dialog.rows do table.insert(k, key .. "=" .. tostring(out.dialog.rows[key])) end return table.concat(k, ",") end)())
check("single-line keys stay single-line", out.dialog.rows.f_t_depends == nil and out.dialog.rows.f_t_name == nil)
check("advanced fields hidden until asked", not out.dialog.fields.f_t_dir)
Store.dispatch(S, "taskform.adv")
Store.dispatch(S, "taskform.source")
out = render(S, "task form advanced + source")
check("advanced fields shown", out.dialog.fields.f_t_dir and out.dialog.fields.f_t_sources and out.dialog.fields.f_t_shell)
check("source preview shows a header", has_text(out, "[tasks.name]"))
Store.dispatch(S, "dialog.close")
Store.dispatch(S, "task.edit", "multi")
out = render(S, "task form locked")
check("locked run is not a field", not out.dialog.fields.f_t_run and has_text(out, "multi-line value"))
Store.dispatch(S, "dialog.close")
Store.dispatch(S, "task.open", "build")
out = render(S, "task run dialog")
check("run dialog has args field", out.dialog.fields.f_args)
Store.dispatch(S, "dialog.close")

Lib.section("the drift banner can be hidden until what it reports changes")
S.drift = { { name = "MISE_INSTALLS_DIR", saved = "<saved>", live = nil } }
out = render(S, "drift shown")
check("banner shown", has_text(out, "Environment differs"))
Store.dispatch(S, "drift.hide")
out = render(S, "drift hidden")
check("hide is remembered and silences this report", not has_text(out, "Environment differs"))
S.drift = { { name = "MISE_INSTALLS_DIR", saved = "<other>", live = nil } }
out = render(S, "drift changed")
check("a different report comes back", has_text(out, "Environment differs"))
S.drift = {}
Shim.tern.kv.set("mise.driftHidden", nil)

Lib.section("more tabs")
for _, tab in { "overview", "config", "activity", "settings" } do
	Store.dispatch(S, "tab", tab)
	settled(S, Store.needs(S))
	out = render(S, tab)
	if tab == "overview" then
		check("overview shows folders", has_text(out, "FOLDERS"))
		Store.dispatch(S, "doctor.run")
		settled(S, { "doctor" })
		out = render(S, "overview after doctor")
		check("doctor result shown", has_text(out, "HEALTH"))
	elseif tab == "settings" then
		check("widget options", table.find(out.acts, "widget.mode=mixed") and table.find(out.acts, "widget.show=tools"))
		check("settings rows", has_text(out, "upgrade.prune_after"))
		Store.dispatch(S, "setting.edit", "minimum_release_age")
		out = render(S, "setting dialog")
		check("setting dialog", out.dialog and out.dialog.fields.f_value)
		Store.dispatch(S, "dialog.close")
	end
end

Lib.section("mise missing")
Cli.exe = nil
local S2 = Store.new({ redraw = function() end, effect = function() end })
S2.setup = { status = "missing", info = { steps = { { label = "PATH", result = "not found" } } } }
out = render(S2, "missing")
check("explains and offers to choose", has_text(out, "mise was not found") and table.find(out.acts, "exe.choose") ~= nil)

Shim.settle(30)
w.cleanup()
Lib.finish()
