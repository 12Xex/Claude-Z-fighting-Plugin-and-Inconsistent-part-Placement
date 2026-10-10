-- Shared helpers: name words, paths, spatial hash keys, corner wedges,
-- support points, place-wide config, classification, joints and vehicles.
local T = require("../lib")
local roblox, BG = T.roblox, T.BG
local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum
local test, expect, near, setup = T.test, T.expect, T.near, T.setup

local Util = require("../harness").module("Util")
local Kinematics = require("../harness").module("Kinematics")

T.section("Foundation")

test("Util.words splits names at capitals, digits and punctuation", function()
	local function same(name, expected)
		local got = Util.words(name)
		expect(table.concat(got, ",") == table.concat(expected, ","), name .. " -> " .. table.concat(got, ","))
	end
	same("RoadSign_02", { "road", "sign", "02" })
	same("HTTPServer", { "http", "server" })
	same("Wheel_FL", { "wheel", "fl" })
	same("WheelFL", { "wheel", "fl" })
	same("Railroad", { "railroad" })
	same("TrackBed_Good", { "track", "bed", "good" })
	same("BedRail", { "bed", "rail" })
	same("road 7", { "road", "7" })
	same("", {})
end)

test("Util.path tells repeated names apart and Util.find reverses it", function()
	local root = Instance.new("Model")
	root.Name = "Map"
	local tub = Instance.new("Model")
	tub.Name = "Tub"
	tub.Parent = root
	local tops = {}
	for i = 1, 3 do
		local p = Instance.new("Part")
		p.Name = "TubTop"
		p.Parent = tub
		tops[i] = p
	end
	local other = Instance.new("Part")
	other.Name = "Floor"
	other.Parent = tub
	expect(Util.path(tops[3], root) == "Map/Tub/TubTop#3", Util.path(tops[3], root))
	expect(Util.path(other, root) == "Map/Tub/Floor", Util.path(other, root))
	expect(Util.find(root, "Map/Tub/TubTop#2") == tops[2])
	expect(Util.find(root, "Map/Tub/Floor") == other)
	expect(Util.find(root, "Map/Tub/TubTop#4") == nil)
	-- Outside the given roots: the path runs from the top.
	expect(Util.path(tops[1], { other }) == "Map/Tub/TubTop#1", Util.path(tops[1], { other }))
end)

test("spatial hash keys are numbers and wrap without losing items", function()
	local SpatialHash = require("../harness").module("SpatialHash")
	expect(type(SpatialHash.key(1, -2, 3)) == "number")
	expect(SpatialHash.key(1, 2, 3) ~= SpatialHash.key(3, 2, 1))
	expect(SpatialHash.key(-1, 0, 0) == SpatialHash.key(65535, 0, 0), "wraps at 16 bits")
	local hash = SpatialHash.new(8)
	hash:insert("a", Vector3.new(-100, 0, -100), Vector3.new(-90, 5, -90))
	hash:insert("b", Vector3.new(100000, 0, 0), Vector3.new(100004, 5, 4))
	local near = hash:query(Vector3.new(-95, 1, -95), Vector3.new(-94, 2, -94))
	expect(table.find(near, "a") ~= nil)
	local far = hash:query(Vector3.new(100001, 1, 1), Vector3.new(100002, 2, 2))
	expect(table.find(far, "b") ~= nil)
end)

