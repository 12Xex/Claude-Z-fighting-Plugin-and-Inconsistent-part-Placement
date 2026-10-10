-- Roads: the edge check (the step from the ground up onto a road), paths and
-- positions in road messages, ignored things, and name classification as the
-- road checks see it.
local T = require("../lib")
local roblox, BG, D = T.roblox, T.BG, T.D
local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum
local test, expect, near, setup, checks = T.test, T.expect, T.near, T.setup, T.checks

local Harness = require("../harness")
local Drivability = Harness.module("Checks/Drivability")
local Util = Harness.module("Util")

local W = D.minRoadWidth

-- Edge issues of one part, by edge name ("+X", "-Z", ...).
local function edgesOf(report, part)
	local out, count = {}, 0
	for _, issue in checks(report, "edge") do
		if issue.parts[1] == part then
			out[issue.edge] = issue
			count += 1
		end
	end
	return out, count
end

local function has(text, piece)
	return string.find(text, piece, 1, true) ~= nil
end

-- A road of thickness `thick` resting on the ground (top at `groundY`) with its lift.
local function roadOn(part, name, length, thick, cf, groundY)
	local p = part(name, Vector3.new(length, thick, W), CFrame.new(0, (groundY or 0) + D.roadLift + thick / 2, 0))
	p.CFrame = cf * p.CFrame
	return p
end

T.section("Roads: edge step")

test("edge: a road too thick to drive onto is flagged on every free edge (Ground part)", function()
	local root, world, part = setup()
	local thick = D.maxLedge + 0.5
	local road = roadOn(part, "Road_Thick", 30, thick, CFrame.new())
	local report = BG.scan(root, { world = world })
	local edges, count = edgesOf(report, road)
	expect(count == 4, BG.format(report))
	local step = ("%.2f-stud step from the ground up onto its +Z edge at ("):format(thick + D.roadLift)
	expect(has(edges["+Z"].message, "Road Workspace/Road_Thick: " .. step), edges["+Z"].message)
	expect(has(edges["+Z"].message, ("(limit %.2f)"):format(D.maxLedge)), edges["+Z"].message)
	expect(edges["+Z"].severity == "warning" and not BG.isFixable(edges["+Z"]), "lint, no fix")
	near(edges["+Z"].value, thick + D.roadLift, 1e-3, "step")
	near(edges["+Z"].position.Z, W / 2, 1e-3, "position on the +Z edge")
	near(edges["+Z"].position.Y, D.roadLift + thick, 1e-3, "position on the top surface")
	expect(has(edges["+Z"].message, Util.vector(edges["+Z"].position)), "message gives the position")
	near(edges["-X"].position.X, -15, 1e-3, "-X edge")
end)

test("edge: edges are named by the part's own axes, whatever its heading", function()
	local root, world, part = setup()
	local road = roadOn(part, "Road_Turned", 30, D.maxLedge + 0.5, CFrame.Angles(0, math.rad(37), 0))
	local edges, count = edgesOf(BG.scan(root, { world = world }), road)
	expect(count == 4)
	local lp = road.CFrame:PointToObjectSpace(edges["+X"].position)
	near(lp.X, 15, 1e-3, "on the local +X edge")
	near(lp.Y, road.Size.Y / 2, 1e-3, "on the top")
	lp = road.CFrame:PointToObjectSpace(edges["-Z"].position)
	near(lp.Z, -W / 2, 1e-3, "on the local -Z edge")
end)

test("edge: a thick road on terrain is flagged; the step is measured from the terrain", function()
	local root, world, part = setup()
	world.fillTerrain(CFrame.new(100, 2, 0), Vector3.new(60, 4, 60)) -- surface at y = 4
	local thick = D.maxLedge + 0.3
	local road = roadOn(part, "Road_OnHill", 30, thick, CFrame.new(100, 0, 0), 4)
	local edges, count = edgesOf(BG.scan(root, { world = world }), road)
	expect(count == 4, "every edge")
	near(edges["+X"].value, thick + D.roadLift, 1e-3, "step from the terrain surface")
end)

