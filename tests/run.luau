-- Unit tests + self-test. Run from the repo root: lune run tests/run
local roblox = require("@lune/roblox")
local Harness = require("./harness")
local FakeWorld = require("./FakeWorld")

local Instance, Vector3, CFrame = roblox.Instance, roblox.Vector3, roblox.CFrame
local BG = Harness.load()

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("  ok    " .. name)
	else
		failed += 1
		print("  FAIL  " .. name .. "\n        " .. tostring(err))
	end
end
local function expect(cond, message)
	if not cond then
		error(message or "expectation failed", 2)
	end
end
local function near(a, b, eps, message)
	if math.abs(a - b) > (eps or 1e-3) then
		error(("%s: expected %s, got %s"):format(message or "near", tostring(b), tostring(a)), 2)
	end
end

-- A fresh world with a ground slab whose top is at y = 0.
local function setup()
	local root = Instance.new("Folder")
	root.Name = "Workspace"
	local world = FakeWorld.new(root, BG.Geometry)
	local function part(name, size, cf, parent)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Anchored = true
		p.Parent = parent or root
		return p
	end
	part("Ground", Vector3.new(400, 2, 400), CFrame.new(0, -1, 0))
	return root, world, part
end

local function checks(report, check)
	local out = {}
	for _, issue in report.issues do
		if issue.check == check then
			table.insert(out, issue)
		end
	end
	return out
end

print("Z-fighting")

test("flush faces within tolerance are found; 0.02 apart are not", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	part("FlushSign", Vector3.new(2, 2, 0.4), CFrame.new(-3, 5, -0.3)) -- front at -0.5: coplanar
	part("CloseSign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.309)) -- 0.009 out: still z-fights
	part("ClearSign", Vector3.new(2, 2, 0.4), CFrame.new(3, 5, -0.32)) -- 0.02 out: fine
	local z = checks(BG.scan(root, { world = world }), "zfight")
	expect(#z == 2, "expected 2 z-fights, got " .. #z)
	for _, issue in z do
		expect(not table.find(issue.parts, root.ClearSign), "ClearSign flagged")
	end
end)

test("back-to-back contact (part resting on another) is not z-fighting", function()
	local root, world, part = setup()
	part("Box", Vector3.new(4, 4, 4), CFrame.new(0, 2, 0))
	part("Lid", Vector3.new(4, 1, 4), CFrame.new(0, 4.5, 0))
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0)
end)

test("edge-touching coplanar faces (zero overlap area) are not z-fighting", function()
	local root, world, part = setup()
	part("TileA", Vector3.new(4, 1, 4), CFrame.new(0, 0.5, 0))
	part("TileB", Vector3.new(4, 1, 4), CFrame.new(4, 0.5, 0))
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0)
end)

test("rotated parts: coplanar faces found regardless of world orientation", function()
	local root, world, part = setup()
	local frame = CFrame.new(10, 5, 10) * CFrame.Angles(0.3, 0.7, 0.2)
	part("RotWall", Vector3.new(10, 10, 1), frame)
	part("RotSign", Vector3.new(2, 2, 0.4), frame * CFrame.new(0, 0, -0.3) * CFrame.Angles(0, 0, math.rad(30)))
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 1)
end)

test("fully transparent parts are ignored", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	part("Hitbox", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3)).Transparency = 1
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0)
end)

test("nudge plan: preview changes nothing; apply clears it; revert restores", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local sign = part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3))
	local report = BG.scan(root, { world = world })
	local plan = BG.planFixes(report)
	expect(#plan.items == 1 and plan.items[1].part == sign, "plan should move only the sign")
	near(sign.CFrame.Position.Z, -0.3, 1e-5, "preview must not move")
	BG.apply(plan)
	near(sign.CFrame.Position.Z, -0.32, 1e-4, "nudged by zFightNudge")
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0, "clean after apply")
	BG.revert(plan)
	near(sign.CFrame.Position.Z, -0.3, 1e-5, "reverted")
end)

