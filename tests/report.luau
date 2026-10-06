-- Prints what BuildGuard reports on the test scene before and after fixing:
--   lune run tests/report
local roblox = require("@lune/roblox")
local Harness = require("./harness")
local FakeWorld = require("./FakeWorld")

local BuildGuard = Harness.load()
local root = roblox.Instance.new("Folder")
root.Name = "Workspace"
local world = FakeWorld.new(root, BuildGuard.Geometry)
local options = { world = world }
local scene = BuildGuard.TestScene.build(root, world, BuildGuard.Config.merge())

print("=== Before ===")
print(BuildGuard.check(scene.folder, options))
local result = BuildGuard.fixAll(scene.folder, options)
print(("\n=== After fixAll (%d pass(es)) ==="):format(#result.plans))
print(BuildGuard.format(result.report))
