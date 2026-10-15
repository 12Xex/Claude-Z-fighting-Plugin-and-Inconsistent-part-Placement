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

T.section("Roads: resting on the ground")

test("snapped roads rest right on the ground by default: no gap under them, no z-fight", function()
	local root, world, part = setup()
	local road = part("Road_Hover", Vector3.new(30, 0.8, W), CFrame.new(0, 2, 0))
	BG.fixAll(root, { world = world })
	local bottom = road.CFrame.Position.Y - 0.4
	expect(math.abs(bottom) < 1e-3, ("bottom at %.3f, ground top at 0"):format(bottom))
	local report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
end)

test("a negative roadLift sinks roads into the ground, never so far that they're buried", function()
	local root, world, part = setup()
	root:SetAttribute("BuildGuard_roadLift", -0.3)
	root:SetAttribute("BuildGuardConfigReason", "roads sit into the terrain")
	local road = part("Road_Main", Vector3.new(30, 0.8, W), CFrame.new(0, 2, 0))
	-- Sinking further than the road is thick would bury it: its top stays
	-- 0.05 above the ground.
	local deep = Instance.new("Model")
	deep.Name = "Deep"
	deep:SetAttribute("BuildGuard_roadLift", -2)
	deep:SetAttribute("BuildGuardConfigReason", "test")
	deep.Parent = root
	local thin = part("Road_Thin", Vector3.new(30, 0.8, W), CFrame.new(60, 2, 0), deep)
	BG.fixAll(root, { world = world })
	local function bottomOf(p)
		return p.CFrame.Position.Y - p.Size.Y / 2
	end
	expect(math.abs(bottomOf(road) + 0.3) < 1e-3, ("sunk 0.3: bottom at %.3f"):format(bottomOf(road)))
	expect(math.abs(bottomOf(thin) - (0.05 - 0.8)) < 1e-3, ("top kept 0.05 up: bottom at %.3f"):format(bottomOf(thin)))
	local report = BG.scan(root, { world = world })
	for _, check in { "buried", "offground", "edge" } do
		expect(#checks(report, check) == 0, BG.format(report))
	end
	-- A road resting on the ground is now 0.3 too high, and says so.
	road.CFrame += Vector3.new(0, 0.3, 0)
	local again = checks(BG.scan(root, { world = world }), "offground")
	expect(#again == 1 and again[1].parts[1] == road, "resting road not reported as 0.3 too high")
end)

test("roads only sink into real ground: not into a plinth, and a wedge ramp never sinks", function()
	local root, world, part = setup()
	root:SetAttribute("BuildGuard_roadLift", -0.3)
	root:SetAttribute("BuildGuardConfigReason", "roads sit into the terrain")
	part("Plinth", Vector3.new(34, 2, W + 4), CFrame.new(0, 1, 0))
	local raised = part("Road_Raised", Vector3.new(30, 0.8, W), CFrame.new(0, 3, 0))
	local ramp = Instance.new("WedgePart")
	ramp.Name, ramp.Size, ramp.Anchored = "Road_Ramp", Vector3.new(W, 2, 16), true
	ramp.CFrame = CFrame.new(60, 1.5, 0)
	ramp.Parent = root
	BG.fixAll(root, { world = world })
	local function bottomOf(p)
		return p.CFrame.Position.Y - p.Size.Y / 2
	end
	expect(math.abs(bottomOf(raised) - 2) < 1e-3, ("rests on the plinth: bottom at %.3f"):format(bottomOf(raised)))
	expect(math.abs(bottomOf(ramp)) < 1e-3, ("wedge rests on the ground: bottom at %.3f"):format(bottomOf(ramp)))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "buried") == 0 and #checks(report, "offground") == 0, BG.format(report))
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

T.section("Roads: gaps under the edges")

-- Two ground pads `hang` high with a dip `dip` wide between them, and a part
-- of `size` centred over the dip, its bottom `lift` above the pads.
local function overDip(part, name, size, hang, dip, lift, parent)
	for _, side in { -1, 1 } do
		part("Ground_Pad", Vector3.new(8, hang, W + 4), CFrame.new(side * (dip / 2 + 4), hang / 2, 0), parent)
	end
	return part(name, size, CFrame.new(0, hang + (lift or 0) + size.Y / 2, 0), parent)
end

local function gapsOf(report, part)
	local out = {}
	for _, issue in checks(report, "gap") do
		if issue.parts[1] == part then
			table.insert(out, issue)
		end
	end
	return out
end

test("gap: a road resting on two raised pads is flagged where its edges hang over the dip between them", function()
	local root, world, part = setup()
	local road = overDip(part, "Road_West_2", Vector3.new(24, 0.8, W), 1.21, 12)
	local report = BG.scan(root, { world = world })
	local gaps = checks(report, "gap")
	expect(#gaps == 1 and gaps[1].parts[1] == road, BG.format(report))
	local g = gaps[1]
	near(g.value, 1.21, 1e-3, "gap")
	expect(g.edge == "-Z" or g.edge == "+Z", tostring(g.edge))
	expect(g.severity == "warning" and not BG.isFixable(g), "a warning with no fix")
	near(g.position.Y, 1.21, 1e-3, "on the face it rests on")
	expect(math.abs(g.position.X) < 6, "over the dip")
	near(math.abs(g.position.Z), W / 2, 0.3, "at the edge")
	local wanted = ("Road Workspace/Road_West_2 has a 1.21-stud gap under its %s edge at %s (limit %.2f): sink it into the ground (negative roadLift), put a footing under it, or raise the ground there"):format(
		g.edge,
		Util.vector(g.position),
		D.maxHover
	)
	expect(g.message == wanted, g.message .. "\n" .. wanted)
	expect(#checks(report, "offground") == 0, "it rests on the pads")
	expect(has(BG.format(report), "[WARNING] gap"), BG.format(report))

	-- Upside down it rests on its Top face, and is measured from that.
	local root2, world2, part2 = setup()
	local flipped = overDip(part2, "Road_Flipped", Vector3.new(24, 0.8, W), 1.21, 12)
	flipped.CFrame *= CFrame.Angles(math.pi, 0, 0)
	local flippedGaps = checks(BG.scan(root2, { world = world2 }), "gap")
	expect(#flippedGaps == 1, "flipped road over the dip")
	near(flippedGaps[1].value, 1.21, 1e-3, "gap under the flipped road")
end)

test("gap: a footing (any part starting below the road's bottom) or terrain in the dip closes the gap", function()
	local root, world, part = setup()
	local road = overDip(part, "Road_1", Vector3.new(24, 0.8, W), 1.21, 12)
	part("Footing", Vector3.new(12, 1.21, W), CFrame.new(0, 1.21 / 2, 0))
	local report = BG.scan(root, { world = world })
	expect(#gapsOf(report, road) == 0, BG.format(report))

	local root2, world2, part2 = setup()
	local road2 = overDip(part2, "Road_1", Vector3.new(24, 0.8, W), 1.21, 12)
	world2.fillTerrain(CFrame.new(0, 1.21 / 2, 0), Vector3.new(12, 1.21, W + 4))
	report = BG.scan(root2, { world = world2 })
	expect(#gapsOf(report, road2) == 0, BG.format(report))
end)

test("gap: another road, an ignored part or a marking in the dip isn't ground under the road", function()
	for _, case in { "road", "ignored", "layered" } do
		local root, world, part = setup()
		local road = overDip(part, "Road_1", Vector3.new(24, 0.8, W), 1.21, 12)
		local filler = part(if case == "road" then "Road_Below" else "Filler", Vector3.new(12, 1, W), CFrame.new(0, 0.5, 0))
		if case == "ignored" then
			filler:SetAttribute("BuildGuardIgnore", true)
		elseif case == "layered" then
			filler:SetAttribute("BuildGuardLayer", 1)
		end
		local report = BG.scan(root, { world = world })
		local gaps = gapsOf(report, road)
		expect(#gaps == 1, case .. ": " .. BG.format(report))
		near(gaps[1].value, 1.21, 1e-3, case .. ": measured from the ground below it")
	end
end)

test("gap: only the edges count; how far in grows with sampleSpacing", function()
	local root, world, part = setup()
	local hang = 1.21
	-- Ground strips 4 wide under every edge, a hollow under the middle.
	local road = part("Road_1", Vector3.new(32, 0.8, W), CFrame.new(0, hang + 0.4, 0))
	for _, side in { -1, 1 } do
		part("Ground_Side", Vector3.new(32, hang, 4), CFrame.new(0, hang / 2, side * (W / 2 - 2)))
		part("Ground_End", Vector3.new(4, hang, W - 8), CFrame.new(side * 14, hang / 2, 0))
	end
	local report = BG.scan(root, { world = world })
	expect(#gapsOf(report, road) == 0 and #checks(report, "offground") == 0, BG.format(report))
	local wide = BG.scan(root, { world = world, config = { sampleSpacing = 6 } })
	local gaps = gapsOf(wide, road)
	expect(#gaps == 1, "6 studs in from the edges, the hollow counts:\n" .. BG.format(wide))
	near(gaps[1].value, hang, 1e-3, "gap over the hollow")
end)

test("gap: within maxHover passes; maxHover is set per model and the message says where", function()
	local root, world, part = setup()
	local hills = Instance.new("Model")
	hills.Name = "Hills"
	hills.Parent = root
	local road = overDip(part, "Road_1", Vector3.new(24, 0.8, W), D.maxHover - 0.05, 12, 0, hills)
	local report = BG.scan(root, { world = world })
	expect(#gapsOf(report, road) == 0, BG.format(report))
	BG.setConfig(hills, { maxHover = 0.1 }, "flat valley")
	local gaps = gapsOf(BG.scan(root, { world = world }), road)
	expect(#gaps == 1, "over the model's 0.1")
	expect(has(gaps[1].message, "(limit 0.10, set on Workspace/Hills)"), gaps[1].message)
	expect(not pcall(BG.setConfig, hills, { maxHover = 11 }, "x"), "maxHover is 0 to 10")
	expect(not pcall(BG.setConfig, hills, { maxHover = -1 }, "x"), "maxHover is 0 to 10")
	expect(BG.Config.check("maxHover", 0) and BG.Config.check("maxHover", 10), "0 and 10 allowed")
end)

test("gap: sunk roads, ramps, bridge spans and roads reported buried or off the ground get no gap warning", function()
	-- Sunk into flat ground with a negative roadLift: every gap is negative.
	local root, world, part = setup()
	root:SetAttribute("BuildGuard_roadLift", -0.3)
	root:SetAttribute("BuildGuardConfigReason", "roads sit into the terrain")
	part("Road_Sunk", Vector3.new(30, 0.8, W), CFrame.new(0, 0.4 - 0.3, 0))
	-- A 10° ramp resting on its foot: its high end is meant to leave the ground.
	part("Road_Ramp", Vector3.new(16, 0.8, W), CFrame.new(60, 0.8, 0) * CFrame.Angles(0, 0, math.rad(10)) * CFrame.new(8, -0.4, 0))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "gap") == 0 and #checks(report, "offground") == 0, BG.format(report))

	-- An overpass deck on piers: the drop under it is deeper than connectMaxStep.
	local root2, world2, part2 = setup()
	local thin = D.maxLedge - D.roadLift - 0.1
	local bottom = D.roadLift + thin + D.connectMaxStep
	part2("Road_Under", Vector3.new(30, thin, W), CFrame.new(0, D.roadLift + thin / 2, 0))
	for _, side in { -1, 1 } do
		part2("Pier", Vector3.new(W, bottom, 2), CFrame.new(0, bottom / 2, side * (W / 2 + 2)))
	end
	part2("Road_Overpass", Vector3.new(W, 0.8, W + 8), CFrame.new(0, bottom + 0.4, 0))
	report = BG.scan(root2, { world = world2 })
	expect(#checks(report, "gap") == 0, BG.format(report))

	-- Hovering (off the ground) or buried under a crate, over a dip: one issue each.
	local root3, world3, part3 = setup()
	local hover = overDip(part3, "Road_Hover", Vector3.new(24, 0.8, W), 1.21, 12, 2)
	report = BG.scan(root3, { world = world3 })
	expect(#checks(report, "offground") == 1 and #gapsOf(report, hover) == 0, BG.format(report))
	local root4, world4, part4 = setup()
	local covered = overDip(part4, "Road_Covered", Vector3.new(24, 0.8, W), 1.21, 12)
	part4("Crate", Vector3.new(4, 4, 4), CFrame.new(0, 1.21 + 0.8 + 2, 0))
	report = BG.scan(root4, { world = world4 })
	expect(#checks(report, "buried") == 1 and #gapsOf(report, covered) == 0, BG.format(report))
end)

test("gap: a rail sits its railLift above the ground: that's no gap, and rails aren't told to sink", function()
	local root, world, part = setup()
	part("Rail_1", Vector3.new(20, 0.5, 1), CFrame.new(0, D.railLift + 0.25, 0))
	local report = BG.scan(root, { world = world, config = { maxHover = 0.1 } })
	expect(#checks(report, "gap") == 0 and #report.issues == 0, BG.format(report))
	local root2, world2, part2 = setup()
	local rail = overDip(part2, "Rail_2", Vector3.new(20, 0.5, 1), 1, 12, D.railLift)
	local gaps = gapsOf(BG.scan(root2, { world = world2, config = { maxHover = 0.1 } }), rail)
	expect(#gaps == 1, "over the dip")
	near(gaps[1].value, 1 + D.railLift, 1e-3, "measured from the ground")
	local message = gaps[1].message
	expect(has(message, ("(limit 0.10 + railLift %.2f): put a footing under it or raise the ground there"):format(D.railLift)), message)
	expect(not has(message, "negative"), message)
end)

test("gap: the edge step is still checked on a road with a gap under it", function()
	local root, world, part = setup()
	local road = overDip(part, "Road_1", Vector3.new(24, 0.8, W), 1.21, 12)
	local report = BG.scan(root, { world = world })
	expect(#gapsOf(report, road) == 1, BG.format(report))
	local edges = edgesOf(report, road)
	expect(edges["+Z"] and edges["-Z"], "the drop beside it is a step too:\n" .. BG.format(report))
end)

test("gap: an invisible footing doesn't close the gap (light shows through it), though the road still rests on it", function()
	for _, transparency in { 0, 0.5, 1 } do
		local root, world, part = setup()
		local road = overDip(part, "Road_West_2", Vector3.new(24, 0.8, W), 1.21, 12)
		local footing = part("Footing", Vector3.new(12, 1.21, W), CFrame.new(0, 1.21 / 2, 0))
		footing.Transparency = transparency
		local report = BG.scan(root, { world = world })
		local gaps = gapsOf(report, road)
		expect(#checks(report, "offground") == 0, transparency .. ": " .. BG.format(report))
		if transparency < D.zFightIgnoreTransparency then
			expect(#gaps == 0, transparency .. ": a footing you can see fills the dip\n" .. BG.format(report))
		else
			expect(#gaps == 1, transparency .. ": " .. BG.format(report))
			local g = gaps[1]
			near(g.value, 1.21, 1e-3, "measured through the footing to the ground under it")
			local wanted = (
				"Road Workspace/Road_West_2 has a 1.21-stud gap under its %s edge at %s (limit %.2f) that shows through invisible "
				.. "Workspace/Footing: make it opaque (Transparency under %.2f) so it fills the gap, sink the road into the ground "
				.. "(negative roadLift), or raise the ground there"
			):format(g.edge, Util.vector(g.position), D.maxHover, D.zFightIgnoreTransparency)
			expect(g.message == wanted, g.message .. "\n" .. wanted)
		end
	end
	-- A rail gets no advice to sink.
	local root, world, part = setup()
	local rail = overDip(part, "Rail_1", Vector3.new(20, 0.5, 1), 1, 12, D.railLift)
	part("Footing", Vector3.new(12, 1, 2), CFrame.new(0, 0.5, 0)).Transparency = 1
	local report = BG.scan(root, { world = world })
	local gaps = gapsOf(report, rail)
	expect(#gaps == 1, "rail over an invisible footing: " .. BG.format(report))
	near(gaps[1].value, 1 + D.railLift, 1e-3, "rail gap")
	expect(has(gaps[1].message, "so it fills the gap, or raise the ground there"), gaps[1].message)
	-- The snap still counts an invisible part as ground: a road on one stays put.
	local root2, world2, part2 = setup()
	part2("CollisionFloor", Vector3.new(30, 1, W + 4), CFrame.new(0, 0.5, 0)).Transparency = 1
	local onFloor = part2("Road_1", Vector3.new(20, 0.8, W), CFrame.new(0, 1 + D.roadLift + 0.4, 0))
	local plan = BG.planSnap({ onFloor }, { world = world2 })
	expect(#plan.items == 0, BG.Plan.describe(plan))
end)

-- Terrain banks `depth` high either side of a ravine running along Z,
-- sloping at 45° from x = ±14 at their tops down to the ground slab, and a
-- road 40 long resting across them.
local function overRavine(part, world, name, depth)
	for _, side in { -1, 1 } do
		world.fillTerrain(CFrame.new(side * 34, depth / 2, 0), Vector3.new(40, depth, W + 8))
		-- The slope is the top face of a block 4 thick turned 45° about Z.
		local mid = CFrame.new(side * (14 - depth / 2), depth / 2, 0) * CFrame.Angles(0, 0, side * math.rad(45))
		world.fillTerrain(mid * CFrame.new(0, -2, 0), Vector3.new(depth * math.sqrt(2), 4, W + 8))
	end
	return part(name, Vector3.new(40, 0.8, W), CFrame.new(0, depth + D.roadLift + 0.4, 0))
end

test("gap: an edge spanning a drop deeper than connectMaxStep is a bridge, sloped banks and all; a shallow dip is still a gap", function()
	-- A bridge resting on 45° banks over a ravine 12 deep: its long edges
	-- pass every depth on the way down the banks.
	local root, world, part = setup()
	local bridge = overRavine(part, world, "Road_Bridge", 12)
	local report = BG.scan(root, { world = world })
	expect(#gapsOf(report, bridge) == 0, BG.format(report))
	expect(#checks(report, "offground") == 0, BG.format(report))
	-- The same banks round a dip 1.5 deep.
	local root2, world2, part2 = setup()
	local road = overRavine(part2, world2, "Road_Dip", 1.5)
	local gaps = gapsOf(BG.scan(root2, { world = world2 }), road)
	expect(#gaps == 1, "a shallow dip with sloped sides")
	near(gaps[1].value, 1.5, 1e-3, "down to the dip's floor")
	-- The ravine filled up to 1.5 below the deck under its +Z side only: the
	-- -Z edge is still a span, the +Z edge hangs over a dip.
	local root3, world3, part3 = setup()
	local half = overRavine(part3, world3, "Road_Half", 12)
	part3("Fill", Vector3.new(30, 10.5, W / 2 + 4), CFrame.new(0, 10.5 / 2, (W / 2 + 4) / 2))
	report = BG.scan(root3, { world = world3 })
	gaps = gapsOf(report, half)
	expect(#gaps == 1 and gaps[1].edge == "+Z", BG.format(report))
	near(gaps[1].value, 1.5, 1e-3, "over the fill")
end)

test("gap: over water it's measured to the water surface; the snap still looks through water", function()
	-- A beach road with its +Z edge 3 studs out over the sea: deep water
	-- (the seabed more than connectMaxStep down), then shallow water.
	for _, case in { { beach = 6, water = 4 }, { beach = 3, water = 2 } } do
		local root, world, part = setup()
		world.fillTerrain(CFrame.new(0, case.beach / 2, -20), Vector3.new(60, case.beach, 40))
		world.fillTerrain(CFrame.new(0, case.water / 2, 20), Vector3.new(60, case.water, 40), "Water")
		local road = part("Road_Beach", Vector3.new(30, 0.8, W), CFrame.new(0, case.beach + D.roadLift + 0.4, 3 - W / 2))
		local report = BG.scan(root, { world = world })
		local gaps = gapsOf(report, road)
		local label = ("beach %d, water %d: "):format(case.beach, case.water)
		expect(#gaps == 1, label .. BG.format(report))
		near(gaps[1].value, case.beach - case.water, 1e-3, label .. "to the water surface")
		local wanted = ("Road Workspace/Road_Beach has a %.2f-stud gap above the water under its"):format(case.beach - case.water)
		expect(has(gaps[1].message, wanted), gaps[1].message)
	end
	-- A road out over the water: it hovers above the seabed, not the water.
	local root, world, part = setup()
	world.fillTerrain(CFrame.new(0, 2, 0), Vector3.new(80, 4, 80), "Water")
	local pier = part("Road_Pier", Vector3.new(20, 0.8, W), CFrame.new(0, 4 + D.roadLift + 0.4, 0))
	local report = BG.scan(root, { world = world })
	local off = checks(report, "offground")
	expect(#off == 1 and off[1].parts[1] == pier, BG.format(report))
	near(off[1].value, -4, 1e-3, "measured to the seabed")
	expect(not world.isSolidTerrain(Vector3.new(0, 2, 0)) and not world.isInsideTerrain(Vector3.new(0, 2, 0)), "water isn't solid")
end)

test("issue order: zseam comes right after zgap, and gap right after edge", function()
	local root, world, part = setup()
	overDip(part, "Road_1", Vector3.new(24, 0.8, W), 1.21, 12)
	-- A sign 0.02 off its wall in a model seen from 300 studs: a zgap.
	local far = Instance.new("Model")
	far.Name = "Quarry"
	far.Parent = root
	BG.setConfig(far, { zFightViewDistance = 300 }, "seen across the pit")
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 100), far)
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, 100 - 0.32), far)
	-- Two blocks overlapping by 0.01 along their shared side: a zseam.
	part("BlockA", Vector3.new(4, 2, 4), CFrame.new(-100, 10, 0))
	part("BlockB", Vector3.new(4, 2, 4), CFrame.new(-100 + 3.99, 10, 0))
	local report = BG.scan(root, { world = world })
	local order = {}
	for _, issue in report.issues do
		if order[#order] ~= issue.check then
			table.insert(order, issue.check)
		end
	end
	local text = table.concat(order, ", ")
	expect(text == "zgap, zseam, edge, gap", text .. "\n" .. BG.format(report))
end)

test("gap: what shows is found with no extra rays unless the ground hit is invisible or under water", function()
	local Ground = Harness.module("Checks/Ground")
	local root, world, part = setup()
	local road = overDip(part, "Road_1", Vector3.new(24, 0.8, W), 1.21, 12)
	local footing = part("Footing", Vector3.new(12, 1.21, W), CFrame.new(0, 1.21 / 2, 0))
	local ctx = BG.newContext(root, { world = world })
	local calls, raycast = 0, world.raycast
	world.raycast = function(...)
		calls += 1
		return raycast(...)
	end
	local s = BG.Geometry.solid(road)
	local config = (ctx.configFor(road))
	local m = Ground.measure(s, ctx)
	expect(calls == #m.samples, ("%d rays for %d samples"):format(calls, #m.samples))
	calls = 0
	expect(Ground.edgeGap(s, m, config, ctx) and calls == 0, ("%d extra rays"):format(calls))
	-- An invisible footing is looked through: one more ray per edge sample over it.
	footing.Transparency = 1
	m = Ground.measure(s, ctx)
	calls = 0
	local worst = Ground.edgeGap(s, m, config, ctx)
	expect(calls > 0 and worst.through == footing, ("%d extra rays"):format(calls))
	near(worst.gap, 1.21, 1e-3, "through the footing")
	-- Without ctx it measures to the snap's ground, as before.
	near(Ground.edgeGap(s, m, config).gap, 0, 1e-3, "to the footing")
end)

test("self-test: P32 is left out when maxHover leaves no room for a gap under connectMaxStep, and the self-test passes", function()
	local origin = Vector3.new(4000, 0, 4000)
	local function hasP32(overrides)
		local root = Instance.new("Folder")
		root.Name = "Workspace"
		local scene = BG.TestScene.build(root, T.FakeWorld.new(root, BG.Geometry), BG.Config.merge(overrides), origin)
		for _, p in scene.planted do
			if p.id == "P32" then
				return true
			end
		end
		return false
	end
	expect(hasP32({}), "planted at the defaults")
	expect(hasP32({ maxHover = D.connectMaxStep - 0.2 }), "room for a gap just over maxHover")
	expect(not hasP32({ maxHover = D.connectMaxStep - 0.1 }), "no room under connectMaxStep")
	expect(not hasP32({ connectMaxStep = 0.1 }), "no room at the smallest connectMaxStep")
	local root = Instance.new("Folder")
	root.Name = "Workspace"
	local world = T.FakeWorld.new(root, BG.Geometry)
	local result = BG.selfTest({ world = world, parent = root, config = { maxHover = D.connectMaxStep }, origin = origin })
	expect(result.passed, result.text)
end)

T.section("Roads: road-like slabs that aren't checked as roads")

local function slab(part, name, size, material, cf, parent)
	local p = part(name, size, cf or CFrame.new(0, size.Y / 2, 0), parent)
	p.Material = Enum.Material[material]
	return p
end

test("unclassified: flat road-like slabs no check treats as roads are listed, with one NOTE line", function()
	local root, world, part = setup()
	local yard = slab(part, "Lookout_Yard", Vector3.new(30, 1, 30), "Asphalt", CFrame.new(0, 0.5, 0))
	local shoulder = slab(part, "Shoulder", Vector3.new(40, 0.5, 6), "Pebble", CFrame.new(0, 0.25, 40))
	-- Upside down, and a wedge whose slope is the top: still slabs.
	local flipped = slab(part, "Lane", Vector3.new(30, 1, 8), "Concrete", CFrame.new(60, 0.5, 0) * CFrame.Angles(math.pi, 0, 0))
	local ramp = Instance.new("WedgePart")
	ramp.Name, ramp.Size, ramp.Anchored, ramp.Material = "Ramp", Vector3.new(W, 2, 16), true, Enum.Material.Asphalt
	ramp.CFrame = CFrame.new(60, 1, 60)
	ramp.Parent = root
	local report = BG.scan(root, { world = world })
	local listed = report.unclassified
	expect(#listed == 4, BG.format(report))
	for _, p in { yard, shoulder, flipped, ramp } do
		expect(table.find(listed, p), p.Name .. " not listed")
	end
	local text = BG.format(report)
	local wanted = "  [NOTE] 4 flat slab(s) look like road surfaces (Asphalt, Concrete, Pebble) but aren't checked as roads: Workspace/Lookout_Yard, Workspace/Shoulder, Workspace/Lane, Workspace/Ramp — name or tag them Road/Rail/Track (or set BuildGuardKind), or set BuildGuardKind = \"None\" on them or their folder if they aren't roads"
	expect(has(text, wanted), text .. "\n" .. wanted)
	expect(#report.issues == 0, "a note, not an issue")
	-- Named as a road, it's checked and drops off the list.
	yard.Name = "Road_Yard"
	expect(not table.find(BG.scan(root, { world = world }).unclassified, yard), "a road now")
end)

test("unclassified: a long list names the first 10 and gives the count", function()
	local root, world, part = setup()
	local roads = Instance.new("Folder")
	roads.Name = "Roads"
	roads.Parent = root
	for i = 1, 12 do
		slab(part, "Shoulder", Vector3.new(20, 0.5, 6), "Pebble", CFrame.new(0, 0.25, i * 10), roads)
	end
	local report = BG.scan(root, { world = world })
	expect(#report.unclassified == 12, BG.format(report))
	local text = BG.format(report)
	expect(has(text, "  [NOTE] 12 flat slab(s) look like road surfaces (Pebble) but aren't checked as roads: Workspace/Roads/Shoulder#1, Workspace/Roads/Shoulder#2,"), text)
	expect(has(text, "Workspace/Roads/Shoulder#10 (first 10) — name or tag them"), text)
	expect(not has(text, "Shoulder#11"), text)
	expect(select(2, string.gsub(text, "%[NOTE%]", "")) == 1, "one line")
end)

test("unclassified: roads, ground, markings, ignored, None-marked, narrow, steep, round, standing, footings, other materials and vehicle parts aren't listed", function()
	local root, world, part = setup()
	local road = slab(part, "Road_1", Vector3.new(30, 0.8, W), "Asphalt", CFrame.new(0, 0.4, 0))
	BG.Layers.place(slab(part, "Crossing", Vector3.new(6, 0.1, 6), "Asphalt", CFrame.new()), road, { layer = 1 })
	slab(part, "Baseplate", Vector3.new(40, 1, 40), "Concrete", CFrame.new(100, 0.5, 0))
	local floor = Instance.new("Folder")
	floor.Name = "Floor"
	floor:AddTag("BuildGuardGround")
	floor.Parent = root
	slab(part, "Tile", Vector3.new(20, 1, 20), "Slate", CFrame.new(100, 0.5, 60), floor)
	slab(part, "Label", Vector3.new(20, 1, 20), "Asphalt", CFrame.new(100, 0.5, 120)):SetAttribute("BuildGuardIgnore", true)
	slab(part, "Pad", Vector3.new(20, 1, 20), "Asphalt", CFrame.new(-100, 0.5, 0)):SetAttribute("BuildGuardKind", "None")
	local pads = Instance.new("Folder")
	pads.Name = "Pads"
	pads:SetAttribute("BuildGuardKind", "None")
	pads.Parent = root
	local sub = Instance.new("Model")
	sub.Name = "Farmyard"
	sub.Parent = pads
	slab(part, "Pad", Vector3.new(20, 1, 20), "Mud", CFrame.new(-100, 0.5, 60), sub)
	slab(part, "Kerb", Vector3.new(30, 0.5, 1), "Concrete", CFrame.new(-100, 0.25, 120))
	slab(part, "Bank", Vector3.new(20, 1, 20), "Sand", CFrame.new(0, 8, 100) * CFrame.Angles(math.rad(60), 0, 0))
	local drum = slab(part, "Drum", Vector3.new(1, 8, 8), "Concrete", CFrame.new(-60, 4, 100))
	drum.Shape = Enum.PartType.Cylinder
	slab(part, "Pillar", Vector3.new(6, 8, 6), "Concrete", CFrame.new(-60, 4, -100))
	local corner = Instance.new("CornerWedgePart")
	corner.Name, corner.Size, corner.Anchored, corner.Material = "Corner", Vector3.new(8, 1, 8), true, Enum.Material.Asphalt
	corner.CFrame = CFrame.new(60, 0.5, -100)
	corner.Parent = root
	slab(part, "Floor", Vector3.new(30, 1, 30), "WoodPlanks", CFrame.new(0, 0.5, -100))
	-- A footing under a road and a plinth a little wider than one: they hold
	-- roads up, nobody drives on them.
	slab(part, "Footing", Vector3.new(30, 2, W), "Concrete", CFrame.new(0, 1, 200))
	part("Road_2", Vector3.new(30, 0.8, W), CFrame.new(0, 2.4, 200))
	slab(part, "Plinth", Vector3.new(21, 2, W + 2), "Concrete", CFrame.new(60, 1, 200))
	part("Road_3", Vector3.new(20, 0.8, W), CFrame.new(60, 2.4, 200))
	local truck = Instance.new("Model")
	truck.Name = "Truck"
	truck.Parent = root
	slab(part, "Bed", Vector3.new(8, 0.5, 16), "Concrete", CFrame.new(-150, 3, 0), truck)
	local seat = Instance.new("VehicleSeat")
	seat.Name, seat.Size, seat.CFrame, seat.Anchored = "Seat", Vector3.new(2, 1, 2), CFrame.new(-150, 4, -5), true
	seat.Parent = truck
	local report = BG.scan(root, { world = world })
	local names = {}
	for _, p in report.unclassified do
		table.insert(names, report.path(p))
	end
	expect(#report.unclassified == 0, table.concat(names, ", "))
	expect(not has(BG.format(report), "[NOTE]"), BG.format(report))
	-- None on a folder only silences the note: a road inside still counts.
	local inside = slab(part, "Road_Farm", Vector3.new(30, 0.8, W), "Mud", CFrame.new(-100, 3, 60), sub)
	expect(BG.newContext(root, { world = world }).kindOf(inside) == "Road", "still a road")
end)

-- Paths of the listed slabs, for messages.
local function listedPaths(report)
	local names = {}
	for _, p in report.unclassified do
		table.insert(names, report.path(p))
	end
	return table.concat(names, ", ")
end

test("unclassified: a yard a road runs onto is listed; a footing the road covers isn't", function()
	local root, world, part = setup()
	-- 60x60 pads: one a road runs onto and ends in the middle of, one with
	-- no road at all.
	local yard = slab(part, "Lookout_Yard", Vector3.new(60, 1, 60), "Asphalt", CFrame.new(0, 0.5, 0))
	part("Road_to_the_Lookout", Vector3.new(40, 0.8, W), CFrame.new(-20, 1.4, 0))
	local farmyard = slab(part, "Farmyard", Vector3.new(60, 1, 60), "Pebble", CFrame.new(100, 0.5, 0))
	-- A bed 4 studs wider than its road on each side: bare bed to drive on.
	local bed = slab(part, "Bed", Vector3.new(40, 1, W + 8), "Concrete", CFrame.new(0, 0.5, 100))
	part("Road_OnBed", Vector3.new(40, 0.8, W), CFrame.new(0, 1.4, 100))
	-- Held up whole: a footing exactly under a road, one under two road
	-- pieces that meet over it, and a plinth a stud past its road all round.
	slab(part, "Footing", Vector3.new(30, 2, W), "Concrete", CFrame.new(0, 1, 200))
	part("Road_2", Vector3.new(30, 0.8, W), CFrame.new(0, 2.4, 200))
	slab(part, "Footing", Vector3.new(60, 2, W), "Concrete", CFrame.new(100, 1, 200))
	part("Road_3", Vector3.new(30, 0.8, W), CFrame.new(85, 2.4, 200))
	part("Road_4", Vector3.new(30, 0.8, W), CFrame.new(115, 2.4, 200))
	slab(part, "Plinth", Vector3.new(12, 2, W + 2), "Concrete", CFrame.new(-100, 1, 200))
	part("Road_5", Vector3.new(10, 0.8, W), CFrame.new(-100, 2.4, 200))
	-- The same footing and road turned 30°.
	local turned = CFrame.new(0, 0, 300) * CFrame.Angles(0, math.rad(30), 0)
	slab(part, "Footing", Vector3.new(30, 2, W), "Concrete", turned * CFrame.new(0, 1, 0))
	part("Road_6", Vector3.new(30, 0.8, W), turned * CFrame.new(0, 2.4, 0))
	local report = BG.scan(root, { world = world })
	expect(#report.unclassified == 3, listedPaths(report))
	for _, p in { yard, farmyard, bed } do
		expect(table.find(report.unclassified, p), p.Name .. " not listed: " .. listedPaths(report))
	end
end)

test("unclassified: shoulders and lanes from 1.5 studs across are listed, named like a road or not", function()
	local root, world, part = setup()
	-- Hanging 1.4 above the ground beside a road, as the team found them.
	local shoulder = slab(part, "Shoulder", Vector3.new(40, 0.5, 2.5), "Pebble", CFrame.new(0, 1.65, 20))
	local named = slab(part, "Road_Shoulder", Vector3.new(40, 0.5, 3), "Pebble", CFrame.new(0, 1.65, 40))
	local lane = slab(part, "MudRun_Lane", Vector3.new(30, 0.5, 1.5), "Mud", CFrame.new(0, 0.25, 60))
	-- Too narrow or too short to drive on: a kerb, a stepping slab.
	slab(part, "Kerb", Vector3.new(30, 0.5, 1), "Concrete", CFrame.new(0, 0.25, 80))
	slab(part, "Step", Vector3.new(5, 0.5, 2), "Concrete", CFrame.new(0, 0.25, 100))
	expect(BG.newContext(root, { world = world }).kindOf(named) == nil, "too narrow to be a road by its name")
	local report = BG.scan(root, { world = world })
	expect(#report.unclassified == 3, listedPaths(report))
	for _, p in { shoulder, named, lane } do
		expect(table.find(report.unclassified, p), p.Name .. " not listed: " .. listedPaths(report))
	end
	expect(has(BG.format(report), "[NOTE] 3 flat slab(s) look like road surfaces (Pebble, Mud)"), BG.format(report))
end)

test("unclassified: only slabs within 10° of level are listed, so pitched roofs aren't", function()
	local root, world, part = setup()
	local house = Instance.new("Model")
	house.Name = "House"
	house.Parent = root
	-- A 35° Slate roof: two panels meeting at the ridge.
	for _, side in { -1, 1 } do
		slab(part, "Roof", Vector3.new(20, 0.4, 10), "Slate", CFrame.new(0, 12, side * 4) * CFrame.Angles(side * math.rad(35), 0, 0), house)
	end
	-- 12° is past the limit; 8° (a gentle apron) isn't.
	slab(part, "Ramp", Vector3.new(30, 0.5, 10), "Concrete", CFrame.new(50, 4, 0) * CFrame.Angles(0, 0, math.rad(12)))
	local apron = slab(part, "Apron", Vector3.new(30, 0.5, 10), "Concrete", CFrame.new(100, 3, 0) * CFrame.Angles(0, 0, math.rad(8)))
	-- A wedge whose slope rises 20°.
	local wedge = Instance.new("WedgePart")
	wedge.Name, wedge.Size, wedge.Anchored, wedge.Material = "Ramp", Vector3.new(10, 16 * math.tan(math.rad(20)), 16), true, Enum.Material.Asphalt
	wedge.CFrame = CFrame.new(150, wedge.Size.Y / 2, 0)
	wedge.Parent = root
	local report = BG.scan(root, { world = world })
	expect(#report.unclassified == 1 and report.unclassified[1] == apron, listedPaths(report))
end)

test("unclassified: finding them costs no raycasts or part queries", function()
	local root, world, part = setup()
	for i = 1, 40 do
		slab(part, "Pad", Vector3.new(8, 0.5, 8), "Asphalt", CFrame.new(i * 10, 0.25, 0))
	end
	part("Road_1", Vector3.new(30, 0.8, W), CFrame.new(0, 0.4, 60))
	part("Footing", Vector3.new(30, 2, W), CFrame.new(0, 1, 120)).Material = Enum.Material.Concrete
	part("Road_2", Vector3.new(30, 0.8, W), CFrame.new(0, 2.4, 120))
	local ctx = BG.newContext(root, { world = world })
	local calls = 0
	for _, name in { "raycast", "partAt", "partsInBox", "isSolidTerrain", "isInsideTerrain" } do
		local f = world[name]
		world[name] = function(...)
			calls += 1
			return f(...)
		end
	end
	local listed = BG.Classify.unclassified(ctx)
	expect(#listed == 40 and calls == 0, ("%d listed, %d world queries"):format(#listed, calls))
end)
