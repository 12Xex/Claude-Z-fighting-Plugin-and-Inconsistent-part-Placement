-- Runs the planted-problem self-test outside Studio: lune run tests/selftest
local roblox = require("@lune/roblox")
local Harness = require("./harness")
local FakeWorld = require("./FakeWorld")

local BuildGuard = Harness.load()
local root = roblox.Instance.new("Folder")
root.Name = "Workspace"
local result = BuildGuard.selfTest({ world = FakeWorld.new(root, BuildGuard.Geometry), parent = root })
print(result.text)
if not result.passed then
	error("self-test failed", 0)
end
