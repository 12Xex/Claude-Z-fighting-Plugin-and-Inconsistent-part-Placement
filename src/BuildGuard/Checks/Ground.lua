--[[
	Snap to ground, and the "off the ground" check built on it.

	Snapping a road/rail/track raycasts straight down along a grid of columns
	across its bottom. Each column starts just above the part's own top. If
	that point is open air (the surface, or inside a tunnel or cave), the ray
	starts there, so a tunnel road finds the tunnel floor and never the
	mountain above it. If the point is inside ground (the part is sunk or
	buried), it steps up a stud at a time, up to `snapSearchUp`, to the first
	open air and casts down from there. It then moves the part vertically so
	its lowest point sits its kind's lift (roadLift / railLift / trackLift,
	else groundLift) above the highest ground hit: 0 rests it on the ground,
	a negative lift sinks it in, never so far that its top drops below
	MIN_TOP above that ground. "Ground" is terrain, or a part that starts
	below the snapped part's bottom (see `ignoreFor`). Ignored things
	(BuildGuardIgnore) and vehicles are never ground.

	Layered items (markings, signs) on the part's top move with it, unless
	they're ignored.

	Off-ground messages name the part by its path from the scan root; the
	issue's position is the part's bottom centre.

	Gaps (warning, no fix): a straight part can rest on the highest ground
	under it and still hang over dips. For a part that's on the ground (not
	off it, not buried), the same columns measure the gap between its
	resting face and what shows below it at the samples within max(2,
	sampleSpacing) studs of that face's edges, where a gap shows. The
	biggest one is reported when it's over maxHover plus its kind's lift
	(if positive: a rail's room for sleepers isn't a gap). What shows is
	the snap's ground, except that light passes through invisible parts
	(Transparency at or above zFightIgnoreTransparency, as for the z-fight
	scan) and stops at a water surface above the ground. A footing under
	the part is ground like anything else starting below it, so it closes
	the gap if it's visible. Where an edge passes over a drop deeper than
	connectMaxStep (or no ground at all), that stretch is a span (a bridge,
	an overpass, an end out over a cliff) and doesn't count, nor do the
	banks sloping down into it: the samples either side whose gaps keep
	falling as the edge runs away from the drop, out to where it's back on
	the ground (its gap within the limit). A level dip that runs up to the
	drop isn't a bank, and the rest of the edge still counts.

	Tilted parts (ramps, slopes) are skipped: a ramp is meant to leave the
	ground. A block lying upside down rests on its Top face (a box looks the
	same either way up), and a wedge on its flat bottom.

	The driving surface (used by the buried and drivability checks too) is
	the face that's up: Top, Bottom on a block upside down, or a wedge's
	slope.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local Classify = require(script.Parent.Parent.Classify)
local Config = require(script.Parent.Parent.Config)
local Plan = require(script.Parent.Parent.Plan)
local Util = require(script.Parent.Parent.Util)

local Ground = {}

local function isDescendantOf(instance, ancestor)
	return instance:IsDescendantOf(ancestor)
end

--------------------------------------------------------------------------------
-- The driving surface
--------------------------------------------------------------------------------

