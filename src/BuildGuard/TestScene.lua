--[[
	A deliberately messy scene with planted problems, plus "control" parts
	built correctly that must never be flagged or moved.

	Each planted part carries a BuildGuardPlanted attribute (its id) and each
	control a BuildGuardControl attribute, so you can inspect them in Studio.

	Planted problems (expect: "fix" = must be found then fixed,
	                          "flag" = must be found and stay reported):
	  P1  ShopSign           zfight     fix   sign half-sunk into a wall, front faces coplanar
	  P2  LaneMarking_Flush  zfight     fix   marking whose top is flush with the road top
	  P3  Window             zfight     fix   window exactly as thick as its wall (both sides coplanar)
	  P4  CrossMarkB         zfight     fix   two crossing markings at the same height
	  P5  Road_HillCut       buried     fix   road under a terrain hill
	  P6  Rail_Yard          buried     flag  rail under a crate (no safe automatic fix)
	  P7  Road_Sunk          buried     fix   road sunk into the ground slab
	  P8  Segment_Floating   offground  fix   road hovering above the ground (kind set by attribute)
	  P9  Road_B_Raised      ledge      flag  road joined to another with a step above maxLedge
	  P10 Road_C_Steep       slope      flag  road joined to another at more than maxSlopeChange

	The ledge and slope sizes are derived from the config, so the scene still
	plants a real violation (and a real non-violation) whatever limits you set.

	The MountainPass model carries a BuildGuard_maxSlopeChange attribute, so
	its steep join is allowed: a control proving per-model overrides work.
]]

local Layers = require(script.Parent.Layers)

local TestScene = {}

local ASPHALT = Color3.fromRGB(60, 60, 64)
local PAINT = Color3.fromRGB(240, 240, 235)

