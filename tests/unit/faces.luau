-- Faces: round surfaces, corner wedges, duplicates, mesh boxes, mesh
-- triangles, far-view face gaps, and contact positions in messages.
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
local OWN_CHECKS = { zfight = true, zgap = true, duplicate = true, meshoverlap = true }
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

	ctx = BG.newContext(root, { world = world, config = { meshTriangles = false } })
	ZFight.scan(ctx)
	expect(ctx.coverage.meshTriangles == 0 and ctx.coverage.reasons["meshTriangles is off"] == 3)
	expect(Meshes.describeCoverage(BG.newContext(nil, { world = world }).coverage) == nil)
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
			== "Workspace/Tub/TubTop#1 and Workspace/Tub/TubTop#2 z-fight at (3.00, 6.00, -0.50): Front/Front face(s) overlap 4.00 studs²",
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
