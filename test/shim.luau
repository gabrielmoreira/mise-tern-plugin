--!nonstrict
-- A stand-in for Tern's `tern` global, enough to run the plugin's real modules under Lune against the real mise:
-- processes really run, timers really fire (polls of 5 s and longer are recorded, not run), UI builders return plain
-- `{k, p, c}` nodes, kv is an in-memory table. Modules are loaded with `tern` and a relative `require` in scope,
-- as Tern does.

local process = require("@lune/process")
local serde = require("@lune/serde")
local fs = require("@lune/fs")
local task = require("@lune/task")
local luau = require("@lune/luau")

local Shim = {
	extra_env = {} :: { [string]: string }, -- added to every child process
	env_override = {} :: { [string]: any }, -- what tern.getenv answers instead of the real environment (false = unset)
	os_override = nil :: string?,
	pending = 0,
	runs = {} :: { { string } }, -- every argv started
	kv = {} :: { [string]: any },
	logs = {} :: { string },
	handlers = {},
	commands = {},
	blocks = {},
	widgets = {},
	chrome_refreshes = 0,
	status_fn = nil,
	route = nil,
	with_spawn = true,
}

local function merge(a, b)
	local out = {}
	for k, v in a or {} do out[k] = v end
	for k, v in b or {} do out[k] = v end
	return out
end

local function spans(value)
	if type(value) == "string" then return { { t = value } } end
	if type(value) == "table" and value.t then return { value } end
	local out = {}
	for _, s in value or {} do table.insert(out, if type(s) == "string" then { t = s } else s) end
	return out
end

local ui = {}
function ui.span(t, s) return { t = t, s = s } end
function ui.link(t, href, s) return { t = t, s = s, href = href } end
function ui.path(p) return { t = p, s = "path" } end
function ui.text(s) return { k = "text", p = { spans = spans(s) } } end
for _, kind in { "col", "row", "lines" } do
	ui[kind] = function(children) return { k = kind, p = {}, c = children } end
end
function ui.card(head, children, props) return { k = "card", p = merge(props, { head = spans(head) }), c = children } end
function ui.section(head, children) return { k = "section", p = { head = spans(head) }, c = children } end
function ui.rule(label) return { k = "rule", p = { label = spans(label) } } end
function ui.badge(t, tone) return { k = "badge", p = { text = t, tone = tone } } end
function ui.button(text, props) return { k = "button", p = merge(props, { text = text }) } end
function ui.stats(items) return { k = "stats", p = { items = items } } end
function ui.kv(items) return { k = "kv", p = { items = items } } end
function ui.table(cols, rows, opts) return { k = "table", p = merge(opts, { cols = cols, rows = rows }) } end
function ui.code(text, lang) return { k = "code", p = { text = text, lang = lang } } end
function ui.md(text) return { k = "md", p = { text = text } } end
function ui.progress(value, label) return { k = "progress", p = { value = value, label = spans(label) } } end
function ui.list(items) return { k = "list", p = { items = items } } end
function ui.node(kind, props, children) return { k = kind, p = props or {}, c = children } end
function ui.el(tag, props, children) return { k = "el", p = merge(props, { tag = tag }), c = children } end

local function timer(ms, fn)
	if ms >= 5000 then
		return { cancel = function() end }
	end
	Shim.pending += 1
	local done = false
	local thread = task.delay(ms / 1000, function()
		done = true
		Shim.pending -= 1
		fn(Shim.cx)
	end)
	return {
		cancel = function()
			if not done then
				done = true
				Shim.pending -= 1
				task.cancel(thread)
			end
		end,
	}
end

local function proc_env(opts)
	return merge(Shim.extra_env, opts and opts.env)
end

