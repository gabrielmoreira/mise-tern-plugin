--!nonstrict
-- Window half: follows the focused terminal's folder, keeps a snapshot for the widget and status line, places the
-- block, and performs what the block asks for through `mise://` links (open a file, run a task, choose mise).

local Cli = require("./misecli")
local Locate = require("./locate")
local Model = require("./model")
local Redaction = require("./redaction")

local OWNER = "mise"
local KIND = OWNER .. ".panel"
local SNAP_TTL_S = 60
local PANEL_RATIO = 0.34

local windows = tern.runtime.os == "windows"

local function expand(path: string?): string?
	if not path or path == "" then return nil end
	return Locate.expand(path)
end

local function snapshot_key(cwd: string): string
	return "mise.snap." .. Model.hash(string.lower((string.gsub(cwd, "\\", "/"))))
end

-- The folder of the focused shell, nothing else (a content block keeps the last shell's folder).
local function focused_folder(cx): string?
	local focused = cx.session:focused()
	local info = focused and cx.session:pane(focused)
	if not info or info.block == KIND then return nil end
	if info.kind ~= "terminal" and info.kind ~= "agent" then return nil end
	return expand(info.cwd)
end

local function widget_options(): (string, string)
	local mode, show = tern.kv.get("mise.widgetMode"), tern.kv.get("mise.widgetShow")
	if not table.find(Model.WIDGET_MODES, mode) then mode = "local" end
	if not table.find(Model.WIDGET_SHOWS, show) then show = "counters" end
	return mode, show
end

local function ensure_exe(): boolean
	if Cli.exe then return true end
	local found = Locate.find(tern.kv.get("mise.executable"))
	Cli.located = found
	Cli.exe = found.path
	return Cli.exe ~= nil
end

local function tools_of(value): { any }
	local out = {}
	for _, r in Model.parse_ls(value) do
		table.insert(out, { tool = r.tool, version = r.version, requested = r.requested, installed = r.installed, active = r.active, source = r.source_path })
	end
	return out
end

local reading = {}
-- Reads one list into a snapshot field, at most once per TTL. `field` is "merged" or "localtools" (per folder), or "tools" (global).
local function read_list(key: string, cwd: string?, field: string, scope: string)
	local snap = tern.kv.get(key) or {}
	local fresh = snap[field] ~= nil and os.time() - (snap.at or 0) < SNAP_TTL_S
	local token = key .. ":" .. field
	if fresh or reading[token] then return end
	if not ensure_exe() then
		snap.unavailable, snap.at = true, os.time()
		tern.kv.set(key, snap)
		tern.chrome.refresh()
		return
	end
	reading[token] = true
	Cli.run("ls", { scope = scope, cwd = cwd }, function(result)
		reading[token] = nil
		local current = tern.kv.get(key) or {}
		current.at = os.time()
		if cwd then current.cwd = cwd end
		if result.ok then
			current[field] = tools_of(result.value)
			current.unavailable, current.error = nil, nil
		else
			current.error = result.error and result.error.code
			current[field] = current[field] or {}
		end
		tern.kv.set(key, current)
		tern.chrome.refresh()
	end)
end

local function read_snapshots(cwd: string)
	local mode = widget_options()
	local key = snapshot_key(cwd)
	read_list(key, cwd, "merged", "merged")
	read_list(key, cwd, "localtools", "local")
	if mode == "global" or mode == "mixed" then read_list("mise.snap.global", nil, "tools", "global") end
end

local scheduled
local function schedule()
	if scheduled then scheduled:cancel() end
	scheduled = tern.timer(250, function(cx)
		scheduled = nil
		if not cx then return end
		local cwd = focused_folder(cx)
		if cwd then
			local prev = tern.kv.get("mise.focus")
			if not prev or prev.cwd ~= cwd then tern.kv.set("mise.focus", { cwd = cwd, at = os.time() }) end
			read_snapshots(cwd)
		end
		tern.chrome.refresh()
	end)
end

for _, name in { "focus", "tab_created", "tab_closed", "pane_created", "pane_closed", "cwd", "session_ended" } do
	tern.on(name, function(_, _cx) schedule() end)
end
tern.on("window_start", function(_cx) schedule() end)
tern.timer(0, function() schedule() end)

local function snapshot_for(pane)
	local cwd = pane and expand(pane.cwd)
	if not cwd then return nil end
	return tern.kv.get(snapshot_key(cwd))
end

local function view_for(pane)
	local snap = snapshot_for(pane)
	local mode, show = widget_options()
	if snap and (snap.unavailable or snap.error) and not snap.merged and not snap.localtools then return nil, snap end
	return Model.widget_view(snap, tern.kv.get("mise.snap.global"), mode, show), snap
end

-- One place shows the counters: the widget below. A status line segment would draw the same chip a second time next
-- to it (both are always on once the widget is in the bar), which crowded the bars of plugins that were there first.

tern.chrome.widget("mise", {
	name = "mise",
	description = "mise counters for the focused tab's folder (local by default; choose global, mixed or merged in the panel's Settings). Click to open the panel.",
	icon = "package",
	render = function(pane)
		local v, snap = view_for(pane)
		if not v then
			if snap and snap.unavailable then return { text = "mise?", tone = "warning", icon = "package", title = "mise was not found. Open the panel to choose it.", command = "plugin." .. OWNER .. ".open" } end
			return { text = "mise !", tone = "warning", icon = "package", title = "mise reported a problem here (" .. tostring(snap and snap.error) .. "). Open the panel.", command = "plugin." .. OWNER .. ".open" }
		end
		local title = v.title
		if snap and snap.cwd then title ..= "\n" .. tostring(snap.cwd) end
		return { text = v.text, tone = v.tone, icon = "package", title = title, command = "plugin." .. OWNER .. ".open" }
	end,
})

-- Settings and changes made in the block arrive through kv; redraw and read what a new choice needs.
local last_sig
local function watch()
	local mode, show = widget_options()
	local sig = mode .. "|" .. show .. "|" .. tostring(tern.kv.get("mise.changed"))
	if sig ~= last_sig then
		last_sig = sig
		schedule()
		tern.chrome.refresh()
	end
	tern.timer(2000, watch)
end
tern.timer(2000, watch)

-- Placement --------------------------------------------------------------------------------------------------------

local function find_panel(cx): number?
	local cached = tern.kv.get("mise.pane")
	local info = cached and cx.session:pane(cached)
	if info and info.block == KIND then return cached end
	for _, pane in cx.session:panes() do
		if pane.block == KIND then return pane.pane end
	end
	return nil
end

local function open_panel(cx, args: { string }?)
	local existing = find_panel(cx)
	if existing then
		local info = cx.session:pane(existing)
		if info and info.parked then cx.layout:unpark(existing, { focus = true }) else cx.layout:focus(existing) end
		if args and args[1] == "tab" and args[2] then cx.session:event(existing, { ev = "action", act = "tab", value = args[2] }) end
		return existing
	end
	local focused = cx.session:focused()
	local pane = cx:new_block(KIND, args, "beside", { target = focused, dir = "right", ratio = 1 - PANEL_RATIO, focus = true })
	if not pane then
		cx:toast("error", "The mise panel is not loaded on this host", "Reload the plugin and try again.")
		return nil
	end
	tern.kv.set("mise.pane", pane)
	return pane
end

tern.command({ id = "open", title = "mise: Open", icon = "package", keys = { "ctrl+alt+shift+m" }, run = function(cx) open_panel(cx) end })
tern.command({ id = "tasks", title = "mise: Tasks", icon = "play", run = function(cx) open_panel(cx, { "tab", "tasks" }) end })
tern.command({
	id = "close", title = "mise: Close panel", icon = "x",
	run = function(cx)
		local pane = find_panel(cx)
		if pane then cx.layout:close(pane) end
	end,
})
tern.command({
	id = "refresh", title = "mise: Refresh",  icon = "refresh",
	run = function(cx)
		local cwd = focused_folder(cx)
		if cwd then
			tern.kv.set(snapshot_key(cwd), nil)
			tern.kv.set("mise.snap.global", nil)
			read_snapshots(cwd)
		end
		tern.kv.set("mise.changed", tern.now())
	end,
})

-- Block requests -----------------------------------------------------------------------------------------------------

local function decode(text: string): string
	text = string.gsub(text, "+", " ")
	return (string.gsub(text, "%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- A command line for the pane's shell: the task name and arguments are quoted; the executable is quoted for the
-- shell family Tern starts on this OS (PowerShell on Windows, a POSIX shell elsewhere).
local function quote_arg(arg: string): string
	if windows then
		if arg ~= "" and not string.find(arg, "[%s'\"`$&|<>();{}]") then return arg end
		return "'" .. string.gsub(arg, "'", "''") .. "'"
	end
	if arg ~= "" and not string.find(arg, "[^%w%-%._/:=@%%+,]") then return arg end
	return "'" .. string.gsub(arg, "'", "'\\''") .. "'"
end

local function task_command(exe: string, name: string, args: { string }): string
	local words = { quote_arg(exe), "run", quote_arg(name) }
	if #args > 0 then table.insert(words, "--") end
	for _, a in args do table.insert(words, quote_arg(a)) end
	local line = table.concat(words, " ")
	return if windows then "& " .. line else line
end

local function split_args(text: string): { string }
	local out, cur, quote = {}, nil, nil
	for ch in string.gmatch(text, utf8.charpattern) do
		if quote then
			if ch == quote then quote = nil else cur = (cur or "") .. ch end
		elseif ch == '"' or ch == "'" then quote = ch cur = cur or ""
		elseif string.find(ch, "^%s$") then
			if cur then table.insert(out, cur) cur = nil end
		else cur = (cur or "") .. ch end
	end
	if cur then table.insert(out, cur) end
	return out
end

local function run_task(cx, data)
	if not data.cwd or data.cwd == "" or not data.name or not data.exe then
		cx:toast("error", "Cannot run the task", "No folder or mise executable is known.")
		return
	end
	local line = task_command(data.exe, data.name, split_args(data.args or ""))
	local focused = cx.session:focused()
	local target = find_panel(cx) or focused
	local pane = if target then cx.layout:split(target, "down", { cwd = data.cwd, command = line }) else cx.layout:new_tab({ cwd = data.cwd, command = line })
	if not pane then cx:toast("error", "Could not open a terminal for the task") end
end

tern.route.link(function(link, cx)
	local kind, query = string.match(link.url, "^mise://([%w%._-]+)%??(.*)$")
	if not kind then return nil end
	local data = {}
	for k, v in string.gmatch(query, "([^&=]+)=([^&]*)") do data[decode(k)] = decode(v) end
	if kind == "edit" then
		local ok, why = pcall(function() cx.docs:open(data.path, { how = "beside", line = tonumber(data.line) }) end)
		if not ok then cx:toast("error", "Could not open the file", tostring(why)) end
	elseif kind == "task.run" then
		run_task(cx, data)
	elseif kind == "choose_exe" then
		local value = cx:prompt({ placeholder = "Full path to the mise executable", value = tern.kv.get("mise.executable") })
		if value and value ~= "" then
			tern.kv.set("mise.executable", value)
			tern.kv.set("mise.changed", tern.now())
			cx:toast("info", "mise path saved", value)
		end
	end
	return { handled = true }
end)
