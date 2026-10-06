--[[
	A fix plan: a list of planned part changes that can be previewed, applied and
	reverted. Nothing touches the world until `Plan.apply`.

	Item: { part, reason, check, fromCFrame, toCFrame, fromSize, toSize }
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

function Plan.apply(plan)
	for _, item in plan.items do
		item.part.Size = item.toSize
		item.part.CFrame = item.toCFrame
	end
end

function Plan.revert(plan)
	for _, item in plan.items do
		item.part.Size = item.fromSize
		item.part.CFrame = item.fromCFrame
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
	return ("%s: %s — %s"):format(item.part:GetFullName(), table.concat(parts, ", "), item.reason)
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

return Plan