test("corner wedge: faces point outward, apex at +X/-Z, containment", function()
	local G = BG.Geometry
	local p = Instance.new("CornerWedgePart")
	p.Size = Vector3.new(4, 6, 8)
	p.CFrame = CFrame.new(10, 3, -2) * CFrame.Angles(0.2, 0.5, -0.1)
	local s = G.solid(p)
	expect(s.shape == "CornerWedge")
	local faces = G.faces(s)
	expect(#faces == 5)
	for _, f in faces do
		expect(f.normal:Dot(f.center - s.pos) > 0, f.name .. " points inward")
		for _, q in f.points do
			near((q - f.center):Dot(f.normal), 0, 1e-3, f.name .. " planar")
		end
	end
	local apex = s.cf:PointToWorldSpace(Vector3.new(2, 3, -4))
	near((G.support(s, s.axes[2]) - apex).Magnitude, 0, 1e-3, "highest point is the apex")
	expect(G.containsPoint(s, s.cf:PointToWorldSpace(Vector3.new(1.5, -2.5, -3.5))))
	expect(not G.containsPoint(s, s.cf:PointToWorldSpace(Vector3.new(-1.5, 2.5, 3.5))), "far top corner is empty")
	local shaped = Instance.new("Part")
	shaped.Shape = Enum.PartType.CornerWedge
	expect(G.shapeOf(shaped) == "CornerWedge")
end)

test("support points: box corner, ball surface, cylinder rim", function()
	local G = BG.Geometry
	local box = G.solidFrom(CFrame.new(), Vector3.new(2, 4, 6), "Block")
	near((G.support(box, Vector3.new(1, 1, -1)) - Vector3.new(1, 2, -3)).Magnitude, 0, 1e-6)
	local ball = G.solidFrom(CFrame.new(5, 0, 0), Vector3.new(4, 4, 4), "Ball")
	near((G.support(ball, Vector3.new(0, 3, 0)) - Vector3.new(5, 2, 0)).Magnitude, 0, 1e-6)
	local cyl = G.solidFrom(CFrame.new(), Vector3.new(2, 3, 3), "Cylinder")
	near((G.support(cyl, Vector3.new(1, -1, 0)) - Vector3.new(1, -1.5, 0)).Magnitude, 0, 1e-6)
end)

test("coplanar overlap reports where the overlap is", function()
	local G = BG.Geometry
	local wall = G.solidFrom(CFrame.new(0, 5, 0), Vector3.new(10, 10, 1), "Block")
	local sign = G.solidFrom(CFrame.new(3, 6, -0.3), Vector3.new(2, 2, 0.4), "Block")
	local found
	for _, fa in G.faces(wall) do
		for _, fb in G.faces(sign) do
			local area, _, at = G.coplanarOverlap(fa, fb, 0.01, 0.01)
			if area then
				found = at
			end
		end
	end
	expect(found ~= nil)
	near((found - Vector3.new(3, 6, -0.5)).Magnitude, 0, 1e-4, "overlap centre")
end)

test("place-wide settings reach models outside the place root", function()
	local place = Instance.new("Folder")
	place.Name = "Workspace"
	place:SetAttribute("BuildGuard_maxLedge", 0.7)
	local storage = Instance.new("Folder")
	local m = Instance.new("Model")
	m.Parent = storage
	local resolver = BG.Config.resolver(BG.Config.merge(), place)
	local config, sources = resolver.resolve(m)
	expect(config.maxLedge == 0.7 and sources.maxLedge == place)
	m:SetAttribute("BuildGuard_maxLedge", 0.5)
	expect(BG.Config.resolver(BG.Config.merge(), place).resolve(m).maxLedge == 0.5, "own setting still wins")
end)

test("face gap grows with zFightViewDistance", function()
	local C = BG.Config
	local config = C.merge()
	expect(C.faceGap(config) == config.zFightNudge)
	local far = C.merge({ zFightViewDistance = 600 })
	expect(C.faceGap(far) > config.zFightNudge)
	expect(not pcall(C.merge, { meshTriangles = 1 }), "booleans are checked")
end)

T.section("Classification")

test("names: first word plus a flat shape; signs, lamps and bed rails aren't roads", function()
	local config = BG.Config.merge()
	local function kind(name, size, shape)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size or Vector3.new(20, 1, 16)
		if shape then
			p.Shape = shape
		end
		return BG.Classify.kind(p, config)
	end
	expect(kind("Road_01") == "Road")
	expect(kind("StreetCorner") == "Road")
	expect(kind("RailYard", Vector3.new(20, 0.5, 1)) == "Rail")
	expect(kind("Railroad", Vector3.new(20, 0.5, 1)) == "Rail")
	expect(kind("TrackBed", Vector3.new(24, 0.5, 4)) == "Track")
	expect(kind("BedRail", Vector3.new(8, 0.5, 0.5)) == nil, "BedRail")
	expect(kind("RoofRail", Vector3.new(8, 0.5, 0.5)) == nil, "RoofRail")
	expect(kind("Railing", Vector3.new(8, 3, 0.5)) == nil, "Railing")
	expect(kind("Guardrail", Vector3.new(8, 1, 0.5)) == nil, "Guardrail")
	expect(kind("RoadSign", Vector3.new(6, 4, 0.2)) == nil, "RoadSign is a standing panel")
	expect(kind("StreetLamp", Vector3.new(1, 12, 1)) == nil, "StreetLamp is a pole")
	expect(kind("RoadCone", Vector3.new(1, 1, 1), Enum.PartType.Cylinder) == nil, "round parts")
	expect(kind("HaulRoad") == nil, "first word only")
	local byTag = Instance.new("Part")
	byTag.Name = "Thing"
	byTag:AddTag("Road")
	expect(BG.Classify.kind(byTag, config) == "Road", "tag")
	expect(BG.Classify.kind(byTag, BG.Config.merge({ classifyByName = false })) == "Road", "tags work with names off")
	local named = Instance.new("Part")
	named.Name = "Road_9"
	named.Size = Vector3.new(20, 1, 16)
	expect(BG.Classify.kind(named, BG.Config.merge({ classifyByName = false })) == nil, "names off")
	expect(BG.Classify.kind(named, config, nil, function()
		return true
	end) == nil, "parts of a vehicle never count by name")
end)

test("names: standing panels, layered items, steep parts and narrow strips get no kind; tags still do", function()
	local config = BG.Config.merge()
	local function make(name, size, cf, class)
		local p = Instance.new(class or "Part")
		p.Name, p.Size = name, size
		if cf then
			p.CFrame = cf
		end
		return p
	end
	local function kind(...)
		return BG.Classify.kind(make(...), config)
	end
	-- Signs, barriers and fences standing on edge.
	for _, case in {
		{ "RoadSign", Vector3.new(6, 3, 0.2) },
		{ "RoadSign", Vector3.new(8, 2, 0.2) },
		{ "Highway_Exit", Vector3.new(12, 4, 0.5) },
		{ "Road_Guardrail", Vector3.new(30, 2, 0.5) },
		{ "RoadBarrier", Vector3.new(20, 3, 1) },
		{ "RailFence", Vector3.new(20, 4, 0.5) },
	} do
		expect(kind(case[1], case[2]) == nil, case[1] .. " " .. tostring(case[2]) .. " stands on edge")
	end
	-- Real rails are taller than they're wide, but under a stud tall.
	expect(kind("Rail_1", Vector3.new(0.3, 0.7, 40)) == "Rail", "a 0.3 x 0.7 rail")
	expect(kind("Rail_2", Vector3.new(0.4, 0.6, 40)) == "Rail", "a 0.4 x 0.6 rail")
	-- Too narrow for a road.
	expect(kind("StreetLight", Vector3.new(4, 0.5, 1.5)) == nil, "a lamp head")
	expect(kind("Road_Kerb", Vector3.new(30, 0.5, 1)) == nil, "a kerb strip")
	expect(kind("Road_Lane", Vector3.new(30, 0.5, BG.Classify.ROAD_MIN_WIDTH)) == "Road", "exactly the minimum width")
	-- Layered items are details, whatever their shape.
	local line = make("RoadLine", Vector3.new(6, 0.1, 0.5))
	line:SetAttribute("BuildGuardLayer", 1)
	expect(BG.Classify.kind(line, config) == nil, "a layered lane line")
	local patch = make("Road_Patch", Vector3.new(10, 0.1, 10))
	patch:SetAttribute("BuildGuardLayer", 1)
	expect(BG.Classify.kind(patch, config) == nil, "a layered patch")
	local board = make("Board", Vector3.new(8, 6, 0.4), CFrame.new(0, 5, 0))
	local sign = BG.Layers.place(make("RoadSign", Vector3.new(6, 0.2, 4)), board, { face = "Front" })
	expect(BG.Classify.kind(sign, config) == nil, "a sign placed on a board's front")
	sign:SetAttribute("BuildGuardLayer", nil)
	expect(BG.Classify.kind(sign, config) == nil, "facing sideways, even without the layer mark")
	-- Within 45° of upright counts (ramps, and a block upside down); steeper doesn't.
	local size = Vector3.new(20, 1, 16)
	expect(kind("Road_Ramp", size, CFrame.Angles(0, 0, math.rad(20))) == "Road", "20° ramp")
	expect(kind("Road_Ramp", size, CFrame.Angles(math.rad(45), 0, 0)) == "Road", "45° ramp")
	expect(kind("Road_Wall", size, CFrame.Angles(0, 0, math.rad(60))) == nil, "60°")
	expect(kind("Road_Flipped", size, CFrame.Angles(math.pi, 0, 0)) == "Road", "upside down")
	-- Wedges by their slope; corner wedges have no flat top.
	expect(kind("Road_Ramp", Vector3.new(22, 2.9, 12), nil, "WedgePart") == "Road", "gentle wedge")
	expect(kind("Road_Steep", Vector3.new(22, 8, 4), nil, "WedgePart") == nil, "63° wedge")
	expect(kind("Road_Ramp", Vector3.new(22, 2.9, 12), CFrame.Angles(math.pi, 0, 0), "WedgePart") == nil, "wedge upside down")
	expect(kind("Road_Corner", Vector3.new(22, 2, 22), nil, "CornerWedgePart") == nil, "corner wedge")
	-- Tags and the attribute win whatever the shape.
	local tagged = make("RoadSign", Vector3.new(6, 3, 0.2))
	tagged:AddTag("Road")
	expect(BG.Classify.kind(tagged, config) == "Road", "tag")
	local steep = make("Road_Wall", size, CFrame.Angles(0, 0, math.rad(60)))
	steep:SetAttribute("BuildGuardKind", "Road")
	expect(BG.Classify.kind(steep, config) == "Road", "attribute")
end)

test("ground: BuildGuardGround on a folder covers the parts in it; the nearest marker wins", function()
	local config = BG.Config.merge()
	local floor = Instance.new("Folder")
	floor.Name = "MapFloor"
	floor:AddTag("BuildGuardGround")
	local function tile(name, parent)
		local p = Instance.new("Part")
		p.Name, p.Size, p.Parent = name, Vector3.new(200, 2, 200), parent
		return p
	end
	local a = tile("Tile", floor)
	expect(BG.Classify.isGroundLike(a, config), "tag on the folder")
	local shed = Instance.new("Model")
	shed:SetAttribute("BuildGuardGround", false)
	shed.Parent = floor
	local b = tile("ShedFloor", shed)
	expect(not BG.Classify.isGroundLike(b, config), "false on a nearer model wins")
	a:SetAttribute("BuildGuardGround", false)
	expect(not BG.Classify.isGroundLike(a, config), "false on the part itself wins")
	local cache = {}
	local c = tile("Tile2", floor)
	expect(BG.Classify.isGroundLike(c, config, cache) and BG.Classify.isGroundLike(c, config, cache), "with a cache")
	floor:RemoveTag("BuildGuardGround")
	expect(not BG.Classify.isGroundLike(tile("Tile3", floor), config), "untagged tiles are just parts")
end)

test("ground is explicit: big slabs aren't ground unless tagged or named", function()
	local config = BG.Config.merge()
	local slab = Instance.new("Part")
	slab.Name = "FloorSlab"
	slab.Size = Vector3.new(600, 1, 600)
	expect(not BG.Classify.isGroundLike(slab, config), "size alone")
	expect(BG.Classify.isGroundLike(slab, BG.Config.merge({ groundMinFootprint = 512 })), "footprint rule when switched on")
	slab:AddTag("BuildGuardGround")
	expect(BG.Classify.isGroundLike(slab, config), "tag")
	slab:SetAttribute("BuildGuardGround", false)
	expect(not BG.Classify.isGroundLike(slab, config), "attribute false beats the tag")
	local base = Instance.new("Part")
	base.Name = "Baseplate"
	base.Size = Vector3.new(512, 16, 512)
	expect(BG.Classify.isGroundLike(base, config))
	local sign = Instance.new("Part")
	sign.Name = "GroundSign"
	sign.Size = Vector3.new(6, 4, 0.2)
	expect(not BG.Classify.isGroundLike(sign, config), "not flat")
end)

test("BuildGuardIgnore works as a tag too", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local labels = Instance.new("Folder")
	labels.Name = "Labels"
	labels:AddTag("BuildGuardIgnore")
	labels.Parent = root
	part("Label", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3), labels)
	local report = BG.scan(root, { world = world })
	expect(#T.checks(report, "zfight") == 0, BG.format(report))
	expect(BG.Classify.isIgnored(labels.Label))
end)

test("wheels by name: wheel/tire + position words only", function()
	local C = BG.Classify
	for _, name in { "Wheel", "Wheel_FL", "WheelRR", "Tire_RearLeft", "Tyre2", "wheel front left" } do
		expect(C.isWheelName(name), name)
	end
	for _, name in { "SteeringWheel", "SpareWheel", "WheelArch", "Wheel_Mesh", "TireTrack", "Hubcap" } do
		expect(not C.isWheelName(name), name)
	end
end)

-- A cart with a seat, a chassis, a welded bed rail and wheels on hinges.
local function cart(parent)
	local m = Instance.new("Model")
	m.Name = "Cart"
	local function p(name, size, cf, shape)
		local x = Instance.new("Part")
		x.Name, x.Size, x.CFrame = name, size, cf
		if shape then
			x.Shape = shape
		end
		x.Parent = m
		return x
	end
	local chassis = p("Chassis", Vector3.new(6, 1, 10), CFrame.new(0, 2, 0))
	local rail = p("BedRail", Vector3.new(0.4, 0.4, 10), CFrame.new(2.8, 2.7, 0))
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1, weld.Enabled = chassis, rail, true
	weld.Parent = rail
	local wheels = {}
	for _, x in { -3.5, 3.5 } do
		for _, z in { -4, 4 } do
			local w = p("Wheel", Vector3.new(1, 2, 2), CFrame.new(x, 1, z), Enum.PartType.Cylinder)
			local a0 = Instance.new("Attachment")
			a0.CFrame = CFrame.new(x, -1, z)
			a0.Parent = chassis
			local a1 = Instance.new("Attachment")
			a1.Parent = w
			local hinge = Instance.new("HingeConstraint")
			hinge.Attachment0, hinge.Attachment1 = a0, a1
			hinge.Parent = chassis
			table.insert(wheels, w)
		end
	end
	m.Parent = parent
	return m, chassis, rail, wheels
end

test("joints: assemblies, mechanisms, spinning wheels and the vehicle", function()
	local root = setup()
	local m, chassis, rail, wheels = cart(root)
	local g = Kinematics.graph(root)
	local assemblies = Kinematics.assemblies(g)
	expect(assemblies.of[rail] == assemblies.of[chassis], "welded rail is in the chassis assembly")
	expect(assemblies.of[wheels[1]] ~= assemblies.of[chassis], "a hinged wheel is its own assembly")
	expect(Kinematics.mechanisms(g).of[wheels[1]] == Kinematics.mechanisms(g).of[chassis])
	local spinning = BG.Classify.spinningParts(g.constraints)
	for _, w in wheels do
		expect(spinning[w], "wheel spins on its hinge")
	end
	expect(not spinning[chassis])
	local vehicles, owner = Kinematics.vehicles(root, g)
	expect(#vehicles == 1 and vehicles[1].model == m, "one vehicle, the Cart model")
	expect(owner[rail] ~= nil and owner[root.Ground] == nil)
	expect(#BG.Classify.wheels(m) == 4)
end)

test("a wheel on a CylindricalConstraint turns about its inclined axis", function()
	local root = setup()
	local chassis = Instance.new("Part")
	chassis.Size, chassis.CFrame, chassis.Parent = Vector3.new(6, 1, 10), CFrame.new(0, 3, 0), root
	local wheel = Instance.new("Part")
	wheel.Shape = Enum.PartType.Cylinder
	wheel.Size, wheel.CFrame, wheel.Parent = Vector3.new(1, 2, 2), CFrame.new(3.5, 1, 0), root
	-- Slides up and down (Attachment0's X is world up); turns about the axle
	-- (90° from X towards Y, which is world -X).
	local up = CFrame.new(3.5, 1, 0) * CFrame.Angles(0, 0, math.pi / 2)
	local a0 = Instance.new("Attachment")
	a0.CFrame = chassis.CFrame:ToObjectSpace(up)
	a0.Parent = chassis
	local a1 = Instance.new("Attachment")
	a1.CFrame = wheel.CFrame:ToObjectSpace(up)
	a1.Parent = wheel
	local c = Instance.new("CylindricalConstraint")
	c.Attachment0, c.Attachment1 = a0, a1
	c.InclinationAngle = 90
	c.Parent = chassis
	expect(BG.Classify.spinningParts({ c })[wheel], "turns about the axle")
	c.InclinationAngle = 0
	expect(not BG.Classify.spinningParts({ c })[wheel], "turns about the slider (up): not a wheel")
end)

test("parts in a vehicle are never roads or rails by name", function()
	local root, world = setup()
	local _, _, rail = cart(root)
	rail.Name = "Rail_Bed"
	local report = BG.scan(root, { world = world })
	for _, issue in report.issues do
		expect(not table.find(issue.parts, rail), "rail on the cart was linted: " .. issue.message)
	end
end)

test("collision filters: same assembly, hinge pairs, NoCollisionConstraint, groups", function()
	local root, world = setup()
	local m, chassis, rail, wheels = cart(root)
	local fender = Instance.new("Part")
	fender.Name = "Fender"
	fender.Parent = m
	local g = Kinematics.graph(root)
	local a = Kinematics.assemblies(g)
	expect(not Kinematics.canCollide(chassis, rail, g, a, world), "same assembly")
	expect(not Kinematics.canCollide(chassis, wheels[1], g, a, world), "a hinge's two parts don't collide")
	expect(Kinematics.canCollide(fender, wheels[1], g, a, world), "loose fender and wheel do")
	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0, nc.Part1, nc.Enabled = fender, wheels[1], true
	nc.Parent = fender
	g = Kinematics.graph(root)
	expect(not Kinematics.canCollide(fender, wheels[1], g, a, world), "NoCollisionConstraint")
	wheels[2].CollisionGroup = "Wheels"
	world.nonColliding["Default|Wheels"] = true
	expect(not Kinematics.canCollide(fender, wheels[2], g, a, world), "groups")
	wheels[3].CanCollide = false
	expect(not Kinematics.canCollide(fender, wheels[3], g, a, world), "CanCollide off")
end)

T.section("Core: timings, fix report, jobs, far-view rig")

test("scan reports per-check timings and yields when it can", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local stages = {}
	local report
	local thread = coroutine.create(function()
		report = BG.scan(root, { world = world, onProgress = function(stage)
			table.insert(stages, stage)
		end })
	end)
	local ok, err = coroutine.resume(thread)
	expect(ok, tostring(err))
	expect(report and #report.timings >= 5, "collect + one per check")
	for _, t in report.timings do
		expect(type(t.name) == "string" and t.seconds >= 0)
	end
	expect(world.yields > 0, "yielded between checks")
	expect(table.find(stages, "zfight") and table.find(stages, "done"))
	expect(string.find(BG.format(report), "Time: collect", 1, true), BG.format(report))
	local before = world.yields
	BG.scan(root, { world = world, yield = false })
	expect(world.yields == before, "yield = false never yields")
end)

test("fix report lists each part with its exact change and the builder line", function()
	local root, world, part = setup()
	local m = Instance.new("Model")
	m.Name = "Shop"
	m.Parent = root
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0), m)
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(3, 5, -0.3), m)
	-- The second sign is turned around, so its own Z axis is world -Z.
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(-3, 5, -0.3) * CFrame.Angles(0, math.pi, 0), m)
	local result = BG.fixAll(m, { world = world })
	expect(#result.changes == 2, "two signs changed")
	local text = BG.formatChanges(result)
	expect(string.find(text, "Shop/Sign#1", 1, true) and string.find(text, "Shop/Sign#2", 1, true), text)
	local byPath = {}
	for _, c in result.changes do
		byPath[c.path] = c
	end
	near(byPath["Shop/Sign#1"].move.Z, -0.02, 1e-4, "world move")
	near(byPath["Shop/Sign#1"].moveLocal.Z, -0.02, 1e-4, "same in its own axes")
	near(byPath["Shop/Sign#2"].move.Z, -0.02, 1e-4, "world move")
	near(byPath["Shop/Sign#2"].moveLocal.Z, 0.02, 1e-4, "flipped in its own axes")
	expect(string.find(text, "builder: part.CFrame *= CFrame.new(0.0000, 0.0000, -0.0200)", 1, true), text)
	expect(string.find(text, "builder: part.CFrame *= CFrame.new(0.0000, 0.0000, 0.0200)", 1, true), text)
end)

test("startCheck runs a check as a job and jobStatus returns it", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3))
	local jobsFolder = Instance.new("Folder")
	local id = BG.startCheck(root, { world = world, jobParent = jobsFolder })
	local text, state = BG.jobStatus(id, { jobParent = jobsFolder })
	expect(state == "done", state .. ": " .. text)
	expect(string.find(text, "z-fight", 1, true) and string.find(text, "Fix preview", 1, true), text)
	expect(jobsFolder:FindFirstChild(id).Value == text, "stored for later calls")
	local _, unknown = BG.jobStatus("nope", { jobParent = jobsFolder })
	expect(unknown == "unknown")
	for _ = 1, 7 do
		BG.startCheck(root, { world = world, jobParent = jobsFolder })
	end
	expect(#jobsFolder:GetChildren() <= 5, "old jobs are removed")
end)

test("far-view rig: every gap pair is built, labelled and ignored by scans", function()
	local root, world = setup()
	local rig = BG.TestScene.buildFarView(root, Vector3.new(0, 0, 0))
	for _, gap in BG.FarView.GAPS do
		local base = rig.folder:FindFirstChild(("Flat_%g"):format(gap))
		local overlay = rig.folder:FindFirstChild(("FlatOverlay_%g"):format(gap))
		expect(base and overlay, "pair " .. gap)
		local baseTop = base.CFrame.Position.Y + base.Size.Y / 2
		local overlayTop = overlay.CFrame.Position.Y + overlay.Size.Y / 2
		near(overlayTop - baseTop, gap, 1e-4, "gap " .. gap)
	end
	expect(rig.folder:FindFirstChild("View_300"))
	local report = BG.scan(root, { world = world })
	expect(report.partCount == 1, "only the ground is scanned")
end)

test("setProjectConfig needs a place; find reverses paths", function()
	expect(not pcall(BG.setProjectConfig, { roadHeadroom = 10 }, "x"), "no workspace under Lune")
	local root = setup()
	expect(BG.find(root, "Workspace/Ground") == root.Ground)
end)

test("long reports page; withUndo returns what the function returns", function()
	local lines = {}
	for i = 1, 300 do
		lines[i] = "line " .. i
	end
	local text = table.concat(lines, "\n")
	local p2 = BG.page(text, 2, 120)
	expect(string.find(p2, "line 121", 1, true) and not string.find(p2, "line 120\n", 1, true), p2)
	expect(string.find(p2, "page 2 of 3", 1, true), p2)
	expect(BG.page("short", 1) == "short")
	local a, b = BG.withUndo("x", function()
		return 1, 2
	end)
	expect(a == 1 and b == 2)
end)

test("fix report: resizes, and moves over several passes are added up", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local window = part("Window", Vector3.new(4, 4, 1), CFrame.new(2, 5, 0))
	local plan = BG.planFixes(BG.scan(root, { world = world }))
	BG.apply(plan)
	local changes = BG.changes(plan)
	expect(#changes == 1 and changes[1].part == window, "the window changed")
	near(changes[1].resize.Z, 0.04, 1e-4, "grew past both faces")
	expect(string.find(BG.formatChanges(plan), "builder: part.Size += Vector3.new(0.0000, 0.0000, 0.0400)", 1, true), BG.formatChanges(plan))
	-- Two plans moving the same part: one net change.
	local p1 = BG.Plan.new()
	BG.Plan.add(p1, BG.Plan.item(window, "test", "first", window.CFrame + Vector3.new(0, 1, 0)))
	BG.apply(p1)
	local p2 = BG.Plan.new()
	BG.Plan.add(p2, BG.Plan.item(window, "test", "second", window.CFrame + Vector3.new(0, 0.5, 0)))
	BG.apply(p2)
	local net = BG.changes({ p1, p2 })
	expect(#net == 1, "one entry per part")
	near(net[1].move.Y, 1.5, 1e-4, "moves add up")
	expect(#net[1].reasons == 2)
end)
