--!nonstrict
-- Pure data layer: turns mise's JSON into the rows the views draw. No tern.* calls beyond what the caller hands in,
-- so every function runs under Lune against captured fixtures.
--
-- Facts this file depends on (see test/fixtures and the spec, section 7):
--   * `ls --json` is an object keyed by tool, each value an array of version records.
--   * A record has a `source` only when a loaded config requests it; `installed` and `active` are independent.
--   * Tern's JSON decoder drops key order, so every list is sorted here.

local Model = {}

-- Decoded arrays carry Tern's protected array tag; copy into a plain table.
function Model.list(value: any): { any }
	local out = {}
	if type(value) == "table" then
		for _, item in value do
			table.insert(out, item)
		end
	end
	return out
end

-- Splits "1.10.2-rc1" into alternating numeric and text parts.
local function parts(v: string): { { number | string } }
	local out = {}
	local i = 1
	while i <= #v do
		local num = string.match(v, "^%d+", i)
		if num then
			table.insert(out, tonumber(num))
			i += #num
		else
			local word = string.match(v, "^%a+", i)
			if word then
				table.insert(out, string.lower(word))
				i += #word
			else
				i += 1
			end
		end
	end
	return out
end

-- -1, 0 or 1; numeric parts compare as numbers, a release outranks its pre-release text ("1.0" > "1.0-rc1").
function Model.version_cmp(a: string, b: string): number
	local pa, pb = parts(a), parts(b)
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i], pb[i]
		if x == nil and y == nil then return 0 end
		if x == nil then return if type(y) == "string" then 1 else -1 end
		if y == nil then return if type(x) == "string" then -1 else 1 end
		if type(x) == "number" and type(y) == "number" then
			if x ~= y then return if x < y then -1 else 1 end
		elseif type(x) == "number" then
			return 1
		elseif type(y) == "number" then
			return -1
		elseif x ~= y then
			return if x < y then -1 else 1
		end
	end
	return 0
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- `ls --json` (any scope) as records, sorted by tool then newest version first.
function Model.parse_ls(obj: any): { any }
	local out = {}
	if type(obj) ~= "table" then return out end
	for tool, versions in obj do
		for _, r in Model.list(versions) do
			if type(r) == "table" then
				local source = if type(r.source) == "table" then r.source else {}
				table.insert(out, {
					tool = tool,
					version = str(r.version) or "",
					requested = str(r.requested_version),
					install_path = str(r.install_path),
					installed = r.installed == true,
					active = r.active == true,
					source_path = str(source.path),
					source_type = str(source.type),
				})
			end
		end
	end
	table.sort(out, function(a, b)
		if a.tool ~= b.tool then return a.tool < b.tool end
		return Model.version_cmp(a.version, b.version) > 0
	end)
	return out
end