test("a plan goes stale if its parts are edited after preview", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local sign = part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3))
	local plan = BG.planFixes(BG.scan(root, { world = world }))
	sign.CFrame += Vector3.new(1, 0, 0)
	expect(not pcall(BG.apply, plan), "apply must refuse a stale plan")
	near(sign.CFrame.Position.Z, -0.3, 1e-5, "nothing applied")
end)

test("locked and ground parts are never the one moved", function()
	local root, world, part = setup()
	local slab = part("Slab", Vector3.new(4, 1, 4), CFrame.new(0, -0.5, 0)) -- top flush with Ground top
	local plan = BG.planFixes(BG.scan(root, { world = world }))
	expect(#plan.items == 1 and plan.items[1].part == slab, "Ground must not move")
	slab.Locked = true
	local _, unfixed = BG.planFixes(BG.scan(root, { world = world }))
	expect(#unfixed == 1, "both locked: reported as unfixable")
end)

test("wedge slope face coplanar with a matching wedge is found", function()
	local root, world, part = setup()
	local function wedge(name, size, cf)
		local w = Instance.new("WedgePart")
		w.Name, w.Size, w.CFrame, w.Anchored, w.Parent = name, size, cf, true, root
		return w
	end
	wedge("RoofA", Vector3.new(8, 4, 8), CFrame.new(0, 10, 0))
	wedge("RoofTrim", Vector3.new(2, 4, 8), CFrame.new(1, 10, 0))
	local z = checks(BG.scan(root, { world = world }), "zfight")
	expect(#z == 1, "expected the wedge pair")
	expect(string.find(z[1].message, "Slope/Slope", 1, true), z[1].message)
end)

print("Layers")

test("layer n sits n * layerLift above the face, on any face", function()
	local _, _, part = setup()
	local road = part("Road", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0))
	local mark = part("Mark", Vector3.new(4, 0.1, 0.5), CFrame.new())
	BG.Layers.place(mark, road, { layer = 2, u = 3 })
	near(mark.CFrame.Position.Y - mark.Size.Y / 2, 1.05 + 0.04, 1e-4, "bottom height")
	near(mark.CFrame.Position.X, 3, 1e-4, "u offset")
	expect(mark:GetAttribute("BuildGuardLayer") == 2)

	local wall = part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 20) * CFrame.Angles(0, math.rad(90), 0))
	local sign = part("Sign", Vector3.new(3, 0.2, 1), CFrame.new())
	BG.Layers.place(sign, wall, { face = "Front", v = 2 })
	local normal = -wall.CFrame.LookVector
	near(sign.CFrame.UpVector:Dot(normal), -1, 1e-4, "sign faces out of the wall front")
	local out = (sign.CFrame.Position - wall.CFrame.Position):Dot(-normal)
	near(out, 0.5 + 0.02 + 0.1, 1e-4, "distance off the wall")
	near(sign.CFrame.Position.Y, 7, 1e-4, "v offset is up the wall")
end)

test("overlapping items on different layers don't z-fight; same layer does", function()
	local root, world, part = setup()
	local road = part("Road", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0))
	BG.Layers.place(part("Line", Vector3.new(0.6, 0.1, 8), CFrame.new()), road, { layer = 1 })
	BG.Layers.place(part("Arrow", Vector3.new(3, 0.1, 0.6), CFrame.new()), road, { layer = 2 })
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0, "different layers")
	BG.Layers.place(part("Arrow2", Vector3.new(3, 0.1, 0.6), CFrame.new()), road, { layer = 1, rotation = 45 })
	expect(#checks(BG.scan(root, { world = world }), "zfight") >= 1, "same layer overlap is caught")
end)

test("keepPosition: item stays where it was across the face, keeps its heading", function()
	local _, _, part = setup()
	local road = part("Road", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0) * CFrame.Angles(0, math.rad(30), 0))
	local start = road.CFrame * CFrame.new(4, 3, -2) * CFrame.Angles(0, math.rad(40), 0)
	local mark = part("Mark", Vector3.new(4, 0.1, 0.5), start)
	BG.Layers.place(mark, road, { layer = 1, keepPosition = true })
	local lp = road.CFrame:PointToObjectSpace(mark.CFrame.Position)
	near(lp.X, 4, 1e-3, "u kept")
	near(lp.Z, -2, 1e-3, "v kept")
	near(lp.Y, 0.5 + 0.02 + 0.05, 1e-3, "lifted onto layer 1")
	near(mark.CFrame.RightVector:Dot(start.RightVector), 1, 1e-3, "heading kept")
