-- Faces: round surfaces, corner wedges, duplicates, mesh boxes, mesh
-- triangles, far-view face gaps, contact positions in messages, float
-- rounding far from the origin, layer 0, contacts covered by third parts,
-- seams, and yielding during long scans.
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

test("layer 0: overlapping items whose bottoms are coplanar don't z-fight on a deck that hides them; on one that doesn't show they do, and are fixed", function()
	local root, world, part = setup()
	local deck = part("Deck", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
	local a = BG.Layers.place(part("PlateA", Vector3.new(4, 0.1, 4), CFrame.new()), deck, { layer = 0 })
	local b = BG.Layers.place(part("PlateB", Vector3.new(4, 0.2, 4), CFrame.new()), deck, { layer = 0, u = 2, v = 1 })
	local report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
	deck.Transparency = 1
	report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, a, b), BG.format(report))
	expect(string.find(z[1].message, "Bottom/Bottom face(s) overlap 6.00 studs²", 1, true), z[1].message)
	BG.apply((BG.planFixes(report)))
	report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
end)

test("layer 0: overlapping items of the same thickness are fixed by sinking one into the surface, not lifting it off", function()
	-- The plate is the smaller part (the one moved) first, then the rib.
	for _, plateSize in { Vector3.new(2, 0.22, 2), Vector3.new(3, 0.22, 3) } do
		local root, world, part = setup()
		local road = part("Road_Main", Vector3.new(60, 0.8, 22), CFrame.new(0, 0.4, 0))
		local rib = BG.Layers.place(part("Washboard_Rib", Vector3.new(8, 0.22, 0.6), CFrame.new()), road, { layer = 0, u = 5, rotation = 90 })
		local plate = BG.Layers.place(part("Plate", plateSize, CFrame.new()), road, { layer = 0, u = 5 })
		local report = BG.scan(root, { world = world })
		local z = checks(report, "zfight")
		expect(#z == 1 and involves(z, rib, plate), BG.format(report))
		-- Their bottoms are coplanar too, but the road's top hides them.
		expect(string.find(z[1].message, "Top/Top", 1, true) and not string.find(z[1].message, "Bottom/Bottom", 1, true), z[1].message)
		local plan = BG.planFixes(report)
		expect(#plan.items == 1 and string.find(plan.items[1].reason, "nudge clear", 1, true), BG.Plan.describe(plan))
		BG.apply(plan)
		for _, p in { rib, plate } do
			local bottom = p.CFrame.Position.Y - p.Size.Y / 2
			expect(bottom <= 0.8 + 1e-4, ("%s's bottom is at %.3f, above the road top (0.800): light shows under it"):format(p.Name, bottom))
		end
		report = BG.scan(root, { world = world })
		expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
	end
end)

test("crossing markings too thin to sink by the nudge (P4 at zFightNudge 0.1 and 0.3) lift off the road instead, in one pass", function()
	for _, case in {
		{ nudge = 0.1, thick = 0.1 },
		{ nudge = 0.3, thick = 0.1 },
		{ nudge = D.zFightNudge, thick = 0.02 },
		{ nudge = D.zFightNudge, thick = 0.025 },
		-- Thick enough: sunk into the road, no light under it.
		{ nudge = D.zFightNudge, thick = 0.1, sinks = true },
		{ nudge = 0.08, thick = 0.1, sinks = true },
	} do
		local label = ("%.3f thick at zFightNudge %g"):format(case.thick, case.nudge)
		local root, world, part = setup()
		part("Road_Main", Vector3.new(60, 0.8, 22), CFrame.new(0, 0.4, 0))
		local a = part("CrossMarkA", Vector3.new(8, case.thick, 0.4), CFrame.new(0, 0.8 + case.thick / 2, 0))
		local b = part("CrossMarkB", Vector3.new(0.4, case.thick, 8), CFrame.new(0, 0.8 + case.thick / 2, 0))
		local result = BG.fixAll(root, { world = world, config = { zFightNudge = case.nudge } })
		expect(#result.plans == 1, ("%s: %d passes\n%s"):format(label, #result.plans, BG.format(result.report)))
		local report = result.report
		for _, check in { "zfight", "zseam", "zgap" } do
			expect(#checks(report, check) == 0, label .. ": " .. BG.format(report))
		end
		-- Lifted buriedProbeHeight or more, a marking hovers high enough that
		-- the road counts as buried under it (as any marking nudged up that far).
		if case.nudge < D.buriedProbeHeight then
			expect(report.counts.error == 0 and report.counts.warning == 0, label .. ": " .. BG.format(report))
		end
		for _, p in { a, b } do
			local top, bottom = p.CFrame.Position.Y + p.Size.Y / 2, p.CFrame.Position.Y - p.Size.Y / 2
			expect(top > 0.8 + D.zFightTolerance, ("%s: %s's top is at %.3f, not clear of the road top (0.800)"):format(label, p.Name, top))
			if case.sinks then
				expect(bottom <= 0.8 + 1e-4, ("%s: %s's bottom is at %.3f, above the road top"):format(label, p.Name, bottom))
			end
		end
	end
end)

test("self-test passes with zFightNudge 0.1 at its default spot (P4's crossing markings are thick enough to sink by the nudge)", function()
	local root = Instance.new("Folder")
	root.Name = "Workspace"
	local result = BG.selfTest({ world = T.FakeWorld.new(root, BG.Geometry), parent = root, config = { zFightNudge = 0.1 } })
	expect(result.passed, result.text)
end)

test("layer 0: a rib across the road's full width lifts off a crossing item instead of sinking its ends flush with the road's sides", function()
	for _, at in { CFrame.new(), CFrame.new(-24576, 0, 24576) } do
		local root, world, part = setup()
		if at.Position.Magnitude > 0 then
			part("Ground", Vector3.new(400, 2, 400), at * CFrame.new(0, -1, 0))
		end
		local road = part("Road_Main", Vector3.new(60, 0.8, 22), at * CFrame.new(0, 0.4, 0))
		-- The rib is the smaller part, so it's the one moved.
		local rib = BG.Layers.place(part("Washboard_Rib", Vector3.new(22, 0.22, 0.6), CFrame.new()), road, { layer = 0, u = 5, rotation = 90 })
		local plate = BG.Layers.place(part("Plate", Vector3.new(4, 0.22, 4), CFrame.new()), road, { layer = 0, u = 5 })
		local report = BG.scan(root, { world = world })
		local z = checks(report, "zfight")
		expect(#z == 1 and involves(z, rib, plate), BG.format(report))
		local result = BG.fixAll(root, { world = world })
		report = result.report
		expect(#checks(report, "zseam") == 0, BG.format(report))
		expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
		expect(#result.plans == 1, #result.plans .. " passes")
		near(rib.CFrame.Position.Y - 0.11, at.Position.Y + 0.8 + D.zFightNudge, 1e-3, "the rib lifts by the nudge")
	end
end)

T.section("Covered contacts")

-- The docs' footing (workflows.md, Roads step 4): as wide and long as the
-- road, its top at the road's bottom, reaching `depth` down.
local function footing(road, depth)
	local f = Instance.new("Part")
	f.Name = "Footing_" .. road.Name
	f.Size = Vector3.new(road.Size.X, depth, road.Size.Z)
	f.CFrame = road.CFrame * CFrame.new(0, -(road.Size.Y + depth) / 2, 0)
	f.Anchored = true
	f.Parent = road.Parent
	return f
end

-- A road resting on a flat ground pad (top 1.2 up) with one end over the
-- dip beyond it, and its footing through the pad into the ground, at `at`.
local function footingThroughPad(part, at, pieces)
	if at.Position.Magnitude > 0 then
		part("Ground", Vector3.new(400, 2, 400), at * CFrame.new(0, -1, 0))
	end
	local pad = part("Ground_Yard", Vector3.new(30, 1.2, 40), at * CFrame.new(-19, 0.6, 0))
	local roads = {}
	for i = 1, pieces or 1 do
		local length = 28 / (pieces or 1)
		table.insert(roads, part("Road_West_" .. i, Vector3.new(length, 0.8, 22), at * CFrame.new(-14 + length * (i - 0.5), 1.6, 0)))
	end
	return pad, roads
end

test("covered contacts: a footing through a flat ground pad under a resting road is clean; fixes leave it alone", function()
	local spots = { CFrame.new(), CFrame.new(-9000, 0, 9000) * CFrame.Angles(0, math.rad(23), 0), CFrame.new(24576, 0, -24576) }
	for _, at in spots do
		local root, world, part = setup()
		local pad, roads = footingThroughPad(part, at)
		local before = BG.scan(root, { world = world })
		expect(#checks(before, "gap") == 1, "the gap under the road's end over the dip: " .. BG.format(before))
		local f = footing(roads[1], 4)
		local report = BG.scan(root, { world = world })
		expect(not involves(report.issues, f) and not involves(report.issues, pad), BG.format(report))
		local plan = BG.planFixes(report)
		expect(plan.byPart[f] == nil and plan.byPart[pad] == nil, BG.Plan.describe(plan))
	end
	-- One footing under two road pieces end to end: both cover it.
	local root, world, part = setup()
	local pad, roads = footingThroughPad(part, CFrame.new(), 2)
	local f = part("Footing_Run", Vector3.new(28, 4, 22), CFrame.new(0, 1.2 - 2, 0))
	local report = BG.scan(root, { world = world })
	expect(#roads == 2 and not involves(report.issues, f) and not involves(report.issues, pad), BG.format(report))
	-- The footing through a level land facet (a wedge whose Right face is up).
	root, world, part = setup()
	local _, ones = footingThroughPad(part, CFrame.new())
	local land = model(root, "LandBase")
	land:AddTag("BuildGuardGround")
	-- Its Right face is up at y 1.2, over x -2..6, z 0..8 (under the road, past the pad).
	local facet = newPart("WedgePart", land, "Facet", Vector3.new(1.2, 8, 8), CFrame.new(2, 0.6, 4) * CFrame.Angles(0, 0, math.pi / 2))
	f = footing(ones[1], 4)
	report = BG.scan(root, { world = world })
	expect(not involves(report.issues, f), BG.format(report))
	expect(not involves(checks(report, "zfight"), facet), BG.format(report))
end)

test("covered contacts: a contact covered only in part, or by a part that doesn't show or doesn't touch it, is still reported", function()
	-- A marking flush with the road top, half under a crate resting on the road.
	local root, world, part = setup()
	local road = part("Road_Main", Vector3.new(30, 0.8, 22), CFrame.new(0, 0.4, 0))
	local mark = part("LaneMarking", Vector3.new(6, 0.1, 0.5), CFrame.new(0, 0.75, 0))
	part("Crate", Vector3.new(3, 3, 3), CFrame.new(1.5, 2.3, 0))
	-- Control: the same marking wholly under a crate can't be seen.
	local hidden = part("LaneMarking", Vector3.new(6, 0.1, 0.5), CFrame.new(0, 0.75, 8))
	part("Crate", Vector3.new(8, 3, 3), CFrame.new(0, 2.3, 8))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 1 and involves(z, mark, road), BG.format(report))
	expect(string.find(z[1].message, "Top/Top face(s) overlap 3.00 studs²", 1, true), z[1].message)
	expect(not involves(report.issues, hidden), BG.format(report))
	BG.apply((BG.planFixes(report)))
	report = BG.scan(root, { world = world })
	expect(#checks(report, "zfight") == 0, BG.format(report))

	-- The footing under an invisible road, and under a road 0.05 above it.
	for _, case in { { transparency = 1, raise = 0 }, { transparency = 0, raise = 0.05 } } do
		root, world, part = setup()
		local pad, roads = footingThroughPad(part, CFrame.new())
		local f = footing(roads[1], 4)
		roads[1].Transparency = case.transparency
		roads[1].CFrame += Vector3.new(0, case.raise, 0)
		report = BG.scan(root, { world = world })
		z = checks(report, "zfight")
		expect(#z == 1 and involves(z, f, pad), BG.format(report))
		expect(string.find(z[1].message, "Top/Top face(s) overlap 220.00 studs²", 1, true), z[1].message)
	end
end)

test("covered contacts: Geometry.overlapCover finds the union faces pointing the other way cover, and what they leave open", function()
	local G = BG.Geometry
	local function top(s)
		for _, f in G.faces(s) do
			if f.name == "Top" then
				return f
			end
		end
		return nil
	end
	local function bottom(s)
		for _, f in G.faces(s) do
			if f.name == "Bottom" then
				return f
			end
		end
		return nil
	end
	local frame = CFrame.new(5, 2, -3) * CFrame.Angles(0, math.rad(30), 0)
	local slab = G.solidFrom(frame * CFrame.new(0, -0.5, 0), Vector3.new(10, 1, 10), "Block")
	local inlay = G.solidFrom(frame * CFrame.new(2, -0.25, 0), Vector3.new(4, 0.5, 2), "Block")
	-- The inlay's top (x 0..4, z -1..1 in the frame) overlaps the slab's: 8 studs².
	local crateA = G.solidFrom(frame * CFrame.new(-1, 1, 0), Vector3.new(6, 2, 6), "Block")
	local crateB = G.solidFrom(frame * CFrame.new(3, 1, 0), Vector3.new(2, 2, 6), "Block")
	local covered, area = G.overlapCover(top(slab), top(inlay), { bottom(crateA) })
	near(area, 8, 1e-4, "overlap")
	-- Each cover reaches 0.001 further (float rounding at this spot).
	near(covered, 4.002, 1e-4, "crate A covers x 0..2")
	covered = G.overlapCover(top(slab), top(inlay), { bottom(crateA), bottom(crateB) })
	near(covered, 8, 1e-4, "crate B covers x 2..4")
	local wide = G.solidFrom(frame * CFrame.new(2, 1, 0), Vector3.new(6, 2, 6), "Block")
	covered = G.overlapCover(top(slab), top(inlay), { bottom(crateA), bottom(wide) })
	near(covered, 8, 1e-4, "covers overlapping each other")
	-- Covers overlapping each other count once: their sum (8.006) would hide x 3..4.
	covered = G.overlapCover(top(slab), top(inlay), { bottom(crateA), bottom(crateA) })
	near(covered, 4.002, 1e-4, "the same cover twice")
	local mid = G.solidFrom(frame * CFrame.new(2, 1, 0), Vector3.new(2, 2, 6), "Block")
	local open
	covered, area, open = G.overlapCover(top(slab), top(inlay), { bottom(crateA), bottom(mid) })
	near(covered, 6.002, 1e-4, "crate A and a crate over x 1..3: their union")
	local left = 0
	for _, piece in open do
		expect(#piece >= 3, "pieces are polygons")
		for _, p in piece do
			near(frame:PointToObjectSpace(p).Y, 0, 1e-4, "on the overlap's plane")
			expect(frame:PointToObjectSpace(p).X >= 3 - 1e-3, "only x 3..4 is open")
		end
		for i = 3, #piece do
			left += (piece[i - 1] - piece[1]):Cross(piece[i] - piece[1]).Magnitude / 2
		end
	end
	near(left, area - covered, 1e-4, "the open pieces' area")
	-- A cover flush with the overlap's edges but for float rounding covers all of it.
	local flush = G.solidFrom(frame * CFrame.new(2.0004, 1, -0.0003), Vector3.new(3.9995, 2, 1.9996), "Block")
	covered = G.overlapCover(top(slab), top(inlay), { bottom(flush) })
	expect(covered >= 8, "flush cover: " .. covered)
	local away = G.solidFrom(frame * CFrame.new(20, -0.25, 0), Vector3.new(4, 0.5, 2), "Block")
	covered, area = G.overlapCover(top(slab), top(away), { bottom(crateA) })
	expect(covered == 0 and area == 0, "no overlap")
end)

test("covered contacts: Geometry.heldSection is the part of a plane a block or wedge holds on both sides", function()
	local G = BG.Geometry
	local function area(points)
		local total = 0
		for i = 3, #points do
			total += (points[i - 1] - points[1]):Cross(points[i] - points[1]).Magnitude / 2
		end
		return total
	end
	local frame = CFrame.new(-7, 3, 11) * CFrame.Angles(0, math.rad(30), 0)
	local up = frame.UpVector
	-- A 4 x 2 x 6 block through the plane: its 4 x 6 footprint.
	local block = G.solidFrom(frame * CFrame.new(1, 0.5, 0), Vector3.new(4, 2, 6), "Block")
	local held = G.heldSection(block, frame.Position, up, 0.005)
	expect(held, "a block through the plane")
	near(area(held), 24, 1e-3, "its footprint")
	for _, p in held do
		near(frame:PointToObjectSpace(p).Y, 0, 1e-4, "on the plane")
	end
	-- Resting on the plane, or ending just past it: nothing.
	local resting = G.solidFrom(frame * CFrame.new(1, 1, 0), Vector3.new(4, 2, 6), "Block")
	expect(G.heldSection(resting, frame.Position, up, 0.005) == nil, "resting on it")
	local shallow = G.solidFrom(frame * CFrame.new(1, 0.998, 0), Vector3.new(4, 2, 6), "Block")
	expect(G.heldSection(shallow, frame.Position, up, 0.005) == nil, "0.002 into it")
	-- A wedge 4 high and 4 deep through the plane at half its height: its
	-- slope cuts the 4 x 4 footprint in half.
	local wedge = G.solidFrom(frame * CFrame.new(0, 0, 0), Vector3.new(4, 4, 4), "Wedge")
	held = G.heldSection(wedge, frame.Position, up, 0.005)
	near(area(held), 8, 0.05, "half the wedge's footprint")
	expect(G.heldSection(G.solidFrom(frame, Vector3.new(4, 4, 4), "Ball"), frame.Position, up, 0.005) == nil, "round shapes have no polygon")
end)

test("covered contacts: covers overlapping each other or laid end to end don't hide the part of an overlap they leave open", function()
	-- A footing 1 stud longer than its road: 22 studs² of its top, flush
	-- with the pad's, is open to the sky past the road's end. Shoulders
	-- along both sides overlap the road by 1 stud.
	local root, world, part = setup()
	local pad = part("Ground_Yard", Vector3.new(60, 1.2, 40), CFrame.new(0, 0.6, 0))
	part("Road_West", Vector3.new(28, 0.8, 22), CFrame.new(0, 1.6, 0))
	local f = part("Footing_Road_West", Vector3.new(29, 4, 22), CFrame.new(0.5, 1.2 - 2, 0))
	for _, side in { -1, 1 } do
		part("Shoulder", Vector3.new(26.5, 0.6, 3), CFrame.new(-0.25, 1.5, side * 11.5))
	end
	local report = BG.scan(root, { world = world })
	local issue = involves(checks(report, "zfight"), f, pad)
	expect(issue and string.find(issue.message, "Top/Top face(s) overlap 638.00 studs²", 1, true), BG.format(report))
	-- The shoulders' bottoms where they overlap the road are on the footing: hidden.
	expect(#checks(report, "zfight") == 1, BG.format(report))

	-- The road in two pieces overlapping by 4, the footing 2 studs past its end.
	root, world, part = setup()
	pad = part("Ground_Yard", Vector3.new(60, 1.2, 40), CFrame.new(0, 0.6, 0))
	part("Road_West_A", Vector3.new(16, 0.8, 22), CFrame.new(-6, 1.6, 0))
	part("Road_West_B", Vector3.new(16, 0.8, 22), CFrame.new(6, 1.6, 0))
	f = part("Footing_Road_West", Vector3.new(30, 4, 22), CFrame.new(1, 1.2 - 2, 0))
	report = BG.scan(root, { world = world })
	expect(involves(checks(report, "zfight"), f, pad), BG.format(report))

	-- Ten pieces end to end far out, where each cover is grown by about
	-- 0.012 for float rounding: the footing 0.1 or 0.2 past the last one's
	-- end still shows. Flush with it, the joints don't leave anything open.
	local at = CFrame.new(24576, 0, -24576)
	for _, past in { 0.1, 0.2, 0 } do
		root, world, part = setup()
		part("Ground", Vector3.new(400, 2, 400), at * CFrame.new(0, -1, 0))
		pad = part("Ground_Yard", Vector3.new(80, 1.2, 40), at * CFrame.new(0, 0.6, 0))
		for i = 0, 9 do
			part("Road_Piece", Vector3.new(4, 0.8, 22), at * CFrame.new(-18 + i * 4, 1.6, 0))
		end
		f = part("Footing_Run", Vector3.new(40 + past, 4, 22), at * CFrame.new(past / 2, 1.2 - 2, 0))
		report = BG.scan(root, { world = world })
		issue = involves(checks(report, "zfight"), f, pad)
		if past > 0 then
			expect(issue, ("%.1f past the end: %s"):format(past, BG.format(report)))
		else
			expect(not involves(report.issues, f), "flush with the end: " .. BG.format(report))
		end
	end
end)

test("covered contacts: only opaque parts hide a contact (not glass, a see-through part or a force field)", function()
	-- An inlay flush in a deck's top with a panel resting on it.
	local function scene(material, transparency)
		local root, world, part = setup()
		local deck = part("Deck", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
		local inlay = part("Inlay", Vector3.new(6, 0.1, 2), CFrame.new(0, 0.95, 0))
		local panel = part("Panel", Vector3.new(8, 0.2, 4), CFrame.new(0, 1.1, 0))
		panel.Material = Enum.Material[material]
		panel.Transparency = transparency
		return BG.scan(root, { world = world }), deck, inlay
	end
	for _, case in { { "Glass", 0.5 }, { "Glass", 0 }, { "Plastic", 0.5 }, { "Plastic", 0.1 }, { "ForceField", 0 } } do
		local report, deck, inlay = scene(case[1], case[2])
		local issue = involves(checks(report, "zfight"), deck, inlay)
		local label = ("%s at Transparency %g"):format(case[1], case[2])
		expect(issue and string.find(issue.message, "Top/Top face(s) overlap 12.00 studs²", 1, true), label .. ": " .. BG.format(report))
	end
	-- An opaque crate hides it.
	for _, transparency in { 0, 0.05 } do
		local report, _, inlay = scene("Wood", transparency)
		expect(not involves(report.issues, inlay), BG.format(report))
	end

	-- A see-through road doesn't hide a part sunk into it: two equal
	-- layer-0 plates grow past both faces instead of sinking.
	local root, world, part = setup()
	local road = part("Road_Main", Vector3.new(60, 0.8, 22), CFrame.new(0, 0.4, 0))
	road.Transparency = 0.5
	BG.Layers.place(part("Washboard_Rib", Vector3.new(8, 0.22, 0.6), CFrame.new()), road, { layer = 0, u = 5, rotation = 90 })
	BG.Layers.place(part("Plate", Vector3.new(2, 0.22, 2), CFrame.new()), road, { layer = 0, u = 5 })
	local plan = BG.planFixes(BG.scan(root, { world = world }))
	expect(#plan.items == 1 and string.find(plan.items[1].reason, "grow past both faces", 1, true), BG.Plan.describe(plan))
end)

test("covered contacts: a contact sunk inside an opaque part is hidden, unless part of it is outside", function()
	-- A footing a little narrower than its road, the road sunk 0.05 into it
	-- and the pad: their flush tops are inside the road.
	local root, world, part = setup()
	local pad = part("Ground_Yard", Vector3.new(40, 1.2, 40), CFrame.new(-10, 0.6, 0))
	local f = part("Footing", Vector3.new(27, 4, 21), CFrame.new(0, 1.2 - 2, 0))
	part("Road_West", Vector3.new(28, 0.8, 22), CFrame.new(0, 1.55, 0))
	local report = BG.scan(root, { world = world })
	expect(not involves(checks(report, "zfight"), f, pad), BG.format(report))
	-- The footing and pad both a stud past the road's ends.
	root, world, part = setup()
	pad = part("Ground_Yard", Vector3.new(60, 1.2, 40), CFrame.new(0, 0.6, 0))
	f = part("Footing", Vector3.new(30, 4, 21), CFrame.new(0, 1.2 - 2, 0))
	part("Road_West", Vector3.new(28, 0.8, 22), CFrame.new(0, 1.55, 0))
	report = BG.scan(root, { world = world })
	expect(involves(checks(report, "zfight"), f, pad), BG.format(report))
	-- An inlay held by two blocks sunk into the deck: hidden when they
	-- meet, not when a stud between them shows (even though its corners and
	-- middle are all held).
	for _, gap in { 1, 0 } do
		root, world, part = setup()
		local deck = part("Deck", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
		local inlay = part("Inlay", Vector3.new(10, 0.1, 2), CFrame.new(0, 0.95, 0))
		part("BlockA", Vector3.new(6, 0.6, 3), CFrame.new(-2, 1.2, 0))
		part("BlockB", Vector3.new(4 - gap, 0.6, 3), CFrame.new(3 + gap / 2, 1.2, 0))
		report = BG.scan(root, { world = world })
		local issue = involves(checks(report, "zfight"), deck, inlay)
		expect((issue ~= nil) == (gap > 0), ("gap %d: %s"):format(gap, BG.format(report)))
	end
	-- A crate resting on half of an inlay and the deck under it don't hide
	-- the other half (only their faces would, and they don't reach).
	root, world, part = setup()
	local deck = part("Deck", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
	local inlay = part("Inlay", Vector3.new(6, 0.1, 2), CFrame.new(0, 0.95, 0))
	part("Crate", Vector3.new(3, 3, 3), CFrame.new(-1.5, 2.5, 0))
	report = BG.scan(root, { world = world })
	expect(involves(checks(report, "zfight"), deck, inlay), BG.format(report))
end)

test("covered contacts: a cover lifted by the face gap (as a fix leaves it) still hides the contact", function()
	for _, case in { { raise = D.zFightNudge, hidden = true }, { raise = 0.05, hidden = false } } do
		local root, world, part = setup()
		local pad, roads = footingThroughPad(part, CFrame.new())
		local f = footing(roads[1], 4)
		roads[1].CFrame += Vector3.new(0, case.raise, 0)
		local report = BG.scan(root, { world = world })
		local issue = involves(checks(report, "zfight"), f, pad)
		expect((issue == nil) == case.hidden, ("road %.2f up: %s"):format(case.raise, BG.format(report)))
	end
end)

test("covered contacts: a road running flush onto a plaza, on its footing through a pad, is fixed in one pass in either creation order; the footing never moves", function()
	for _, padFirst in { true, false } do
		local label = if padFirst then "pad first" else "footing first"
		local root, world, part = setup()
		local f
		local function addFooting()
			f = part("Footing_Road_West", Vector3.new(28, 4, 22), CFrame.new(0, 1.2 - 2, 0))
		end
		if not padFirst then
			addFooting()
		end
		part("Ground_Yard", Vector3.new(40, 1.2, 40), CFrame.new(-10, 0.6, 0))
		if padFirst then
			addFooting()
		end
		local road = part("Road_West", Vector3.new(28, 0.8, 22), CFrame.new(0, 1.6, 0))
		-- Its top flush with the road's over the road's last 4 studs.
		local plaza = part("PlazaDeck", Vector3.new(40, 0.5, 40), CFrame.new(30, 1.75, 0))
		local footingAt, footingSize, roadSize = f.CFrame, f.Size, road.Size
		local report = BG.scan(root, { world = world })
		local z = checks(report, "zfight")
		expect(#z == 1 and involves(z, road, plaza), label .. ": " .. BG.format(report))
		local result = BG.fixAll(root, { world = world })
		expect(#result.plans == 1, ("%s: %d passes\n%s"):format(label, #result.plans, BG.format(result.report)))
		report = result.report
		expect(report.counts.error == 0 and report.counts.warning == 0, label .. ": " .. BG.format(report))
		expect(f.CFrame == footingAt and f.Size == footingSize, label .. ": the footing moved")
		expect(road.Size == roadSize, label .. ": the road was resized")
		expect(road.CFrame.Position.Y - 0.4 >= 1.2 - 1e-4, label .. ": the road sank into its footing")
	end
end)

test("covered contacts: overlapping footings buried in the ground are clean and never moved; their sides over a dip z-fight", function()
	local function scene(dip)
		local root, world, part = setup()
		local ground = root:FindFirstChild("Ground")
		if dip then
			-- The ground drops to 6 below in front of the footings' Front sides.
			ground.Size, ground.CFrame = Vector3.new(400, 20, 211), CFrame.new(0, -10, 94.5)
			part("Ground_Low", Vector3.new(400, 14, 189), CFrame.new(0, -13, -105.5))
		else
			ground.Size, ground.CFrame = Vector3.new(400, 20, 400), CFrame.new(0, -10, 0)
		end
		-- Two road pieces overlapping by 4, each with the docs' footing.
		local a = part("Road_A", Vector3.new(22, 0.8, 22), CFrame.new(-9, 0.4, 0))
		local b = part("Road_B", Vector3.new(22, 0.6, 22), CFrame.new(9, 0.3, 0))
		return root, world, footing(a, 4), footing(b, 4)
	end
	local root, world, fa, fb = scene(false)
	local report = BG.scan(root, { world = world })
	expect(not involves(report.issues, fa) and not involves(report.issues, fb), BG.format(report))
	local was = { fa.CFrame, fa.Size, fb.CFrame, fb.Size }
	BG.fixAll(root, { world = world })
	expect(fa.CFrame == was[1] and fa.Size == was[2] and fb.CFrame == was[3] and fb.Size == was[4], "a footing moved")

	root, world, fa, fb = scene(true)
	report = BG.scan(root, { world = world })
	local issue = involves(checks(report, "zfight"), fa, fb)
	expect(issue and string.find(issue.message, "Front/Front face(s) overlap 16.00 studs²", 1, true), BG.format(report))

	-- In ground made of two slabs meeting under them, and in terrain.
	root, world, fa, fb = scene(false)
	local ground = root:FindFirstChild("Ground")
	ground.Size, ground.CFrame = Vector3.new(200, 20, 400), CFrame.new(-100, -10, 0)
	local east = ground:Clone()
	east.CFrame = CFrame.new(100, -10, 0)
	east.Parent = root
	report = BG.scan(root, { world = world })
	expect(not involves(report.issues, fa) and not involves(report.issues, fb), "two slabs: " .. BG.format(report))
	ground.Parent, east.Parent = nil, nil
	world.fillTerrain(CFrame.new(0, -10, 0), Vector3.new(400, 20, 400), "Grass")
	report = BG.scan(root, { world = world })
	expect(not involves(checks(report, "zfight"), fa, fb), "terrain: " .. BG.format(report))
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

test("seams: a thin part sunk flush inside a bigger face (an inlay, a wire) is a z-fight with a fix, not a seam", function()
	local root, world, part = setup()
	part("Deck", Vector3.new(20, 1, 20), CFrame.new(0, 0.5, 0))
	-- Narrower than zFightSeamWidth, its top flush in the middle of the deck's.
	local inlay = part("Inlay", Vector3.new(0.025, 0.5, 12), CFrame.new(0, 0.75, 0))
	part("Wall", Vector3.new(10, 4, 1), CFrame.new(30, 2, 0))
	-- A wire whose front is flush with the wall's, across its middle.
	local wire = part("Wire", Vector3.new(6, 0.025, 0.025), CFrame.new(30, 2, -0.4875))
	local report = BG.scan(root, { world = world })
	local z = checks(report, "zfight")
	expect(#z == 2 and involves(z, inlay) and involves(z, wire) and #checks(report, "zseam") == 0, BG.format(report))
	for _, issue in z do
		expect(issue.severity == "error" and BG.isFixable(issue), issue.message)
	end
	expect(string.find(involves(z, inlay).message, "Top/Top face(s) overlap 0.30 studs², a strip 0.025 wide", 1, true), involves(z, inlay).message)
	local plan = BG.planFixes(report)
	expect(#plan.items == 2, BG.Plan.describe(plan))
	BG.apply(plan)
	near(inlay.CFrame.Position.Y + 0.25, 1 + D.zFightNudge, 1e-4, "the inlay's top is nudged clear of the deck's")
	near(wire.CFrame.Position.Z - 0.0125, -0.5 - D.zFightNudge, 1e-4, "the wire's front is nudged clear of the wall's")
	report = BG.scan(root, { world = world })
	expect(report.counts.error == 0 and report.counts.warning == 0, BG.format(report))
end)

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
	expect(not pcall(BG.Config.merge, { zFightSeamWidth = 0.25 }), "over 0.2: the self-test's planted z-fights (0.4 wide and more) would turn into seams")
	expect(pcall(BG.Config.merge, { zFightSeamWidth = 0.2 }))
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

test("hidden-contact checks stay quick and yield: a mesh path flush in the ground with 600 crates on it", function()
	local root, world, part = setup()
	local path = mesh(root, "MeshPath", Vector3.new(40, 0.5, 40), CFrame.new(0, -0.25, 0))
	-- Its top only: a 40 x 40 grid of quads, two triangles each.
	local n, h, triangles = 40, path.Size / 2, {}
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local x0, x1 = -h.X + 2 * h.X * i / n, -h.X + 2 * h.X * (i + 1) / n
			local z0, z1 = -h.Z + 2 * h.Z * j / n, -h.Z + 2 * h.Z * (j + 1) / n
			local p00, p10, p11, p01 = Vector3.new(x0, h.Y, z0), Vector3.new(x1, h.Y, z0), Vector3.new(x1, h.Y, z1), Vector3.new(x0, h.Y, z1)
			table.insert(triangles, { p00, p11, p10 })
			table.insert(triangles, { p00, p01, p11 })
		end
	end
	world.setMeshTriangles(path, triangles)
	local seed = 7
	local function random(lo, hi)
		seed = (seed * 1103515245 + 12345) % 2147483648
		return lo + (hi - lo) * seed / 2147483648
	end
	for _ = 1, 600 do
		part("Crate", Vector3.new(3, 3, 3), CFrame.new(random(-25, 25), 1.5, random(-25, 25)))
	end
	-- The longest stretch of z-fight work between yields.
	local stage, last, longest = nil, os.clock(), 0
	world.yield = function()
		local now = os.clock()
		if stage == "zfight" then
			longest = math.max(longest, now - last)
		end
		last = now
	end
	local report
	coroutine.wrap(function()
		report = BG.scan(root, {
			world = world,
			onProgress = function(name)
				stage = name
			end,
		})
	end)()
	local seconds = 0
	for _, t in report.timings do
		if t.name == "zfight" then
			seconds = t.seconds
		end
	end
	expect(involves(checks(report, "zfight"), path), "the path's top is flush with the ground's")
	-- 0.6.2 took about 8 s here, with 0.7 s stretches without a yield.
	expect(seconds < 4, ("z-fight check took %.2f s"):format(seconds))
	expect(longest < 0.2, ("%.3f s of z-fight work without a yield"):format(longest))
end)