test("edge: a thin road (thickness + lift within maxLedge) is not flagged, even exactly at it", function()
	local root, world, part = setup()
	roadOn(part, "Road_Thin", 30, D.maxLedge - D.roadLift - 0.1, CFrame.new())
	roadOn(part, "Road_AtLimit", 30, D.maxLedge - D.roadLift, CFrame.new(0, 0, 60))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "edge") == 0, BG.format(report))
	local road = roadOn(part, "Road_Over", 30, D.maxLedge - D.roadLift + 0.05, CFrame.new(0, 0, 120))
	expect(select(2, edgesOf(BG.scan(root, { world = world }), road)) == 4, "just over the limit is flagged")
end)

test("edge: where a road joins another only the free stretch is measured (T-junction)", function()
	local root, world, part = setup()
	local thick = D.maxLedge + 0.5
	local main = roadOn(part, "Road_Main", 40, thick, CFrame.new())
	local stem = part("Road_Stem", Vector3.new(10, thick, 20), CFrame.new(0, D.roadLift + thick / 2, W / 2 + 10))
	local ctx = BG.newContext(root, { world = world, config = { sampleSpacing = 2 } })
	local function edge(solid, name)
		for _, e in Drivability.edgeSteps(ctx, solid) do
			if e.name == name then
				return e
			end
		end
		return nil
	end
	local mainZ = edge(BG.Geometry.solid(main), "+Z")
	-- 21 samples along the 40-stud edge; the 5 within the stem's 10 studs land on the stem.
	expect(mainZ.samples == 21 and mainZ.measured == 16, ("%d of %d measured"):format(mainZ.measured, mainZ.samples))
	expect(math.abs(mainZ.position.X) > 5, "worst point is outside the join")
	local stemZ = edge(BG.Geometry.solid(stem), "-Z")
	expect(stemZ.measured == 0 and stemZ.step == nil, "the stem's end lies on the main road")
	local report = BG.scan(root, { world = world })
	local stemEdges, stemCount = edgesOf(report, stem)
	expect(stemCount == 3 and stemEdges["-Z"] == nil, BG.format(report))
	expect(select(2, edgesOf(report, main)) == 4, "the main road's +Z edge still has free stretches")
end)

test("edge: a kerb or a wall beside the edge is skipped", function()
	local root, world, part = setup()
	local road = roadOn(part, "Road_Kerbed", 30, D.maxLedge + 0.5, CFrame.new())
	part("Kerb", Vector3.new(32, 0.4, 1), CFrame.new(0, 0.2, W / 2 + 0.5))
	part("Wall", Vector3.new(32, 10, 1), CFrame.new(0, 5, -(W / 2 + 0.5)))
	local edges, count = edgesOf(BG.scan(root, { world = world }), road)
	expect(count == 2 and edges["+Z"] == nil and edges["-Z"] == nil, "only the open ends")
end)

test("edge: a drop deeper than connectMaxStep (bridge, embankment) is not a step", function()
	local root, world, part = setup()
	local deck = D.connectMaxStep + 3
	part("Pier", Vector3.new(4, deck, 4), CFrame.new(0, deck / 2, 0))
	part("Road_Bridge", Vector3.new(30, 1, W), CFrame.new(0, deck + D.roadLift + 0.5, 0))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "edge") == 0, BG.format(report))
	expect(#checks(report, "offground") == 0, "it rests on its pier")
end)