end)

test("layer must be a whole number >= 1", function()
	expect(not pcall(BG.Layers.lift, 0))
	expect(not pcall(BG.Layers.lift, 1.5))
end)

print("Buried / snap to ground")

test("scan accepts a list of roots and de-duplicates", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3))
	local report = BG.scan({ root.Wall, root.Sign, root.Sign }, { world = world })
	expect(report.partCount == 2 and #checks(report, "zfight") == 1)
end)

test("road under a part is buried; covers that are other roads or markings are not", function()
	local root, world, part = setup()
	part("Road_1", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0))
	part("Road_Overlap", Vector3.new(6, 1, 10), CFrame.new(8, 0.57, 0)) -- junction plate
	BG.Layers.place(part("Mark", Vector3.new(4, 0.1, 0.5), CFrame.new()), root.Road_1, { layer = 1 })
	expect(#checks(BG.scan(root, { world = world }), "buried") == 0, "no false positives")
	part("Shed", Vector3.new(4, 6, 4), CFrame.new(-5, 3, 0))
	local buried = checks(BG.scan(root, { world = world }), "buried")
	expect(#buried == 1 and buried[1].parts[1] == root.Road_1, "road under shed")
	expect(buried[1].fixItems == nil, "a shed is not ground: no auto-fix")
end)

test("something high overhead (bridge, sign gantry) is not burying", function()
	local root, world, part = setup()
	part("Road_1", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0))
	part("Gantry", Vector3.new(2, 1, 12), CFrame.new(0, 8, 0))
	expect(#checks(BG.scan(root, { world = world }), "buried") == 0)
end)

test("rails on a track bed: neither is buried or off the ground", function()
	local root, world, part = setup()
	part("TrackBed", Vector3.new(24, 0.5, 4), CFrame.new(0, 0.3, 0))
	for _, z in { -0.7, 0, 0.7 } do
		part("Rail", Vector3.new(23, 0.3, 0.3), CFrame.new(0, 0.75, z))
	end
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "buried") == 0, BG.format(report))
	expect(#checks(report, "offground") == 0, BG.format(report))
end)

