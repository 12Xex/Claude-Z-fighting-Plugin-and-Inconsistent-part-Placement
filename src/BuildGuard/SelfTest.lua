--[[
	Builds the test scene and proves BuildGuard handles every planted problem:

	  1. Scan: every planted problem is found; no control part is flagged.
	  2. Preview/undo: the fix plan applies and reverts back exactly.
	  3. Fix: fix-all runs; "fix" problems are gone, "flag" problems are still
	     reported, nothing else is left, and no control part moved.

	Options: { world?, parent?, origin?, config?, keep? }
	Returns { passed, text, rows }.
]]

local TestScene = require(script.Parent.TestScene)
local Classify = require(script.Parent.Classify)

local SelfTest = {}

SelfTest.DEFAULT_ORIGIN = Vector3.new(4096, 0, 4096)

local function reported(report, check, part)
	for _, issue in report.issues do
		if issue.check == check and table.find(issue.parts, part) then
			return true
		end
	end
	return false
end

local function snapshot(parts)
	local out = {}
	for _, p in parts do
		out[p] = { p.CFrame, p.Size }
	end
	return out
end

local function sameAs(snap)
	for p, state in snap do
		if (p.CFrame.Position - state[1].Position).Magnitude > 1e-4 or (p.Size - state[2]).Magnitude > 1e-4 then
			return false, p
		end
		local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = p.CFrame:GetComponents()
		local _, _, _, s00, s01, s02, s10, s11, s12, s20, s21, s22 = state[1]:GetComponents()
		local diff = math.abs(r00 - s00) + math.abs(r01 - s01) + math.abs(r02 - s02) + math.abs(r10 - s10)
			+ math.abs(r11 - s11) + math.abs(r12 - s12) + math.abs(r20 - s20) + math.abs(r21 - s21) + math.abs(r22 - s22)
		if diff > 1e-4 then
			return false, p
		end
	end
	return true
end

