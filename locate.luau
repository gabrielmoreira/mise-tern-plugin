--!nonstrict
-- Finding mise and reasoning about where it keeps things, without ever running a user profile.
-- Rule (spec section 6): paths shown to the user come from mise itself (`doctor --json` dirs, `ls` install_path,
-- `where`, `which`); environment variables are second; documented defaults are labelled "predicted".

local Locate = {}

local function exists(path: string): boolean
	local ok, found = pcall(tern.fs.exists, path)
	return ok and found == true
end

local function windows(): boolean
	return tern.runtime.os == "windows"
end

local function join(a: string, b: string): string
	if string.sub(a, -1) == "/" or string.sub(a, -1) == "\\" then return a .. b end
	return a .. "/" .. b
end

local function home(): string?
	return if windows() then (tern.getenv("USERPROFILE") or tern.getenv("HOME")) else tern.getenv("HOME")
end

-- "~" and "~/x" -> the home directory; the daemon only expands a leading ~ for some paths.
function Locate.expand(path: string?): string?
	if not path or path == "" then return nil end
	local h = home()
	if h and (path == "~" or string.sub(path, 1, 2) == "~/" or string.sub(path, 1, 2) == "~\\") then
		return h .. string.sub(path, 2)
	end
	if windows() then
		path = string.gsub(path, "%%([%w_]+)%%", function(name) return tern.getenv(name) or ("%" .. name .. "%") end)
	end
	return path
end

local function path_entries(): { string }
	local out = {}
	local raw = tern.getenv(if windows() then "Path" else "PATH") or tern.getenv("PATH") or ""
	local sep = if windows() then ";" else ":"
	for entry in string.gmatch(raw, "[^" .. sep .. "]+") do
		table.insert(out, (string.gsub(entry, '^"(.*)"$', "%1")))
	end
	return out
end