local function run(argv, opts, cb)
	if cb == nil and type(opts) == "function" then cb, opts = opts, nil end
	local program = argv[1]
	Shim.pending += 1
	if string.find(program, "[/\\]") and not fs.isFile(program) then
		Shim.pending -= 1
		error("spawn failed: program not found: " .. program)
	end
	table.insert(Shim.runs, table.clone(argv))
	local args = table.move(argv, 2, #argv, 1, {})
	task.defer(function()
		local r = process.exec(program, args, { cwd = opts and opts.cwd, env = proc_env(opts) })
		Shim.pending -= 1
		cb({ status = r.code, stdout = r.stdout, stderr = r.stderr, timed_out = false }, Shim.cx)
	end)
end

-- Streams each line to `stdout`/`stderr` after the run finishes; the callbacks' contract is the same as Tern's.
local function spawn(argv, opts)
	opts = opts or {}
	local program = argv[1]
	Shim.pending += 1
	if string.find(program, "[/\\]") and not fs.isFile(program) then
		Shim.pending -= 1
		error("spawn failed: program not found: " .. program)
	end
	table.insert(Shim.runs, table.clone(argv))
	local args = table.move(argv, 2, #argv, 1, {})
	local killed = false
	task.defer(function()
		local r = process.exec(program, args, { cwd = opts.cwd, env = proc_env(opts) })
		for line in string.gmatch(r.stdout or "", "[^\r\n]+") do
			if opts.stdout then opts.stdout(line, Shim.cx) end
		end
		for line in string.gmatch(r.stderr or "", "[^\r\n]+") do
			if opts.stderr then opts.stderr(line, Shim.cx) end
		end
		Shim.pending -= 1
		if opts.exit then opts.exit({ pid = 1, status = if killed then -1 else r.code, stderr = "" }, Shim.cx) end
	end)
	return { pid = 1, kill = function() killed = true end, write = function() end, close_stdin = function() end }
end

local function sync(fn, ...)
	Shim.pending += 1
	local ok, a = pcall(fn, ...)
	Shim.pending -= 1
	if not ok then error(a, 0) end
	return a
end

local function tag(v)
	if type(v) ~= "table" then return v end
	for k, x in v do v[k] = tag(x) end
	if #v > 0 then setmetatable(v, { __metatable = "json array" }) end
	return v
end

Shim.tern = {
	runtime = setmetatable({ jit = false }, { __index = function(_, k) if k == "os" then return Shim.os_override or (if process.os == "windows" then "windows" elseif process.os == "macos" then "macos" else "linux") end end }),
	plugin = { id = "mise" },
	context = "host",
	getenv = function(name)
		local o = Shim.env_override[name]
		if o ~= nil then return if o == false then nil else o end
		return process.env[name]
	end,
	fs = {
		exists = function(p) return sync(function() return fs.isFile(p) or fs.isDir(p) end) end,
		read = function(p) return sync(fs.readFile, p) end,
		write = function(p, text) sync(fs.writeFile, p, text) end,
		list = function(p) local n = sync(fs.readDir, p) table.sort(n) return n end,
		mkdir = function(p) sync(fs.writeDir, p) end,
	},
	json = {
		encode = function(v, pretty) return serde.encode("json", v, pretty == true) end,
		decode = function(s) return tag(serde.decode("json", s)) end,
		array = function(t) return t or {} end,
		null = {},
	},
	sha256 = function(s) return serde.hash("sha256", s) end,
	process = { run = run, spawn = nil },
	timer = timer,
	now = function() return os.clock() * 1000 end,
	kv = {
		get = function(k) return Shim.kv[k] end,
		set = function(k, v) Shim.kv[k] = v end,
	},
	log = {
		warn = function(...) table.insert(Shim.logs, table.concat({ ... }, " ")) end,
		info = function() end, debug = function() end,
		error = function(...) table.insert(Shim.logs, table.concat({ ... }, " ")) end,
	},
	ui = ui,
	chrome = {
		status = function(fn) Shim.status_fn = fn end,
		widget = function(id, spec) Shim.widgets[id] = spec end,
		refresh = function() Shim.chrome_refreshes += 1 end,
	},
	command = function(def) Shim.commands[def.id] = def end,
	bind = function() end,
	on = function(name, fn)
		Shim.handlers[name] = Shim.handlers[name] or {}
		table.insert(Shim.handlers[name], fn)
	end,
	route = { link = function(fn) Shim.route = fn end, open = function() end },
	block = { define = function(id, def) Shim.blocks[id] = def end },
	pane = { list = function() return {} end },
}

function Shim.enable_spawn(on: boolean)
	Shim.tern.process.spawn = if on then spawn else nil
end

-- A fake window/block cx that records effects.
Shim.effects = {}
Shim.cx = {
	pane = 1,
	cols = 60,
	rows = 40,
	toast = function(_, level, text, sub) table.insert(Shim.effects, { "toast", level, text, sub }) end,
	open = function(_, target) table.insert(Shim.effects, { "open", target }) end,
	copy = function(_, text) table.insert(Shim.effects, { "copy", text }) end,
	render = function() table.insert(Shim.effects, { "render" }) end,
	save = function() end,
	frame = function(_, ops) table.insert(Shim.effects, { "frame", ops }) end,
}

local cache = {}
function Shim.load(path: string)
	path = string.gsub(path, "\\", "/")
	if cache[path] then return cache[path] end
	local dir = string.match(path, "^(.*)/[^/]*$") or "."
	local env = setmetatable({
		tern = Shim.tern,
		require = function(rel)
			local target = rel
			if string.sub(rel, 1, 2) == "./" then target = dir .. "/" .. string.sub(rel, 3) end
			if not string.match(target, "%.luau$") then target ..= ".luau" end
			return Shim.load(target)
		end,
	}, { __index = _G })
	local fn = luau.load(luau.compile(fs.readFile(path)), { debugName = path, environment = env })
	local result = fn()
	cache[path] = result
	return result
end

function Shim.reset_cache() cache = {} end

-- Lets short timers and process callbacks run; returns false on timeout.
function Shim.settle(timeout_s: number?): boolean
	local deadline = os.clock() + (timeout_s or 20)
	local quiet = 0
	while os.clock() < deadline do
		task.wait(0.02)
		if Shim.pending == 0 then
			quiet += 1
			if quiet >= 3 then return true end
		else
			quiet = 0
		end
	end
	return false
end

-- Waits until `cond()` or the timeout.
function Shim.wait_for(cond: () -> boolean, timeout_s: number?): boolean
	local deadline = os.clock() + (timeout_s or 20)
	while os.clock() < deadline do
		if cond() then return true end
		task.wait(0.02)
	end
	return cond()
end

return Shim
