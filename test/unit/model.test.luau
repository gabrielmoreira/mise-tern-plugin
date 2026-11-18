--!nonstrict
local fs = require("@lune/fs")
local Lib = require("../lib")
local Shim = require("../shim")
local check, eq = Lib.check, Lib.eq

local ROOT = Lib.root()
local FX = ROOT .. "/test/fixtures/windows/2026.10.15/"
local Model = Shim.load(ROOT .. "/model.luau")

local function fixture(name: string): any
	local text = fs.readFile(FX .. name)
	if string.match(text, "^%s*$") then return nil end
	return Shim.tern.json.decode(text)
end

Lib.section("version_cmp")
eq("numeric, not lexical", Model.version_cmp("1.10", "1.9"), 1)
eq("equal", Model.version_cmp("22.1.0", "22.1.0"), 0)
eq("release outranks pre-release", Model.version_cmp("1.0.0", "1.0.0-rc1"), 1)
eq("shorter older", Model.version_cmp("22", "22.1"), -1)

Lib.section("parse_ls on captured fixtures")
local all = Model.parse_ls(fixture("ls.out"))
check("ls fixture has records", #all >= 3, #all)
local by = {}
for _, r in all do by[r.tool .. "@" .. r.version] = r end
check("installed but not requested has no source", by["jq@1.7.1"] and by["jq@1.7.1"].installed and by["jq@1.7.1"].source_path == nil)
check("requested + installed is active", by["jq@1.6"] and by["jq@1.6"].active and by["jq@1.6"].requested == "1.6")
check("missing request is not installed", by["node@26.13.1"] and not by["node@26.13.1"].installed and by["node@26.13.1"].requested == "latest")
check("sorted by tool then newest first", all[1].tool == "jq" and all[1].version == "1.7.1" and all[2].version == "1.6")

Lib.section("rows: requested vs also installed")
local current = Model.parse_ls(fixture("ls-current.out"))
local groups = Model.rows(current, all, nil)
local names = {}
for _, r in groups.requested do names[r.tool] = r.status.text end
eq("jq requested here is Active", names.jq, "Active")
eq("node requested here is Missing", names.node, "Missing")
eq("one also-installed row (jq 1.7.1)", #groups.also, 1)
eq("also-installed is not active here", groups.also[1].status.text, "Not active here")
eq("also-installed names the version", groups.also[1].version, "1.7.1")

Lib.section("outdated")
local od = Model.parse_outdated(fixture("outdated.out"))
check("node is listed", od.node ~= nil)
check("a missing tool is not an Update", od.node.update == false, tostring(od.node.update))
local synthetic = Model.parse_outdated({ node = { name = "node", requested = "22", current = "22.1.0", latest = "22.3.0", bump = "22", source = { path = "/x/mise.toml" } } })
check("older installed than latest is an Update", synthetic.node.update == true)
local withod = Model.rows({ { tool = "node", version = "22.1.0", requested = "22", installed = true, active = true, source_path = "/x/mise.toml" } }, {}, synthetic)
eq("row carries the Update status", withod.requested[1].status.text, "Update")
eq("and the target", withod.requested[1].update_to, "22.3.0")

Lib.section("merge: who won")
local g = Model.parse_ls({ node = { { version = "20.19.0", requested_version = "20", installed = true, active = true, source = { type = "mise.toml", path = "C:\\Users\\x\\.config\\mise\\config.toml" } } } })
local l = Model.parse_ls({ node = { { version = "22.1.0", requested_version = "22", installed = true, active = true, source = { type = "mise.toml", path = "C:\\proj\\mise.toml" } } } })
local m = Model.merge(l, g, l, "C:/proj", true)
eq("local wins", m[1].winner, "local")
eq("override badge", m[1].merge_badges[1].text, "override")
eq("global request annotated", m[1].global_request, "20")
local m2 = Model.merge(g, g, {}, "C:/proj", true)
eq("global-only winner chip", m2[1].winner, "global")
eq("a tool requested in one place carries no merge badge (the source chip says where)", #m2[1].merge_badges, 0)

Lib.section("tasks and config")
local tasks = Model.parse_tasks(fixture("tasks-ls.out"))
eq("two tasks, alphabetical", tasks[1].name, "build")
eq("description kept", tasks[1].description, "Build the app")
check("hidden tasks are dropped", #Model.parse_tasks({ { name = "x", hide = true }, { name = "y" } }) == 1)
local cfg = Model.parse_config(fixture("config-ls.out"))
eq("config stack in mise's order", #cfg, 2)

Lib.section("errors and paths")
eq("untrusted detected", Model.error_kind("mise ERROR Config files in C:/x/mise.toml are not trusted. Run `mise trust`"), "UNTRUSTED_CONFIG")
eq("network detected", Model.error_kind("error sending request for url"), "NETWORK")
eq("other is nil", Model.error_kind("boom"), nil)
check("same path ignores case and separators on Windows", Model.same_path("C:\\Proj\\", "c:/proj", true))
check("same path is exact elsewhere", not Model.same_path("/A/b", "/a/b", false))
eq("dirname", Model.dirname("C:\\a\\b\\mise.toml"), "C:\\a\\b")

Lib.section("widget text")
eq("two tools then a count", Model.widget_text({ { tool = "node", version = "24.1.0" }, { tool = "python", version = "3.13" }, { tool = "go", version = "1.25" } }, 2), "node 24.1.0 · python 3.13 +1")
eq("backend prefix is shortened", Model.widget_text({ { tool = "aqua:pnpm/pnpm", version = "10" } }, 2), "pnpm 10")
eq("empty", Model.widget_text({}, 2), "no tools")

Lib.section("widget view: local, global, mixed, merged")
local function t(tool, installed) return { tool = tool, version = "1", installed = installed } end
local snap = { localtools = { t("node", true), t("go", false) }, merged = { t("node", true), t("go", false), t("jq", true), t("bat", true) }, updates = { ["local"] = 1, merged = 2 } }
local gsnap = { tools = { t("jq", true), t("bat", true), t("fd", true) }, updates = 0 }
local v = Model.widget_view(snap, gsnap, "local", "counters")
eq("local counters", v.text, "2 local · 1 missing · 1 update")
eq("missing makes it a warning", v.tone, "warning")
check("hover lists all three scopes", string.find(v.title, "Local: 2 tools", 1, true) and string.find(v.title, "Global: 3 tools", 1, true) and string.find(v.title, "Merged: 4 tools", 1, true), v.title)
eq("global counters", Model.widget_view(snap, gsnap, "global", "counters").text, "3 global")
eq("global tone is clean", Model.widget_view(snap, gsnap, "global", "counters").tone, nil)
eq("merged counters", Model.widget_view(snap, gsnap, "merged", "counters").text, "4 active · 1 missing · 2 updates")
eq("mixed counters", Model.widget_view(snap, gsnap, "mixed", "counters").text, "2 local · 3 global · 1 missing · 1 update")
eq("local tools", Model.widget_view(snap, gsnap, "local", "tools").text, "node 1 · go 1")
eq("mixed tools", Model.widget_view(snap, gsnap, "mixed", "tools").text, "node 1 · go 1 · 3 global · 1 missing · 1 update")
check("not ready while reading", Model.widget_view(nil, nil, "local", "counters").ready == false)
check("global needs the global snapshot", Model.widget_view(snap, nil, "global", "counters").ready == false)
check("local does not need the global snapshot", Model.widget_view(snap, nil, "local", "counters").ready == true)
eq("empty project", Model.widget_view({ localtools = {}, merged = {} }, nil, "local", "counters").text, "0 local")

Lib.section("path keys")
check("macOS /private spellings are one place", Model.same_path("/private/var/folders/x/app", "/var/folders/x/app/", false))
check("only the system links are folded", not Model.same_path("/private/home/x", "/home/x", false))
check("a folder merely named like one is not folded", not Model.same_path("/private/variable/x", "/variable/x", false))
check("Windows ignores case and separators", Model.same_path("C:\\Work\\App", "c:/work/app", true))
check("and macOS paths stay case-sensitive", not Model.same_path("/a/App", "/a/app", false))

Lib.finish()
