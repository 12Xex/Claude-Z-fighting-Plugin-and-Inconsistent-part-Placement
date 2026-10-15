-- Faces: round surfaces, corner wedges, duplicates, mesh boxes, mesh
-- triangles, far-view face gaps, contact positions in messages, float
-- rounding far from the origin, and yielding during long scans.
local T = require("../lib")
local roblox, BG, D = T.roblox, T.BG, T.D
local Instance, Vector3, CFrame, Enum = roblox.Instance, roblox.Vector3, roblox.CFrame, roblox.Enum
local test, expect, near, setup, checks = T.test, T.expect, T.near, T.setup, T.checks

local ZFight = require("../harness").module("Checks/ZFight")
local Meshes = require("../harness").module("Checks/Meshes")

local function shaped(p, shape)
	p.Shape = Enum.PartType[shape]
	return p
end

local function model(parent, name, attributes)
	local m = Instance.new("Model")
	m.Name = name
	for key, value in attributes or {} do
		m:SetAttribute(key, value)
	end
	m.Parent = parent
	return m
end

local function newPart(class, parent, name, size, cf)
	local p = Instance.new(class)
	p.Name, p.Size, p.CFrame, p.Anchored = name, size, cf, true
	p.Parent = parent
	return p
end

local function mesh(parent, name, size, cf, meshId)
	local m = newPart("MeshPart", parent, name, size, cf)
	m.MeshId = meshId or "rbxassetid://1"
	return m
end

-- A closed box mesh fitted to `size` (part-local), each face split into
-- n x n quads. Wound counter-clockwise seen from outside, or clockwise when
-- `reversed`.
local function boxTriangles(size, reversed, n)
	n = n or 1
	local h = { size.X / 2, size.Y / 2, size.Z / 2 }
	local out = {}
	for axis = 1, 3 do
		for _, sign in { 1, -1 } do
			local u, v = axis % 3 + 1, (axis + 1) % 3 + 1
			if sign < 0 then
				u, v = v, u
			end
			local function at(i, j)
				local c = { 0, 0, 0 }
				c[axis] = sign * h[axis]
				c[u] = -h[u] + 2 * h[u] * i / n
				c[v] = -h[v] + 2 * h[v] * j / n
				return Vector3.new(c[1], c[2], c[3])
			end
			for i = 0, n - 1 do
				for j = 0, n - 1 do
					local p00, p10, p11, p01 = at(i, j), at(i + 1, j), at(i + 1, j + 1), at(i, j + 1)
					if reversed then
						table.insert(out, { p00, p11, p10 })
						table.insert(out, { p00, p01, p11 })
					else
						table.insert(out, { p00, p10, p11 })
						table.insert(out, { p00, p11, p01 })
					end
				end
			end
		end
	end
	return out
end

local function involves(issues, a, b)
	for _, issue in issues do
		if table.find(issue.parts, a) and (b == nil or table.find(issue.parts, b)) then
			return issue
		end
	end
	return nil
end

-- Every issue from these checks says where to look.
local OWN_CHECKS = { zfight = true, zgap = true, zseam = true, duplicate = true, meshoverlap = true }
local function expectPositions(report)
	for _, issue in report.issues do
		if OWN_CHECKS[issue.check] then
			expect(typeof(issue.position) == "Vector3", issue.check .. " issue without a position")
		end
	end
end

local function totalArea(issue)
	local total = 0
	for _, c in issue.contacts do
		total += c.area
	end
	return total
end

T.section("Round surfaces")

test("rod in a sleeve: same radius on one axis z-fights; the fix grows the sleeve; rescan clean", function()
	local root, world, part = setup()
	local frame = CFrame.new(0, 6, 0) * CFrame.Angles(0.3, 0.5, 1.1)
	local sleeve = shaped(part("Sleeve", Vector3.new(6, 2, 2), frame), "Cylinder")
	-- Longer, rolled about its own axis and pointing the other way: still the same round surface.
	local rod = shaped(part("Rod", Vector3.new(10, 2, 2), frame * CFrame.new(1, 0, 0) * CFrame.Angles(0.7, math.pi, 0)), "Cylinder")
	local z = checks(BG.scan(root, { world = world }), "zfight")
	expect(#z == 1, "expected the rod/sleeve pair, got " .. #z)
	expect(string.find(z[1].message, "Round/Round", 1, true), z[1].message)
	near((z[1].position - frame.Position).Magnitude, 0, 1e-3, "position: middle of the shared stretch")

	local plan = BG.planFixes(BG.scan(root, { world = world }))
	expect(#plan.items == 1 and plan.items[1].part == sleeve, "the shorter sleeve is the mover")
	local item = plan.items[1]
	near(item.toSize.Y, 2 + 2 * D.zFightNudge, 1e-4, "radius grows by the gap")
	near(item.toSize.Z, 2 + 2 * D.zFightNudge, 1e-4)
	near(item.toSize.X, 6, 1e-4, "length kept")
	near((item.toCFrame.Position - sleeve.CFrame.Position).Magnitude, 0, 1e-5, "CFrame kept")
	BG.apply(plan)
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0, "clean after the fix")
	expect(rod.Size.Y == 2, "rod untouched")
end)

test("cylinders: 0.03 apart in radius, off-axis, or end to end are not z-fighting", function()
	local root, world, part = setup()
	shaped(part("Sleeve", Vector3.new(6, 2, 2), CFrame.new(0, 5, 0)), "Cylinder")
	shaped(part("Rod", Vector3.new(10, 2.06, 2.06), CFrame.new(1, 5, 0)), "Cylinder")
	shaped(part("PipeA", Vector3.new(6, 2, 2), CFrame.new(0, 5, 10)), "Cylinder")
	shaped(part("PipeB", Vector3.new(6, 2, 2), CFrame.new(1, 5.5, 10)), "Cylinder") -- caps apart too
	shaped(part("SegA", Vector3.new(6, 2, 2), CFrame.new(0, 5, 20)), "Cylinder")
	shaped(part("SegB", Vector3.new(6, 2, 2), CFrame.new(6, 5, 20)), "Cylinder")
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 0, BG.format(report))
end)