test("edge: ground higher than the road is flagged with its own wording", function()
	local root, world, part = setup()
	local thick = 0.5
	local road = roadOn(part, "Road_Cutting", 30, thick, CFrame.new())
	local roadTop = D.roadLift + thick
	world.fillTerrain(CFrame.new(25, (roadTop + 1.4) / 2, 0), Vector3.new(20, roadTop + 1.4, 40))
	local report = BG.scan(root, { world = world })
	local edges, count = edgesOf(report, road)
	expect(count == 1 and edges["+X"], BG.format(report))
	local message = edges["+X"].message
	expect(has(message, "Road Workspace/Road_Cutting: the ground beside its +X edge is 1.40 above the road surface at ("), message)
	expect(edges["+X"].step < 0, "negative step: the ground is higher")
	expect(#checks(report, "buried") == 0, "a bank beside the road doesn't bury it")
end)

test("edge: steep parts (over 45°), rails and markings are not edge-checked", function()
	local root, world, part = setup()
	part("Road_Wall", Vector3.new(16, 2, W), CFrame.new(0, 6, 0) * CFrame.Angles(0, 0, math.rad(60)))
	part("Rail_Tall", Vector3.new(20, 1.5, 1), CFrame.new(0, D.railLift + 0.75, 60))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "edge") == 0, BG.format(report))
	local rails = BG.scan(root, { world = world, config = { edgeLedgeKinds = { "Road", "Rail" } } })
	expect(#checks(rails, "edge") == 4, "rails when edgeLedgeKinds lists them")
end)

test("edge: vehicles, ignored things and markings beside a road don't hide the step", function()
	local root, world, part = setup()
	local road = roadOn(part, "Road_Thick", 30, D.maxLedge + 0.5, CFrame.new())
	local truck = Instance.new("Model")
	truck.Name = "Truck"
	truck.Parent = root
	part("Chassis", Vector3.new(30, 2, 4), CFrame.new(0, 1, W / 2 + 2), truck)
	local seat = Instance.new("VehicleSeat")
	seat.Name, seat.Size, seat.CFrame, seat.Anchored = "Seat", Vector3.new(2, 1, 2), CFrame.new(0, 2.5, W / 2 + 2), true
	seat.Parent = truck
	local labels = Instance.new("Folder")
	labels.Name = "Labels"
	labels:AddTag("BuildGuardIgnore")
	labels.Parent = root
	part("Label", Vector3.new(30, 0.5, 4), CFrame.new(0, 0.25, -(W / 2 + 2)), labels)
	local edges = edgesOf(BG.scan(root, { world = world }), road)
	expect(edges["+Z"] and edges["-Z"], "truck and ignored label are looked through")
	-- Control: an ordinary part there is a kerb, and is skipped.
	truck:Destroy()
	part("Bench", Vector3.new(30, 2, 4), CFrame.new(0, 1, W / 2 + 2))
	edges = edgesOf(BG.scan(root, { world = world }), road)
	expect(edges["+Z"] == nil, "a plain part beside the edge counts as a kerb")
end)

test("edge: the limit comes from the road's own settings, and the message says where", function()
	local root, world, part = setup()
	local hills = Instance.new("Model")
	hills.Name = "Hills"
	hills:SetAttribute("BuildGuard_maxLedge", 2)
	hills.Parent = root
	local road = roadOn(part, "Road_Thick", 30, 1.5, CFrame.new())
	road.Parent = hills
	expect(select(2, edgesOf(BG.scan(root, { world = world }), road)) == 0, "1.6 is within the model's 2")
	hills:SetAttribute("BuildGuard_maxLedge", 1.2)
	local edges = edgesOf(BG.scan(root, { world = world }), road)
	expect(has(edges["+Z"].message, "(limit 1.20, set on Workspace/Hills)"), edges["+Z"].message)
end)

test("edge: parts passed in skipEdges (already reported off the ground) aren't edge-checked", function()
	local root, world, part = setup()
	local road = part("Road_Hover", Vector3.new(30, 0.5, W), CFrame.new(0, 3, 0))
	local ctx = BG.newContext(root, { world = world })
	local function edgeCount(skip)
		local n = 0
		for _, issue in Drivability.scan(ctx, skip) do
			n += if issue.check == "edge" then 1 else 0
		end
		return n
	end
	expect(edgeCount() == 4, "hovering 3 up: every edge is a step")
	expect(edgeCount({ [road] = true }) == 0, "skipped")
end)

