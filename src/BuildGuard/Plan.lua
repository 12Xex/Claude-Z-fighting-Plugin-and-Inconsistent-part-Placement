--[[
	A fix plan: a list of planned part changes that can be previewed, applied and
	reverted. Nothing touches the world until `Plan.apply`.

	Item: { part, reason, check, fromCFrame, toCFrame, fromSize, toSize, path? }
	(`path` is the part's path from the scan root, set by BuildGuard.planFixes.)

	Plan.changes turns applied plans into a fix report: each part's net
	move and resize, in world axes and in the part's own axes, so a builder
	script that makes the part can be corrected and a rebuild keeps the fix.
]]

local Plan = {}

function Plan.new()
	return { items = {}, byPart = {}, deferred = 0 }
end

function Plan.item(part, check, reason, toCFrame, toSize)
	return {
		part = part,
		check = check,
		reason = reason,
		fromCFrame = part.CFrame,
		toCFrame = toCFrame or part.CFrame,
		fromSize = part.Size,
		toSize = toSize or part.Size,
	}
end

-- Adds an item. A part only gets one change per plan; a second one is
-- deferred (it shows up again on the next scan, against the moved part).
function Plan.add(plan, item)
	if plan.byPart[item.part] then
		plan.deferred += 1
		return false
	end
	plan.byPart[item.part] = item
	table.insert(plan.items, item)
	return true
end

local function differs(a, b)
	if typeof(a) == "Vector3" then
		return (a - b).Magnitude > 1e-4
	end
	local ac, bc = { a:GetComponents() }, { b:GetComponents() }
	for i = 1, 12 do
		if math.abs(ac[i] - bc[i]) > 1e-4 then
			return true
		end
	end
	return false
end

-- Parts that moved, resized or were deleted since the plan was made. Applying
-- a stale plan would undo those edits, so callers should re-plan instead.
function Plan.staleParts(plan)
	local stale = {}
	for _, item in plan.items do
		local part = item.part
		if part.Parent == nil or differs(part.CFrame, item.fromCFrame) or differs(part.Size, item.fromSize) then
			table.insert(stale, part)
		end
	end
	return stale
end

-- Welds and Motor6Ds (JointInstance) and WeldConstraints holding `part`.
-- Attachment-based constraints (springs, hinges) move with their part and
-- need nothing.
function Plan.jointsOf(part)
	local out = {}
	local function consider(j)
		if j:IsA("JointInstance") or j:IsA("WeldConstraint") then
			if j.Part0 == part or j.Part1 == part then
				table.insert(out, j)
			end
		end
	end
	local ok, joints = pcall(function()
		return part:GetJoints()
	end)
	if ok and joints then
		for _, j in joints do
			consider(j)
		end
		return out
	end
	-- Outside Studio: joints live in the part's model (or next to it).
	local scope = part.Parent
	local node = part.Parent
	while node do
		if node:IsA("Model") then
			scope = node
			break
		end
		node = node.Parent
	end
	if scope then
		for _, d in scope:GetDescendants() do
			consider(d)
		end
	end
	return out
end

-- Applies the plan. Joints on moved parts are updated so they hold the parts
-- where the plan put them (otherwise a Weld or Motor6D pulls a nudged strut
-- back when the game runs).
function Plan.apply(plan)
	for _, item in plan.items do
		item.part.Size = item.toSize
		item.part.CFrame = item.toCFrame
	end
	plan.joints = {}
	local seen = {}
	for _, item in plan.items do
		for _, joint in Plan.jointsOf(item.part) do
			if not seen[joint] then
				seen[joint] = true
				if joint:IsA("JointInstance") then
					if joint.Part0 and joint.Part1 then
						table.insert(plan.joints, { joint = joint, c0 = joint.C0, c1 = joint.C1 })
						-- A joint holds Part0.CFrame * C0 == Part1.CFrame * C1.
						joint.C1 = joint.Part1.CFrame:Inverse() * joint.Part0.CFrame * joint.C0
					end
				elseif joint.Enabled then
					-- A WeldConstraint records the offset when it's enabled.
					table.insert(plan.joints, { joint = joint })
					joint.Enabled = false
					joint.Enabled = true
				end
			end
		end
	end
end

function Plan.revert(plan)
	for _, item in plan.items do
		item.part.Size = item.fromSize
		item.part.CFrame = item.fromCFrame
	end
	for _, saved in plan.joints or {} do
		if saved.c1 then
			saved.joint.C0 = saved.c0
			saved.joint.C1 = saved.c1
		else
			saved.joint.Enabled = false
			saved.joint.Enabled = true
		end
	end
end

local function fmtVector(v)
	return ("(%.3f, %.3f, %.3f)"):format(v.X, v.Y, v.Z)
end

function Plan.describeItem(item)
	local parts = {}
	local move = item.toCFrame.Position - item.fromCFrame.Position
	if move.Magnitude > 1e-5 then
		table.insert(parts, "move " .. fmtVector(move))
	end
	local grow = item.toSize - item.fromSize
	if grow.Magnitude > 1e-5 then
		table.insert(parts, "resize " .. fmtVector(grow))
	end
	if #parts == 0 then
		table.insert(parts, "no change")
	end
	local joints = #Plan.jointsOf(item.part)
	if joints > 0 then
		table.insert(parts, ("keeps %d joint(s) in step"):format(joints))
	end
	return ("%s: %s — %s"):format(item.path or item.part:GetFullName(), table.concat(parts, ", "), item.reason)
end

function Plan.describe(plan)
	local lines = { ("%d planned change(s)"):format(#plan.items) }
	for _, item in plan.items do
		table.insert(lines, "  " .. Plan.describeItem(item))
	end
	if plan.deferred > 0 then
		table.insert(lines, ("  (%d more change(s) wait for the next scan)"):format(plan.deferred))
	end
	return table.concat(lines, "\n")
end

--------------------------------------------------------------------------------
-- Fix report
--------------------------------------------------------------------------------

-- Net change per part across `plans` (a plan or a list of plans, in the
-- order they were applied). Returns a list of {
--   part, path, checks, reasons, fromCFrame, toCFrame, fromSize, toSize,
--   move      = world-space offset of the part's centre,
--   moveLocal = the same offset in the part's own axes (before the change),
--   resize    = change in Size,
--   rotated   = true if its orientation changed,
-- }, in the order parts were first changed.
function Plan.changes(plans)
	if plans.items then
		plans = { plans }
	end
	local byPart, order = {}, {}
	for _, plan in plans do
		for _, item in plan.items do
			local entry = byPart[item.part]
			if not entry then
				entry = {
					part = item.part,
					path = item.path or item.part:GetFullName(),
					checks = {},
					reasons = {},
					fromCFrame = item.fromCFrame,
					fromSize = item.fromSize,
				}
				byPart[item.part] = entry
				table.insert(order, entry)
			end
			entry.toCFrame = item.toCFrame
			entry.toSize = item.toSize
			if not table.find(entry.checks, item.check) then
				table.insert(entry.checks, item.check)
			end
			table.insert(entry.reasons, item.reason)
		end
	end
	local out = {}
	for _, e in order do
		e.move = e.toCFrame.Position - e.fromCFrame.Position
		e.moveLocal = e.fromCFrame:VectorToObjectSpace(e.move)
		e.resize = e.toSize - e.fromSize
		e.rotated = differs(e.fromCFrame - e.fromCFrame.Position, e.toCFrame - e.toCFrame.Position)
		if e.move.Magnitude > 1e-6 or e.resize.Magnitude > 1e-6 or e.rotated then
			table.insert(out, e)
		end
	end
	return out
end

-- Rounded to 4 decimals, without "-0.0000".
local function n4(x)
	local r = math.floor(x * 1e4 + 0.5) / 1e4
	return if r == 0 then 0 else r
end

local function fmt4(v)
	return ("(%.4f, %.4f, %.4f)"):format(n4(v.X), n4(v.Y), n4(v.Z))
end

-- The fix report as text: every changed part with its exact change and the
-- line to put in the script that builds it.
function Plan.formatChanges(changes)
	local lines = {
		("Fix report: %d part(s) changed. Put these changes in the script that builds them, or a rebuild brings the problems back."):format(
			#changes
		),
	}
	for _, e in changes do
		table.insert(lines, ("  %s  [%s] %s"):format(e.path, table.concat(e.checks, ", "), table.concat(e.reasons, "; ")))
		if e.move.Magnitude > 1e-6 then
			table.insert(
				lines,
				("      Position %s -> %s: moved %s, which is %s in its own axes"):format(
					fmt4(e.fromCFrame.Position),
					fmt4(e.toCFrame.Position),
					fmt4(e.move),
					fmt4(e.moveLocal)
				)
			)
			local l = e.moveLocal
			table.insert(lines, ("      builder: part.CFrame *= CFrame.new(%.4f, %.4f, %.4f)"):format(n4(l.X), n4(l.Y), n4(l.Z)))
		end
		if e.resize.Magnitude > 1e-6 then
			local r = e.resize
			table.insert(lines, ("      Size %s -> %s: grew %s"):format(fmt4(e.fromSize), fmt4(e.toSize), fmt4(r)))
			table.insert(lines, ("      builder: part.Size += Vector3.new(%.4f, %.4f, %.4f)"):format(n4(r.X), n4(r.Y), n4(r.Z)))
		end
		if e.rotated then
			table.insert(lines, "      orientation changed too: copy its new CFrame")
		end
	end
	return table.concat(lines, "\n")
end

return Plan