function TestScene.build(parent, world, config, origin)
	origin = origin or Vector3.zero
	local base = CFrame.new(origin)
	local folder = Instance.new("Folder")
	folder.Name = "BuildGuardTestScene"
	local planted, controls = {}, {}

	local function part(name, size, cframe, color, material)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = base * cframe
		p.Anchored = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Color = color or ASPHALT
		p.Material = material or Enum.Material.SmoothPlastic
		p.Parent = folder
		return p
	end
	local function plant(p, id, check, expect, note)
		p:SetAttribute("BuildGuardPlanted", id)
		table.insert(planted, { id = id, part = p, check = check, expect = expect, note = note })
		return p
	end
	local function control(p)
		p:SetAttribute("BuildGuardControl", true)
		table.insert(controls, p)
		return p
	end
	local function road(name, size, cframe)
		return part(name, size, cframe, ASPHALT, Enum.Material.Asphalt)
	end

	part("Ground", Vector3.new(240, 2, 240), CFrame.new(0, -1, 0), Color3.fromRGB(90, 140, 70), Enum.Material.Grass)

	-- Shop wall with a sign, a window and a correctly layered sign.
	local wall = part("ShopWall", Vector3.new(20, 12, 1), CFrame.new(-60, 6, -60), Color3.fromRGB(150, 90, 70), Enum.Material.Brick)
	plant(
		part("ShopSign", Vector3.new(8, 2, 0.4), CFrame.new(-60, 9, -60.3), Color3.fromRGB(200, 40, 40)),
		"P1",
		"zfight",
		"fix",
		"sign half-sunk into wall"
	)
	plant(
		part("Window", Vector3.new(4, 4, 1), CFrame.new(-55, 5, -60), Color3.fromRGB(150, 200, 230), Enum.Material.Glass),
		"P3",
		"zfight",
		"fix",
		"window as thick as the wall"
	)
	control(Layers.place(
		part("ShopSign_Layered", Vector3.new(6, 0.4, 1.5), CFrame.new(), Color3.fromRGB(40, 90, 200)),
		wall,
		{ face = "Front", layer = 1, u = -4, v = -3, config = config }
	))

	-- Main road with bad and good markings.
	local main = road("Road_Main", Vector3.new(100, 1, 16), CFrame.new(0, 0.55, 0))
	plant(part("LaneMarking_Flush", Vector3.new(6, 0.1, 0.5), CFrame.new(-30, 1.0, 0), PAINT), "P2", "zfight", "fix", "flush with road top")
	part("CrossMarkA", Vector3.new(8, 0.1, 0.4), CFrame.new(20, 1.1, 0), PAINT)
	plant(part("CrossMarkB", Vector3.new(0.4, 0.1, 8), CFrame.new(20, 1.1, 0), PAINT), "P4", "zfight", "fix", "crossing markings, same height")
	control(Layers.place(part("LaneMarking_Layered", Vector3.new(6, 0.1, 0.5), CFrame.new(), PAINT), main, { layer = 1, u = -10, config = config }))

	-- Road cut through a terrain hill.
	plant(road("Road_HillCut", Vector3.new(12, 1, 8), CFrame.new(-60, 0.55, 40)), "P5", "buried", "fix", "under terrain hill")
	local hill = { cframe = base * CFrame.new(-60, 4, 40), size = Vector3.new(16, 8, 16) }
	world.fillTerrain(hill.cframe, hill.size, "Grass")

	-- Rail with a crate dumped on it.
	plant(part("Rail_Yard", Vector3.new(20, 0.5, 1), CFrame.new(40, 0.3, 40), Color3.fromRGB(110, 110, 120), Enum.Material.Metal), "P6", "buried", "flag", "crate on top")
	part("Crate", Vector3.new(4, 4, 4), CFrame.new(40, 2, 40), Color3.fromRGB(160, 120, 70), Enum.Material.WoodPlanks)

	-- Road sunk into the ground slab, and one hovering above it.
	plant(road("Road_Sunk", Vector3.new(20, 1, 10), CFrame.new(60, -1, -40)), "P7", "buried", "fix", "sunk into ground")
	local floating = road("Segment_Floating", Vector3.new(20, 1, 10), CFrame.new(60, 3.5, 60))
	floating:SetAttribute("BuildGuardKind", "Road")
	plant(floating, "P8", "offground", "fix", "hovering 2.95 studs")

	-- Drivability: a ledge and a steep slope off Road_A.
	local ledge = math.min(config.maxLedge * 3, (config.maxLedge + config.connectMaxStep) / 2)
	local steep = math.min(config.maxSlopeChange + 25, 75)
	road("Road_A", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, -80))
	part("Plinth", Vector3.new(20, ledge, 10), CFrame.new(20, ledge / 2, -80), Color3.fromRGB(170, 170, 160), Enum.Material.Concrete)
	plant(road("Road_B_Raised", Vector3.new(20, 1, 10), CFrame.new(20, ledge + 0.55, -80)), "P9", "ledge", "flag", ("%.2f stud step"):format(ledge))
	plant(
		road("Road_C_Steep", Vector3.new(16, 1, 10), CFrame.new(-10, 1.05, -80) * CFrame.Angles(0, 0, -math.rad(steep)) * CFrame.new(-8, -0.5, 0)),
		"P10",
		"slope",
		"flag",
		("%.0f° ramp"):format(steep)
	)

	-- Controls: a gentle ramp, a correctly built road, rail and track.
	local gentle = config.maxSlopeChange / 2
	control(road("Road_E", Vector3.new(20, 1, 10), CFrame.new(60, 0.55, -80)))
	control(road("Road_F_Gentle", Vector3.new(16, 1, 10), CFrame.new(70, 1.05, -80) * CFrame.Angles(0, 0, math.rad(gentle)) * CFrame.new(8, -0.5, 0)))
	local good = control(road("Road_Good", Vector3.new(30, 1, 12), CFrame.new(0, 0.55, 80)))
	control(Layers.place(part("StopLine", Vector3.new(0.6, 0.1, 10), CFrame.new(), PAINT), good, { layer = 1, u = 10, config = config }))
	control(Layers.place(part("Arrow", Vector3.new(3, 0.1, 0.6), CFrame.new(), PAINT), good, { layer = 2, u = 10, config = config }))
	control(part("Rail_Good", Vector3.new(20, 0.5, 1), CFrame.new(-40, 0.3, 80), Color3.fromRGB(110, 110, 120), Enum.Material.Metal))
	control(part("TrackBed_Good", Vector3.new(24, 0.5, 4), CFrame.new(-40, 0.3, 100), Color3.fromRGB(120, 105, 90), Enum.Material.Slate))
	for _, z in { -0.7, 0.7 } do
		control(part("Rail_OnBed", Vector3.new(23, 0.3, 0.3), CFrame.new(-40, 0.75, 100 + z), Color3.fromRGB(110, 110, 120), Enum.Material.Metal))
	end

	-- Per-model override: MountainPass allows its own steep join.
	local pass = Instance.new("Model")
	pass.Name = "MountainPass"
	pass:SetAttribute("BuildGuard_maxSlopeChange", steep + 10)
	pass:SetAttribute("BuildGuardConfigReason", "switchback mountain road")
	pass.Parent = folder
	control(road("Road_M1", Vector3.new(20, 1, 10), CFrame.new(-60, 0.55, -100))).Parent = pass
	control(road("Road_M2_Steep", Vector3.new(16, 1, 10), CFrame.new(-50, 1.05, -100) * CFrame.Angles(0, 0, math.rad(steep)) * CFrame.new(8, -0.5, 0))).Parent = pass

	folder.Parent = parent
	return { folder = folder, planted = planted, controls = controls, terrain = { hill }, overrideModel = pass }
end

function TestScene.destroy(scene, world)
	for _, block in scene.terrain do
		world.clearTerrain(block.cframe, block.size)
	end
	scene.folder:Destroy()
end

return TestScene