function SelfTest.run(BuildGuard, options)
	options = options or {}
	local world = options.world or require(script.Parent.StudioWorld).new()
	local parent = options.parent or workspace
	-- Built from the settings the scan will apply under `parent` (place-wide
	-- ones included), so it plants real violations whatever they are.
	local config = (BuildGuard.getConfig(parent, { config = options.config }))
	local scanOptions = { world = world, config = options.config }

	-- Far from the origin so it doesn't land in the middle of a real map.
	local scene = TestScene.build(parent, world, config, options.origin or SelfTest.DEFAULT_ORIGIN)
	local root = scene.folder
	local rows, failures = {}, 0
	local function row(ok, text)
		if not ok then
			failures += 1
		end
		table.insert(rows, { ok = ok, text = text })
	end

	-- 1. Scan.
	local before = BuildGuard.scan(root, scanOptions)
	for _, p in scene.planted do
		row(reported(before, p.check, p.part), ("%-4s found    %-9s %s (%s)"):format(p.id, p.check, p.part.Name, p.note))
	end
	for _, issue in before.issues do
		for _, part in issue.parts do
			if part:GetAttribute("BuildGuardControl") then
				row(false, "control flagged: " .. issue.message)
			end
		end
	end
	local listed = false
	for _, o in before.overrides do
		listed = listed or o.instance == scene.overrideModel
	end
	row(listed, "override   MountainPass's BuildGuard_maxSlopeChange is listed in the report")
	local controlState = snapshot(scene.controls)

	-- 2. Preview, apply, revert.
	local allParts = {}
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(allParts, d)
		end
	end
	local original = snapshot(allParts)
	local plan = BuildGuard.planFixes(before)
	local untouched = sameAs(original)
	row(untouched and #plan.items > 0, ("preview    plan has %d change(s), nothing moved yet"):format(#plan.items))
	BuildGuard.apply(plan, "BuildGuard self-test")
	BuildGuard.revert(plan, "BuildGuard self-test revert")
	local restored, moved = sameAs(original)
	row(restored, "undo       revert restores every part" .. (if moved then " (failed on " .. moved.Name .. ")" else ""))

	-- 3. Fix all.
	local result = BuildGuard.fixAll(root, scanOptions)
	local after = result.report
	for _, p in scene.planted do
		local still = reported(after, p.check, p.part)
		if p.expect == "fix" then
			row(not still, ("%-4s fixed    %-9s %s"):format(p.id, p.check, p.part.Name))
			if p.expectBottomY then
				local bottom = p.part.CFrame.Position.Y - p.part.Size.Y / 2
				row(
					math.abs(bottom - p.expectBottomY) < 0.02,
					("%-4s landed   %-9s %s at %.2f (expected %.2f)"):format(
						p.id,
						p.check,
						p.part.Name,
						bottom,
						p.expectBottomY
					)
				)
			end
		else
			row(still, ("%-4s flagged  %-9s %s (lint/manual, stays reported)"):format(p.id, p.check, p.part.Name))
		end
	end
	for _, issue in after.issues do
		local expected = false
		for _, p in scene.planted do
			if p.expect == "flag" and issue.check == p.check and table.find(issue.parts, p.part) then
				expected = true
			end
		end
		if not expected then
			row(false, "left over after fixing: " .. issue.message)
		end
	end
	local jointsOk, joints, broken = true, 0, nil
	for _, d in root:GetDescendants() do
		if d:IsA("JointInstance") and d.Part0 and d.Part1 then
			joints += 1
			local a = (d.Part0.CFrame * d.C0).Position
			local b = (d.Part1.CFrame * d.C1).Position
			if (a - b).Magnitude > 1e-3 then
				jointsOk, broken = false, d
			end
		end
	end
	row(
		jointsOk and joints > 0,
		("joints     all %d weld(s) still hold their parts where they are"):format(joints)
			.. (if broken then " (" .. broken:GetFullName() .. " doesn't)" else "")
	)
	local controlsOk, movedControl = sameAs(controlState)
	row(controlsOk, "controls   no control part moved" .. (if movedControl then " (" .. movedControl.Name .. " moved)" else ""))

	-- 4. Paths, positions, timings, fix report, names, real shapes.
	SelfTest.extraRows(BuildGuard, scene, before, result, original, config, row)
	SelfTest.shapeRows(BuildGuard, scanOptions, row)

	local lines = {
		("BuildGuard self-test: %s (%d check(s), %d failure(s), %d fix pass(es))"):format(
			if failures == 0 then "PASS" else "FAIL",
			#rows,
			failures,
			#result.plans
		),
	}
	for _, r in rows do
		table.insert(lines, (if r.ok then "  ok    " else "  FAIL  ") .. r.text)
	end

	if not options.keep then
		TestScene.destroy(scene, world)
	end
	return { passed = failures == 0, text = table.concat(lines, "\n"), rows = rows, scene = scene }
end

local function plantedById(scene, id)
	for _, p in scene.planted do
		if p.id == id then
			return p
		end
	end
	return nil
end

function SelfTest.extraRows(BuildGuard, scene, before, result, original, config, row)
	local root = scene.folder

	-- Repeated names are told apart by path, and every issue says where.
	-- The path is spelled out here, so a path builder that loses "#n" fails.
	local p26 = plantedById(scene, "P26")
	if p26 then
		local expected = root.Name .. "/TubRow/TubTop#3"
		local found = nil
		for _, issue in before.issues do
			if issue.check == "zfight" and table.find(issue.parts, p26.part) then
				found = issue
			end
		end
		row(
			found ~= nil and table.find(found.paths or {}, expected) ~= nil and found.position ~= nil,
			("paths      %s is named by its path and position in its z-fight"):format(expected)
		)
	end
	local missing = 0
	for _, issue in before.issues do
		if issue.check ~= "config" and issue.position == nil then
			missing += 1
		end
	end
	row(missing == 0, ("positions  every issue says where it is (%d without)"):format(missing))

	-- Each check is timed.
	local timed = {}
	for _, t in before.timings or {} do
		timed[t.name] = true
	end
	local untimed = {}
	for _, check in BuildGuard.CHECKS do
		if not timed[check.name] then
			table.insert(untimed, check.name)
		end
	end
	row(timed.collect and #untimed == 0, "timings    the report times every check" .. (if #untimed > 0 then " (missing " .. table.concat(untimed, ", ") .. ")" else ""))

	-- The fix report gives each changed part's exact move.
	local changes = result.changes or {}
	local wrong = nil
	for _, change in changes do
		local start = original[change.part]
		if not start or (start[1].Position + change.move - change.part.CFrame.Position).Magnitude > 1e-3 then
			wrong = change.path
		end
	end
	row(#changes > 0 and wrong == nil, ("fixreport  %d changed part(s), each with the move that took it where it is%s"):format(
		#changes,
		if wrong then " (wrong for " .. wrong .. ")" else ""
	))

	-- Names and sizes that used to fool the checks.
	local fooled = {}
	local function probe(name, size, className)
		local p = Instance.new(className or "Part")
		p.Name = name
		p.Size = size
		return p
	end
	for _, case in {
		{ "StreetLamp", Vector3.new(1, 12, 1) },
		{ "RoadSign", Vector3.new(6, 4, 0.2) },
		{ "BedRail", Vector3.new(0.3, 0.3, 8) },
		{ "RoofRail", Vector3.new(8, 0.3, 0.3) },
		{ "Railing", Vector3.new(8, 3, 0.3) },
	} do
		if Classify.kind(probe(case[1], case[2]), config) ~= nil then
			table.insert(fooled, case[1])
		end
	end
	local slab = probe("FloorSlab", Vector3.new(600, 1, 600))
	if Classify.isGroundLike(slab, config) then
		table.insert(fooled, "FloorSlab as ground")
	end
	for _, name in { "SteeringWheel", "SpareWheel", "WheelArch_FL" } do
		if Classify.isWheelName(name) then
			table.insert(fooled, name .. " as a wheel")
		end
	end
	row(#fooled == 0, "names      lamps, signs, bed/roof rails, railings, big slabs and steering/spare wheels aren't misread" .. (if #fooled > 0 then " (" .. table.concat(fooled, ", ") .. ")" else ""))
end

-- Controls only real geometry passes: each pair would be flagged if its
-- ball, cylinder or corner wedge were taken for its box, or if any two
-- overlapping meshes counted as a copy. Never parented, so they can't
-- touch the map.
function SelfTest.shapeRows(BuildGuard, scanOptions, row)
	local function probe(className, name, size, cframe, shape)
		local p = Instance.new(className)
		p.Name = name
		if shape then
			p.Shape = Enum.PartType[shape]
		end
		p.Size = size
		p.CFrame = cframe
		p.Anchored = true
		return p
	end
	local at = CFrame.new(0, 10, 0)
	local cases = {
		{
			"a ball inside a cube of its size (touches only at points)",
			probe("Part", "Cube", Vector3.new(2, 2, 2), at),
			probe("Part", "Ball", Vector3.new(2, 2, 2), at, "Ball"),
		},
		{
			"a rod lying in a box channel (touches only along lines)",
			probe("Part", "Channel", Vector3.new(2, 1, 1), at),
			probe("Part", "Rod", Vector3.new(1.8, 1, 1), at, "Cylinder"),
		},
		{
			"a block in a corner wedge's empty top corner (flush only with its box)",
			probe("CornerWedgePart", "Corner", Vector3.new(2, 2, 2), at),
			probe("Part", "Block", Vector3.new(1, 0.5, 1), at * CFrame.new(-0.5, 0.75, 0.5)),
		},
		{
			"two meshes on one spot, one half as tall (not a copy, half their boxes shared)",
			probe("MeshPart", "MeshTall", Vector3.new(4, 4, 4), at),
			probe("MeshPart", "MeshLow", Vector3.new(4, 2, 4), at),
		},
	}
	local options = table.clone(scanOptions)
	options.yield = false
	for _, case in cases do
		local report = BuildGuard.scan({ case[2], case[3] }, options)
		local first = report.issues[1]
		row(first == nil, "shapes     " .. case[1] .. (if first then " (flagged: " .. first.message .. ")" else ""))
	end
end

return SelfTest
