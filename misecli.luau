--!nonstrict
-- The mise port: operation name + input -> argv, timeout and decoded result. argv, flags newer than the installed
-- binary and output decoding stay in here; the store calls `Cli.run(op, input, done)` and gets
-- `{ ok = true, value, text, took_ms }` or `{ ok = false, error = { code, message, stderr_tail, status } }`.
--
-- The installed binary decides which flags exist: `Cli.setup` reads `--help` of the commands whose flags moved
-- between releases (spec section 12), because the docs describe the latest mise, not the one on this machine.

local Locate = require("./locate")
local Model = require("./model")
local Redaction = require("./redaction")

local Cli = {
	exe = nil :: string?,
	version = nil :: string?,
	caps = {} :: { [string]: boolean },
	located = nil :: any,
	extra_env = {} :: { [string]: string },
}

local function has(text: string, needle: string): boolean
	return string.find(text, needle, 1, true) ~= nil
end

local function tail(text: string, bytes: number): string
	if #text <= bytes then return text end
	return "…" .. string.sub(text, -bytes)
end

local function failure(code: string, message: string, extra: { [string]: any }?): any
	local e = { code = code, message = message }
	for k, v in extra or {} do e[k] = v end
	return { ok = false, error = e }
end

-- A directory with no project config above it, so `--global` reads see every global request: mise hides a global
-- request from `ls --global` when a project config in the cwd chain overrides it.
function Cli.neutral_cwd(): string
	if tern.runtime.os == "windows" then
		return tern.getenv("TEMP") or tern.getenv("TMP") or "C:/Windows/Temp"
	end
	return tern.getenv("TMPDIR") or "/tmp"
end

local function base_env(): { [string]: string }
	local env = { NO_COLOR = "1" }
	for k, v in Cli.extra_env do env[k] = v end
	return env
end

-- Scope flag for `ls`/`outdated`/`upgrade`: nil means "no flag" (the merged/current read adds its own).
function Cli.scope_flag(cmd: string, scope: string): string?
	if scope == "global" then return "--global" end
	if scope == "local" then
		return if Cli.caps[cmd .. "_no_global"] then "--no-global" else "--local"
	end
	return nil
end

-- Operations. `cwd` is "focus" (the folder shown), "neutral" or nil (no folder).
local OPS = {
	version = { argv = function() return { "--version" } end, text = true, timeout = 5000 },
	ls = {
		argv = function(i)
			local a = { "ls", "--json" }
			if i.scope == "merged" or i.scope == "current" then table.insert(a, "--current")
			elseif i.scope == "installed" then table.insert(a, "--installed")
			elseif i.scope == "missing" then table.insert(a, "--missing")
			elseif i.scope == "prunable" then table.insert(a, "--prunable")
			elseif i.scope == "project" and Cli.caps.ls_project then table.insert(a, "--project")
			else
				local f = Cli.scope_flag("ls", i.scope or "all")
				if f then table.insert(a, f) end
			end
			if i.tool then table.insert(a, i.tool) end
			return a
		end,
		json = true, timeout = 15000,
		cwd = function(i) return if i.scope == "global" then "neutral" else "focus" end,
	},
	outdated = {
		argv = function(i)
			local a = { "outdated", "--json" }
			local f = Cli.scope_flag("outdated", i.scope or "merged")
			if f then table.insert(a, f) end
			if i.bump then table.insert(a, "--bump") end
			return a
		end,
		json = true, timeout = 60000,
		cwd = function(i) return if i.scope == "global" then "neutral" else "focus" end,
	},
	config = { argv = function() return { "config", "ls", "--json" } end, json = true, timeout = 15000 },
	tasks = { argv = function() return { "tasks", "ls", "--json" } end, json = true, timeout = 15000 },
	tasks_check = { argv = function() return { "tasks", "ls", "--json", "--hidden" } end, json = true, timeout = 15000 },
	settings = { argv = function() return { "settings", "ls", "--all", "--json-extended" } end, json = true, timeout = 15000 },
	setting_get = { argv = function(i) return { "settings", "get", i.key } end, text = true, timeout = 10000 },
	doctor = { argv = function() return { "doctor", "--json" } end, json = true, allow_fail = true, timeout = 60000 },
	registry = { argv = function() return { "registry", "--json" } end, json = true, timeout = 30000, cwd = function() return "neutral" end },
	ls_remote = { argv = function(i) return { "ls-remote", "--json", i.tool } end, json = true, timeout = 90000 },
	env = { argv = function() return { "env", "--json" } end, json = true, timeout = 15000 },
	where = { argv = function(i) return { "where", i.spec } end, text = true, timeout = 10000 },
	which = { argv = function(i) return { "which", i.bin } end, text = true, timeout = 10000 },
	cache_path = { argv = function() return { "cache", "path" } end, text = true, timeout = 10000, cwd = function() return "neutral" end },
	-- Previews: dry runs that predict, never mutate.
	use_dry = { argv = function(i) return i.argv end, text = true, timeout = 30000 },
	upgrade_dry = { argv = function(i) return i.argv end, text = true, timeout = 60000 },
	prune_dry = { argv = function(i) return i.argv end, text = true, timeout = 60000 },
	trust_path = { argv = function(i) return { "trust", i.path } end, text = true, timeout = 15000 },
	trust_show = { argv = function() return { "trust", "--show" } end, text = true, timeout = 10000 },
}
Cli.OPS = OPS

