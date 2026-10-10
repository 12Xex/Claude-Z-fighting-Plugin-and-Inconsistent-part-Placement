--[[
	Buried-part check for roads, rails and tracks.

	Samples a grid of points (every `sampleSpacing` studs) across each part's
	top surface and probes
	`buriedProbeHeight` above each one. A point is buried when the probe is
	inside terrain or another part, or a ray cast down from `buriedClearance`
	above it hits something before reaching it.

	Never cover: other roads/rails/tracks and layered items (rails sit on
	track beds, and markings lie on roads), ignored things (BuildGuardIgnore)
	and vehicles parked on the road.

	Headroom (separate, warning): when the part isn't buried and its kind's
	headroom setting is above 0, rays go straight up from the same points and
	anything closer than that (a tunnel roof, a bridge) is reported. What
	can't be cover can't be a ceiling either.

	Fix: when everything covering the part is ground (terrain, baseplate...),
	the fix is a snap onto that ground's surface. When it's an ordinary part
	(a crate, a building, a floor slab) there's no safe automatic answer, so
	it's only flagged.

	Messages name parts by their path from the scan root and say where to
	look: the middle of the covered points, or the lowest ceiling point.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local Classify = require(script.Parent.Parent.Classify)
local Util = require(script.Parent.Parent.Util)
local Ground = require(script.Parent.Ground)

local Buried = {}

local function coverIgnore(part, ctx)
	return function(instance)
		if instance == part or instance:IsDescendantOf(part) then
			return true
		end
		if not instance:IsA("BasePart") or ctx.world.isTerrain(instance) then
			return false
		end
		return Classify.isLayered(instance)
			or ctx.kindOf(instance) ~= nil
			or ctx.isIgnored(instance)
			or ctx.vehicleOf(instance) ~= nil
	end
end

local function nameOf(ctx, instance)
	return if ctx.world.isTerrain(instance) then "Terrain" else ctx.path(instance)
end

-- What covers each sample point: covered count, covers in the order found,
-- and the middle of the covered points.
local function findCovers(s, samples, config, ignore, ctx)
	local world = ctx.world
	local up = s.axes[2]
	local covered, seen, covers, sum = 0, {}, {}, Vector3.zero
	for _, point in samples do
		local probe = point + up * config.buriedProbeHeight
		local cover
		if world.isInsideTerrain(probe) then
			cover = world.terrain
		else
			cover = world.partAt(probe, ignore)
			if not cover then
				local hit = world.raycast(probe + up * config.buriedClearance, -up * config.buriedClearance, ignore)
				cover = hit and hit.instance
			end
		end
		if cover then
			covered += 1
			sum += point
			if not seen[cover] then
				seen[cover] = true
				table.insert(covers, cover)
			end
		end
	end
	return covered, covers, if covered > 0 then sum / covered else nil
end

local function buriedIssue(s, kind, samples, covered, covers, position, ctx)
	local names, allGround = {}, true
	for _, cover in covers do
		table.insert(names, nameOf(ctx, cover))
		if not Classify.isGroundLike(cover, ctx.config) and not ctx.world.isTerrain(cover) then
			allGround = false
		end
	end
	local issue = {
		check = "buried",
		severity = "error",
		parts = { s.part },
		covers = covers,
		position = position,
		message = ("%s %s is buried under %s at %s (%d/%d sample points)"):format(
			kind,
			ctx.path(s.part),
			table.concat(names, ", "),
			Util.vector(position),
			covered,
			#samples
		),
	}
	if allGround then
		local m = Ground.measure(s, ctx)
		if m.delta and m.delta > 0 then
			issue.fixItems = Ground.items(s, ctx, m.delta, "buried", ("lift onto ground (%+.3f)"):format(m.delta))
		end
	end
	if not issue.fixItems then
		issue.message ..= " — move the cover or the " .. string.lower(kind) .. " by hand"
	end
	return issue
end

function Buried.scan(ctx)
	local issues = {}
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind then
			local config = ctx.configFor(s.part)
			local ignore = coverIgnore(s.part, ctx)
			local samples = Geometry.faceSamples(s, "Top", 0.05, 0.25, config.sampleSpacing)
			local covered, covers, position = findCovers(s, samples, config, ignore, ctx)
			local issue
			if covered > 0 then
				issue = buriedIssue(s, kind, samples, covered, covers, position, ctx)
			else
				issue = Buried.headroom(s, kind, samples, config, ignore, ctx)
			end
			if issue then
				table.insert(issues, issue)
			end
			ctx.yield()
		end
	end
	return issues
end

local HEADROOM_KEY = { Road = "roadHeadroom", Rail = "railHeadroom", Track = "trackHeadroom" }

-- Headroom: the clear height above a road/rail/track (tunnel roofs, bridges,
-- overhangs) must be at least its kind's headroom setting (0 = off).
function Buried.headroom(s, kind, samples, config, ignore, ctx)
	local key = HEADROOM_KEY[kind]
	local need = config[key]
	if not need or need <= 0 then
		return nil
	end
	local up = s.axes[2]
	local lowest, ceiling, at = math.huge, nil, nil
	for _, point in samples do
		local probe = point + up * config.buriedProbeHeight
		local hit = ctx.world.raycast(probe, up * (need - config.buriedProbeHeight), ignore)
		if hit then
			local clear = (hit.position - point):Dot(up)
			if clear < lowest then
				lowest, ceiling, at = clear, hit.instance, hit.position
			end
		end
	end
	if not ceiling then
		return nil
	end
	local _, sources = ctx.configFor(s.part)
	return {
		check = "headroom",
		severity = "warning",
		parts = { s.part },
		position = at,
		value = lowest,
		message = ("%s %s has %.1f studs of headroom under %s at %s (needs %.1f%s)"):format(
			kind,
			ctx.path(s.part),
			lowest,
			nameOf(ctx, ceiling),
			Util.vector(at),
			need,
			if sources[key] then ", set on " .. ctx.path(sources[key]) else ""
		),
	}
end

return Buried
