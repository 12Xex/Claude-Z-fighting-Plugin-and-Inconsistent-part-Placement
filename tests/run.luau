-- Unit tests + self-test. Run from the repo root:
--   lune run tests/run              every file in tests/unit
--   lune run tests/run -- vehicle   only tests whose name contains "vehicle"
local fs = require("@lune/fs")
local process = require("@lune/process")
local T = require("./lib")

for _, arg in process.args do
	if arg ~= "--" and arg ~= "" then
		T.filter = string.lower(arg)
		break
	end
end

local files = {}
for _, name in fs.readDir("tests/unit") do
	if string.match(name, "%.luau$") then
		table.insert(files, name)
	end
end
table.sort(files, function(a, b)
	-- core first (it holds the self-test), then the rest alphabetically
	if (a == "core.luau") ~= (b == "core.luau") then
		return a == "core.luau"
	end
	return a < b
end)
for _, name in files do
	print(("== %s"):format(name))
	require("./unit/" .. string.gsub(name, "%.luau$", ""))
end

print(("\n%d passed, %d failed"):format(T.passed, T.failed))
if T.failed > 0 then
	error("tests failed", 0)
end