-- Packages directories matching a glob like `jdx.mise_*` under `dir`.
local function glob_dirs(dir: string, prefix: string): { string }
	local ok, names = pcall(tern.fs.list, dir)
	local out = {}
	if ok then
		for _, name in names do
			if string.sub(name, 1, #prefix) == prefix then table.insert(out, join(dir, name)) end
		end
	end
	return out
end

-- Candidate absolute paths in the order spec 6.1 gives, as { path, source }.
function Locate.candidates(setting: string?): { any }
	local out = {}
	local exe = if windows() then "mise.exe" else "mise"
	if setting and setting ~= "" then table.insert(out, { path = setting, source = "setting" }) end
	for _, dir in path_entries() do
		table.insert(out, { path = join(dir, exe), source = "PATH" })
	end
	local h = home()
	if windows() then
		local la = tern.getenv("LOCALAPPDATA")
		if la then
			table.insert(out, { path = join(la, "Microsoft/WinGet/Links/mise.exe"), source = "winget" })
			for _, pkg in glob_dirs(join(la, "Microsoft/WinGet/Packages"), "jdx.mise_") do
				table.insert(out, { path = join(pkg, "mise/bin/mise.exe"), source = "winget" })
			end
		end
		if h then
			table.insert(out, { path = join(h, "scoop/shims/mise.exe"), source = "scoop" })
			table.insert(out, { path = join(h, ".local/bin/mise.exe"), source = "standalone" })
			table.insert(out, { path = join(h, ".cargo/bin/mise.exe"), source = "cargo" })
		end
		table.insert(out, { path = "C:/ProgramData/chocolatey/bin/mise.exe", source = "choco" })
	else
		if h then table.insert(out, { path = join(h, ".local/bin/mise"), source = "standalone" }) end
		table.insert(out, { path = "/opt/homebrew/bin/mise", source = "brew" })
		table.insert(out, { path = "/usr/local/bin/mise", source = "brew" })
		table.insert(out, { path = "/opt/local/bin/mise", source = "macports" })
		if h then
			table.insert(out, { path = join(h, ".cargo/bin/mise"), source = "cargo" })
			table.insert(out, { path = join(h, ".nix-profile/bin/mise"), source = "nix" })
		end
	end
	return out
end

-- First existing candidate. `steps` records every probe for the Overview ("why this one").
function Locate.find(setting: string?): { path: string?, source: string?, steps: { any } }
	local steps = {}
	for _, c in Locate.candidates(setting) do
		local found = exists(c.path)
		table.insert(steps, { path = c.path, source = c.source, found = found })
		if found then
			return { path = c.path, source = c.source, steps = steps }
		end
	end
	return { path = nil, source = nil, steps = steps }
end

-- "winget", "scoop", "brew", ... judged from the path; used only to suggest a self-update command.
function Locate.install_method(path: string): string
	local p = string.lower(string.gsub(path, "\\", "/"))
	if string.find(p, "/winget/", 1, true) then return "winget"
	elseif string.find(p, "/scoop/", 1, true) then return "scoop"
	elseif string.find(p, "chocolatey", 1, true) then return "choco"
	elseif string.find(p, "/homebrew/", 1, true) or string.find(p, "/cellar/", 1, true) then return "brew"
	elseif string.find(p, "/.cargo/", 1, true) then return "cargo"
	elseif string.find(p, "/.local/bin/", 1, true) then return "standalone"
	elseif string.find(p, "/mise/", 1, true) then return "mise-managed" end
	return "unknown"
end

-- Directory variables that change which inventory mise reads (spec 6.2).
Locate.DIR_VARS = {
	"MISE_DATA_DIR", "MISE_INSTALLS_DIR", "MISE_INSTALL_STORE_DIR", "MISE_CONFIG_DIR", "MISE_CACHE_DIR", "MISE_STATE_DIR",
	"MISE_TMP_DIR", "MISE_SYSTEM_CONFIG_DIR", "MISE_GLOBAL_CONFIG_FILE", "MISE_PLUGINS_DIR", "MISE_DOWNLOADS_DIR",
	"MISE_SHIMS_DIR", "MISE_ENV", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME",
}

-- The documented defaults, labelled predictions: { data, config, cache, state, shims } for this OS and environment.
function Locate.predicted(): { [string]: string }
	local h = home() or "~"
	local out = {}
	local data = tern.getenv("MISE_DATA_DIR")
	local xdg_data = tern.getenv("XDG_DATA_HOME")
	if not data then
		if xdg_data and xdg_data ~= "" then data = xdg_data .. "/mise"
		elseif windows() then data = (tern.getenv("LOCALAPPDATA") or (h .. "/AppData/Local")) .. "/mise"
		else data = h .. "/.local/share/mise" end
	end
	out.data = data
	out.shims = tern.getenv("MISE_SHIMS_DIR") or (data .. "/shims")
	out.installs = tern.getenv("MISE_INSTALLS_DIR") or (data .. "/installs")
	local config = tern.getenv("MISE_CONFIG_DIR")
	local xdg_config = tern.getenv("XDG_CONFIG_HOME")
	if not config then
		config = if xdg_config and xdg_config ~= "" then xdg_config .. "/mise" else h .. "/.config/mise"
	end
	out.config = config
	local cache = tern.getenv("MISE_CACHE_DIR")
	local xdg_cache = tern.getenv("XDG_CACHE_HOME")
	if not cache then
		if xdg_cache and xdg_cache ~= "" then cache = xdg_cache .. "/mise"
		elseif windows() then cache = (tern.getenv("TEMP") or (h .. "/AppData/Local/Temp")) .. "/mise"
		else cache = h .. "/Library/Caches/mise" end
	end
	out.cache = cache
	local state = tern.getenv("MISE_STATE_DIR")
	local xdg_state = tern.getenv("XDG_STATE_HOME")
	if not state then
		state = if xdg_state and xdg_state ~= "" then xdg_state .. "/mise" else h .. "/.local/state/mise"
	end
	out.state = state
	return out
end

-- Where each predicted value came from: "env", or "default (predicted)".
function Locate.prediction_source(key: string): string
	local vars = {
		data = { "MISE_DATA_DIR", "XDG_DATA_HOME" }, installs = { "MISE_INSTALLS_DIR" }, config = { "MISE_CONFIG_DIR", "XDG_CONFIG_HOME" },
		cache = { "MISE_CACHE_DIR", "XDG_CACHE_HOME" }, state = { "MISE_STATE_DIR", "XDG_STATE_HOME" }, shims = { "MISE_SHIMS_DIR" },
	}
	for _, name in vars[key] or {} do
		local v = tern.getenv(name)
		if v and v ~= "" then return "env: " .. name end
	end
	return "default (predicted)"
end

local function norm(p: string): string
	local x = string.gsub(p, "\\", "/")
	x = string.gsub(x, "/+$", "")
	if windows() then x = string.lower(x) end
	return x
end

-- Rows for the Overview: { key, reported, predicted, source, differs }.
function Locate.directory_rows(reported: { [string]: any }?): { any }
	local predicted = Locate.predicted()
	local rows = {}
	for _, key in { "data", "config", "cache", "state", "shims" } do
		local rep = reported and reported[key]
		local pred = predicted[key]
		local row = { key = key, value = rep or pred, source = if rep then "reported by mise" else Locate.prediction_source(key) }
		if rep and pred and norm(rep) ~= norm(pred) then row.predicted = pred end
		table.insert(rows, row)
	end
	if reported == nil or reported.installs == nil then
		table.insert(rows, 3, { key = "installs", value = predicted.installs, source = Locate.prediction_source("installs") })
	end
	return rows
end

-- Names whose persisted user-environment value differs from this process's: read-only checks, no profile runs.
-- `read(name, cb)` fetches the persisted value (reg query / launchctl getenv); cb(value or nil).
function Locate.drift(read: (string, (string?) -> ()) -> (), done: ({ any }) -> ())
	local names = {}
	for _, name in Locate.DIR_VARS do
		if string.sub(name, 1, 5) == "MISE_" or string.sub(name, 1, 4) == "XDG_" then table.insert(names, name) end
	end
	local out, pending = {}, #names
	for _, name in names do
		read(name, function(saved)
			local live = tern.getenv(name)
			if saved and saved ~= "" and (live == nil or live == "" or norm(live) ~= norm(saved)) then
				table.insert(out, { name = name, saved = saved, live = live })
			end
			pending -= 1
			if pending == 0 then
				table.sort(out, function(a, b) return a.name < b.name end)
				done(out)
			end
		end)
	end
end

-- argv that reads one persisted variable without executing user code.
function Locate.persisted_argv(name: string): { string }?
	if windows() then return { "reg", "query", "HKCU\\Environment", "/v", name } end
	if tern.runtime.os == "macos" then return { "launchctl", "getenv", name } end
	return nil
end

-- Parses that command's stdout for the value.
function Locate.parse_persisted(stdout: string): string?
	if windows() then
		local value = string.match(stdout, "REG_[%u_]*SZ%s+([^\r\n]*)")
		return if value and value ~= "" then value else nil
	end
	local v = string.match(stdout, "^%s*(.-)%s*$")
	return if v and v ~= "" then v else nil
end

return Locate
