--[[
	Snap to ground, and the "off the ground" check built on it.

	Snapping a road/rail/track raycasts straight down along a grid of columns
	across its bottom. Each column starts just above the part's own top. If
	that point is open air (the surface, or inside a tunnel or cave), the ray
	starts there, so a tunnel road finds the tunnel floor and never the
	mountain above it. If the point is inside ground (the part is sunk or
	buried), it steps up a stud at a time, up to `snapSearchUp`, to the first
	open air and casts down from there. It then moves the part vertically so its lowest point sits its kind's
	lift (roadLift / railLift / trackLift, else groundLift) above the highest
	ground hit. "Ground" is terrain, or a part that starts
	below the snapped part's bottom (see `ignoreFor`). Ignored things
	(BuildGuardIgnore) and vehicles are never ground.

	Layered items (markings, signs) on the part's top move with it, unless
	they're ignored.

	Off-ground messages name the part by its path from the scan root; the
	issue's position is the part's bottom centre.

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
-- items, parts of the same kind (overlapping junctions), ignored things and
-- vehicles never count.
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
		if Classify.isLayered(instance) or ctx.isIgnored(instance) or ctx.vehicleOf(instance) ~= nil then
			return true
		end
		if kind ~= nil and ctx.kindOf(instance) == kind then
			return true
		end
		return Geometry.solid(instance).min.Y >= s.min.Y - 1e-3
	end
end

-- Layered items and child parts riding on top of the part (ignored ones
-- stay where they are).
local function riders(s, ctx)
	local out = {}
	local seen = {}
	for _, d in s.part:GetDescendants() do
		if d:IsA("BasePart") and not ctx.isIgnored(d) then
			seen[d] = true
			table.insert(out, d)
		end
	end
	local box = s.cf * CFrame.new(0, s.half.Y + 1, 0)
	for _, other in ctx.world.partsInBox(box, Vector3.new(s.size.X, 2, s.size.Z)) do
		if not seen[other] and other ~= s.part and Classify.isLayered(other) and not ctx.isIgnored(other) then
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

local function insideGround(point, ctx, ignore)
	return ctx.world.isSolidTerrain(point) or ctx.world.partAt(point, ignore) ~= nil
end

-- Open air at or above `start`, searching up to `maxUp` studs; nil if none.
local function openAirAbove(start, ctx, ignore, maxUp)
	if not insideGround(start, ctx, ignore) then
		return start
	end
	for h = 1, math.floor(maxUp) do
		local q = start + Vector3.new(0, h, 0)
		if not insideGround(q, ctx, ignore) then
			-- One more stud of margin: terrain is only known per 4-stud voxel.
			return q + Vector3.new(0, 1, 0)
		end
	end
	return nil
end

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
	local topY = s.max.Y + 0.05
	local best, hits, buried = -math.huge, 0, 0
	for _, p in Geometry.faceSamples(s, "Bottom", 0.05, 0.25, config.sampleSpacing) do
		local start = openAirAbove(Vector3.new(p.X, topY, p.Z), ctx, ignore, config.snapSearchUp)
		local hit
		if start then
			hit = ctx.world.raycast(start, Vector3.new(0, -(start.Y - p.Y + config.snapSearchDown), 0), ignore)
		else
			buried += 1
		end
		if hit then
			hits += 1
			best = math.max(best, hit.position.Y + lift - p.Y)
		end
	end
	if hits == 0 then
		if buried > 0 then
			return { skip = ("buried deeper than %d studs; carve it out or move it"):format(config.snapSearchUp) }
		end
		return { skip = "no ground below" }
	end
	return { delta = best }
end

-- Plan items that move `s` (and its riders) by `delta` studs vertically.
function Ground.items(s, ctx, delta, check, reason)
	local offset = Vector3.new(0, delta, 0)
	local items = { Plan.item(s.part, check, reason, s.cf + offset) }
	for _, rider in riders(s, ctx) do
		table.insert(items, Plan.item(rider, check, "rides on " .. ctx.path(s.part), rider.CFrame + offset))
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

-- Off-ground issue for one road/rail/track, or nil.
local function offGroundIssue(s, kind, ctx)
	local m = Ground.measure(s, ctx)
	local bottom = s.cf:PointToWorldSpace(Vector3.new(0, -s.half.Y, 0))
	if m.delta and math.abs(m.delta) > ctx.configFor(s.part).groundTolerance then
		local what = if m.delta < 0
			then ("hovers %.2f studs above the ground"):format(-m.delta)
			else ("is sunk %.2f studs into the ground"):format(m.delta)
		return {
			check = "offground",
			severity = "warning",
			parts = { s.part },
			position = bottom,
			value = m.delta,
			message = ("%s %s %s"):format(kind, ctx.path(s.part), what),
			fixItems = Ground.items(s, ctx, m.delta, "offground", ("snap to ground (%+.3f)"):format(m.delta)),
		}
	elseif m.skip == "no ground below" then
		return {
			check = "offground",
			severity = "warning",
			parts = { s.part },
			position = bottom,
			message = ("%s %s has no ground below it — put ground under it or move it"):format(kind, ctx.path(s.part)),
		}
	end
	return nil
end

-- Roads/rails/tracks that are hovering above or sunk below the ground.
function Ground.scan(ctx, alreadyFlagged)
	local issues = {}
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind and not alreadyFlagged[s.part] then
			local issue = offGroundIssue(s, kind, ctx)
			if issue then
				table.insert(issues, issue)
			end
			ctx.yield()
		end
	end
	return issues
end

return Ground