-- `outdated --json` as a map tool -> entry. `update` is true only for an installed version older than `latest`
-- (a missing tool is a Missing state, not an update; a failed or empty check is the caller's `nil`).
function Model.parse_outdated(obj: any): { [string]: any }
	local out = {}
	if type(obj) ~= "table" then return out end
	for tool, e in obj do
		if type(e) == "table" then
			local current, latest, bump = str(e.current), str(e.latest), str(e.bump)
			out[tool] = {
				tool = tool,
				requested = str(e.requested),
				current = current,
				latest = latest,
				bump = bump,
				source_path = if type(e.source) == "table" then str(e.source.path) else nil,
				update = current ~= nil and latest ~= nil and Model.version_cmp(current, latest) < 0,
			}
		end
	end
	return out
end

-- `tasks ls --json`: visible tasks, sorted by name.
function Model.parse_tasks(list: any): { any }
	local out = {}
	for _, t in Model.list(list) do
		if type(t) == "table" and type(t.name) == "string" and t.hide ~= true then
			table.insert(out, {
				name = t.name,
				description = str(t.description),
				source = str(t.source),
				dir = str(t.dir),
				aliases = Model.list(t.aliases),
				global = t.global == true,
				file = str(t.file),
				toml = str(t.source) ~= nil and string.match(string.lower(t.source), "%.toml$") ~= nil and t.file == nil,
				depends = Model.list(t.depends),
			})
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

-- `config ls --json`: the config stack as mise reports it (nearest first, as printed).
function Model.parse_config(list: any): { any }
	local out = {}
	for _, c in Model.list(list) do
		if type(c) == "table" and type(c.path) == "string" then
			table.insert(out, { path = c.path, tools = Model.list(c.tools), override = c.override == true })
		end
	end
	return out
end

-- The recognisable failure kinds in mise's stderr.
function Model.error_kind(stderr: string): string?
	local lower = string.lower(stderr)
	if string.find(lower, "not trusted", 1, true) or string.find(lower, "mise trust", 1, true) then
		return "UNTRUSTED_CONFIG"
	elseif string.find(lower, "no such tool", 1, true) or string.find(lower, "not found in registry", 1, true)
		or string.find(lower, "unknown tool", 1, true) or string.find(lower, "no backend", 1, true) then
		return "TOOL_NOT_FOUND"
	elseif string.find(lower, "unable to connect", 1, true) or string.find(lower, "dns error", 1, true)
		or string.find(lower, "error sending request", 1, true) or string.find(lower, "timed out", 1, true)
		or string.find(lower, "network", 1, true) then
		return "NETWORK"
	end
	return nil
end

-- The config path an UNTRUSTED_CONFIG error names ("... config file /x/mise.toml is not trusted").
function Model.untrusted_path(stderr: string): string?
	for line in string.gmatch(stderr, "[^\r\n]+") do
		local path = string.match(line, "[Cc]onfig file ([^%s]+) is not trusted") or string.match(line, "mise trust ([^\r\n]+)")
		if path then
			path = string.gsub(path, "^['\"]", "")
			path = string.gsub(path, "['\"]$", "")
			return path
		end
	end
	return nil
end

local function base(path: string?): string
	if not path then return "" end
	return string.match(path, "([^/\\]+)$") or path
end
Model.basename = base

-- Directory part, no trailing separator.
function Model.dirname(path: string): string
	return string.match(path, "^(.*)[/\\][^/\\]*$") or ""
end

function Model.path_key(path: string, windows: boolean): string
	local k = string.gsub(path, "\\", "/")
	return if windows then string.lower(k) else k
end

-- Case-insensitive on Windows, exact elsewhere, separators folded.
function Model.same_path(a: string?, b: string?, windows: boolean): boolean
	if not a or not b then return false end
	local x = string.gsub(a, "\\", "/")
	local y = string.gsub(b, "\\", "/")
	x = string.gsub(x, "/+$", "")
	y = string.gsub(y, "/+$", "")
	if windows then x, y = string.lower(x), string.lower(y) end
	return x == y
end

-- Which scope a config path belongs to, judged from the scope reads themselves (never from computed locations).
local function source_chip(path: string?, global_paths: { [string]: boolean }, cwd: string?, windows: boolean): string
	if not path then return "env" end
	local key = if windows then string.lower(string.gsub(path, "\\", "/")) else string.gsub(path, "\\", "/")
	if global_paths[key] then return "global" end
	if cwd and Model.same_path(Model.dirname(path), cwd, windows) then return "local" end
	return "parent dir"
end

local function key_of(path: string, windows: boolean): string
	local k = string.gsub(path, "\\", "/")
	return if windows then string.lower(k) else k
end

-- Rows for one scope. `scope_records` are what the scope's read returned; `all_records` the plain `ls --json`
-- (installed + requested). `outdated` is a map from parse_outdated, or nil when not checked.
-- Returns { requested = {...}, also = {...} }, each row:
--   { id, tool, version, requested, installed, active, source_path, install_path, badges = {{text,tone}}, status = {text,tone} }
function Model.rows(scope_records: { any }, all_records: { any }, outdated: { [string]: any }?, opts: { [string]: any }?): any
	opts = opts or {}
	local requested, also = {}, {}
	local seen = {}
	for _, r in scope_records do
		local row = table.clone(r)
		row.id = r.tool .. "@" .. r.version .. "|" .. (r.source_path or "")
		row.badges = {}
		local o = outdated and outdated[r.tool]
		if not r.installed then
			row.status = { text = "Missing", tone = "warn", rank = 1 }
		elseif o and o.update and (o.current == r.version or o.current == nil) then
			row.status = { text = "Update", tone = "accent", rank = 2 }
			row.update_to = o.latest
		elseif r.active then
			row.status = { text = "Active", tone = "ok", rank = 4 }
		else
			row.status = { text = "Installed", tone = "muted", rank = 5 }
		end
		if o and o.bump and o.bump ~= r.version then row.bump_to = o.bump end
		table.insert(requested, row)
		seen[r.tool .. "@" .. r.version] = true
	end
	for _, r in all_records do
		if not seen[r.tool .. "@" .. r.version] and r.installed then
			local row = table.clone(r)
			row.id = r.tool .. "@" .. r.version .. "|installed"
			row.badges = {}
			row.status = { text = "Not active here", tone = "muted", rank = 6 }
			row.not_requested = true
			table.insert(also, row)
		end
	end
	return { requested = requested, also = also }
end

-- Merged annotations: join the effective list with the global and local reads, naming who won.
function Model.merge(current: { any }, global: { any }?, localr: { any }?, cwd: string?, windows: boolean): { any }
	local gmap, lmap, gpaths = {}, {}, {}
	for _, r in global or {} do
		gmap[r.tool] = r
		if r.source_path then gpaths[key_of(r.source_path, windows)] = true end
	end
	for _, r in localr or {} do lmap[r.tool] = r end
	local rows = {}
	for _, r in current do
		local row = table.clone(r)
		local g, l = gmap[r.tool], lmap[r.tool]
		row.global_request = g and (g.requested or g.version)
		row.local_request = l and (l.requested or l.version)
		row.winner = source_chip(r.source_path, gpaths, cwd, windows)
		row.merge_badges = {}
		if g and l then
			if (g.requested or g.version) ~= (l.requested or l.version) then
				table.insert(row.merge_badges, { text = "override", tone = "accent" })
			else
				table.insert(row.merge_badges, { text = "same as global", tone = "muted" })
			end
		end
		table.insert(rows, row)
	end
	return rows
end

-- Case-insensitive substring over the fields people type from.
function Model.matches(row: any, query: string): boolean
	if query == "" then return true end
	local q = string.lower(query)
	for _, f in { row.tool, row.name, row.version, row.requested, row.description, row.source_path } do
		if f and string.find(string.lower(f), q, 1, true) then return true end
	end
	return false
end

-- A short human line for the widget and status: counts from a cwd's current records.
function Model.summary(current: { any }): { [string]: any }
	local missing, installed = 0, 0
	for _, r in current do
		if not r.installed then missing += 1 else installed += 1 end
	end
	return { requested = #current, installed = installed, missing = missing }
end

-- "node 24.1 · py 3.13 +3": first `limit` tools by name, then a count.
function Model.widget_text(current: { any }, limit: number): string
	if #current == 0 then return "no tools" end
	local names, shown = {}, {}
	for _, r in current do
		if not shown[r.tool] then
			shown[r.tool] = true
			table.insert(names, r)
		end
	end
	local out = {}
	for i = 1, math.min(limit, #names) do
		local r = names[i]
		local short = string.match(r.tool, "([^:/]+)$") or r.tool
		table.insert(out, short .. " " .. (r.version ~= "" and r.version or (r.requested or "?")))
	end
	local text = table.concat(out, " · ")
	if #names > limit then text ..= " +" .. tostring(#names - limit) end
	return text
end

Model.WIDGET_MODES = { "local", "global", "mixed", "merged" }
Model.WIDGET_SHOWS = { "counters", "tools" }

local function counts(list: { any }?, updates: number?): any
	local missing = 0
	for _, r in list or {} do
		if not r.installed then missing += 1 end
	end
	return { tools = #(list or {}), missing = missing, updates = updates or 0 }
end

local function count_text(label: string, c: any): string
	local out = tostring(c.tools) .. " " .. label
	if c.missing > 0 then out ..= " · " .. tostring(c.missing) .. " missing" end
	if c.updates > 0 then out ..= " · " .. tostring(c.updates) .. (if c.updates == 1 then " update" else " updates") end
	return out
end

-- The widget and status text. `snap` is the folder's snapshot { merged, localtools, updates = {merged, ["local"]} },
-- `gsnap` the global one { tools, updates }. Both may be nil while reading.
-- Returns { text, tone, title, ready }.
function Model.widget_view(snap: any, gsnap: any, mode: string, show: string): any
	local lc = snap and snap.localtools and counts(snap.localtools, snap.updates and snap.updates["local"])
	local mc = snap and snap.merged and counts(snap.merged, snap.updates and snap.updates.merged)
	local gc = gsnap and gsnap.tools and counts(gsnap.tools, gsnap.updates)
	local lines = {}
	if lc then table.insert(lines, "Local: " .. count_text("tools", lc)) end
	if gc then table.insert(lines, "Global: " .. count_text("tools", gc)) end
	if mc then table.insert(lines, "Merged: " .. count_text("tools", mc)) end
	local title = table.concat(lines, "\n")
	local primary, list, text
	if mode == "global" then
		primary, list = gc, gsnap and gsnap.tools
		if gc then text = if show == "tools" then Model.widget_text(list, 2) else count_text("global", gc) end
	elseif mode == "merged" then
		primary, list = mc, snap and snap.merged
		if mc then text = if show == "tools" then Model.widget_text(list, 2) else count_text("active", mc) end
	elseif mode == "mixed" then
		primary = mc or lc
		if lc and gc then
			text = if show == "tools" then Model.widget_text(snap.localtools, 2) .. " · " .. tostring(gc.tools) .. " global"
				else tostring(lc.tools) .. " local · " .. tostring(gc.tools) .. " global"
			local c = counts(snap.merged or snap.localtools, 0)
			if lc.missing > 0 then text ..= " · " .. tostring(lc.missing) .. " missing" end
			local u = (lc.updates or 0)
			if u > 0 then text ..= " · " .. tostring(u) .. (if u == 1 then " update" else " updates") end
			primary = lc
		end
	else
		primary, list = lc, snap and snap.localtools
		if lc then text = if show == "tools" then Model.widget_text(list, 2) else count_text("local", lc) end
	end
	if not text or not primary then return { text = "mise", tone = "muted", title = "mise: reading…", ready = false } end
	local tone = if primary.missing > 0 then "warning" elseif primary.updates > 0 then "accent" else nil
	return { text = text, tone = tone, title = title, ready = true }
end

-- A short stable hash for kv keys (FNV-1a, 32 bit), hex.
function Model.hash(text: string): string
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = (h * 16777619) % 4294967296
	end
	return string.format("%08x", h)
end

return Model