T.section("Roads: paths and positions in messages")

test("every road check names parts by path and gives a position", function()
	local root, world, part = setup()
	local map = Instance.new("Model")
	map.Name = "Map"
	map.Parent = root
	local roads = Instance.new("Folder")
	roads.Name = "Roads"
	roads.Parent = map
	local thin = D.maxLedge - D.roadLift - 0.1
	local y = D.roadLift + thin / 2
	-- buried: Road#1 under a shed; offground: Road#2 hovering. Same name, told apart by path.
	local buried = part("Road", Vector3.new(20, thin, W), CFrame.new(0, y, 0), roads)
	part("Shed", Vector3.new(4, 6, 4), CFrame.new(-5, 3, 0), map)
	local hover = part("Road", Vector3.new(30, thin, W), CFrame.new(0, y + 3, 60), roads)
	-- headroom: a deck 6 above a road (needs 10).
	local covered = part("Road_Under", Vector3.new(30, thin, W), CFrame.new(0, y, 120), roads)
	part("Deck", Vector3.new(10, 1, W + 4), CFrame.new(0, D.roadLift + thin + 6.5, 120), map)
	-- ledge + slope + routeslope: a raised road and a steep ramp off Road_A.
	part("Road_A", Vector3.new(20, thin, W), CFrame.new(100, y, 0), roads)
	local step = D.maxLedge + 0.5
	part("Plinth", Vector3.new(21, step, W + 2), CFrame.new(120.5, step / 2, 0), map)
	local raised = part("Road_B", Vector3.new(20, thin, W), CFrame.new(120, step + y, 0), roads)
	local ramp = part(
		"Road_Ramp",
		Vector3.new(16, thin, W),
		CFrame.new(90, D.roadLift + thin, 0) * CFrame.Angles(0, 0, -math.rad(40)) * CFrame.new(-8, -thin / 2, 0),
		roads
	)
	-- roadwidth: a narrow road; edge: a thick one.
	local narrow = part("Road_Narrow", Vector3.new(30, thin, W - 6), CFrame.new(100, y, 80), roads)
	local thick = part("Road_Thick", Vector3.new(30, 1.5, W), CFrame.new(100, D.roadLift + 0.75, 140), roads)

	-- Scanning the map: paths start at it ("Map/Roads/Road#2"); the ground slab
	-- outside it is still ground.
	local report = BG.scan(map, { world = world, config = { roadHeadroom = 10 } })
	local path = report.path
	local function find(check, p)
		for _, issue in checks(report, check) do
			if table.find(issue.parts, p) then
				return issue
			end
		end
		error(("no %s issue for %s:\n%s"):format(check, path(p), BG.format(report)))
	end
	local function located(issue, inMessage)
		expect(typeof(issue.position) == "Vector3", issue.check .. " has a position")
		for _, p in issue.parts do
			expect(has(issue.message, path(p)), issue.message)
		end
		if inMessage then
			expect(has(issue.message, " at " .. Util.vector(issue.position)), issue.message)
		end
		return issue.position
	end

	expect(path(buried) == "Map/Roads/Road#1" and path(hover) == "Map/Roads/Road#2")
	local b = find("buried", buried)
	local at = located(b, true)
	expect(has(b.message, "under Map/Shed at "), b.message)
	expect(math.abs(at.X + 5) <= 2 and math.abs(at.Z) <= 2, "middle of the covered points is under the shed")
	near(at.Y, D.roadLift + thin, 1e-3, "on the road top")

	at = located(find("offground", hover), false)
	near(at.Y, hover.CFrame.Position.Y - thin / 2, 1e-3, "bottom centre")
	near(at.Z, 60, 1e-3, "bottom centre")

	local h = find("headroom", covered)
	at = located(h, true)
	expect(has(h.message, "under Map/Deck"), h.message)
	near(at.Y, D.roadLift + thin + 6, 1e-3, "lowest point of the deck")

	at = located(find("ledge", raised), true)
	near(at.X, 110, 0.2, "at the join")
	located(find("slope", ramp), true)
	at = located(find("routeslope", ramp), false)
	near((at - ramp.CFrame:PointToWorldSpace(Vector3.new(0, thin / 2, 0))).Magnitude, 0, 1e-3, "top centre")
	at = located(find("roadwidth", narrow), false)
	near(at.Y, D.roadLift + thin, 1e-3, "top centre")
	located(find("edge", thick), true)
end)

