--[[
	Shared test helpers. Every file in tests/unit requires this (Lune caches
	it, so the pass/fail counts are shared) and registers tests with T.test.
]]
local roblox = require("@lune/roblox")
local Harness = require("./harness")
local FakeWorld = require("./FakeWorld")

local T = {}
T.roblox = roblox
T.FakeWorld = FakeWorld
T.BG = Harness.load()
-- Project numbers come from the config, so tests follow it when it changes.
T.D = T.BG.Config.defaults
T.passed, T.failed = 0, 0
T.filter = nil -- set by run.luau from the command line

function T.section(name)
	print(name)
end

function T.test(name, fn)
	if T.filter and not string.find(string.lower(name), T.filter, 1, true) then
		return
	end
	local ok, err = pcall(fn)
	if ok then
		T.passed += 1
		print("  ok    " .. name)
	else
		T.failed += 1
		print("  FAIL  " .. name .. "\n        " .. tostring(err))
	end
end

function T.expect(cond, message)
	if not cond then
		error(message or "expectation failed", 2)
	end
end

function T.near(a, b, eps, message)
	if math.abs(a - b) > (eps or 1e-3) then
		error(("%s: expected %s, got %s"):format(message or "near", tostring(b), tostring(a)), 2)
	end
end

-- A fresh world with a ground slab whose top is at y = 0.
-- Returns root, world, part(name, size, cframe, parent?).
function T.setup()
	local root = roblox.Instance.new("Folder")
	root.Name = "Workspace"
	local world = FakeWorld.new(root, T.BG.Geometry)
	local function part(name, size, cf, parent)
		local p = roblox.Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Anchored = true
		p.Parent = parent or root
		return p
	end
	part("Ground", roblox.Vector3.new(400, 2, 400), roblox.CFrame.new(0, -1, 0))
	return root, world, part
end

-- Issues of one check.
function T.checks(report, check)
	local out = {}
	for _, issue in report.issues do
		if issue.check == check then
			table.insert(out, issue)
		end
	end
	return out
end

return T
