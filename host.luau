--!nonstrict
-- The mise block: one navigator for sidebar-sized or panel-sized placement. The host half owns native text fields
-- and dialogs; everything that needs a window (opening files, launching a terminal, the chooser) goes through the
-- `mise://` route.

local Store = require("./store")
local View = require("./view")
local Redaction = require("./redaction")

local ui = tern.ui
local POLL_MS = 60 * 1000
local TICK_MS = 2 * 1000

local FIELD_PATH = {
	f_filter = "main.root.f_filter",
	f_task = "main.root.f_task",
	f_add = "layer.dialog.form.f_add",
	f_args = "layer.dialog.form.f_args",
	f_value = "layer.dialog.form.f_value",
}

for _, key in Store.TASK_TEXT_KEYS do FIELD_PATH["f_t_" .. key] = "layer.dialog.form.f_t_" .. key end
FIELD_PATH.f_t_name = "layer.dialog.form.f_t_name"

local running: { [number]: any } = {}

local function units(text: string): number
	local n = 0
	for _, cp in utf8.codes(text) do n += if cp > 0xFFFF then 2 else 1 end
	return n
end

local function bytes(text: string, offset: number): number
	local n = 0
	for pos, cp in utf8.codes(text) do
		local width = if cp > 0xFFFF then 2 else 1
		if n + width > offset then return pos - 1 end
		n += width
	end
	return #text
end

