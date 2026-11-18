--!nonstrict
-- Tiny assertion helpers shared by the Lune suites. A suite exits non-zero when any check failed.
local process = require("@lune/process")
local Lib = { passed = 0, failures = {} :: { string } }

function Lib.check(name: string, cond: any, detail: any?)
	if cond then
		Lib.passed += 1
		print("  ok   " .. name)
	else
		table.insert(Lib.failures, name)
		print("  FAIL " .. name .. (if detail ~= nil then "\n       " .. tostring(detail) else ""))
	end
end

function Lib.eq(name: string, got: any, want: any)
	Lib.check(name, got == want, "got " .. tostring(got) .. ", want " .. tostring(want))
end

function Lib.section(name: string) print("\n## " .. name) end

function Lib.finish()
	print(string.format("\n%d passed, %d failed", Lib.passed, #Lib.failures))
	for _, f in Lib.failures do print("  - " .. f) end
	process.exit(if #Lib.failures == 0 then 0 else 1)
end

-- Plugin root, from the working directory.
function Lib.root(): string
	local cwd = string.gsub(process.cwd, "\\", "/")
	return (string.gsub(cwd, "/$", ""))
end

return Lib
