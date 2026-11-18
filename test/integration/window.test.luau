--!nonstrict
-- The window half against real mise: follows the focused folder, writes snapshots, renders widget and status per
-- scope option, places the panel, quotes task command lines.
local fs = require("@lune/fs")
local Lib = require("../lib")
local Shim = require("../shim")
local World = require("./world")
local check, eq = Lib.check, Lib.eq
local ROOT = Lib.root()

local w = World.new("window")
-- A global tool, a local override-free project with one tool, and an empty one.
fs.writeFile(w.env.MISE_GLOBAL_CONFIG_FILE, '[tools]\njq = "1.7.1"\n')
local proj = w.project("app", '[tools]\nbat = "latest"\n')
local empty = w.project("empty", "")

local focus = { cwd = proj, kind = "terminal" }
local sent = {}
Shim.cx.session = {
	focused = function() return 1 end,
	pane = function(_, id) return { pane = 1, kind = focus.kind, cwd = focus.cwd, block = focus.block } end,
	panes = function() return {} end,
	event = function(_, pane, ev) table.insert(sent, { pane, ev }) end,
}
Shim.cx.layout = {
	split = function(_, target, dir, launch) table.insert(Shim.effects, { "split", target, dir, launch }) return 9 end,
	new_tab = function(_, launch) table.insert(Shim.effects, { "tab", launch }) return 8 end,
	focus = function() end, close = function() end, unpark = function() end,
}
Shim.cx.docs = { open = function(_, path, opts) table.insert(Shim.effects, { "docs", path, opts }) return 5 end }
Shim.cx.prompt = function() return "C:/x/mise.exe" end
Shim.cx.new_block = function(_, kind, args, how, opts) table.insert(Shim.effects, { "new_block", kind, args, how, opts }) return 7 end

Shim.load(ROOT .. "/window.luau")
local widget = Shim.widgets.mise
check("widget registered", widget ~= nil)
check("status formatter registered", Shim.status_fn ~= nil)
check("open command registered", Shim.commands.open ~= nil and Shim.commands.tasks ~= nil)

Lib.section("before anything is read")
local v = widget.render({ cwd = proj })
eq("reading placeholder", v.text, "mise")
eq("muted", v.tone, "muted")

Lib.section("snapshot service follows the focused folder")
check("snapshots appear", Shim.wait_for(function()
	local key = "mise.snap." .. Shim.load(ROOT .. "/model.luau").hash(string.lower((string.gsub(proj, "\\", "/"))))
	local s = Shim.kv[key]
	return s and s.merged and s.localtools
end, 60))
eq("focus recorded for the block", Shim.kv["mise.focus"] and Shim.kv["mise.focus"].cwd, proj)
v = widget.render({ cwd = proj })
eq("default is local counters", v.text, "1 local · 1 missing")
eq("missing tool makes it a warning", v.tone, "warning")
check("hover lists local, merged", string.find(v.title, "Local: 1 tools", 1, true) and string.find(v.title, "Merged: 2 tools", 1, true), v.title)
local st = Shim.status_fn({ cwd = proj })
eq("status line follows the same option", st[1].text, "1 local · 1 missing")

Lib.section("each option")
Shim.kv["mise.widgetMode"] = "merged"
eq("merged counts global and local together (jq from global is not installed here)", widget.render({ cwd = proj }).text, "2 active · 2 missing")
Shim.kv["mise.widgetMode"] = "global"
-- The watcher notices the new mode every 2 s; trigger the same path by moving focus once.
Shim.handlers.focus[1]({}, Shim.cx)
local gv
check("global snapshot appears", Shim.wait_for(function()
	gv = widget.render({ cwd = proj })
	return gv.text ~= "mise"
end, 30), gv and gv.text)
eq("global counters (jq is requested globally, not installed here)", gv.text, "1 global · 1 missing")
Shim.kv["mise.focus"] = nil
local gother = widget.render({ cwd = empty })
check("the global count does not depend on the folder", gother.text == "1 global · 1 missing" or gother.text == "mise", gother.text)
Shim.kv["mise.widgetMode"] = "mixed"
eq("mixed", widget.render({ cwd = proj }).text, "1 local · 1 global · 1 missing")
Shim.kv["mise.widgetShow"] = "tools"
check("mixed tool names", string.match(widget.render({ cwd = proj }).text, "^bat [%w%.]+ · 1 global · 1 missing$") ~= nil, widget.render({ cwd = proj }).text)
Shim.kv["mise.widgetMode"] = "local"
check("local tool names", string.match(widget.render({ cwd = proj }).text, "^bat [%w%.]+$") ~= nil, widget.render({ cwd = proj }).text)
Shim.kv["mise.widgetShow"] = nil

Lib.section("switching tab shows that tab's folder")
focus.cwd = empty
Shim.handlers.focus[1]({}, Shim.cx)
check("empty folder read", Shim.wait_for(function() return widget.render({ cwd = empty }).text ~= "mise" end, 60))
eq("empty project counts zero local", widget.render({ cwd = empty }).text, "0 local")
eq("the other tab still shows its own", widget.render({ cwd = proj }).text, "1 local · 1 missing")

Lib.section("a content block keeps the last shell's folder")
focus.kind, focus.block = "plugin", "mise.panel"
Shim.handlers.focus[1]({}, Shim.cx)
Shim.settle(5)
eq("focus not overwritten by the panel", Shim.kv["mise.focus"].cwd, empty)
focus.kind, focus.block = "terminal", nil

Lib.section("panel placement and task launching")
Shim.effects = {}
Shim.commands.open.run(Shim.cx)
local nb = Shim.effects[1]
eq("new block of the plugin's kind", nb and nb[2], "mise.panel")
eq("beside the focused pane", nb and nb[4], "beside")
Shim.kv["mise.pane"] = nil

local handled = Shim.route({ url = "mise://task.run?name=build&args=--flag%20%27two%20words%27&cwd=" .. string.gsub(proj, "[^%w]", function(c) return string.format("%%%02X", string.byte(c)) end) .. "&exe=C%3A%5CProgram%20Files%5Cmise%5Cmise.exe" }, Shim.cx)
check("route handled", handled and handled.handled)
local launch
for _, e in Shim.effects do if e[1] == "split" or e[1] == "tab" then launch = e[#e] end end
check("terminal launched in the project", launch ~= nil and launch.cwd == proj, launch and launch.cwd)
check("command quotes exe, task and each argument", launch and string.find(launch.command, "'C:\\Program Files\\mise\\mise.exe' run build -- --flag 'two words'", 1, true) ~= nil, launch and launch.command)
Shim.effects = {}
Shim.route({ url = "mise://edit?path=" .. "C%3A%2Fx%2Fmise.toml&line=4" }, Shim.cx)
check("edit opens the file", Shim.effects[1] and Shim.effects[1][1] == "docs" and Shim.effects[1][2] == "C:/x/mise.toml")
eq("at the line", Shim.effects[1][3] and Shim.effects[1][3].line, 4)

Shim.settle(30)
w.cleanup()
Lib.finish()
