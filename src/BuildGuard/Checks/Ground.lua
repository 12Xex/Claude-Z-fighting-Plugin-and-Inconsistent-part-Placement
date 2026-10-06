--[[
	Snap to ground, and the "off the ground" check built on it.

	Snapping a road/rail/track raycasts straight down from a grid of points across
	its bottom, starting above the part (so a sunk part still finds the surface over
	it), and moves the part vertically so its lowest point sits its kind's
	lift (roadLift / railLift / trackLift, else groundLift) above the highest
	ground hit. "Ground" is terrain, or a part that starts
	below the snapped part's bottom (see `ignoreFor`).

	Layered items (markings, signs) on the part's top move with it.

	Tilted parts (ramps, slopes) are skipped: a ramp is meant to leave the ground.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local Classify = require(script.Parent.Parent.Classify)
local Plan = require(script.Parent.Parent.Plan)

local Ground = {}

local function isDescendantOf(instance, ancestor)
	return instance:IsDescendantOf(ancestor)
end

-- Raycast filter for snapping solid `s`. Ground under a part has to start
-- below the part's bottom; anything starting at or above it (markings, crates,
-- rails on a track bed) is resting on the part, not holding it up. Layered
-- items and parts of the same kind (overlapping junctions) never count.
function Ground.ignoreFor(s, ctx)
	local part = s.part
	local kind = ctx.kindOf(part)
	return function(instance)
		if instance == part or isDescendantOf(instance, part) then
			return true
		end
		if not instance:IsA("BasePart") or ctx.world.isTerrain(instance) then
			return false
		end
		if Classify.isLayered(instance) then
			return true
		end
		if kind ~= nil and ctx.kindOf(instance) == kind then
			return true
		end
		return Geometry.solid(instance).min.Y >= s.min.Y - 1e-3
	end
end

-- Layered items and child parts riding on top of the part.
local function riders(s, ctx)
	local out = {}
	local seen = {}
	for _, d in s.part:GetDescendants() do
		if d:IsA("BasePart") then
			seen[d] = true
			table.insert(out, d)
		end
	end
	local box = s.cf * CFrame.new(0, s.half.Y + 1, 0)
	for _, other in ctx.world.partsInBox(box, Vector3.new(s.size.X, 2, s.size.Z)) do
		if not seen[other] and other ~= s.part and Classify.isLayered(other) then
			local lp = s.cf:PointToObjectSpace(other.CFrame.Position)
			if math.abs(lp.X) <= s.half.X and math.abs(lp.Z) <= s.half.Z and lp.Y >= s.half.Y and lp.Y <= s.half.Y + 2 then
				seen[other] = true
				table.insert(out, other)
			end
		end
	end
	return out
end

local LIFT_KEY = { Road = "roadLift", Rail = "railLift", Track = "trackLift" }

-- Works out how far `s` must move vertically to sit on the ground.
-- Returns { delta = number } or { skip = reason }.
function Ground.measure(s, ctx)
	local config = ctx.configFor(s.part)
	local tilt = Geometry.tiltDegrees(s)
	if tilt > config.flatTiltDegrees then
		return { skip = ("tilted %.1f°, treated as a ramp"):format(tilt) }
	end
	local ignore = Ground.ignoreFor(s, ctx)
	local lift = config[LIFT_KEY[ctx.kindOf(s.part)] or "groundLift"]
	local startY = s.max.Y + config.snapSearchUp
	local best, hits = -math.huge, 0
	for _, p in Geometry.faceSamples(s, "Bottom", 0.05, 0.25, config.sampleSpacing) do
		local length = startY - p.Y + config.snapSearchDown
		local hit = ctx.world.raycast(Vector3.new(p.X, startY, p.Z), Vector3.new(0, -length, 0), ignore)
		if hit then
			hits += 1
			best = math.max(best, hit.position.Y + lift - p.Y)
		end
	end
	if hits == 0 then
		return { skip = "no ground below" }
	end
	return { delta = best }
end

-- Plan items that move `s` (and its riders) by `delta` studs vertically.
function Ground.items(s, ctx, delta, check, reason)
	local offset = Vector3.new(0, delta, 0)
	local items = { Plan.item(s.part, check, reason, s.cf + offset) }
	for _, rider in riders(s, ctx) do
		table.insert(items, Plan.item(rider, check, "rides on " .. s.part.Name, rider.CFrame + offset))
	end
	return items
end

-- Snap plan for arbitrary parts (the "Snap to ground" tool).
function Ground.planSnap(solids, ctx, plan)
	local skipped = {}
	for _, s in solids do
		local m = Ground.measure(s, ctx)
		if m.delta then
			if math.abs(m.delta) > 1e-4 then
				local reason = ("snap to ground (%+.3f)"):format(m.delta)
				for _, item in Ground.items(s, ctx, m.delta, "snap", reason) do
					Plan.add(plan, item)
				end
			end
		else
			table.insert(skipped, { part = s.part, reason = m.skip })
		end
	end
	return skipped
end

-- Roads/rails/tracks that are hovering above or sunk below the ground.
function Ground.scan(ctx, alreadyFlagged)
	local issues = {}
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind and not alreadyFlagged[s.part] then
			local m = Ground.measure(s, ctx)
			if m.delta and math.abs(m.delta) > ctx.configFor(s.part).groundTolerance then
				local what = if m.delta < 0
					then ("hovers %.2f studs above the ground"):format(-m.delta)
					else ("is sunk %.2f studs into the ground"):format(m.delta)
				table.insert(issues, {
					check = "offground",
					severity = "warning",
					parts = { s.part },
					message = ("%s %s %s"):format(kind, s.part.Name, what),
					fixItems = Ground.items(s, ctx, m.delta, "offground", ("snap to ground (%+.3f)"):format(m.delta)),
				})
			elseif m.skip == "no ground below" then
				table.insert(issues, {
					check = "offground",
					severity = "warning",
					parts = { s.part },
					message = ("%s %s has no ground below it"):format(kind, s.part.Name),
				})
			end
		end
	end
	return issues
end

return Ground
