-- Prints checkVehicle for a sample haul truck: lune run tests/vehicle_demo
local roblox = require("@lune/roblox")
local Harness = require("./harness")
local BG = Harness.load()
local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum

local m = Instance.new("Model")
m.Name = "HaulTruck"
local function p(name, size, cf, shape)
	local x = Instance.new("Part")
	x.Name, x.Size, x.CFrame = name, size, cf
	if shape then
		x.Shape = shape
	end
	x.Parent = m
	return x
end
m.PrimaryPart = p("Chassis", Vector3.new(8, 2, 16), CFrame.new(0, 2, 0))
p("Cab", Vector3.new(8, 6, 5), CFrame.new(0, 6, -5))
for _, x in { -4.5, 4.5 } do
	for _, z in { -6, 6 } do
		p("Wheel", Vector3.new(1, 3, 3), CFrame.new(x, 1.5, z), Enum.PartType.Cylinder)
	end
end
print((BG.checkVehicle(m, nil, {})))