local function encode(text: string): string
	return (string.gsub(text, "[^%w%-%._~]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

local function alive(state): boolean
	if running[state.cx.pane] ~= state then return false end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then return true end
	end
	running[state.cx.pane] = nil
	return false
end

local function anchor_units(f): number?
	if f.anchor and f.anchor ~= f.cursor then return units(string.sub(f.text, 1, f.anchor)) end
	return nil
end

-- Fields that hold more than a line: an editor that grows with its text up to `rows` lines, not a one-line input.
local function make_input(state)
	return function(key: string, placeholder: string, aria: string, rows: number?)
		local f = state.fields[key]
		return ui.node(if rows then "editor" else "input", {
			key = key, text = f.text, cursor = units(string.sub(f.text, 1, f.cursor)), anchor = anchor_units(f),
			placeholder = placeholder, aria = aria, rows = rows,
		})
	end
end

local function is_multiline(key: string?): boolean
	return key ~= nil and View.MULTILINE[key] ~= nil
end

-- Start of the line holding byte `at`, and the offset from it.
local function line_start(text: string, at: number): number
	local i = at
	while i > 0 and string.sub(text, i, i) ~= "\n" do i -= 1 end
	return i
end

local function boundary_before(text: string, at: number): number
	if at <= 0 then return 0 end
	return (utf8.offset(text, -1, at + 1) or 1) - 1
end

local function boundary_after(text: string, at: number): number
	if at >= #text then return #text end
	local nxt = utf8.offset(text, 2, at + 1)
	return if nxt then nxt - 1 else #text
end

local function replace(f, from: number, to: number, text: string)
	f.text = string.sub(f.text, 1, from) .. text .. string.sub(f.text, to + 1)
	f.cursor, f.anchor = from + #text, nil
end

-- Edits a field from a key event; returns whether the key was used.
local function edit_key(f, key, multiline: boolean?): boolean
	local cursor = math.clamp(f.cursor, 0, #f.text)
	local anchor = f.anchor
	local lo, hi = cursor, cursor
	if anchor then lo, hi = math.min(anchor, cursor), math.max(anchor, cursor) end
	local name = key.name
	if ((key.ctrl and not key.alt) or key.meta) and name == "a" then
		f.anchor, f.cursor = 0, #f.text
		return true
	elseif name == "left" or name == "right" or name == "home" or name == "end" then
		local target
		if name == "home" then target = 0
		elseif name == "end" then target = #f.text
		elseif lo ~= hi and not key.shift then target = if name == "left" then lo else hi
		else target = if name == "left" then boundary_before(f.text, cursor) else boundary_after(f.text, cursor) end
		f.anchor = if key.shift then (anchor or cursor) else nil
		f.cursor = target
		return true
	elseif name == "backspace" or name == "delete" then
		if lo == hi then
			if name == "backspace" then lo = boundary_before(f.text, cursor) else hi = boundary_after(f.text, cursor) end
		end
		if lo == hi then return false end
		replace(f, lo, hi, "")
		return true
	end
	if multiline and (name == "up" or name == "down") then
		local text = f.text
		local start = line_start(text, cursor)
		local col = utf8.len(string.sub(text, start + 1, cursor)) or (cursor - start)
		local target
		if name == "up" then
			if start == 0 then target = 0 else
				local prev = line_start(text, start - 1)
				local width = utf8.len(string.sub(text, prev + 1, start - 1)) or (start - 1 - prev)
				target = prev + (utf8.offset(string.sub(text, prev + 1, start - 1), math.min(col, width) + 1) or 1) - 1
			end
		else
			local nl = string.find(text, "\n", cursor + 1, true)
			if not nl then target = #text else
				local line_end = (string.find(text, "\n", nl + 1, true) or (#text + 1)) - 1
				local seg = string.sub(text, nl + 1, line_end)
				local width = utf8.len(seg) or #seg
				target = nl + (utf8.offset(seg, math.min(col, width) + 1) or (#seg + 1)) - 1
			end
		end
		f.anchor = if key.shift then (anchor or cursor) else nil
		f.cursor = target
		return true
	end
	local text = key.text
	if multiline and name == "enter" and not (key.ctrl or key.meta) then
		text = "\n"
	elseif name == "paste" then
		local pasted = string.gsub(text or "", "\r\n?", "\n")
		text = if multiline then pasted else (string.gsub(pasted, "\n+", " "))
	elseif key.meta or (key.ctrl and not key.alt) then
		return false
	elseif text == nil and name == "space" then
		text = " "
	elseif text == nil and not (key.ctrl or key.alt) and utf8.len(name) == 1 then
		text = if key.shift then string.upper(name) else name
	end
	if type(text) ~= "string" or text == "" then return false end
	if string.find(text, if multiline then "[\1-\9\11-\31\127]" else "%c") then return false end
	replace(f, lo, hi, text)
	return true
end

local function set_field(state, key: string, text: string)
	state.fields[key] = { text = text, cursor = #text }
end

-- The fields this screen draws.
local function shown_fields(state): { [string]: boolean }
	local S = state.store
	local d = S.dialog
	if d then
		if d.kind == "add" then return { f_add = true }
		elseif d.kind == "task" then return { f_args = true }
		elseif d.kind == "setting" then return { f_value = true }
		elseif d.kind == "taskform" then return View.taskform_fields(d) end
		return {}
	end
	if S.tab == "tools" then return { f_filter = true } end
	if S.tab == "tasks" then return { f_task = true } end
	return {}
end

local TAB_ORDER = { "f_add", "f_args", "f_value", "f_t_name", "f_t_run", "f_t_description", "f_t_depends", "f_t_dir", "f_t_alias",
	"f_t_sources", "f_t_outputs", "f_t_depends_post", "f_t_wait_for", "f_t_shell", "f_t_run_windows" }

-- Tab / Shift+Tab moves between the fields on screen.
local function cycle_focus(state, step: number): boolean
	local fields = shown_fields(state)
	local order = {}
	for _, k in TAB_ORDER do if fields[k] then table.insert(order, k) end end
	if #order < 2 then return false end
	local at = table.find(order, state.focus_field or "") or 0
	local nxt = order[((at - 1 + step) % #order) + 1]
	state.focus_field = nxt
	state.cx:frame({ { "focus", FIELD_PATH[nxt] } })
	return true
end

local function focus_first(state)
	local fields = shown_fields(state)
	local key
	for _, k in { "f_add", "f_args", "f_value", "f_t_name", "f_t_run", "f_t_description", "f_filter", "f_task" } do
		if fields[k] then key = k break end
	end
	state.focus_field = key
	if key then state.cx:frame({ { "focus", FIELD_PATH[key] } }) end
end

-- After any change: dialogs start with their field empty and focused; leaving one returns focus to the filter.
local function settle(state)
	local S = state.store
	local d = S.dialog
	local kind = d and d.kind
	if kind == "taskform" and not d.prefilled then
		d.prefilled = true
		for key in FIELD_PATH do
			if string.sub(key, 1, 4) == "f_t_" then set_field(state, key, (d.prefill and d.prefill[key]) or "") end
		end
	end
	if kind ~= state.dialog_seen then
		state.dialog_seen = kind
		if kind == "add" then set_field(state, "f_add", "")
		elseif kind == "task" then set_field(state, "f_args", "")
		elseif kind == "setting" then set_field(state, "f_value", "") end
		focus_first(state)
	end
	local tabkey = S.tab
	if tabkey ~= state.tab_seen then
		state.tab_seen = tabkey
		if not d then focus_first(state) end
	end
end

local function move_cursor(S, step: number)
	local order = View.order(S)
	if #order == 0 then S.cursor = nil return end
	local at = table.find(order, S.cursor or "")
	if not at then S.cursor = if step > 0 then order[1] else order[#order]
	else S.cursor = order[math.clamp(at + step, 1, #order)] end
end

local function poll(state)
	state.timer = tern.timer(TICK_MS, function()
		state.timer = nil
		if not alive(state) then return end
		Store.follow(state.store)
		if tern.now() - state.polled >= POLL_MS and not state.store.running and not state.store.dialog then
			state.polled = tern.now()
			Store.refresh(state.store)
		end
		poll(state)
	end)
end

local function field_values(state): { [string]: string }
	local out = {}
	for k, f in state.fields do out[k] = f.text end
	return out
end

local SUBMIT = { ["add.submit"] = true, ["task.run"] = true, ["setting.submit"] = true, ["taskform.submit"] = true }

local function handle_action(state, act: string, value: string?, cx)
	local S = state.store
	if act == "copy" and value then
		cx:copy(value)
		cx:toast("info", "Copied", Redaction.text(value))
		return
	end
	if SUBMIT[act] then
		Store.submit(S, field_values(state))
		return
	end
	if act == "add.pick" and S.dialog and S.dialog.kind == "add" and value then
		set_field(state, "f_add", value .. "@")
		focus_first(state)
		cx:render()
		return
	end
	if act == "history.open" and (value == nil or value == "") then
		S.selected = nil
		cx:render()
		return
	end
	if act == "select" and S.tab == "tasks" then return end
	Store.dispatch(S, act, value)
end

local Panel = {
	features = { "edit" },
	font = "sans",

	init = function(cx, args, _saved)
		local previous = running[cx.pane]
		if previous and previous.timer then previous.timer:cancel() end
		local state
		state = {
			cx = cx,
			fields = {
				f_filter = { text = "", cursor = 0 }, f_task = { text = "", cursor = 0 },
				f_add = { text = "", cursor = 0 }, f_args = { text = "", cursor = 0 }, f_value = { text = "", cursor = 0 },
			},
			polled = tern.now(),
		}
		for key in FIELD_PATH do
			if not state.fields[key] then state.fields[key] = { text = "", cursor = 0 } end
		end
		state.store = Store.new({
			surface = "block",
			redraw = function(_)
				settle(state)
				if alive(state) then cx:render() end
			end,
			effect = function(_, kind: string, data)
				if kind == "copy" then
					cx:copy(data.text)
					cx:toast("info", "Copied", Redaction.text(data.text))
					return
				end
				local query = {}
				for k, v in data do table.insert(query, encode(tostring(k)) .. "=" .. encode(tostring(v))) end
				table.sort(query)
				cx:open("mise://" .. kind .. (if #query > 0 then "?" .. table.concat(query, "&") else ""))
			end,
		})
		running[cx.pane] = state
		if args and args[1] == "tab" and args[2] then state.store.tab = args[2] end
		Store.start(state.store)
		poll(state)
		return state
	end,

	title = function(state): string?
		local S = state.store
		return if S.cwd then "mise · " .. (string.match(S.cwd, "([^/\\]+)[/\\]*$") or S.cwd) else "mise"
	end,

	view = function(state, _cx)
		local S = state.store
		S.filter = state.fields.f_filter.text
		S.task_query = state.fields.f_task.text
		local input = make_input(state)
		local opts = {}
		if not S.dialog then
			if S.tab == "tools" then opts.filter = input("f_filter", "Filter tools…", "Filter tools") end
			if S.tab == "tasks" then opts.task_filter = input("f_task", "Filter tasks…", "Filter tasks") end
		end
		local main, dock = View.render(S, opts)
		local layer = ui.col({})
		local dlg = View.dialog(S, input, function(key) return state.fields[key].text end)
		if dlg then
			local children = {
				View.button("", "dialog.close", { key = "close", icon = "x", variant = "quiet", title = "Close" }),
				View.with(ui.col(dlg.children), { key = "form", role = View.role("form") }),
				View.with(ui.row(dlg.foot), { key = "dialog-foot", role = View.role("dialog-foot") }),
			}
			layer = ui.col({ ui.node("overlay", {
				key = "dialog", modal = true, size = "md", role = View.role("dialog"),
				head = dlg.title, ["end"] = "layer.dialog.close", foot = "layer.dialog.dialog-foot",
				actions = { close = "dialog.close" },
			}, children) })
		end
		return { main = main, dock = dock, layer = layer }
	end,

	resize = function(state, cols: number, _rows: number, _cx)
		state.cols = cols
		if state.focus_field == nil then focus_first(state) end
	end,

	key = function(state, key, cx): boolean?
		local S = state.store
		local name = key.name
		local plain = not (key.ctrl or key.alt or key.meta)
		if name == "escape" or name == "esc" then
			if S.dialog then
				Store.dispatch(S, "dialog.close")
			elseif S.tab == "tools" and state.fields.f_filter.text ~= "" then
				set_field(state, "f_filter", "")
				S.cursor = nil
			elseif S.tab == "tasks" and state.fields.f_task.text ~= "" then
				set_field(state, "f_task", "")
				S.cursor = nil
			else
				return false
			end
			settle(state)
			cx:render()
			return true
		elseif name == "tab" and S.dialog then
			if cycle_focus(state, if key.shift then -1 else 1) then
				cx:render()
				return true
			end
			return false
		elseif name == "enter" and S.dialog and not (is_multiline(state.focus_field) and not (key.ctrl or key.meta)) then
			-- Enter submits; inside a multi-line field it is a line break (Ctrl+Enter submits from there).
			if S.dialog.kind == "plan" then Store.dispatch(S, "plan.run") else Store.submit(S, field_values(state)) end
			return true
		elseif not S.dialog and (name == "up" or name == "down") and plain then
			S.filter, S.task_query = state.fields.f_filter.text, state.fields.f_task.text
			move_cursor(S, if name == "down" then 1 else -1)
			cx:render()
			return true
		elseif not S.dialog and name == "enter" and plain and (S.tab == "tools" or S.tab == "tasks") then
			S.filter, S.task_query = state.fields.f_filter.text, state.fields.f_task.text
			local order = View.order(S)
			local target = if S.cursor and table.find(order, S.cursor) then S.cursor else order[1]
			if not target then return false end
			if S.tab == "tasks" then Store.dispatch(S, "task.open", string.sub(target, 6)) else Store.dispatch(S, "select", target) end
			settle(state)
			return true
		elseif name == "f5" and not S.dialog then
			Store.refresh(S)
			return true
		end
		local focused = state.focus_field
		if focused and shown_fields(state)[focused] and edit_key(state.fields[focused], key, is_multiline(focused)) then
			if focused == "f_filter" or focused == "f_task" then S.cursor = nil end
			cx:render()
			return true
		end
		return false
	end,

	event = function(state, ev, cx)
		local S = state.store
		local id = type(ev.id) == "string" and ev.id or ""
		local key = string.match(id, "([^%.]+)$")
		local f = key and state.fields[key]
		if f and not shown_fields(state)[key] then return end
		if f and ev.ev == "focus" then
			state.focus_field = key
			cx:frame({ { "focus", id } })
			return
		elseif f and ev.ev == "edit" then
			state.focus_field = key
			if type(ev.from) ~= "number" or type(ev.to) ~= "number" or type(ev.text) ~= "string" or ev.len ~= units(f.text) then return end
			local first, last = bytes(f.text, math.min(ev.from, ev.to)), bytes(f.text, math.max(ev.from, ev.to))
			local text = if is_multiline(key) then string.gsub(ev.text, "\r\n?", "\n") else string.gsub(ev.text, "[\r\n]+", "")
			f.text = string.sub(f.text, 1, first) .. text .. string.sub(f.text, last + 1)
			f.cursor = if type(ev.cursor) == "number" then bytes(f.text, ev.cursor) else first + #text
			f.anchor = nil
			if key == "f_filter" or key == "f_task" then S.cursor = nil end
			cx:render()
			return
		end
		if ev.ev ~= "action" or type(ev.act) ~= "string" then return end
		if S.dialog and not (ev.act == "dialog.close" or ev.act == "close" or SUBMIT[ev.act] or string.find(ev.act, "^plan%.") or string.find(ev.act, "^add%.")
			or string.find(ev.act, "^upgrade%.") or string.find(ev.act, "^remove%.") or string.find(ev.act, "^taskform%.") or ev.act == "trust" or ev.act == "copy" or ev.act == "open") then
			return
		end
		if ev.act == "close" then ev.act = "dialog.close" end
		handle_action(state, ev.act, ev.value, cx)
		settle(state)
		cx:render()
	end,
}

tern.block.define("panel", Panel)