test("snap: hovering road comes down, its markings ride along, ramps are skipped", function()
	local root, world, part = setup()
	local road = part("Road_Hover", Vector3.new(20, 1, 10), CFrame.new(0, 5, 0))
	local mark = BG.Layers.place(part("Mark", Vector3.new(4, 0.1, 0.5), CFrame.new()), road, { layer = 1 })
	local ramp = part("Road_Ramp", Vector3.new(10, 1, 10), CFrame.new(30, 3, 0) * CFrame.Angles(0, 0, math.rad(20)))
	local plan, skipped = BG.planSnap({ road, ramp }, { world = world })
	expect(#skipped == 1 and skipped[1].part == ramp, "ramp skipped")
	BG.apply(plan)
	near(road.CFrame.Position.Y - 0.5, 0.05, 1e-4, "road bottom at groundLift")
	near(mark.CFrame.Position.Y - mark.Size.Y / 2, 1.05 + 0.02, 1e-4, "marking moved with the road")
end)

test("snap onto terrain", function()
	local root, world, part = setup()
	world.fillTerrain(CFrame.new(0, 2, 0), Vector3.new(40, 4, 40)) -- surface at y = 4
	local road = part("Road_T", Vector3.new(10, 1, 10), CFrame.new(0, 9, 0))
	BG.apply((BG.planSnap({ road }, { world = world })))
	near(road.CFrame.Position.Y - 0.5, 4.05, 1e-4)
end)

test("road sunk slightly (within groundTolerance) is not flagged", function()
	local root, world, part = setup()
	part("Road_OK", Vector3.new(20, 1, 10), CFrame.new(0, 0.5, 0)) -- resting with no lift
	expect(#BG.scan(root, { world = world }).issues == 0)
end)

test("classification: attribute beats name; railings aren't rails", function()
	local config = BG.Config.merge()
	local p = Instance.new("Part")
	p.Name = "Railing"
	expect(BG.Classify.kind(p, config) == nil)
	p.Name = "Railroad"
	expect(BG.Classify.kind(p, config) == "Rail")
	p:SetAttribute("BuildGuardKind", "None")
	expect(BG.Classify.kind(p, config) == nil)
	p.Name = "Thing"
	p:SetAttribute("BuildGuardKind", "Track")
	expect(BG.Classify.kind(p, config) == "Track")
end)

print("Drivability")

local function ledgeScene(step)
	local root, world, part = setup()
	part("Road_A", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0))
	if step > 0 then
		part("Plinth", Vector3.new(20, step, 10), CFrame.new(20, step / 2, 0))
	end
	part("Road_B", Vector3.new(20, 1, 10), CFrame.new(20, step + 0.55, 0))
	return root, world
end

test("ledge above maxLedge flagged, at or below it not", function()
	local root, world = ledgeScene(0.6)
	expect(#checks(BG.scan(root, { world = world }), "ledge") == 1)
	root, world = ledgeScene(0.4)
	expect(#checks(BG.scan(root, { world = world }), "ledge") == 0)
	expect(#checks(BG.scan(root, { world = world, config = { maxLedge = 0.3 } }), "ledge") == 1, "config respected")
end)

test("overpass (beyond connectMaxStep) is not a ledge", function()
	local root, world, part = setup()
	part("Road_Low", Vector3.new(40, 1, 10), CFrame.new(0, 0.55, 0))
	part("Pillar", Vector3.new(2, 10, 2), CFrame.new(0, 5, 20))
	part("Road_Over", Vector3.new(10, 1, 40), CFrame.new(0, 10.55, 10))
	expect(#checks(BG.scan(root, { world = world }), "ledge") == 0)
end)

test("slope change measured between connected roads, not absolute tilt", function()
	local root, world, part = setup()
	part("Road_Flat", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0))
	local function ramp(name, degrees, fromX)
		return part(name, Vector3.new(16, 1, 10), CFrame.new(fromX, 1.05, 0) * CFrame.Angles(0, 0, math.rad(degrees)) * CFrame.new(8, -0.5, 0))
	end
	ramp("Road_R1", 10, 10)
	local slope = checks(BG.scan(root, { world = world }), "slope")
	expect(#slope == 0, "10° change is under the 15° limit")
	-- A second ramp continuing at 20° from the end of the first: 10° change.
	local r1 = root.Road_R1
	local topEnd = r1.CFrame:PointToWorldSpace(Vector3.new(8, 0.5, 0))
	part("Road_R2", Vector3.new(16, 1, 10), CFrame.new(topEnd) * CFrame.Angles(0, 0, math.rad(20)) * CFrame.new(8, -0.5, 0))
	expect(#checks(BG.scan(root, { world = world }), "slope") == 0, "10° + 10° is fine pairwise")
	expect(#checks(BG.scan(root, { world = world, config = { maxSlopeChange = 8 } }), "slope") == 2, "both joins over 8°")
end)

print("Config")

test("unknown keys and a nudge not above tolerance are rejected", function()
	expect(not pcall(BG.Config.merge, { maxLedgee = 1 }))
	expect(not pcall(BG.Config.merge, { zFightNudge = 0.005 }))
end)

print("Self-test (planted-problem scene)")

for _, overrides in { {}, { maxLedge = 0.25, maxSlopeChange = 8 }, { maxLedge = 1, maxSlopeChange = 30 } } do
	local label = {}
	for k, v in overrides do
		table.insert(label, k .. "=" .. tostring(v))
	end
	test("self-test passes with " .. (if #label > 0 then table.concat(label, ", ") else "defaults"), function()
		local root = Instance.new("Folder")
		local result = BG.selfTest({
			world = FakeWorld.new(root, BG.Geometry),
			parent = root,
			config = overrides,
			origin = Vector3.new(4000, 0, 4000),
		})
		expect(result.passed, result.text)
		expect(#root:GetChildren() == 0, "scene cleaned up")
	end)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	error("tests failed", 0)
end
