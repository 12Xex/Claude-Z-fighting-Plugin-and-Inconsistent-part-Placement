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
	-- Over 45° a name alone doesn't make a road, so this one is marked.
	part("Road_Wall", Vector3.new(16, 2, W), CFrame.new(0, 6, 0) * CFrame.Angles(0, 0, math.rad(60))):SetAttribute("BuildGuardKind", "Road")
	part("Rail_Tall", Vector3.new(20, 1.5, 2), CFrame.new(0, D.railLift + 0.75, 60))
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

test("edge: a scan doesn't edge-check roads it already reports as off the ground", function()
	local root, world, part = setup()
	part("Road_Hover", Vector3.new(30, 0.5, W), CFrame.new(0, 3, 0))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "offground") == 1, BG.format(report))
	expect(#checks(report, "edge") == 0, BG.format(report))
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

T.section("Roads: locked pieces")

test("snaps never move a locked road: reported, not fixed; an unlocked twin is", function()
	local root, world, part = setup()
	local hover = part("Road_Hover", Vector3.new(30, 0.8, W), CFrame.new(0, 3, 0))
	hover.Locked = true
	local sunk = part("Road_Sunk", Vector3.new(30, 0.8, W), CFrame.new(60, -0.2, 0))
	sunk:SetAttribute("BuildGuardLocked", true)
	local twin = part("Road_Twin", Vector3.new(30, 0.8, W), CFrame.new(-60, 3, 0))
	local before = { hover.CFrame, sunk.CFrame }
	local report = BG.scan(root, { world = world })
	for _, issue in report.issues do
		if issue.parts[1] == hover or issue.parts[1] == sunk then
			expect(not BG.isFixable(issue), "locked piece fixable: " .. issue.message)
			expect(string.find(issue.message, "locked", 1, true), issue.message)
		end
	end
	BG.fixAll(root, { world = world })
	expect(hover.CFrame == before[1] and sunk.CFrame == before[2], "a locked road moved")
	expect(math.abs(twin.CFrame.Position.Y - (D.roadLift + 0.4)) < 1e-3, "the unlocked twin is snapped")
	local plan, skipped = BG.planSnap({ hover, twin }, { world = world })
	expect(#plan.items == 0, "twin already snapped, locked one skipped")
	expect(#skipped == 1 and skipped[1].part == hover and string.find(skipped[1].reason, "locked", 1, true))
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

test("signs on posts and boards, lane lines and lamp heads named like roads are never linted or moved", function()
	local root, world, part = setup()
	local thin = D.maxLedge - D.roadLift - 0.1
	local road = part("Road_1", Vector3.new(40, thin, W), CFrame.new(0, D.roadLift + thin / 2, 0))
	local z = W / 2 + 2
	-- Mounted on the road side of their posts, high up.
	part("SignPost", Vector3.new(0.5, 12, 0.5), CFrame.new(-10, 6, z))
	local exit = part("Highway_Exit", Vector3.new(12, 4, 0.5), CFrame.new(-10, 10, z - 0.5))
	part("SignPost", Vector3.new(0.5, 8, 0.5), CFrame.new(6, 4, z))
	local sign = part("RoadSign", Vector3.new(6, 3, 0.2), CFrame.new(6, 6, z - 0.35))
	-- Placed on a board's front the documented way (Size.Y is its thickness).
	local board = part("Board", Vector3.new(8, 6, 0.4), CFrame.new(16, 5, z))
	local boardSign = BG.Layers.place(part("RoadSign", Vector3.new(6, 0.2, 4), CFrame.new()), board, { face = "Front" })
	local line = BG.Layers.place(part("RoadLine", Vector3.new(10, 0.1, 0.5), CFrame.new()), road, { layer = 1 })
	part("LampPole", Vector3.new(0.6, 10, 0.6), CFrame.new(-18, 5, z))
	local head = part("StreetLight", Vector3.new(4, 0.5, 1.5), CFrame.new(-18, 10.25, z - 0.4))
	local watched = { exit, sign, boardSign, line, head }
	local before = {}
	for _, p in watched do
		before[p] = p.CFrame
	end
	local report = BG.scan(root, { world = world })
	expect(#report.issues == 0, BG.format(report))
	BG.fixAll(root, { world = world })
	for p, cf in before do
		near((p.CFrame.Position - cf.Position).Magnitude, 0, 1e-5, p.Name .. " moved")
	end
end)

T.section("Roads: headroom")

-- Road_Under on the ground, piers beside it and a Road_* deck on them whose
-- underside is `clear` above the road's top.
local function overpass(part, clear)
	local thin = D.maxLedge - D.roadLift - 0.1
	local bottom = D.roadLift + thin + clear
	local under = part("Road_Under", Vector3.new(30, thin, W), CFrame.new(0, D.roadLift + thin / 2, 0))
	for _, side in { -1, 1 } do
		part("Pier", Vector3.new(W, bottom - D.roadLift, 2), CFrame.new(0, (bottom - D.roadLift) / 2, side * (W / 2 + 2)))
	end
	local deck = part("Road_Overpass", Vector3.new(W, 0.8, W + 8), CFrame.new(0, bottom + 0.4, 0))
	return under, deck
end

test("headroom: a road deck (named Road_*) over a road is a ceiling, low or high", function()
	for _, clear in { 3.5, 6.5 } do
		local root, world, part = setup()
		local under = overpass(part, clear)
		local report = BG.scan(root, { world = world, config = { roadHeadroom = 10 } })
		local h = checks(report, "headroom")
		expect(#h == 1 and h[1].parts[1] == under, BG.format(report))
		expect(has(h[1].message, "under Workspace/Road_Overpass at ("), h[1].message)
		near(h[1].value, clear, 1e-3, "clear height")
		local enough = BG.scan(root, { world = world, config = { roadHeadroom = clear - 0.5 } })
		expect(#checks(enough, "headroom") == 0, BG.format(enough))
	end
end)

test("headroom: overlapping junction pieces and rails on their bed are not ceilings", function()
	local root, world, part = setup()
	local thin = D.maxLedge - D.roadLift - 0.1
	local y = D.roadLift + thin / 2
	part("Road_Main", Vector3.new(40, thin, W), CFrame.new(0, y, 0))
	part("Road_Junction", Vector3.new(W, thin, W), CFrame.new(10, y, 0))
	part("Road_JunctionHigh", Vector3.new(W, thin, W), CFrame.new(-10, y + 0.1, 0))
	-- Rails resting on a track bed, even with a big rail lift.
	local railLift = 0.6
	local bedTop = D.trackLift + 0.5
	part("TrackBed", Vector3.new(24, 0.5, 4), CFrame.new(0, D.trackLift + 0.25, 60))
	for _, z in { -0.7, 0.7 } do
		part("Rail_OnBed", Vector3.new(23, 0.3, 0.3), CFrame.new(0, bedTop + railLift + 0.15, 60 + z))
	end
	local config = { roadHeadroom = 10, railHeadroom = 10, trackHeadroom = 10, railLift = railLift }
	local report = BG.scan(root, { world = world, config = config })
	expect(#checks(report, "headroom") == 0, BG.format(report))
end)

T.section("Roads: wedge ramps")

-- A WedgePart ramp `run` long rising `rise`, resting on the ground with its
-- foot at x = `foot` and its high end towards +X.
local function wedge(root, name, rise, run, foot)
	local p = Instance.new("WedgePart")
	p.Name = name
	p.Size = Vector3.new(W, rise, run)
	p.CFrame = CFrame.new(foot + run / 2, D.roadLift + rise / 2, 0) * CFrame.Angles(0, math.pi / 2, 0)
	p.Anchored = true
	p.Parent = root
	return p
end

-- Barriers along both open sides of a ramp from x = foot.
local function barriers(part, run, foot, height)
	for _, side in { -1, 1 } do
		part("Barrier", Vector3.new(run, height, 1), CFrame.new(foot + run / 2, height / 2, side * (W / 2 + 0.5)))
	end
end

test("wedge ramp: its slope is the driving surface (foot edge, joins, route slope)", function()
	local root, world, part = setup()
	local rise, run = 2, 12
	local ramp = wedge(root, "Road_Ramp", rise, run, 0)
	barriers(part, run, 0, rise + 1)
	-- A road on a plinth at the top, level with the ramp's high end.
	local top = D.roadLift + rise
	part("Plinth", Vector3.new(21, top - 0.8 - D.roadLift, W + 2), CFrame.new(run + 10.5, (top - 0.8 - D.roadLift) / 2, 0))
	part("Road_Top", Vector3.new(20, 0.8, W), CFrame.new(run + 10, top - 0.4, 0))
	local report = BG.scan(root, { world = world })
	expect(#report.issues == 0, "the foot is at ground level, the top meets Road_Top:\n" .. BG.format(report))
	-- A road at the foot, 0.8 above it.
	part("Road_Low", Vector3.new(20, 0.8, W), CFrame.new(-10, D.roadLift + 0.4, 0))
	report = BG.scan(root, { world = world, config = { maxLedge = 0.5 } })
	local ledges = checks(report, "ledge")
	expect(#ledges == 1 and table.find(ledges[1].parts, ramp), BG.format(report))
	near(ledges[1].value, 0.8, 1e-3, "the real step down onto the foot")
	near(ledges[1].position.X, 0, 1e-3, "at the foot")
end)

test("wedge ramp: a steep one gets routeslope from its slope; a crate on its low end buries it", function()
	local root, world = setup()
	local steep = wedge(root, "Ramp_Steep", 8, 4, 0)
	steep:SetAttribute("BuildGuardKind", "Road")
	local report = BG.scan(root, { world = world })
	local slopes = checks(report, "routeslope")
	expect(#slopes == 1 and slopes[1].parts[1] == steep, BG.format(report))
	near(slopes[1].value, math.deg(math.atan2(8, 4)), 1e-2, "slope angle")
	near(slopes[1].position.Y, D.roadLift + 4, 1e-3, "middle of the slope")

	local root2, world2, part2 = setup()
	local ramp = wedge(root2, "Road_Ramp", 2, 12, 0)
	barriers(part2, 12, 0, 3)
	-- Resting on the slope near the foot, well below the wedge's box top.
	part2("Crate", Vector3.new(3, 1, 3), CFrame.new(2.5, D.roadLift + 2 * 4 / 12 + 0.5, 0))
	local buried = checks(BG.scan(root2, { world = world2 }), "buried")
	expect(#buried == 1 and buried[1].parts[1] == ramp, "crate on the slope")
end)

T.section("Roads: small gaps, tagged floors and upside-down pieces")

test("ledge: two pieces a small gap apart (under edgeProbe) are still a join", function()
	local root, world, part = setup()
	local step = D.maxLedge + 1
	local gap = 0.3
	local low = part("Road_Low", Vector3.new(20, 0.8, W), CFrame.new(-10, D.roadLift + 0.4, 0))
	part("Plinth", Vector3.new(21, step, W + 2), CFrame.new(gap + 10.5, step / 2, 0))
	local high = part("Road_High", Vector3.new(20, 0.8, W), CFrame.new(gap + 10, step + D.roadLift + 0.4, 0))
	local report = BG.scan(root, { world = world })
	local ledges = checks(report, "ledge")
	expect(#ledges == 1 and table.find(ledges[1].parts, low) and table.find(ledges[1].parts, high), BG.format(report))
	near(ledges[1].value, step, 1e-3, "step")
	expect(#checks(report, "edge") == 0, BG.format(report))
end)

test("edge: a floor whose folder is tagged BuildGuardGround is ground beside the road", function()
	local root, world, part = setup()
	root.Ground:Destroy()
	local floor = Instance.new("Folder")
	floor.Name = "MapFloor"
	floor:AddTag("BuildGuardGround")
	floor.Parent = root
	for i = -1, 1 do
		part("Tile", Vector3.new(200, 2, 200), CFrame.new(i * 200, -1, 0), floor)
	end
	local road = roadOn(part, "Road_Thick", 30, D.maxLedge + 0.5, CFrame.new())
	local edges, count = edgesOf(BG.scan(root, { world = world }), road)
	expect(count == 4, "every edge")
	near(edges["+Z"].value, D.maxLedge + 0.5 + D.roadLift, 1e-3, "step from the tile")
	floor:RemoveTag("BuildGuardGround")
	expect(select(2, edgesOf(BG.scan(root, { world = world }), road)) == 0, "untagged tiles are just parts (kerbs)")
end)

test("an upside-down road is checked on the face that's up", function()
	local root, world, part = setup()
	local thin = D.maxLedge - D.roadLift - 0.1
	local flip = CFrame.Angles(math.pi, 0, 0)
	local resting = part("Road_Flipped", Vector3.new(30, thin, W), CFrame.new(0, D.roadLift + thin / 2, 0) * flip)
	local report = BG.scan(root, { world = world })
	expect(#report.issues == 0, BG.format(report))
	-- A crate on the face that's up buries it.
	local crate = part("Crate", Vector3.new(3, 3, 3), CFrame.new(4, D.roadLift + thin + 1.5, 0))
	local buried = checks(BG.scan(root, { world = world }), "buried")
	expect(#buried == 1 and buried[1].parts[1] == resting, "crate on top")
	crate:Destroy()
	-- Hovering: reported and snapped down, keeping its rotation.
	local hover = part("Road_FlippedHover", Vector3.new(30, thin, W), CFrame.new(0, 3, 60) * flip)
	local look = hover.CFrame.LookVector
	report = BG.scan(root, { world = world })
	local off = checks(report, "offground")
	expect(#off == 1 and off[1].parts[1] == hover and BG.isFixable(off[1]), BG.format(report))
	near(off[1].position.Y, 3 - thin / 2, 1e-3, "bottom centre")
	BG.fixAll(root, { world = world })
	near(hover.CFrame.Position.Y - thin / 2, D.roadLift, 1e-3, "landed with its lift")
	near((hover.CFrame.LookVector - look).Magnitude, 0, 1e-5, "same rotation")
	-- A thick one: edges named by the part's own axes, on the face that's up.
	local thick = part("Road_FlippedThick", Vector3.new(30, 1.5, W), CFrame.new(0, D.roadLift + 0.75, 120) * flip)
	local edges, count = edgesOf(BG.scan(root, { world = world }), thick)
	expect(count == 4, "every edge")
	local lp = thick.CFrame:PointToObjectSpace(edges["+Z"].position)
	near(lp.Z, W / 2, 1e-3, "on the part's own +Z edge")
	near(lp.Y, -0.75, 1e-3, "on the face that's up")
end)