test("concentric balls of one radius z-fight; the smaller grows clear", function()
	local root, world, part = setup()
	local inner = shaped(part("Inner", Vector3.new(4, 4, 4), CFrame.new(0, 8, 0)), "Ball")
	shaped(part("Outer", Vector3.new(4.016, 4.016, 4.016), CFrame.new(0, 8, 0) * CFrame.Angles(0.4, 0, 0)), "Ball")
	shaped(part("Apart", Vector3.new(4, 4, 4), CFrame.new(0, 8, 0.5)), "Ball") -- off-centre: crosses, doesn't fight
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, inner, root.Outer), BG.format(report))
	expect(string.find(z[1].message, "Round/Round", 1, true), z[1].message)
	near((z[1].position - Vector3.new(0, 8, 0)).Magnitude, 0, 1e-4, "position: the centre")
	local plan = BG.planFixes(report)
	expect(#plan.items == 1 and plan.items[1].part == inner, "the smaller ball moves")
	-- Inner radius 2 must clear Outer's 2.008 by the gap.
	near(plan.items[1].toSize.X, 2 * (2.008 + D.zFightNudge), 1e-4)
	BG.apply(plan)
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0, "clean after the fix")
end)

T.section("Corner wedges")

local function cornerWedge(root, name, size, cf)
	return newPart("CornerWedgePart", root, name, size, cf)
end

test("corner wedge: a plate flush in its slope and an inlay flush in its side are found and fixed", function()
	local root, world, part = setup()
	local base = CFrame.new(0, 10, 0)
	cornerWedge(root, "Peak", Vector3.new(8, 8, 8), base)
	-- SlopeLeft runs through (-4,-4,-4), (-4,-4,4) and (4,4,-4): the plane y = x.
	local n = Vector3.new(-1, 1, 0).Unit
	local onSlope = Vector3.new(-4, -4, -4) / 3
	local plate = part(
		"Plate",
		Vector3.new(1, 0.2, 1),
		base * CFrame.fromMatrix(onSlope - n * 0.1, Vector3.new(1, 1, 0).Unit, n)
	)
	-- The Right face (x = 4) is the triangle with y + z <= 0.
	local inlay = part("Inlay", Vector3.new(0.2, 1, 1), base * CFrame.new(3.9, -2, -1))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 2, BG.format(report))
	local slope = involves(z, plate)
	expect(slope and string.find(slope.message, "SlopeLeft/Top", 1, true), slope and slope.message)
	local side = involves(z, inlay)
	expect(side and string.find(side.message, "Right/Right", 1, true), side and side.message)
	BG.apply((BG.planFixes(report)))
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 0, BG.format(report))
	near((plate.CFrame.Position - base:PointToWorldSpace(onSlope - n * 0.1)):Dot(base:VectorToWorldSpace(n)), D.zFightNudge, 1e-4, "plate lifted off the slope")
end)

test("a small corner wedge sharing a big one's apex clears all four faces in one fix", function()
	local root, world = setup()
	local base = CFrame.new(0, 10, 30) * CFrame.Angles(0, math.rad(25), 0)
	cornerWedge(root, "Peak", Vector3.new(8, 8, 8), base)
	-- Same apex, half size: Right, Front and both slopes lie in Peak's planes.
	local cap = cornerWedge(root, "Cap", Vector3.new(4, 4, 4), base * CFrame.new(2, 2, -2))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and #z[1].contacts == 4, BG.format(report))
	local plan = BG.planFixes(report)
	expect(#plan.items == 1 and plan.items[1].part == cap)
	BG.apply(plan)
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 0, BG.format(report))
end)

test("a corner wedge resting on a block (back-to-back) is not z-fighting", function()
	local root, world, part = setup()
	part("Plinth", Vector3.new(4, 4, 4), CFrame.new(0, 2, 0))
	cornerWedge(root, "Cap", Vector3.new(4, 4, 4), CFrame.new(0, 6, 0))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 0, BG.format(report))
end)

T.section("Fix plan")

test("contacts sharing a direction move the part once, not once per contact", function()
	local root, world, part = setup()
	local function wedge(name, size, cf)
		return newPart("WedgePart", root, name, size, cf)
	end
	wedge("RoofA", Vector3.new(8, 4, 8), CFrame.new(0, 10, 0))
	wedge("RoofB", Vector3.new(8, 4, 8), CFrame.new(8, 10, 0))
	-- Half-size wedge whose slope lies in both roofs' slope plane, across their seam.
	local trim = wedge("Trim", Vector3.new(2, 2, 4), CFrame.new(4, 10.5, 1))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 2, BG.format(report))
	local plan = BG.planFixes(report)
	expect(#plan.items == 1 and plan.items[1].part == trim)
	local move = plan.items[1].toCFrame.Position - plan.items[1].fromCFrame.Position
	near(move.Magnitude, D.zFightNudge, 1e-4, "moved by the gap once")
	BG.apply(plan)
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0)
end)

test("a trim flush on a wedge's bottom, back and slope can't be moved clear: reported, not half-fixed", function()
	-- No move clears all three (it would have to go down, back and out along
	-- the slope at once), so the planner leaves it for a person.
	local root, world = setup()
	local function wedge(name, size, cf)
		return newPart("WedgePart", root, name, size, cf)
	end
	wedge("Roof", Vector3.new(8, 4, 8), CFrame.new(0, 10, 0))
	wedge("RoofTrim", Vector3.new(2, 4, 8), CFrame.new(1, 10, 0))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and #z[1].contacts == 3, BG.format(report))
	local plan, unfixed = BG.planFixes(report)
	expect(#plan.items == 0 and #unfixed == 1 and unfixed[1] == z[1], BG.Plan.describe(plan))
end)

test("a marking flush on a sunk road moves with the road's snap, not into the road", function()
	local root, world, part = setup()
	local road = part("Road_Main", Vector3.new(22, 0.8, 60), CFrame.new(0, 0.2, 0))
	local marking = part("LaneMarking", Vector3.new(0.5, 0.2, 40), CFrame.new(0, 0.5, 0)) -- top flush with the road's
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "offground") == 1 and #checks(report, "zfight") == 1, BG.format(report))
	BG.apply((BG.planFixes(report)))
	local roadTop = road.CFrame.Position.Y + 0.4
	near(road.CFrame.Position.Y - 0.4, D.roadLift, 1e-4, "road snapped up")
	near(marking.CFrame.Position.Y + 0.1 - roadTop, D.zFightNudge, 1e-4, "marking top clears the snapped road top")
	report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
end)

test("crossing stripes inlaid in a deck: one plan clears all three pairs", function()
	local root, world, part = setup()
	part("Deck", Vector3.new(40, 1, 40), CFrame.new(0, 0.5, 0))
	part("StripeA", Vector3.new(30, 0.1, 1), CFrame.new(0, 0.95, 0))
	part("StripeB", Vector3.new(1, 0.1, 20), CFrame.new(0, 0.95, 0))
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 3, BG.format(report))
	BG.apply((BG.planFixes(report)))
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 0, BG.format(report))
end)