T.section("Roads: ignored things")

test("an ignored crate (tag) on a road isn't cover; an untagged one is", function()
	local root, world, part = setup()
	part("Road_1", Vector3.new(20, 0.8, W), CFrame.new(0, D.roadLift + 0.4, 0))
	local crate = part("Crate", Vector3.new(3, 3, 3), CFrame.new(4, D.roadLift + 0.8 + 1.5, 0))
	crate:AddTag("BuildGuardIgnore")
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "buried") == 0, BG.format(report))
	crate:RemoveTag("BuildGuardIgnore")
	expect(#checks(BG.scan(root, { world = world }), "buried") == 1, "control: an untagged crate buries it")
end)

test("an ignored deck isn't a headroom ceiling", function()
	local root, world, part = setup()
	part("Road_1", Vector3.new(20, 0.8, W), CFrame.new(0, D.roadLift + 0.4, 0))
	local deck = part("Deck", Vector3.new(8, 1, W + 4), CFrame.new(0, 6, 0))
	deck:SetAttribute("BuildGuardIgnore", true)
	local options = { world = world, config = { roadHeadroom = 10 } }
	expect(#checks(BG.scan(root, options), "headroom") == 0, "ignored")
	deck:SetAttribute("BuildGuardIgnore", nil)
	expect(#checks(BG.scan(root, options), "headroom") == 1, "control")
end)

test("snapping: ignored parts aren't ground, and ignored markings don't ride along", function()
	local root, world, part = setup()
	local platform = part("Platform", Vector3.new(30, 1, 30), CFrame.new(0, 2.5, 0))
	platform:AddTag("BuildGuardIgnore")
	local road = part("Road_Hover", Vector3.new(20, 0.8, W), CFrame.new(0, 6, 0))
	local mark = BG.Layers.place(part("Mark", Vector3.new(4, 0.1, 0.5), CFrame.new()), road, { layer = 1 })
	local label = part("Label", Vector3.new(4, 0.1, 0.5), CFrame.new(), road)
	label.CFrame = road.CFrame * CFrame.new(5, 0.5, 0)
	label:AddTag("BuildGuardIgnore")
	mark:AddTag("BuildGuardIgnore")
	local markY, labelY = mark.CFrame.Position.Y, label.CFrame.Position.Y
	local plan = BG.planSnap({ road }, { world = world })
	expect(#plan.items == 1, "only the road moves: " .. BG.Plan.describe(plan))
	BG.apply(plan)
	near(road.CFrame.Position.Y - 0.4, D.roadLift, 1e-4, "landed on the ground slab, not the ignored platform")
	near(mark.CFrame.Position.Y, markY, 1e-5, "ignored marking stays")
	near(label.CFrame.Position.Y, labelY, 1e-5, "ignored child stays")
end)

T.section("Roads: classification in the road checks")

test("a StreetLamp and a RoadSign beside a road are never linted", function()
	local root, world, part = setup()
	local thin = D.maxLedge - D.roadLift - 0.1
	part("Road_1", Vector3.new(30, thin, W), CFrame.new(0, D.roadLift + thin / 2, 0))
	local lamp = part("StreetLamp", Vector3.new(1, 12, 1), CFrame.new(-8, 9, W / 2 + 3)) -- hovering, would be "off the ground"
	local sign = part("RoadSign", Vector3.new(6, 4, 0.2), CFrame.new(4, 2, W / 2 + 0.6)) -- right beside the edge
	local report = BG.scan(root, { world = world })
	for _, issue in report.issues do
		expect(not table.find(issue.parts, lamp) and not table.find(issue.parts, sign), issue.message)
	end
	expect(#report.issues == 0, BG.format(report))
end)

test("a BedRail (and a Rail_Side) on a truck with a VehicleSeat never gets road/rail issues", function()
	local root, world, part = setup()
	local truck = Instance.new("Model")
	truck.Name = "Truck"
	truck.Parent = root
	part("Chassis", Vector3.new(8, 1, 16), CFrame.new(0, 3, 0), truck)
	local seat = Instance.new("VehicleSeat")
	seat.Name, seat.Size, seat.CFrame, seat.Anchored = "Seat", Vector3.new(2, 1, 2), CFrame.new(0, 4, -5), true
	seat.Parent = truck
	-- Hovering 3.5 up, under a canopy, and side by side at different heights:
	-- as rails these would be off the ground, buried and a ledge.
	local bedRail = part("BedRail", Vector3.new(0.5, 0.5, 12), CFrame.new(3.5, 3.75, 2), truck)
	local sideRail = part("Rail_Side", Vector3.new(0.5, 0.5, 12), CFrame.new(3.5, 5.75, 14.1), truck)
	part("Canopy", Vector3.new(8, 0.5, 6), CFrame.new(0, 4.3, 2), truck)
	local report = BG.scan(root, { world = world })
	for _, issue in report.issues do
		expect(not table.find(issue.parts, bedRail) and not table.find(issue.parts, sideRail), issue.message)
	end
	for _, check in { "buried", "offground", "ledge", "edge" } do
		expect(#checks(report, check) == 0, check .. ": " .. BG.format(report))
	end
end)

test("a big FloorSlab over a road is cover, but not ground: no automatic snap", function()
	local root, world, part = setup()
	local road = part("Road_1", Vector3.new(20, 0.8, W), CFrame.new(0, D.roadLift + 0.4, 0))
	part("FloorSlab", Vector3.new(600, 1, 600), CFrame.new(0, 1.5, 0))
	local report = BG.scan(root, { world = world })
	local buried = checks(report, "buried")
	expect(#buried == 1 and buried[1].parts[1] == road, BG.format(report))
	expect(not BG.isFixable(buried[1]), "a floor slab isn't ground")
	expect(has(buried[1].message, "under Workspace/FloorSlab at ("), buried[1].message)
	expect(has(buried[1].message, "move the cover or the road by hand"), buried[1].message)
	local plan, unfixed = BG.planFixes(report)
	expect(#plan.items == 0 and #unfixed >= 1, "nothing planned")
end)

test("a truck parked on a road neither buries it nor is a ceiling", function()
	local root, world, part = setup()
	local thin = D.maxLedge - D.roadLift - 0.1
	local top = D.roadLift + thin
	part("Road_1", Vector3.new(30, thin, W), CFrame.new(0, D.roadLift + thin / 2, 0))
	local truck = Instance.new("Model")
	truck.Name = "Truck"
	truck.Parent = root
	part("Chassis", Vector3.new(8, 2, 16), CFrame.new(0, top + 2, 0), truck)
	for _, x in { -4.5, 4.5 } do
		for _, z in { -6, 6 } do
			local wheel = part("Wheel", Vector3.new(1, 3, 3), CFrame.new(x, top + 1.5, z), truck)
			wheel.Shape = Enum.PartType.Cylinder
		end
	end
	local seat = Instance.new("VehicleSeat")
	seat.Name, seat.Size, seat.CFrame, seat.Anchored = "Seat", Vector3.new(2, 1, 2), CFrame.new(0, top + 3.5, -4), true
	seat.Parent = truck
	local report = BG.scan(root, { world = world, config = { roadHeadroom = 10 } })
	expect(#checks(report, "buried") == 0 and #checks(report, "headroom") == 0, BG.format(report))
end)
