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
local Config = require(script.Parent.Config)

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
	local config = Config.merge(options.config)
	local world = options.world or require(script.Parent.StudioWorld).new()
	local parent = options.parent or workspace
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
	local controlsOk, movedControl = sameAs(controlState)
	row(controlsOk, "controls   no control part moved" .. (if movedControl then " (" .. movedControl.Name .. " moved)" else ""))

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

return SelfTest
