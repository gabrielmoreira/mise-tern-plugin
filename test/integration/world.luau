--!nonstrict
-- A throwaway mise world for integration suites: every MISE_* directory lives under one temp folder.
local process = require("@lune/process")
local fs = require("@lune/fs")
local Shim = require("../shim")

local World = {}

local function tmp(): string
	local base = process.env.TEMP or process.env.TMPDIR or "/tmp"
	return (string.gsub(base, "\\", "/"))
end

function World.new(name: string?)
	local root = string.format("%s/mise-lune-%s-%d-%d", tmp(), name or "w", os.time(), math.random(1000, 9999))
	fs.writeDir(root)
	local self = { root = root }
	local function d(n: string): string
		fs.writeDir(root .. "/" .. n)
		return root .. "/" .. n
	end
	self.proj = d("proj")
	local env = {
		MISE_DATA_DIR = d("data"), MISE_INSTALLS_DIR = d("inst"), MISE_CONFIG_DIR = d("cfg"), MISE_CACHE_DIR = d("cache"),
		MISE_STATE_DIR = d("state"), MISE_TMP_DIR = d("tmp"), MISE_SYSTEM_CONFIG_DIR = d("sys"),
		MISE_GLOBAL_CONFIG_FILE = root .. "/cfg/config.toml", MISE_AUTO_INSTALL = "0", MISE_EXPERIMENTAL = "0", NO_COLOR = "1",
		MISE_CEILING_PATHS = root, MISE_ENV = "",
	}
	self.env = env
	for k, v in env do
		Shim.extra_env[k] = v
		Shim.env_override[k] = v
	end
	function self.write(rel: string, text: string)
		local path = root .. "/" .. rel
		local dir = string.match(path, "^(.*)/[^/]*$")
		if dir and not fs.isDir(dir) then fs.writeDir(dir) end
		fs.writeFile(path, text)
		return path
	end
	function self.project(rel: string, toml: string): string
		self.write(rel .. "/mise.toml", toml)
		return root .. "/" .. rel
	end
	function self.cleanup()
		pcall(fs.removeDir, root)
		for k in env do
			Shim.extra_env[k] = nil
			Shim.env_override[k] = nil
		end
	end
	return self
end

return World