local function resolve_cwd(spec: any, input: any): string?
	local kind = if spec.cwd then spec.cwd(input) else "focus"
	if kind == "neutral" then return Cli.neutral_cwd() end
	if kind == "focus" then return input.cwd end
	return nil
end

-- Decodes a finished process for operation `spec`.
function Cli.decode(spec: any, result: any, took_ms: number): any
	if result.timed_out then
		return failure("TIMEOUT", "mise did not finish in time; it was stopped.")
	end
	local out, err = result.stdout or "", result.stderr or ""
	if result.status ~= 0 and not (spec.allow_fail and string.find(out, "^%s*[{%[]")) then
		local kind = Model.error_kind(err .. "\n" .. out)
		return failure(kind or ("EXIT_" .. tostring(result.status)), "mise exited with status " .. tostring(result.status) .. ".", {
			status = result.status,
			stderr_tail = Redaction.text(tail(err ~= "" and err or out, 2000)),
			untrusted_path = if kind == "UNTRUSTED_CONFIG" then Model.untrusted_path(err .. "\n" .. out) else nil,
		})
	end
	if spec.json then
		if string.match(out, "^%s*$") then return { ok = true, value = nil, took_ms = took_ms } end
		local ok, data = pcall(tern.json.decode, out)
		if not ok then
			return failure("BAD_OUTPUT", "mise printed something other than JSON.", { stderr_tail = Redaction.text(tail(out, 600)) })
		end
		return { ok = true, value = data, took_ms = took_ms, stderr = err }
	end
	return { ok = true, text = out, stderr = err, took_ms = took_ms }
end

-- Runs operation `op`; `done(result)` is called exactly once.
function Cli.run(op: string, input: { [string]: any }?, done: (any) -> ())
	input = input or {}
	local spec = OPS[op]
	if not spec then
		done(failure("BAD_OP", "Unknown operation " .. tostring(op)))
		return
	end
	if not Cli.exe then
		done(failure("NOT_FOUND", "mise was not found. Choose its executable in Overview."))
		return
	end
	local argv = { Cli.exe }
	for _, a in spec.argv(input) do table.insert(argv, a) end
	local cwd = resolve_cwd(spec, input)
	local started = tern.now()
	local ok, why = pcall(tern.process.run, argv, { cwd = cwd, env = base_env(), timeout_ms = spec.timeout }, function(result)
		done(Cli.decode(spec, result, tern.now() - started))
	end)
	if not ok then
		done(failure("NOT_FOUND", "Could not start mise: " .. tostring(why)))
	end
end

-- Parses "2026.10.15 windows-x64 (2026-10-19)" to "2026.10.15".
function Cli.parse_version(text: string): string?
	return string.match(text, "(%d+%.%d+%.%d+)")
end

