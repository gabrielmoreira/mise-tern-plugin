--!nonstrict
-- Task definitions in mise.toml, edited as text. Only the lines the user changed are rewritten: comments, other keys,
-- sub-tables stay exactly as they were. Multi-line strings (""" and ''') are read and written as one value.
-- Anything this file cannot represent (multi-line arrays, inline tables, several run commands, line-ending
-- backslashes) is "locked": shown, never rewritten here.

local Tasks = {}

-- Keys the form knows, in the order new ones are written. kind: "str" | "list" | "bool".
Tasks.KEYS = {
	{ key = "description", kind = "str" },
	{ key = "alias", kind = "list" },
	{ key = "depends", kind = "list" },
	{ key = "depends_post", kind = "list" },
	{ key = "wait_for", kind = "list" },
	{ key = "dir", kind = "str" },
	{ key = "shell", kind = "str" },
	{ key = "sources", kind = "list" },
	{ key = "outputs", kind = "list" },
	{ key = "hide", kind = "bool" },
	{ key = "quiet", kind = "bool" },
	{ key = "silent", kind = "bool" },
	{ key = "raw", kind = "bool" },
	{ key = "run", kind = "str" },
	{ key = "run_windows", kind = "str" },
}
local KIND = {}
for _, k in Tasks.KEYS do KIND[k.key] = k.kind end
Tasks.KIND = KIND

-- TOML strings --------------------------------------------------------------------------------------------------

local ESC = { ["\\"] = "\\\\", ['"'] = '\\"', ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

function Tasks.quote(text: string): string
	return '"' .. string.gsub(text, '[%c\\"]', function(c)
		return ESC[c] or string.format("\\u%04X", string.byte(c))
	end) .. '"'
end

local UNESC = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", b = "\b", f = "\f" }

-- Reads a quoted string at `pos`; returns value and the position after it, or nil.
local function read_string(s: string, pos: number): (string?, number?)
	local q = string.sub(s, pos, pos)
	if q == "'" then
		local close = string.find(s, "'", pos + 1, true)
		if not close then return nil, nil end
		return string.sub(s, pos + 1, close - 1), close + 1
	elseif q ~= '"' then
		return nil, nil
	end
	local out, i = {}, pos + 1
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" then
			local n = string.sub(s, i + 1, i + 1)
			if n == "u" then
				local hex = string.match(s, "^%x%x%x%x", i + 2)
				if not hex then return nil, nil end
				table.insert(out, utf8.char(tonumber(hex, 16)))
				i += 6
			elseif UNESC[n] then
				table.insert(out, UNESC[n])
				i += 2
			else
				return nil, nil
			end
		elseif c == '"' then
			return table.concat(out), i + 1
		else
			table.insert(out, c)
			i += 1
		end
	end
	return nil, nil
end

local DQ, SQ = "\"\"\"", "'''"

local function unescape_basic(s: string): string?
	local out, i = {}, 1
	while i <= #s do
		local c = string.sub(s, i, i)
		if c == "\\" then
			local n = string.sub(s, i + 1, i + 1)
			if n == "u" then
				local hex = string.match(s, "^%x%x%x%x", i + 2)
				if not hex then return nil end
				table.insert(out, utf8.char(tonumber(hex, 16)))
				i += 6
			elseif UNESC[n] then
				table.insert(out, UNESC[n])
				i += 2
			else
				return nil
			end
		else
			table.insert(out, c)
			i += 1
		end
	end
	return table.concat(out)
end

-- A value opened with """ or ''' at lines[i] (`rest` is what follows `=`). Returns nil when the value is not
-- multi-line text; else { simple, value, line, last, comment, multi } where `last` is the closing line.
local function read_multi(lines: { string }, i: number, rest: string, limit: number): any
	local s = string.match(rest, "^%s*(.*)$")
	local d = string.sub(s, 1, 3)
	if d ~= DQ and d ~= SQ then return nil end
	local body = string.sub(s, 4)
	local segs, last, after = {}, nil, nil
	local close = string.find(body, d, 1, true)
	if close then
		segs[1], after, last = string.sub(body, 1, close - 1), string.sub(body, close + 3), i
	else
		segs[1] = body
		for j = i + 1, limit do
			local at = string.find(lines[j], d, 1, true)
			if at then
				table.insert(segs, string.sub(lines[j], 1, at - 1))
				after, last = string.sub(lines[j], at + 3), j
				break
			end
			table.insert(segs, lines[j])
		end
	end
	if not last then return { simple = false, line = i, last = limit } end
	local tail = string.match(after, "^%s*(.-)$")
	if tail ~= "" and string.sub(tail, 1, 1) ~= "#" then return { simple = false, line = i, last = last } end
	-- The newline right after the opening delimiter is not part of the value.
	if segs[1] == "" and #segs > 1 then table.remove(segs, 1) end
	local value = table.concat(segs, "\n")
	if d == DQ then
		value = unescape_basic(value)
		if value == nil then return { simple = false, line = i, last = last } end
	end
	return { value = value, simple = true, line = i, last = last, comment = tail, multi = d }
end

-- Parses the value after `=` on one line. Returns { value, comment } or nil when it is not representable.
local function parse_value(rest: string): any
	local s = string.match(rest, "^%s*(.-)%s*$")
	local first = string.sub(s, 1, 1)
	local function trailing(from: number): string?
		local tail = string.match(string.sub(s, from), "^%s*(.-)$")
		if tail == "" then return "" end
		if string.sub(tail, 1, 1) == "#" then return tail end
		return nil
	end
	if string.sub(s, 1, 3) == '"""' or string.sub(s, 1, 3) == "'''" then return nil end
	if first == '"' or first == "'" then
		local v, after = read_string(s, 1)
		if v == nil then return nil end
		local c = trailing(after)
		if c == nil then return nil end
		return { value = v, comment = c }
	elseif first == "[" then
		local list, i = {}, 2
		while true do
			local ws = string.match(s, "^%s*", i)
			i += #ws
			local ch = string.sub(s, i, i)
			if ch == "]" then
				local c = trailing(i + 1)
				if c == nil then return nil end
				return { value = list, comment = c }
			end
			local v, after = read_string(s, i)
			if v == nil then return nil end
			table.insert(list, v)
			i = after
			local ws2 = string.match(s, "^%s*", i)
			i += #ws2
			local sep = string.sub(s, i, i)
			if sep == "," then i += 1 elseif sep ~= "]" then return nil end
		end
	end
	local word = string.match(s, "^(%a+)")
	if word == "true" or word == "false" then
		local c = trailing(#word + 1)
		if c == nil then return nil end
		return { value = word == "true", comment = c }
	end
	return nil
end

function Tasks.encode(key: string, value: any): string
	local kind = KIND[key]
	if kind == "bool" then return if value then "true" else "false" end
	if kind == "list" then
		local parts = {}
		for _, v in value do table.insert(parts, Tasks.quote(v)) end
		return "[" .. table.concat(parts, ", ") .. "]"
	end
	-- Text with line breaks is written as a literal multi-line string, which keeps shell scripts readable. A value
	-- that cannot be literal (it holds ''' or a control character other than tab) falls back to one quoted line.
	if string.find(value, "\n", 1, true) and not string.find(value, "'''", 1, true) and not string.find(value, "[\1-\8\11-\31\127]") then
		return "'''\n" .. value .. "\n'''"
	end
	return Tasks.quote(value)
end

-- Locating the block --------------------------------------------------------------------------------------------------

-- "tasks.\"a.b\".env" -> { "tasks", "a.b", "env" }
local function parse_path(s: string): { string }?
	local out, i = {}, 1
	while i <= #s do
		local ws = string.match(s, "^%s*", i)
		i += #ws
		local c = string.sub(s, i, i)
		local seg
		if c == '"' or c == "'" then
			seg, i = read_string(s, i)
			if seg == nil then return nil end
		else
			seg = string.match(s, "^([%w_%-]+)", i)
			if not seg then return nil end
			i += #seg
		end
		table.insert(out, seg)
		ws = string.match(s, "^%s*", i)
		i += #ws
		local sep = string.sub(s, i, i)
		if sep == "." then i += 1 elseif sep ~= "" then return nil end
	end
	return out
end

local function split_lines(text: string): ({ string }, string)
	local eol = if string.find(text, "\r\n", 1, true) then "\r\n" else "\n"
	local lines = {}
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		table.insert(lines, (string.gsub(line, "\r$", "")))
	end
	if lines[#lines] == "" then table.remove(lines) end
	return lines, eol
end
Tasks.split_lines = split_lines

local function header_of(line: string): { string }?
	if string.match(line, "^%s*%[%[") then return nil end
	local inner = string.match(line, "^%s*%[(.-)%]%s*#?.*$")
	if not inner or string.find(inner, "^%s*%[") then return nil end
	return parse_path(inner)
end

-- For each line: the table path that line opens, or nil. Multi-line strings are skipped.
local function scan(lines: { string }): { [number]: any }
	local headers, ml = {}, nil
	for i, line in lines do
		if ml then
			if string.find(line, ml, 1, true) then ml = nil end
		else
			local h = header_of(line)
			if h then
				headers[i] = h
			else
				for _, d in { '"""', "'''" } do
					local at = string.find(line, "=%s*" .. d)
					if at then
						local after = string.find(line, d, at + 1, true)
						local second = after and string.find(line, d, (select(2, string.find(line, "=%s*" .. d)) :: number) + 1, true)
						if not second then ml = d end
					end
				end
			end
		end
	end
	return headers
end

local function same_prefix(path: { string }, name: string, depth: number): boolean
	return path[1] == "tasks" and path[2] == name and #path >= depth
end

-- Finds [tasks.<name>] (with its sub-tables). Returns
--   { kind = "table", first, last, top_last, lines = {block lines}, all = {file lines}, eol }
-- or { kind = "inline" } when the task is written as `name = ...` under [tasks], or nil.
function Tasks.find(text: string, name: string): any
	local all, eol = split_lines(text)
	local headers = scan(all)
	local first, last
	for i = 1, #all do
		local h = headers[i]
		if h then
			if first == nil and same_prefix(h, name, 2) and #h == 2 then
				first = i
				last = i
			elseif first then
				if same_prefix(h, name, 3) then last = i else break end
			end
		end
		if first and not headers[i] then last = i end
	end
	if first then
		-- Trailing blank lines belong to the gap before the next table, not to this block.
		while last > first and string.match(all[last], "^%s*$") do last -= 1 end
		local top_last = last
		for i = first + 1, last do
			if headers[i] then top_last = i - 1 break end
		end
		while top_last > first and string.match(all[top_last], "^%s*$") do top_last -= 1 end
		local lines = table.move(all, first, last, 1, {})
		return { kind = "table", first = first, last = last, top_last = top_last, lines = lines, all = all, eol = eol }
	end
	-- Inline: under `[tasks]`, a key named `name`.
	local in_tasks = false
	for i, line in all do
		local h = headers[i]
		if h then in_tasks = #h == 1 and h[1] == "tasks" end
		if not h and in_tasks then
			local key = string.match(line, "^%s*([%w_%-]+)%s*=") or string.match(line, '^%s*"([^"]+)"%s*=')
			if key == name then return { kind = "inline", line = i, all = all, eol = eol } end
		end
	end
	return nil
end

-- The values of a found table block: { [key] = { value, simple, line (index in block), comment } }.
function Tasks.read(block: any): { [string]: any }
	local out = {}
	local limit = block.top_last - block.first + 1
	local i = 2
	while i <= limit do
		local key, rest = string.match(block.lines[i], "^%s*([%w_%-]+)%s*=(.*)$")
		if key then
			local multi = read_multi(block.lines, i, rest, limit)
			if multi then
				out[key] = multi
				i = multi.last
			else
				local parsed = parse_value(rest)
				if parsed then
					out[key] = { value = parsed.value, simple = true, line = i, last = i, comment = parsed.comment }
				else
					out[key] = { simple = false, line = i, last = i }
				end
			end
		end
		i += 1
	end
	return out
end

-- Form model ----------------------------------------------------------------------------------------------------------

-- What the form shows for a block: { values = {key -> string}, bools = {key -> bool}, locked = {key -> reason} }.
function Tasks.form(block: any): any
	local read = Tasks.read(block)
	local values, bools, locked = {}, {}, {}
	for _, k in Tasks.KEYS do
		local e = read[k.key]
		if e then
			if not e.simple then
				locked[k.key] = "multi-line value"
			elseif k.key == "run" and type(e.value) == "table" then
				if #e.value == 1 then values.run = e.value[1] else locked.run = tostring(#e.value) .. " commands" end
			elseif k.kind == "bool" then
				bools[k.key] = e.value == true
			elseif k.kind == "list" then
				if type(e.value) == "string" then values[k.key] = e.value else values[k.key] = table.concat(e.value, ", ") end
			elseif type(e.value) == "string" and e.multi then
				if k.kind == "list" then locked[k.key] = "multi-line value" else values[k.key] = (string.gsub(e.value, "%s+$", "")) end
			elseif type(e.value) == "string" then
				values[k.key] = e.value
			else
				locked[k.key] = "unexpected type"
			end
		end
	end
	return { values = values, bools = bools, locked = locked, read = read }
end

local function split_list(text: string): { string }
	local out = {}
	for part in string.gmatch(text, "[^,]+") do
		local v = string.match(part, "^%s*(.-)%s*$")
		if v ~= "" then table.insert(out, v) end
	end
	return out
end
Tasks.split_list = split_list

-- Turns what the user typed into key -> value (nil = unset) for the keys that differ from `form`.
-- `typed.values[key]` strings, `typed.bools[key]` booleans. Locked keys are never touched.
function Tasks.changes(form: any, typed: any): { { string | any } }
	local out = {}
	for _, k in Tasks.KEYS do
		local key = k.key
		if not form.locked[key] then
			if k.kind == "bool" then
				local was, now = form.bools[key] == true, typed.bools[key] == true
				if was ~= now then table.insert(out, { key, if now then true else nil }) end
			else
				local text = string.match(typed.values[key] or "", "^%s*(.-)%s*$")
				local was = form.values[key] or ""
				if text ~= was then
					if text == "" then
						table.insert(out, { key, nil })
					elseif k.kind == "list" then
						table.insert(out, { key, split_list(text) })
					else
						table.insert(out, { key, text })
					end
				end
			end
		end
	end
	return out
end

-- A multi-line value is built as one string; the block is a list of single lines.
local function push_lines(out: { string }, text: string)
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do table.insert(out, line) end
end

-- Rewrites the top-level lines of a block. `changes` is { { key, value|nil }, … }. Returns new block lines, or nil
-- and a reason (a locked key cannot be rewritten).
function Tasks.apply(block: any, changes: { any }): ({ string }?, string?)
	local lines = table.clone(block.lines)
	local read = Tasks.read(block)
	local removed = {}
	local inserts = {}
	for _, c in changes do
		local key, value = c[1], c[2]
		local e = read[key]
		if e and not e.simple then return nil, key .. " is written over several lines; edit it in the source." end
		if e then
			if value == nil then
				for l = e.line, e.last or e.line do removed[l] = true end
			else
				lines[e.line] = key .. " = " .. Tasks.encode(key, value) .. (if e.comment and e.comment ~= "" then "  " .. e.comment else "")
				for l = e.line + 1, e.last or e.line do removed[l] = true end
			end
		elseif value ~= nil then
			table.insert(inserts, key .. " = " .. Tasks.encode(key, value))
		end
	end
	local top = block.top_last - block.first + 1
	local out = {}
	for i, line in lines do
		if not removed[i] then push_lines(out, line) end
		if i == top then
			for _, ins in inserts do push_lines(out, ins) end
		end
	end
	return out
end

-- Splices block lines back into the file; nil `lines` deletes the block.
function Tasks.splice(block: any, lines: { string }?): string
	local out = {}
	for i = 1, block.first - 1 do table.insert(out, block.all[i]) end
	for _, l in lines or {} do table.insert(out, l) end
	local start = block.last + 1
	if lines == nil then
		-- Drop one blank line that separated the block from what follows.
		while start <= #block.all and string.match(block.all[start], "^%s*$") and #out > 0 and string.match(out[#out], "^%s*$") do start += 1 end
	end
	for i = start, #block.all do table.insert(out, block.all[i]) end
	return table.concat(out, block.eol) .. block.eol
end

function Tasks.header(name: string): string
	if string.match(name, "^[%w_%-]+$") then return "[tasks." .. name .. "]" end
	return "[tasks." .. Tasks.quote(name) .. "]"
end

-- A new block from typed values (for previews and the create form).
function Tasks.new_block(name: string, typed: any): { string }
	local lines = { Tasks.header(name) }
	for _, c in Tasks.changes({ locked = {}, values = {}, bools = {} }, typed) do
		if c[2] ~= nil then push_lines(lines, c[1] .. " = " .. Tasks.encode(c[1], c[2])) end
	end
	return lines
end

-- A readable change summary: lines only in `before` are "-", only in `after` "+".
function Tasks.diff(before: { string }, after: { string }): { string }
	local count = {}
	for _, l in before do count[l] = (count[l] or 0) + 1 end
	local seen = {}
	for _, l in after do seen[l] = (seen[l] or 0) + 1 end
	local out = {}
	local budget = table.clone(seen)
	for _, l in before do
		if (budget[l] or 0) > 0 then budget[l] -= 1 else table.insert(out, "- " .. l) end
	end
	local have = table.clone(count)
	for _, l in after do
		if (have[l] or 0) > 0 then have[l] -= 1 else table.insert(out, "+ " .. l) end
	end
	return out
end

return Tasks