-- A block (or a mesh's box) whose up axis points down.
local function upsideDown(s)
	return (s.shape == "Block" or s.shape == "Other") and s.axes[2].Y < 0
end

-- 1, or -1 when the face that's up is the part's Bottom.
local function upSign(s)
	return if upsideDown(s) then -1 else 1
end

-- World point on the driving surface above the part's local (x, z).
function Ground.surfacePoint(s, x, z)
	local h = s.half
	local y = if s.shape == "Wedge" then h.Y * z / h.Z else upSign(s) * h.Y
	return s.cf:PointToWorldSpace(Vector3.new(x, y, z))
end

-- World normal of the driving surface.
function Ground.surfaceNormal(s)
	if s.shape == "Wedge" then
		return s.cf:VectorToWorldSpace(Vector3.new(0, s.half.Z, -s.half.Y).Unit)
	end
	return s.axes[2] * upSign(s)
end

-- Degrees between the driving surface and level.
function Ground.surfaceTilt(s)
	return math.deg(math.acos(math.clamp(Ground.surfaceNormal(s).Y, -1, 1)))
end

-- A grid of points across the driving surface (see Geometry.faceSamples).
function Ground.surfaceSamples(s, spacing)
	if s.shape ~= "Wedge" then
		return Geometry.faceSamples(s, if upsideDown(s) then "Bottom" else "Top", 0.05, 0.25, spacing)
	end
	-- The slope lies right over the bottom face: lift its grid onto it.
	local out = {}
	for i, p in Geometry.faceSamples(s, "Bottom", 0.05, 0.25, spacing) do
		local lp = s.cf:PointToObjectSpace(p)
		out[i] = Ground.surfacePoint(s, lp.X, lp.Z)
	end
	return out
end

--------------------------------------------------------------------------------
-- Snapping
--------------------------------------------------------------------------------

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
	local up = upSign(s)
	local box = s.cf * CFrame.new(0, up * (s.half.Y + 1), 0)
	for _, other in ctx.world.partsInBox(box, Vector3.new(s.size.X, 2, s.size.Z)) do
		if not seen[other] and other ~= s.part and Classify.isLayered(other) and not ctx.isIgnored(other) then
			local lp = s.cf:PointToObjectSpace(other.CFrame.Position)
			local above = up * lp.Y
			if math.abs(lp.X) <= s.half.X and math.abs(lp.Z) <= s.half.Z and above >= s.half.Y and above <= s.half.Y + 2 then
				seen[other] = true
				table.insert(out, other)
			end
		end
	end
	return out
end

local LIFT_KEY = Classify.LIFT_KEY
Ground.LIFT_KEY = LIFT_KEY

-- A sunk part's top stays at least this far above the highest ground
-- under it, so sinking never buries it.
Ground.MIN_TOP = 0.05

-- The lift actually used for a part `thickness` studs thick: a negative
-- lift (sinking it in) is limited so its top stays MIN_TOP above the ground.
-- Parts only sink into real ground (terrain, or ground parts), never into
-- a support such as a plinth or an abutment (`onGround` false), and a
-- wedge never sinks (its slope runs down to its bottom edge).
function Ground.effectiveLift(lift, thickness, onGround, shape)
	if onGround == false or shape == "Wedge" or shape == "CornerWedge" then
		return math.max(lift, 0)
	end
	return math.max(lift, Ground.MIN_TOP - thickness)
end

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
-- Returns { delta = number, samples, groundY, starts, hits, waterY } or
-- { skip = reason }: `samples` are the points on the face it rests on, and
-- groundY[i] the height of the ground found under samples[i] (nil where
-- none was found). starts[i] is where its ray started (nil where buried),
-- hits[i] the ground it hit, and waterY[i] the height of a water surface
-- above that ground (water never holds a part up; the gap check sees it).
function Ground.measure(s, ctx)
	local config = ctx.configFor(s.part)
	local tilt = Geometry.tiltDegrees(s)
	local restsOn = "Bottom"
	if upsideDown(s) then
		tilt, restsOn = 180 - tilt, "Top"
	end
	if tilt > config.flatTiltDegrees then
		return { skip = ("tilted %.1f°, treated as a ramp"):format(tilt) }
	end
	local ignore = Ground.ignoreFor(s, ctx)
	local lift = config[LIFT_KEY[ctx.kindOf(s.part)] or "groundLift"]
	local thickness = s.max.Y - s.min.Y
	local groundCache = {}
	local function liftOver(instance)
		local onGround = ctx.world.isTerrain(instance) or Classify.isGroundLike(instance, ctx.configFor(instance), groundCache)
		return Ground.effectiveLift(lift, thickness, onGround, s.shape)
	end
	local topY = s.max.Y + 0.05
	local best, hits, buried = -math.huge, 0, 0
	local samples = Geometry.faceSamples(s, restsOn, 0.05, 0.25, config.sampleSpacing)
	local groundY, starts, found, waterY = {}, {}, {}, {}
	for i, p in samples do
		local start = openAirAbove(Vector3.new(p.X, topY, p.Z), ctx, ignore, config.snapSearchUp)
		local hit
		if start then
			starts[i] = start
			local down = Vector3.new(0, -(start.Y - p.Y + config.snapSearchDown), 0)
			hit = ctx.world.raycast(start, down, ignore, true)
			if hit and hit.water then
				waterY[i] = hit.position.Y
				hit = ctx.world.raycast(start, down, ignore)
			end
		else
			buried += 1
		end
		if hit then
			hits += 1
			found[i] = hit
			groundY[i] = hit.position.Y
			best = math.max(best, hit.position.Y + liftOver(hit.instance) - p.Y)
		end
	end
	if hits == 0 then
		if buried > 0 then
			return { skip = ("buried deeper than %d studs; carve it out or move it"):format(config.snapSearchUp) }
		end
		return { skip = "no ground below" }
	end
	return { delta = best, samples = samples, groundY = groundY, starts = starts, hits = found, waterY = waterY }
end

-- The edge of `s`'s resting face that the face point `p` lies within
-- `band` studs of, named by the part's own axes, then where `p` lies along
-- that edge and across it (local coordinates); or nil.
local function edgeOf(s, p, band)
	local lp = s.cf:PointToObjectSpace(p)
	local h = s.half
	local dx, dz = h.X - math.abs(lp.X), h.Z - math.abs(lp.Z)
	if math.min(dx, dz) > band then
		return nil
	end
	if dx <= dz then
		return (if lp.X > 0 then "+X" else "-X"), lp.Z, lp.X
	end
	return (if lp.Z > 0 then "+Z" else "-Z"), lp.X, lp.Z
end

-- The biggest gap allowed under a part of `kind` (nil for none): maxHover,
-- plus its kind's lift if positive (a rail's room for sleepers isn't a gap).
local function gapLimit(config, kind)
	local key = LIFT_KEY[kind]
	return config.maxHover + (if key then math.max(config[key], 0) else 0)
end

-- A part light passes through: at or above zFightIgnoreTransparency, the
-- transparency the z-fight scan treats as invisible.
local function isSeeThrough(instance, ctx)
	return instance:IsA("BasePart")
		and not ctx.world.isTerrain(instance)
		and instance.Transparency >= ctx.config.zFightIgnoreTransparency
end

-- What shows under sample `i` of measure `m`: the snap's ground, seen
-- through invisible parts, or a water surface above it. { y, water,
-- through } (`through` the invisible part the snap's ray hit first), or
-- nil for a buried sample. y is nil when nothing was found below.
local function shownUnder(m, i, ctx, ignore, config)
	local start, hit = m.starts[i], m.hits[i]
	if not start then
		return nil
	end
	if hit and isSeeThrough(hit.instance, ctx) then
		local down = Vector3.new(0, -(start.Y - m.samples[i].Y + config.snapSearchDown), 0)
		local seen = ctx.world.raycast(start, down, function(instance)
			return ignore(instance) or isSeeThrough(instance, ctx)
		end, true)
		return { y = seen and seen.position.Y, water = seen ~= nil and seen.water == true, through = hit.instance }
	end
	local water = m.waterY[i]
	if water then
		return { y = water, water = true }
	end
	return { y = hit and hit.position.Y, water = false }
end

-- Samples this close (studs) across an edge lie in the same row along it.
local SAME_ROW = 0.05
-- A bank's gap falls by more than this from one sample to the next.
local BANK_FALL = 1e-3

-- Marks in `dropped` the spans in `row` (sample indexes in order along an
-- edge, their gaps in `found`): each sample deeper than `step` (or with
-- nothing below it), and the bank either side of it: its neighbours out to
-- the first one back on the ground (its gap within `limit`) or the first
-- whose gap doesn't fall (a level dip running up to the drop still counts).
local function dropSpans(row, found, limit, step, dropped)
	for k, i in row do
		if found[i].gap > step then
			dropped[i] = true
			for _, dir in { -1, 1 } do
				local n, last = k + dir, found[i].gap
				while row[n] and found[row[n]].gap > limit and found[row[n]].gap < last - BANK_FALL do
					dropped[row[n]] = true
					last = found[row[n]].gap
					n += dir
				end
			end
		end
	end
end

-- The biggest gap between `s`'s resting face and the ground under it where
-- it shows: at the samples within max(2, sampleSpacing) studs of the face's
-- edges, from a measure `m`. Returns { gap, position, edge, water, through }
-- (edges named by the part's own axes), or nil when no such sample found
-- ground. A sunk part's gaps are negative. Where an edge passes over a drop
-- deeper than connectMaxStep it's a span (a bridge, an overpass, an end
-- out over a cliff): those samples don't count, nor do the banks either
-- side (see dropSpans), out to the first sample whose gap is within the
-- part's limit (maxHover plus its kind's lift) or doesn't fall.
-- Given `ctx` (as the gap check does), it measures to what shows (see
-- shownUnder): `water` is set when that's a water surface, `through` to an
-- invisible part looked through, and a sample with nothing below it is a
-- span. Without, it measures to the snap's ground.
function Ground.edgeGap(s, m, config, ctx)
	local band = math.max(2, config.sampleSpacing) + 1e-3
	local ignore = ctx and Ground.ignoreFor(s, ctx)
	local limit = gapLimit(config, ctx and ctx.kindOf(s.part)) + 1e-3
	local samples = m.samples or {}
	local found, edges = {}, {}
	for i, p in samples do
		local edge, along, across = edgeOf(s, p, band)
		local seen = nil
		if edge and ctx then
			seen = shownUnder(m, i, ctx, ignore, config)
		elseif edge and m.groundY[i] then
			seen = { y = m.groundY[i], water = false }
		end
		if seen then
			local gap = if seen.y then p.Y - seen.y else math.huge
			found[i] = { gap = gap, edge = edge, along = along, across = across, water = seen.water, through = seen.through }
			edges[edge] = edges[edge] or {}
			table.insert(edges[edge], i)
		end
	end
	-- Each edge's samples in rows (one per distance in from the edge), each
	-- row in order along it.
	local dropped = {}
	for _, list in edges do
		table.sort(list, function(a, b)
			return found[a].across < found[b].across
		end)
		local rows = {}
		for _, i in list do
			local row = rows[#rows]
			if not row or found[i].across - found[row[1]].across > SAME_ROW then
				row = {}
				table.insert(rows, row)
			end
			table.insert(row, i)
		end
		for _, row in rows do
			table.sort(row, function(a, b)
				return found[a].along < found[b].along
			end)
			dropSpans(row, found, limit, config.connectMaxStep, dropped)
		end
	end
	local best = nil
	for i in samples do
		if found[i] and not dropped[i] and (not best or found[i].gap > found[best].gap) then
			best = i
		end
	end
	if not best then
		return nil
	end
	local f = found[best]
	return { gap = f.gap, position = samples[best], edge = f.edge, water = f.water, through = f.through }
end

-- Locked parts (Locked, BuildGuardLocked) are never moved by a snap.
Ground.LOCKED_NOTE = "it's locked (Locked or BuildGuardLocked): unlock it to let the fix move it, or move it by hand"
function Ground.isLocked(s, ctx)
	return Classify.isLocked(s.part, ctx.configFor(s.part))
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
		local m = if Ground.isLocked(s, ctx) then { skip = "locked (Locked or BuildGuardLocked), so it stays where it is" } else Ground.measure(s, ctx)
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

-- Off-ground issue for one road/rail/track measured as `m`, or nil.
local function offGroundIssue(s, kind, ctx, m)
	local bottom = s.cf:PointToWorldSpace(Vector3.new(0, -upSign(s) * s.half.Y, 0))
	if m.delta and math.abs(m.delta) > ctx.configFor(s.part).groundTolerance then
		local what = if m.delta < 0
			then ("hovers %.2f studs above the ground"):format(-m.delta)
			else ("is sunk %.2f studs into the ground"):format(m.delta)
		local locked = Ground.isLocked(s, ctx)
		return {
			check = "offground",
			severity = "warning",
			parts = { s.part },
			position = bottom,
			value = m.delta,
			message = ("%s %s %s%s"):format(kind, ctx.path(s.part), what, if locked then " — " .. Ground.LOCKED_NOTE else ""),
			fixItems = if locked then nil else Ground.items(s, ctx, m.delta, "offground", ("snap to ground (%+.3f)"):format(m.delta)),
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

-- Gap issue for a road/rail/track that rests on the ground (measured as
-- `m`) but hangs over a dip at its edges, or nil. Its kind's lift (a rail's
-- room for sleepers) isn't a gap.
local function gapIssue(s, kind, ctx, m)
	local config, sources = ctx.configFor(s.part)
	local worst = Ground.edgeGap(s, m, config, ctx)
	local key = LIFT_KEY[kind]
	local lift = math.max(config[key], 0)
	if not worst or worst.gap <= gapLimit(config, kind) + 1e-3 then
		return nil
	end
	local canSink = Config.schema[key].min < 0
	local fix
	if worst.through then
		fix = ("make it opaque (Transparency under %.2f) so it fills the gap, %sor raise the ground there"):format(
			ctx.config.zFightIgnoreTransparency,
			if canSink then ("sink the %s into the ground (negative %s), "):format(string.lower(kind), key) else ""
		)
	elseif canSink then
		fix = ("sink it into the ground (negative %s), put a footing under it, or raise the ground there"):format(key)
	else
		fix = "put a footing under it or raise the ground there"
	end
	return {
		check = "gap",
		severity = "warning",
		parts = { s.part },
		position = worst.position,
		value = worst.gap,
		edge = worst.edge,
		message = ("%s %s has a %.2f-stud gap%s under its %s edge at %s (limit %.2f%s%s)%s: %s"):format(
			kind,
			ctx.path(s.part),
			worst.gap,
			if worst.water then " above the water" else "",
			worst.edge,
			Util.vector(worst.position),
			config.maxHover,
			if lift > 0 then (" + %s %.2f"):format(key, lift) else "",
			if sources.maxHover then ", set on " .. ctx.path(sources.maxHover) else "",
			if worst.through then " that shows through invisible " .. ctx.path(worst.through) else "",
			fix
		),
	}
end

-- Roads/rails/tracks that are hovering above or sunk below the ground, or
-- that rest on it with a gap under their edges.
function Ground.scan(ctx, alreadyFlagged)
	local issues = {}
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind and not alreadyFlagged[s.part] then
			local m = Ground.measure(s, ctx)
			local issue = offGroundIssue(s, kind, ctx, m) or (m.delta and gapIssue(s, kind, ctx, m))
			if issue then
				table.insert(issues, issue)
			end
			ctx.yield()
		end
	end
	return issues
end

return Ground