local HELP_PROBES = {
	{ "ls", { "ls", "--help" }, { ls_no_global = "--no-global", ls_project = "--project", ls_prunable = "--prunable", ls_current = "--current" } },
	{ "outdated", { "outdated", "--help" }, { outdated_no_global = "--no-global", outdated_local = "--local", outdated_global = "--global", outdated_bump = "--bump" } },
	{ "use", { "use", "--help" }, { use_dry_run = "--dry-run", use_path = "--path", use_min_age = "--minimum-release-age", use_pin = "--pin", use_fuzzy = "--fuzzy" } },
	{ "upgrade", { "upgrade", "--help" }, { upgrade_dry_run = "--dry-run", upgrade_no_prune = "--no-prune", upgrade_min_age = "--minimum-release-age", upgrade_bump = "--bump" } },
	{ "unuse", { "unuse", "--help" }, { unuse = "--path", unuse_no_prune = "--no-prune" } },
	{ "uninstall", { "uninstall", "--help" }, { uninstall_dry_run = "--dry-run" } },
	{ "prune", { "prune", "--help" }, { prune_tools = "--tools", prune_dry_run = "--dry-run", prune_configs = "--configs" } },
	{ "install", { "install", "--help" }, { install_dry_run = "--dry-run" } },
	{ "tasks", { "tasks", "ls", "--help" }, { tasks_ls = "--json" } },
	{ "trust", { "trust", "--help" }, { trust_show = "--show" } },
}

-- Chooses the executable, reads its version and which flags it understands.
-- `setting` is the user's explicit path (may be nil). `done(info)`: { ok, path, source, version, caps, steps }.
function Cli.setup(setting: string?, done: (any) -> ())
	local found = Locate.find(setting)
	Cli.located = found
	if not found.path then
		Cli.exe, Cli.version, Cli.caps = nil, nil, {}
		done({ ok = false, steps = found.steps })
		return
	end
	local exe = found.path
	local caps, pending, version = {}, #HELP_PROBES + 1, nil
	local function finish()
		pending -= 1
		if pending > 0 then return end
		Cli.exe, Cli.version, Cli.caps = exe, version, caps
		done({ ok = version ~= nil, path = exe, source = found.source, version = version, caps = caps, steps = found.steps,
			method = Locate.install_method(exe) })
	end
	local function probe(argv: { string }, cb: (any) -> ())
		local ok = pcall(tern.process.run, { exe, table.unpack(argv) }, { env = base_env(), cwd = Cli.neutral_cwd(), timeout_ms = 10000 }, cb)
		if not ok then cb({ status = -1, stdout = "", stderr = "" }) end
	end
	probe({ "--version" }, function(r)
		version = Cli.parse_version((r.stdout or "") .. (r.stderr or ""))
		finish()
	end)
	for _, p in HELP_PROBES do
		probe(p[2], function(r)
			local text = (r.stdout or "") .. (r.stderr or "")
			if r.status == 0 then
				for key, flag in p[3] do
					if has(text, flag) then caps[key] = true end
				end
			end
			finish()
		end)
	end
end

-- Mutations and previews --------------------------------------------------------------------------------------

-- Long-running commands: streams lines through `handlers.line(text, stream)` where `tern.process.spawn` exists,
-- else collects them. `handlers.exit(status, took_ms, stderr_tail)` runs once. Returns { kill = fn }.
function Cli.exec(args: { string }, opts: { cwd: string?, timeout_ms: number? }?, handlers: any): { kill: () -> () }
	opts = opts or {}
	local argv = { Cli.exe :: string }
	for _, a in args do table.insert(argv, a) end
	local started = tern.now()
	local stderr_lines = {}
	local function finish(status: number, stderr: string?)
		local text = stderr or table.concat(stderr_lines, "\n")
		handlers.exit(status, tern.now() - started, Redaction.text(tail(text, 2000)))
	end
	if tern.process.spawn ~= nil then
		local done = false
		local ok, child = pcall(tern.process.spawn, argv, {
			cwd = opts.cwd,
			env = base_env(),
			stdout = function(line) handlers.line(line, "out") end,
			stderr = function(line)
				table.insert(stderr_lines, line)
				if #stderr_lines > 40 then table.remove(stderr_lines, 1) end
				handlers.line(line, "err")
			end,
			exit = function(r)
				if done then return end
				done = true
				finish(r.status, nil)
			end,
		})
		if not ok then
			handlers.exit(-1, 0, "Could not start mise: " .. tostring(child))
			return { kill = function() end }
		end
		return { kill = function() pcall(function() child:kill("terminate") end) end }
	end
	local ok, why = pcall(tern.process.run, argv, { cwd = opts.cwd, env = base_env(), timeout_ms = opts.timeout_ms or 15 * 60 * 1000 }, function(r)
		for line in string.gmatch((r.stdout or "") .. "\n" .. (r.stderr or ""), "[^\r\n]+") do handlers.line(line, "out") end
		finish(r.status, r.stderr or "")
	end)
	if not ok then handlers.exit(-1, 0, "Could not start mise: " .. tostring(why)) end
	return { kill = function() end }
end

return Cli
