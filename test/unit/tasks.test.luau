--!nonstrict
local Lib = require("../lib")
local Shim = require("../shim")
local check, eq = Lib.check, Lib.eq
local DQ, SQ = "\"\"\"", "'''"
local Tasks = Shim.load(Lib.root() .. "/tasks.luau")

local DOC = [[
# project file
[tools]
node = "22"

[tasks.build]
description = "Build the app"   # shown in lists
depends = ["lint", "gen"]
run = [
  "echo one",
  "echo two",
]

[tasks.build.env]
FOO = "bar"

[tasks."test:unit"]
run = "bun test"
quiet = true

[tasks.lint]
run = '''
echo "[tasks.fake]"
'''
hide = false
]]

Lib.section("find")
local b = Tasks.find(DOC, "build")
check("table block found", b and b.kind == "table")
eq("starts at its header", b.lines[1], "[tasks.build]")
eq("includes the sub-table", b.lines[#b.lines], 'FOO = "bar"')
check("top region stops before the sub-table", b.top_last < b.last)
local q = Tasks.find(DOC, "test:unit")
eq("quoted name", q.lines[1], '[tasks."test:unit"]')
eq("ends at the next table", q.lines[#q.lines], "quiet = true")
local l = Tasks.find(DOC, "lint")
eq("a fake header inside a multi-line string is not a block", #l.lines, 5)
check("missing task", Tasks.find(DOC, "nope") == nil)
local inline = Tasks.find("[tasks]\nfoo = \"echo hi\"\n", "foo")
eq("inline form recognised", inline and inline.kind, "inline")

Lib.section("form reads what is simple and locks the rest")
local f = Tasks.form(b)
eq("description", f.values.description, "Build the app")
eq("depends as text", f.values.depends, "lint, gen")
eq("multi-line run is locked", f.locked.run, "multi-line value")
local one = Tasks.form(Tasks.find("[tasks.a]\nrun = [\"x\", \"y\"]\n", "a"))
eq("two commands on one line are locked", one.locked.run, "2 commands")
local fq = Tasks.form(q)
eq("run", fq.values.run, "bun test")
eq("quiet bool", fq.bools.quiet, true)
eq("literal multi-line string is read as text", Tasks.form(l).values.run, 'echo "[tasks.fake]"')
check("and is not locked", Tasks.form(l).locked.run == nil)
check("the key after it is still seen", Tasks.read(l).hide ~= nil and Tasks.read(l).hide.value == false)

Lib.section("changes only touch what differs")
local ch = Tasks.changes(f, { values = { description = "Build the app", depends = "lint, gen", dir = "web" }, bools = {} })
eq("one change: dir", #ch, 1)
eq("key", ch[1][1], "dir")
local ch2 = Tasks.changes(f, { values = { description = "", depends = "lint, gen, docs" }, bools = {} })
eq("two changes", #ch2, 2)
eq("description unset", ch2[1][1] .. tostring(ch2[1][2]), "descriptionnil")
eq("depends list", table.concat(ch2[2][2], "|"), "lint|gen|docs")
local ch3 = Tasks.changes(f, { values = { run = "should be ignored" }, bools = {} })
check("locked keys are ignored", #ch3 == 2 - 2 + #ch3 and not (function() for _, c in ch3 do if c[1] == "run" then return true end end end)())

Lib.section("apply keeps comments, siblings and multi-line values")
local new, err = Tasks.apply(b, { { "description", "Build it" }, { "depends", nil }, { "dir", "web" }, { "quiet", true } })
check("applied", new ~= nil, err)
local text = table.concat(new, "\n")
check("description replaced, comment kept", string.find(text, 'description = "Build it"  # shown in lists', 1, true) ~= nil, text)
check("depends removed", not string.find(text, "depends", 1, true))
check("new keys inserted at the end of the top table", string.find(text, 'dir = "web"', 1, true) ~= nil and string.find(text, "quiet = true", 1, true) ~= nil)
check("multi-line run untouched", string.find(text, '  "echo one",', 1, true) ~= nil)
check("sub-table untouched and after the new keys", (string.find(text, "[tasks.build.env]", 1, true) :: number) > (string.find(text, "quiet = true", 1, true) :: number))
local bad, why = Tasks.apply(b, { { "run", "x" } })
check("rewriting a locked key is refused", bad == nil and why ~= nil, why)

Lib.section("splice")
local out = Tasks.splice(b, new)
check("other tables untouched", string.find(out, '[tasks."test:unit"]', 1, true) ~= nil and string.find(out, 'node = "22"', 1, true) ~= nil)
check("trailing newline", string.sub(out, -1) == "\n")
local gone = Tasks.splice(b, nil)
check("delete removes the block and its sub-table", not string.find(gone, "tasks.build", 1, true) and string.find(gone, "[tasks.lint]", 1, true) ~= nil, gone)
local crlf = Tasks.splice(Tasks.find("[tasks.a]\r\nrun = \"x\"\r\n", "a"), { "[tasks.a]", 'run = "y"' })
eq("CRLF preserved", crlf, "[tasks.a]\r\nrun = \"y\"\r\n")

Lib.section("strings and new blocks")
eq("quote escapes", Tasks.quote('say "hi"\\n'), '"say \\"hi\\"\\\\n"')
eq("header bare", Tasks.header("build"), "[tasks.build]")
eq("header quoted", Tasks.header("a b"), '[tasks."a b"]')
local nb = Tasks.new_block("x", { values = { run = "echo 'a' \"b\"", description = "D", depends = "a,b" }, bools = { hide = true } })
eq("new block lines", table.concat(nb, "\n"), '[tasks.x]\ndescription = "D"\ndepends = ["a", "b"]\nhide = true\nrun = "echo \'a\' \\"b\\""')
local round = Tasks.find(table.concat(nb, "\n") .. "\n", "x")
eq("round trips through the reader", Tasks.form(round).values.run, "echo 'a' \"b\"")
local d = Tasks.diff({ "a", "b", "c" }, { "a", "B", "c" })
eq("diff", table.concat(d, "|"), "- b|+ B")

Lib.section("multi-line values")
local script = "echo one\nif [ -f x ]; then\n  echo two\nfi"
local ml_block = Tasks.find("[tasks.m]\ndescription = \"d\"\nrun = "..SQ.."\n"..script.."\n"..SQ.."  # keep\nquiet = true\n\n[tasks.n]\nrun = \"z\"\n", "m")
eq("reads a script", Tasks.form(ml_block).values.run, script)
local edited = Tasks.apply(ml_block, Tasks.changes(Tasks.form(ml_block), { values = { description = "d", run = script .. "\necho three" }, bools = { quiet = true } }))
local etext = table.concat(edited, "\n")
check("rewrites the whole value, comment kept after the closing quotes", string.find(etext, "echo three\n"..SQ.."  # keep\nquiet = true", 1, true) ~= nil, etext)
check("unchanged value is not touched", #Tasks.changes(Tasks.form(ml_block), { values = { description = "d", run = script }, bools = { quiet = true } }) == 0)
local shorter = Tasks.apply(ml_block, { { "run", "echo hi" } })
check("a script can become one line", string.find(table.concat(shorter, "\n"), 'run = "echo hi"  # keep', 1, true) ~= nil)
local gone_ml = Tasks.apply(ml_block, { { "run", nil } })
check("removing deletes every line of it", not string.find(table.concat(gone_ml, "\n"), "echo one", 1, true) and string.find(table.concat(gone_ml, "\n"), "quiet = true", 1, true) ~= nil)
local grown = Tasks.apply(Tasks.find("[tasks.g]\nrun = \"x\"\n", "g"), { { "run", "a\nb" } })
eq("one line becomes a block", table.concat(grown, "\n"), "[tasks.g]\nrun = "..SQ.."\na\nb\n"..SQ)
local needs = Tasks.encode("run", "it's "..SQ.."\nx")
eq("text holding the delimiter falls back to one quoted line", needs, '"it\'s '..SQ..'\\nx"')
local basic = Tasks.find("[tasks.b]\nrun = "..DQ.."\necho \\\"hi\\\"\n"..DQ.."\n", "b")
eq("basic multi-line strings are unescaped", Tasks.form(basic).values.run, 'echo "hi"')
local cont = Tasks.find("[tasks.c]\nrun = "..DQ.."\nabc \\\ndef\n"..DQ.."\n", "c")
check("a line-ending backslash stays locked", Tasks.form(cont).locked.run ~= nil)
local oneline = Tasks.find("[tasks.o]\nrun = "..SQ.."inline"..SQ.."\n", "o")
eq("triple quotes on one line", Tasks.form(oneline).values.run, "inline")
local crlf2 = Tasks.splice(Tasks.find("[tasks.a]\r\nrun = \"x\"\r\n", "a"), Tasks.apply(Tasks.find("[tasks.a]\r\nrun = \"x\"\r\n", "a"), { { "run", "p\nq" } }))
eq("CRLF kept across a multi-line write", crlf2, "[tasks.a]\r\nrun = "..SQ.."\r\np\r\nq\r\n"..SQ.."\r\n")

Lib.finish()