test("a plan made from a scan older than a hand edit is refused, not applied over the edit", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local sign = part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 6, -0.3))
	local report = BG.scan(root, { world = world })
	sign.CFrame = CFrame.new(3, 6, -0.6) -- fixed by hand after the scan
	local plan = BG.planFixes(report)
	expect(not pcall(BG.apply, plan), "apply must refuse a plan from an old scan")
	near((sign.CFrame.Position - Vector3.new(3, 6, -0.6)).Magnitude, 0, 1e-5, "the hand edit stays")
end)

test("a z-fight between two locked parts says so and isn't offered as an automatic fix", function()
	local root, world, part = setup()
	local wall = part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0))
	local sign = part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.3))
	wall.Locked, sign.Locked = true, true
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and not BG.isFixable(z[1]), BG.format(report))
	expect(string.find(z[1].message, "both parts are locked", 1, true), z[1].message)
	expect(string.find(BG.format(report), "(not auto-fixable)", 1, true), BG.format(report))
	local plan, unfixed = BG.planFixes(report)
	expect(#plan.items == 0 and #unfixed == 1)
	-- Control: with one part unlocked, the other one moves.
	sign.Locked = false
	z = checks(BG.scan(root, { world = world }), "zfight")
	expect(#z == 1 and BG.isFixable(z[1]) and not string.find(z[1].message, "locked", 1, true), z[1].message)
end)

T.section("Duplicates and mesh boxes")

test("duplicates: same mesh or block, pose and size; each copy reported once, never as a z-fight", function()
	local root, world, part = setup()
	local truck = model(root, "Truck")
	local pose = CFrame.new(0, 3, 0) * CFrame.Angles(0, 0.3, 0)
	local bodies = {}
	for i = 1, 3 do
		bodies[i] = mesh(truck, "Body", Vector3.new(4, 2, 6), pose, "rbxassetid://77")
	end
	local crateA = part("Crate", Vector3.new(4, 4, 4), CFrame.new(20, 2, 0))
	local crateB = part("Crate", Vector3.new(4, 4, 4), CFrame.new(20, 2.005, 0))
	part("Crate", Vector3.new(4, 4, 4), CFrame.new(20, 2, 0) * CFrame.Angles(0, math.rad(1), 0)) -- turned: not a copy
	local report = BG.scan(root, { world = world })
	local dups = checks(report, "duplicate")
	expect(#dups == 3, BG.format(report))
	local first = involves(dups, bodies[1], bodies[2])
	expect(first, "Body#1/Body#2")
	expect(involves(dups, bodies[1], bodies[3]), "Body#1/Body#3")
	expect(not involves(dups, bodies[2], bodies[3]), "a third copy is reported once")
	expect(involves(dups, crateA, crateB), "identical blocks")
	expect(
		string.find(first.message, "Workspace/Truck/Body#1 and Workspace/Truck/Body#2 are duplicates at (0.00, 3.00, 0.00)", 1, true),
		first.message
	)
	expect(string.find(first.message, "same mesh", 1, true) and string.find(first.message, "delete one", 1, true))
	expect(not BG.isFixable(first), "no automatic fix")
	for _, issue in checks(report, "zfight") do
		expect(not (table.find(issue.parts, crateA) and table.find(issue.parts, crateB)), "duplicate also reported as z-fight")
	end
	expect(#checks(report, "meshoverlap") == 0, "duplicates aren't box overlaps too")
	local _, unfixed = BG.planFixes(report)
	expect(#unfixed >= 3)
	expectPositions(report)
end)

test("copies that look different are a z-fight to fix, not a duplicate", function()
	local root, world, part = setup()
	local globe = shaped(part("Globe", Vector3.new(2, 2, 2), CFrame.new(0, 3, 0)), "Ball")
	globe.Material, globe.Transparency = Enum.Material.Glass, 0.5
	local bulb = shaped(part("Bulb", Vector3.new(2, 2, 2), CFrame.new(0, 3, 0)), "Ball")
	bulb.Material = Enum.Material.Neon
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "duplicate") == 0, BG.format(report))
	local z = checks(report, "zfight")
	expect(#z == 1 and BG.isFixable(z[1]), BG.format(report))
	BG.apply(BG.planFixes(report))
	expect(#checks(BG.scan(root, { world = world }), "zfight") == 0, "fixed")
end)

test("mesh boxes: different meshes in one place, or nearly coincident copies, are box overlaps", function()
	local root, world = setup()
	local pose = CFrame.new(0, 3, 0)
	local a = mesh(root, "Rock", Vector3.new(4, 2, 6), pose, "rbxassetid://1")
	-- Another mesh turned 90 degrees with its size swapped: the same box.
	local b = mesh(root, "Boulder", Vector3.new(6, 2, 4), pose * CFrame.Angles(0, math.rad(90), 0), "rbxassetid://2")
	local c = mesh(root, "Rock", Vector3.new(4, 2, 6), CFrame.new(20, 3, 0), "rbxassetid://1")
	local d = mesh(root, "Rock", Vector3.new(4, 2, 6), CFrame.new(20.1, 3, 0), "rbxassetid://1")
	local u1 = newPart("UnionOperation", root, "Arch", Vector3.new(8, 6, 2), CFrame.new(0, 3, 30))
	local u2 = newPart("UnionOperation", root, "Arch", Vector3.new(8, 6, 2), CFrame.new(0, 3.2, 30))
	-- Control: shifted a whole stud, they share only 60%.
	local e = mesh(root, "Rock", Vector3.new(4, 2, 6), CFrame.new(40, 3, 0), "rbxassetid://1")
	local f = mesh(root, "Rock", Vector3.new(4, 2, 6), CFrame.new(41, 3, 0), "rbxassetid://1")
	local report = BG.scan(root, { world = world })
	local overlaps = checks(report, "meshoverlap")
	expect(#overlaps == 3, BG.format(report))
	local ab = involves(overlaps, a, b)
	expect(ab and string.find(ab.message, "overlap 100%", 1, true), ab and ab.message)
	expect(string.find(ab.message, "Workspace/Rock#1 and Workspace/Boulder", 1, true), ab.message)
	local cd = involves(overlaps, c, d)
	expect(cd and string.find(cd.message, "overlap 95%", 1, true), cd and cd.message)
	expect(involves(overlaps, u1, u2), "unions too")
	expect(not involves(overlaps, e, f), "60% isn't flagged")
	expect(#checks(report, "duplicate") == 0, BG.format(report))
	expect(ab.severity == "warning" and not BG.isFixable(ab))
	expectPositions(report)
end)

T.section("Mesh triangles")

test("a mesh plate flush with a slab top z-fights by its triangles, either winding, and is fixed", function()
	for _, reversed in { false, true } do
		local root, world, part = setup()
		local slab = part("Slab", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
		local plate = mesh(root, "Plate", Vector3.new(2, 0.2, 2), CFrame.new(1, 0.9, 1) * CFrame.Angles(0, math.rad(30), 0))
		world.setMeshTriangles(plate, boxTriangles(plate.Size, reversed))
		local report = BG.scan(root, { world = world })
		local z = checks(report, "zfight")
		expect(#z == 1 and involves(z, slab, plate), BG.format(report))
		expect(string.find(z[1].message, "Top/tri x2", 1, true), z[1].message)
		near(totalArea(z[1]), 4, 1e-3, "the plate's whole top")
		local plan = BG.planFixes(report)
		expect(#plan.items == 1 and plan.items[1].part == plate)
		local move = plan.items[1].toCFrame.Position - plan.items[1].fromCFrame.Position
		near(move.Y, D.zFightNudge, 1e-4, "up by the gap, once for both triangles")
		near(move.Magnitude, D.zFightNudge, 1e-4)
		BG.apply(plan)
		report = BG.scan(root, { world = world })
		expect(#checks(report, "zfight") == 0, BG.format(report))
	end
end)

test("mesh against mesh: triangles decide, not boxes", function()
	local root, world = setup()
	local deck = mesh(root, "Deck", Vector3.new(10, 1, 10), CFrame.new(0, 3, 0), "rbxassetid://10")
	local hatch = mesh(root, "Hatch", Vector3.new(2, 0.2, 2), CFrame.new(2, 3.4, 2), "rbxassetid://11")
	-- Two different meshes in one place: a z-fight, not just a box overlap.
	local twinA = mesh(root, "Twin", Vector3.new(4, 4, 4), CFrame.new(30, 3, 0), "rbxassetid://12")
	local twinB = mesh(root, "Twin", Vector3.new(4, 4, 4), CFrame.new(30, 3, 0), "rbxassetid://13")
	for _, m in { deck, hatch, twinA, twinB } do
		world.setMeshTriangles(m, boxTriangles(m.Size))
	end
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 2, BG.format(report))
	local hd = involves(z, deck, hatch)
	expect(hd and string.find(hd.message, "tri/tri", 1, true), hd and hd.message)
	local twins = involves(z, twinA, twinB)
	expect(twins and #twins.contacts >= 6, "every side of the twins")
	expect(#checks(report, "meshoverlap") == 0, "triangles were read for both: no box warning")
	-- A mesh flush on opposite sides can't be cleared by a move: left for a person.
	local plan, unfixed = BG.planFixes(report)
	expect(#plan.items == 1 and plan.items[1].part == hatch, BG.Plan.describe(plan))
	expect(#unfixed == 1 and unfixed[1] == twins, "the twins are reported as not fixable")
	BG.apply(plan)
	near(hatch.CFrame.Position.Y, 3.4 + D.zFightNudge, 1e-4, "hatch up by the gap")
	report = BG.scan(root, { world = world })
	expect(not involves(checks(report, "zfight"), deck, hatch), BG.format(report))
end)

test("two meshes of about 2000 triangles each scan quickly", function()
	-- Worst case: two different meshes in one place, every triangle of one
	-- overlapping several of the other.
	local root, world = setup()
	local a = mesh(root, "BigA", Vector3.new(10, 10, 10), CFrame.new(0, 20, 0), "rbxassetid://20")
	local b = mesh(root, "BigB", Vector3.new(10, 10, 10), CFrame.new(0, 20, 0), "rbxassetid://21")
	local trianglesA, trianglesB = boxTriangles(a.Size, false, 13), boxTriangles(b.Size, false, 12)
	expect(#trianglesA == 2028 and #trianglesB == 1728)
	world.setMeshTriangles(a, trianglesA)
	world.setMeshTriangles(b, trianglesB)
	local start = os.clock()
	local report = BG.scan(root, { world = world })
	local elapsed = os.clock() - start
	local z = checks(report, "zfight")
	expect(#z == 1, BG.format(report))
	near(totalArea(z[1]), 6 * 10 * 10, 0.01, "every side overlaps")
	expect(elapsed < 1.5, ("scan took %.2f s"):format(elapsed))
	-- Half-overlapping sides.
	b.CFrame = CFrame.new(0, 25, 0)
	z = checks(BG.scan(root, { world = world }), "zfight")
	expect(#z == 1)
	near(totalArea(z[1]), 4 * 10 * 5, 0.01, "half of each side")
end)

test("coverage counts meshes checked by triangles and by box only, with reasons", function()
	local root, world, part = setup()
	local read = mesh(root, "Read", Vector3.new(2, 2, 2), CFrame.new(0, 1, 0))
	world.setMeshTriangles(read, boxTriangles(read.Size))
	mesh(root, "Unreadable", Vector3.new(2, 2, 2), CFrame.new(10, 1, 0))
	local big = mesh(root, "Detailed", Vector3.new(2, 2, 2), CFrame.new(20, 1, 0))
	world.setMeshTriangles(big, boxTriangles(big.Size, false, 2))
	newPart("UnionOperation", root, "Arch", Vector3.new(2, 2, 2), CFrame.new(30, 1, 0))
	local alone = mesh(root, "Alone", Vector3.new(2, 2, 2), CFrame.new(0, 100, 0))
	world.setMeshTriangles(alone, boxTriangles(alone.Size))
	part("Hidden", Vector3.new(2, 2, 2), CFrame.new(50, 1, 0)).Transparency = 1

	local ctx = BG.newContext(root, { world = world, config = { meshTriangleLimit = 12 } })
	ZFight.scan(ctx)
	local coverage = ctx.coverage
	expect(coverage.meshTriangles == 1, "only Read (Alone is near nothing)")
	expect(coverage.meshBoxOnly == 3)
	expect(coverage.reasons["mesh not loadable"] == 1)
	expect(coverage.reasons[Meshes.UNION_REASON] == 1)
	expect(coverage.reasons["more than meshTriangleLimit (12) triangles"] == 1)
	local line = Meshes.describeCoverage(coverage)
	expect(string.find(line, "1 checked by their triangles, 3 by box only", 1, true), line)
	-- Box-only meshes get no z-fight check at all, and the line says so.
	expect(string.find(line, "aren't checked for z-fighting", 1, true), line)
	local report = BG.scan(root, { world = world, config = { meshTriangleLimit = 12 } })
	expect(string.find(BG.format(report), "  " .. Meshes.describeCoverage(report.coverage), 1, true), BG.format(report))

	ctx = BG.newContext(root, { world = world, config = { meshTriangles = false } })
	ZFight.scan(ctx)
	expect(ctx.coverage.meshTriangles == 0 and ctx.coverage.reasons["meshTriangles is off"] == 3)
	expect(Meshes.describeCoverage(BG.newContext(nil, { world = world }).coverage) == nil)
end)

-- An open mesh: a 20 x 20 floor at local y = -0.5 (wound to face down when
-- `facingDown`, else up), plus a closed 1-stud rock standing on it.
local function floorTriangles(facingDown)
	local a, b, c, d = Vector3.new(-10, -0.5, -10), Vector3.new(-10, -0.5, 10), Vector3.new(10, -0.5, 10), Vector3.new(10, -0.5, -10)
	local out = if facingDown then { { a, c, b }, { a, d, c } } else { { a, b, c }, { a, c, d } }
	for _, t in boxTriangles(Vector3.one) do
		local offset = Vector3.new(5, 0, 5)
		table.insert(out, { t[1] + offset, t[2] + offset, t[3] + offset })
	end
	return out
end

test("an open mesh keeps its own winding: a crate on a ground patch is fine, a slab flush with it isn't", function()
	local root, world, part = setup()
	local patch = mesh(root, "GroundPatch", Vector3.new(20, 1, 20), CFrame.new(0, 10.5, 0))
	world.setMeshTriangles(patch, floorTriangles(false))
	expect(Meshes.signedVolume(floorTriangles(false)) < 0, "the floor sits below the centre: its volume is negative")
	local crate = part("Crate", Vector3.new(4, 4, 4), CFrame.new(-5, 12, -3)) -- resting on the floor
	local slab = part("Slab", Vector3.new(4, 1, 4), CFrame.new(-5, 9.5, 4)) -- top flush with the floor
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(not involves(z, patch, crate), BG.format(report))
	expect(#z == 1 and involves(z, patch, slab), BG.format(report))

	-- Wound to face down, the floor is seen from below only: the slab's top shows.
	world.setMeshTriangles(patch, floorTriangles(true))
	report = BG.scan(root, { world = world })
	expect(not involves(checks(report, "zfight"), patch, slab), BG.format(report))
	-- DoubleSided draws it both ways.
	patch.DoubleSided = true
	report = BG.scan(root, { world = world })
	expect(involves(checks(report, "zfight"), patch, slab), BG.format(report))
end)

test("parts drawn by a SpecialMesh or a scaled BlockMesh are checked by box only", function()
	local root, world, part = setup()
	local function special(p, meshId)
		local m = Instance.new("SpecialMesh")
		m.MeshType = Enum.MeshType.FileMesh
		m.MeshId = meshId
		m.Parent = p
		return p
	end
	-- Two different lamp meshes sharing a box: not a "delete one" duplicate.
	local post = special(part("LampPost", Vector3.new(2, 8, 2), CFrame.new(0, 4, 0)), "rbxassetid://111")
	local head = special(part("LampHead", Vector3.new(2, 8, 2), CFrame.new(0, 4, 0)), "rbxassetid://222")
	-- A half-scale BlockMesh: its box front is on the wall front, but what's drawn is inside the wall.
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(20, 5, 0))
	local plaque = part("Plaque", Vector3.new(2, 2, 0.4), CFrame.new(20, 5, -0.3))
	local block = Instance.new("BlockMesh")
	block.Scale = Vector3.new(0.5, 0.5, 0.5)
	block.Parent = plaque
	-- Controls: the same lamp mesh twice is a duplicate; a plain BlockMesh draws its box.
	local copyA = special(part("Lamp", Vector3.new(2, 8, 2), CFrame.new(40, 4, 0)), "rbxassetid://111")
	local copyB = special(part("Lamp", Vector3.new(2, 8, 2), CFrame.new(40, 4, 0)), "rbxassetid://111")
	local plain = part("PlainPlaque", Vector3.new(2, 2, 0.4), CFrame.new(23, 5, -0.3))
	Instance.new("BlockMesh").Parent = plain

	local report = BG.scan(root, { world = world })
	local dups = checks(report, "duplicate")
	expect(#dups == 1 and involves(dups, copyA, copyB), BG.format(report))
	local z = checks(report, "zfight")
	expect(not involves(z, post, head) and not involves(z, plaque), BG.format(report))
	expect(involves(z, plain), "a plain BlockMesh still z-fights by its box")
	expect(involves(checks(report, "meshoverlap"), post, head), "the lamps' boxes are flagged for a look")
	expect(report.coverage.reasons[Meshes.MESH_CHILD_REASON] == 5, BG.format(report))
end)

test("a mesh's note (data not centred on its bounds) is kept in the coverage with the part's path", function()
	local root, world = setup()
	local rock = mesh(root, "Rock", Vector3.new(2, 2, 2), CFrame.new(0, 1, 0))
	local note = "mesh data isn't centred on its bounds (off by (0.000, 0.500, 0.000) studs), so its box doesn't match what you see"
	world.meshTriangles = function(p)
		if p == rock then
			return boxTriangles(p.Size), nil, note
		end
		return nil, "mesh not loadable"
	end
	local report = BG.scan(root, { world = world })
	expect(report.coverage.meshTriangles == 1, BG.format(report))
	expect(report.coverage.notes["Workspace/Rock"] == note, "note kept")
	local lines = Meshes.describeNotes(report.coverage)
	expect(#lines == 1 and lines[1] == "Workspace/Rock: " .. note, lines[1])
	-- The report shows it, so it can be passed on.
	expect(string.find(BG.format(report), "  [NOTE] Workspace/Rock: " .. note, 1, true), BG.format(report))
end)

T.section("Messages")

test("z-fight messages give the path (with #n for repeated names) and where to look", function()
	local root, world, part = setup()
	local tub = model(root, "Tub")
	part("TubTop", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0), tub)
	part("TubTop", Vector3.new(2, 2, 0.4), CFrame.new(3, 6, -0.3), tub)
	local z = checks(BG.scan(root, { world = world }), "zfight")
	expect(#z == 1)
	expect(
		z[1].message
			== "Workspace/Tub/TubTop#1 and Workspace/Tub/TubTop#2 z-fight at (3.00, 6.00, -0.50): Front/Front face(s) overlap 4.00 studs², 2.00 wide",
		z[1].message
	)
	near((z[1].position - Vector3.new(3, 6, -0.5)).Magnitude, 0, 1e-4)
	local plan = BG.planFixes(BG.scan(root, { world = world }))
	expect(string.find(plan.items[1].reason, "Workspace/Tub/TubTop#1", 1, true), plan.items[1].reason)
end)

T.section("Far view")

local FAR = 300

test("far view: 0.02 off a wall is a zgap in a model seen from 300 studs, fixed to the face gap", function()
	local root, world, part = setup()
	local pit = model(root, "Pit", { BuildGuard_zFightViewDistance = FAR })
	local farConfig = BG.Config.merge({ zFightViewDistance = FAR })
	local gap = BG.Config.faceGap(farConfig)
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0), pit)
	local sign = part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.32), pit)
	local sunk = part("Sunk", Vector3.new(2, 2, 0.4), CFrame.new(3, 5, -0.305), pit)
	-- The same 0.02 outside the model is fine.
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 40))
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, 39.68))
	local report = BG.scan(root, { world = world })
	local gaps = checks(report, "zgap")
	expect(#gaps == 1 and involves(gaps, sign), BG.format(report))
	local message = gaps[1].message
	expect(gaps[1].severity == "warning" and BG.isFixable(gaps[1]))
	expect(string.find(message, "0.020 studs apart", 1, true), message)
	expect(string.find(message, "beyond about 129 studs", 1, true) or string.find(message, "beyond about 130 studs", 1, true), message)
	expect(string.find(message, "Workspace/Pit is seen from 300 studs", 1, true), message)
	expect(string.find(message, ("leave at least %.3f"):format(gap), 1, true), message)
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, sunk), "within tolerance it's still a z-fight")
	expectPositions(report)
	near((gaps[1].position - Vector3.new(0, 5, -0.5)).Magnitude, 0, 1e-3, "gap position on the wall front")

	local plan = BG.planFixes(report)
	expect(#plan.items == 2)
	BG.apply(plan)
	near(-0.5 - (sign.CFrame.Position.Z - 0.2), gap, 1e-4, "sign front leaves the face gap")
	near(-0.5 - (sunk.CFrame.Position.Z - 0.2), gap, 1e-4, "the z-fight fix leaves the face gap too")
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zgap") == 0 and #checks(report, "zfight") == 0, BG.format(report))
end)

test("far view: a zgap fix keeps which surface is in front", function()
	local root, world, part = setup()
	local pit = model(root, "Pit", { BuildGuard_zFightViewDistance = FAR })
	local gap = BG.Config.faceGap(BG.Config.merge({ zFightViewDistance = FAR }))
	-- A neon bulb 0.05 inside a glass globe.
	local globe = shaped(part("Globe", Vector3.new(4.1, 4.1, 4.1), CFrame.new(0, 8, 0), pit), "Ball")
	globe.Material, globe.Transparency = Enum.Material.Glass, 0.5
	local bulb = shaped(part("Bulb", Vector3.new(4, 4, 4), CFrame.new(0, 8, 0), pit), "Ball")
	bulb.Material = Enum.Material.Neon
	-- A panel whose front sits 0.03 behind the wall's front (hidden).
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(20, 5, 0), pit)
	local panel = part("Panel", Vector3.new(2, 2, 0.4), CFrame.new(20, 5, -0.27), pit)
	local report = BG.scan(root, { world = world })
	local gaps = checks(report, "zgap")
	expect(#gaps == 2 and involves(gaps, bulb) and involves(gaps, panel), BG.format(report))
	local plan = BG.planFixes(report)
	expect(#plan.items == 2, BG.Plan.describe(plan))
	for _, item in plan.items do
		expect(string.find(item.reason, "z-gap with", 1, true), item.reason)
		local action = if item.part == bulb then "shrink its round surface clear" else "nudge further back"
		expect(string.find(item.reason, action, 1, true), item.reason)
	end
	BG.apply(plan)
	near(globe.Size.X / 2 - bulb.Size.X / 2, gap, 1e-4, "the bulb stays inside the globe, by the face gap")
	near(globe.Size.X, 4.1, 1e-5, "globe untouched")
	near((panel.CFrame.Position.Z - 0.2) - -0.5, gap, 1e-4, "the panel stays behind the wall's front, by the face gap")
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zgap") == 0 and #checks(report, "zfight") == 0, BG.format(report))
end)

test("far view under about 130 studs adds no zgap warnings: the normal nudge already holds there", function()
	local root, world, part = setup()
	local yard = model(root, "Yard", { BuildGuard_zFightViewDistance = 60 })
	part("Wall", Vector3.new(10, 10, 1), CFrame.new(0, 5, 0), yard)
	part("Sign", Vector3.new(2, 2, 0.4), CFrame.new(0, 5, -0.315), yard) -- 0.015 off the wall
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "zgap") == 0 and #checks(report, "zfight") == 0, BG.format(report))
	-- Control: at 120 studs 0.015 isn't enough any more.
	yard:SetAttribute("BuildGuard_zFightViewDistance", 120)
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zgap") == 1, BG.format(report))
end)

test("far view: layers lift by the face gap", function()
	local root, world, part = setup()
	local pit = model(root, "Pit", { BuildGuard_zFightViewDistance = FAR })
	local gap = BG.Config.faceGap(BG.Config.merge({ zFightViewDistance = FAR }))
	expect(gap > D.layerLift, "300 studs needs more than layerLift")
	local road = part("Haul", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 0), pit)
	local line = BG.Layers.place(part("Line", Vector3.new(0.6, 0.1, 8), CFrame.new(), pit), road, { layer = 1 })
	near(line.CFrame.Position.Y - 0.05, 1.05 + gap, 1e-4, "layer 1")
	local arrow = BG.Layers.place(part("Arrow", Vector3.new(3, 0.1, 0.6), CFrame.new(), pit), road, { layer = 2 })
	near(arrow.CFrame.Position.Y - 0.05, 1.05 + 2 * gap, 1e-4, "layer 2")
	local report = BG.scan(root, { world = world })
	expect(#checks(report, "zgap") == 0 and #checks(report, "zfight") == 0, BG.format(report))
	local outside = part("Slab", Vector3.new(20, 1, 10), CFrame.new(0, 0.55, 40))
	local mark = BG.Layers.place(part("Mark", Vector3.new(4, 0.1, 0.5), CFrame.new()), outside, { layer = 1 })
	near(mark.CFrame.Position.Y - 0.05, 1.05 + D.layerLift, 1e-4, "outside: layerLift")
end)

T.section("Float rounding")

test("parts laid edge to edge far from the origin don't z-fight along the shared edge", function()
	-- float32 positions put each shared edge about 1e-4 studs to one side.
	for _, at in { 2000, 4000, 8000 } do
		local root, world, part = setup()
		for i = 0, 5 do
			part("Paver", Vector3.new(21.7, 1, 512), CFrame.new(at + 0.37 + i * 21.7, 10, -at))
			part("Kerb", Vector3.new(18.45, 1, 512), CFrame.new(at + 0.37 + i * 18.45, 10, at))
		end
		local frame = CFrame.new(-at, 10, at) * CFrame.Angles(0, math.rad(37), 0)
		for i = 0, 5 do
			part("Slab", Vector3.new(22, 1, 512), frame * CFrame.new(22 * i, 0, 0))
		end
		local report = BG.scan(root, { world = world })
		expect(#checks(report, "zfight") == 0, BG.format(report))
	end
	-- Control: a real 0.05 overlap along the same kind of edge still z-fights.
	local root, world, part = setup()
	part("Paver", Vector3.new(21.7, 1, 512), CFrame.new(4000, 10, -4000))
	part("Paver", Vector3.new(21.7, 1, 512), CFrame.new(4000 + 21.7 - 0.05, 10, -4000))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and string.find(z[1].message, "Top/Top", 1, true), BG.format(report))
	for _, c in z[1].contacts do
		if c.faceA.name == "Top" then
			near(c.area, 0.05 * 512, 0.5, "the whole 0.05-wide strip (float32 positions)")
		end
	end
end)

T.section("Layer 0")

test("layer 0: a 0.22 rib rests flush on the road, scans clean and rides along when the road is snapped", function()
	local root, world, part = setup()
	expect(BG.Layers.lift(0) == 0, "no lift")
	expect(BG.Layers.lift(0, BG.Config.merge({ zFightViewDistance = FAR })) == 0, "not even seen from far away")
	local road = part("Road_Main", Vector3.new(60, 0.8, 22), CFrame.new(0, 0.4, 0))
	-- Across the road, its ends in line with the road's sides.
	local rib = BG.Layers.place(part("Washboard_Rib", Vector3.new(22, 0.22, 0.6), CFrame.new()), road, { layer = 0, u = 5, rotation = 90 })
	expect(rib:GetAttribute("BuildGuardLayer") == 0)
	near(rib.CFrame.Position.Y - 0.11, 0.8, 1e-4, "bottom on the road top")
	near(rib.CFrame.Position.X, 5, 1e-4, "u offset")
	near(math.abs(rib.CFrame.RightVector.Z), 1, 1e-4, "turned across the road")
	local report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))

	-- Raised off the ground with its rib, the road snaps down and the rib comes along.
	road.CFrame += Vector3.new(0, 3, 0)
	rib.CFrame += Vector3.new(0, 3, 0)
	report = BG.scan(root, { world = world })
	expect(#checks(report, "offground") == 1, BG.format(report))
	BG.apply((BG.planFixes(report)))
	near(road.CFrame.Position.Y - 0.4, D.roadLift, 1e-4, "road snapped")
	near(rib.CFrame.Position.Y - 0.11, road.CFrame.Position.Y + 0.4, 1e-4, "rib still on the road top")
	report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
end)

test("layer 0: overlapping items both at layer 0 z-fight (their bottoms are coplanar) and are fixed", function()
	local root, world, part = setup()
	local deck = part("Deck", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
	local a = BG.Layers.place(part("PlateA", Vector3.new(4, 0.1, 4), CFrame.new()), deck, { layer = 0 })
	local b = BG.Layers.place(part("PlateB", Vector3.new(4, 0.2, 4), CFrame.new()), deck, { layer = 0, u = 2, v = 1 })
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, a, b), BG.format(report))
	expect(string.find(z[1].message, "Bottom/Bottom face(s) overlap 6.00 studs²", 1, true), z[1].message)
	BG.apply((BG.planFixes(report)))
	report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
end)

T.section("Seams")

-- Two thin wedges making a square land facet (2h across): each is thin
-- along X, with X turned up. A's Right face is on top; B is turned over
-- about their shared edge (the square's diagonal), so its Left face is on
-- top and its triangle fills the rest of the square, then pushed `overlap`
-- across the edge into A.
local function facetPair(parent, at, overlap, h, t)
	h, t = h or 4, t or 0.2
	local frame = at * CFrame.Angles(0, 0, math.pi / 2)
	local size = Vector3.new(t, 2 * h, 2 * h)
	local s = overlap / math.sqrt(2)
	local a = newPart("WedgePart", parent, "Facet", size, frame)
	local b = newPart("WedgePart", parent, "Facet", size, frame * CFrame.new(0, -s, s) * CFrame.fromAxisAngle(Vector3.new(0, 1, 1).Unit, math.pi))
	return a, b
end

test("overlap width: the thinnest extent of the overlap polygon, also given by coplanarOverlap", function()
	local G = BG.Geometry
	near(G.polygonWidth({ { 0, 0 }, { 10, 0 }, { 10, 0.5 }, { 0, 0.5 } }), 0.5, 1e-9, "a strip")
	near(G.polygonWidth({ { 0, 0 }, { 4, 0 }, { 0, 3 } }), 2.4, 1e-9, "3-4-5 triangle: its smallest height")
	near(G.polygonWidth({ { 0, 0 }, { 1, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 } }), 1, 1e-9, "repeated points are skipped")
	-- A sign hanging 0.02 over a wall's right edge, its front flush with the wall's.
	local wall = G.solidFrom(CFrame.new(0, 5, 0), Vector3.new(10, 10, 1), "Block")
	local sign = G.solidFrom(CFrame.new(5.98, 5, -0.3), Vector3.new(2, 2, 0.4), "Block")
	local found
	for _, fa in G.faces(wall) do
		for _, fb in G.faces(sign) do
			local area, _, _, width = G.coplanarOverlap(fa, fb, 0.01, 0.01)
			if area then
				found = width
				near(area, 0.04, 1e-4, "area")
			end
		end
	end
	expect(found ~= nil, "front faces overlap")
	near(found, 0.02, 1e-4, "width")
end)

test("seams: wedge facets overlapping by a hair along their shared edge are a zseam warning, left alone", function()
	local root, world = setup()
	local land = model(root, "LandBase")
	local a, b = facetPair(land, CFrame.new(0, 2, 0), 0.01)
	-- Control: the same pair laid exactly edge to edge.
	local c, d = facetPair(land, CFrame.new(20, 2, 0), 0)
	local report = BG.scan(root, { world = world })
	local seams = checks(report, "zseam")
	expect(#seams == 1 and involves(seams, a, b), BG.format(report))
	expect(#checks(report, "zfight") == 0 and not involves(report.issues, c) and not involves(report.issues, d), BG.format(report))
	local issue = seams[1]
	expect(issue.severity == "warning" and not BG.isFixable(issue), "a warning, not fixed")
	expect(
		string.find(
			issue.message,
			"Workspace/LandBase/Facet#1 and Workspace/LandBase/Facet#2 overlap in a strip 0.010 studs wide along their shared edge (Right/Left, Left/Right faces, 0.23 studs²) at (",
			1,
			true
		),
		issue.message
	)
	expect(
		string.find(issue.message, "): barely visible; pull the pieces apart in their plane (often a generator overlapping pieces by a hair)", 1, true),
		issue.message
	)
	near(issue.width, 0.01, 1e-4, "issue width")
	-- The middle of the strip on the top faces, beside the diagonal.
	near((issue.position - Vector3.new(0, 2.1, 0)).Magnitude, 0, 0.01, "position")
	local plan, unfixed = BG.planFixes(report)
	expect(#plan.items == 0 and #unfixed == 1 and unfixed[1] == issue, BG.Plan.describe(plan))
	expectPositions(report)
end)

test("seams: a wider overlap along the same edge is a z-fight error whose message gives the strip's width", function()
	local root, world = setup()
	local a, b = facetPair(root, CFrame.new(0, 2, 0), 0.05)
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, a, b) and #checks(report, "zseam") == 0, BG.format(report))
	expect(z[1].severity == "error" and BG.isFixable(z[1]))
	expect(string.find(z[1].message, "Right/Left, Left/Right face(s) overlap 1.12 studs², a strip 0.050 wide", 1, true), z[1].message)
	near(z[1].width, 0.05, 1e-4, "issue width")
end)

test("seams: a pair with one wide contact stays a z-fight, however thin its other contacts", function()
	local root, world, part = setup()
	part("Wall", Vector3.new(10, 4, 1), CFrame.new(0, 2, 0))
	-- A 0.01-thick trim: its front is flush with the wall's (1 wide) and its
	-- top with the wall's top (0.01 wide).
	local trim = part("Trim", Vector3.new(2, 1, 0.01), CFrame.new(0, 3.5, -0.495))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, trim) and #z[1].contacts == 2 and #checks(report, "zseam") == 0, BG.format(report))
	expect(string.find(z[1].message, "overlap 2.02 studs², 1.00 wide", 1, true), z[1].message)
end)

-- A closed box mesh fitted to `size` whose top is cut into `n` strips along X.
local function stripedTop(size, n)
	local h = size / 2
	local out = {}
	for _, t in boxTriangles(size) do
		if not (t[1].Y == h.Y and t[2].Y == h.Y and t[3].Y == h.Y) then
			table.insert(out, t)
		end
	end
	for i = 0, n - 1 do
		local x0, x1 = -h.X + size.X * i / n, -h.X + size.X * (i + 1) / n
		local p00, p10 = Vector3.new(x0, h.Y, -h.Z), Vector3.new(x1, h.Y, -h.Z)
		local p11, p01 = Vector3.new(x1, h.Y, h.Z), Vector3.new(x0, h.Y, h.Z)
		table.insert(out, { p00, p11, p10 })
		table.insert(out, { p00, p01, p11 })
	end
	return out
end

test("seams: mesh triangles are never seams (thin triangles can tile a wide overlap)", function()
	local root, world, part = setup()
	part("Slab", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
	local plate = mesh(root, "Plate", Vector3.new(2, 0.2, 2), CFrame.new(1, 0.9, 1))
	-- 100 strips 0.02 wide: every triangle is thinner than zFightSeamWidth.
	world.setMeshTriangles(plate, stripedTop(plate.Size, 100))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, plate) and #checks(report, "zseam") == 0, BG.format(report))
	near(totalArea(z[1]), 4, 1e-3, "the plate's whole top")
	expect(not string.find(z[1].message, "wide", 1, true), "a triangle's width isn't the overlap's: " .. z[1].message)
	expect(z[1].width == nil)
end)

test("seams: zFightSeamWidth is global; 0 turns seams off", function()
	local root, world = setup()
	expect(D.zFightSeamWidth == 0.03)
	local a, b = facetPair(root, CFrame.new(0, 2, 0), 0.01)
	local report = BG.scan(root, { world = world, config = { zFightSeamWidth = 0 } })
	expect(#checks(report, "zseam") == 0 and involves(checks(report, "zfight"), a, b), BG.format(report))
	report = BG.scan(root, { world = world, config = { zFightSeamWidth = 0.005 } })
	expect(#checks(report, "zseam") == 0 and #checks(report, "zfight") == 1, BG.format(report))
	expect(not pcall(BG.setConfig, root, { zFightSeamWidth = 0.1 }, "facets"), "can't be set per model")
	expect(not pcall(BG.Config.merge, { zFightSeamWidth = -1 }), "out of range")
end)

test("seams far from the origin (float32 positions): a 0.012 overlap is a seam, edge to edge is nothing", function()
	local root, world = setup()
	local a, b = facetPair(root, CFrame.new(9000, 10, -9000) * CFrame.Angles(0, math.rad(23), 0), 0.012, 6)
	facetPair(root, CFrame.new(-9000, 10, 9000) * CFrame.Angles(0, math.rad(23), 0), 0, 6)
	local report = BG.scan(root, { world = world })
	local seams = checks(report, "zseam")
	expect(#seams == 1 and involves(seams, a, b) and #report.issues == 1, BG.format(report))
	near(seams[1].width, 0.012, 0.002, "width")
end)

T.section("Yielding")

-- Runs a scan where it can yield and counts the yields made in each stage.
local function yieldsPerStage(root, world)
	local stage, counts = nil, {}
	world.yield = function()
		counts[stage] = (counts[stage] or 0) + 1
	end
	coroutine.wrap(function()
		BG.scan(root, {
			world = world,
			onProgress = function(name)
				stage = name
			end,
		})
	end)()
	return counts
end

test("long z-fight work yields as it goes: one slab under hundreds of crates, two big meshes", function()
	local root, world, part = setup()
	for i = 0, 399 do
		part("Crate", Vector3.one, CFrame.new(-100 + (i % 20) * 3, 0.5, -100 + math.floor(i / 20) * 3))
	end
	local counts = yieldsPerStage(root, world)
	expect((counts.zfight or 0) >= 20, ("only %d yield(s) while checking the slab against 400 crates"):format(counts.zfight or 0))

	root, world = setup()
	local a = mesh(root, "BigA", Vector3.new(10, 10, 10), CFrame.new(0, 20, 0), "rbxassetid://20")
	local b = mesh(root, "BigB", Vector3.new(10, 10, 10), CFrame.new(0, 20, 0), "rbxassetid://21")
	world.setMeshTriangles(a, boxTriangles(a.Size, false, 13))
	world.setMeshTriangles(b, boxTriangles(b.Size, false, 12))
	counts = yieldsPerStage(root, world)
	expect((counts.zfight or 0) >= 20, ("only %d yield(s) while checking one pair of big meshes"):format(counts.zfight or 0))
end)
