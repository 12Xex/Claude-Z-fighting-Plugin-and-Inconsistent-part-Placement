--[[
	Drivability lint for roads and rails (Config.drivableKinds). Report only,
	no fixes.

	Per part:
	  * routeslope: the top surface tilts more than maxRouteSlope
	  * roadwidth:  a road's top surface is narrower than minRoadWidth,
	    measured across the direction it's driven: the axis its connected
	    roads join it along. A piece with joins on both axes (a junction) or
	    none at all is measured across its shorter side.
	  * edge: the step from the ground beside a part up onto its top surface
	    is more than maxLedge (kinds in edgeLedgeKinds, tilted 45° or less so
	    a ramp's foot counts). Points along each top edge are probed
	    `edgeProbe` studs outside it, looking straight down from
	    connectMaxStep above the surface to connectMaxStep below it. Terrain
	    or a ground part there is measured. Another road or rail is a join,
	    so only the free stretches of an edge count; any other part (a kerb,
	    a wall) is skipped, and so is a drop deeper than connectMaxStep (a
	    bridge, an embankment). Markings, ignored things and vehicles are
	    looked through. Parts in `skipEdges` (already reported buried or
	    off the ground) aren't edge-checked: their edges change once fixed.

	Two parts of the same kind are connected when their top surfaces, seen from above,
	touch or overlap (within `connectMargin`). For each connected pair this
	measures, at the junction:
	  * ledge: the height step between the two top surfaces (> maxLedge flags)
	  * slope: the angle between the two top surfaces (> maxSlopeChange flags)

	Surfaces more than `connectMaxStep` apart vertically are treated as an
	overpass and skipped. Each road's driving surface is its Top (+Y) face.

	Limits for a join come from the smallest instance containing both pieces
	(ctx.pairConfig): a model's overrides cover joins inside it, and joins to
	roads outside it use the outside settings.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local SpatialHash = require(script.Parent.Parent.SpatialHash)
local Classify = require(script.Parent.Parent.Classify)
local Util = require(script.Parent.Parent.Util)

local Drivability = {}

-- Parts tilted more than this have no top edge a vehicle drives onto.
local EDGE_MAX_TILT = 45
-- Edge samples start this far in from the corners...
local EDGE_CORNER_INSET = 0.5
-- ...and an edge is split into at most this many intervals.
local EDGE_MAX_INTERVALS = 256

-- The top face's edges, named by the part's own axes.
local EDGES = {
	{ name = "+X", axis = 1, sign = 1 },
	{ name = "-X", axis = 1, sign = -1 },
	{ name = "+Z", axis = 3, sign = 1 },
	{ name = "-Z", axis = 3, sign = -1 },
}

local function kindSet(list)
	local set = {}
	for _, kind in list do
		set[kind] = true
	end
	return set
end

local function footprint(s)
	local out = {}
	for i, p in Geometry.topCorners(s) do
		out[i] = { p.X, p.Z }
	end
	return out
end

local function topCenter(s)
	return s.cf:PointToWorldSpace(Vector3.new(0, s.half.Y, 0))
end

-- ", set on Map/Hills" when a limit came from a BuildGuard_ attribute.
local function setOn(ctx, sources, key)
	local source = sources[key]
	return if source then ", set on " .. ctx.path(source) else ""
end

--------------------------------------------------------------------------------
-- Edges: the step from the ground beside a road up onto it
--------------------------------------------------------------------------------

-- Points along one top edge, `spacing` apart and EDGE_CORNER_INSET in from
-- the corners (just the midpoint on a short edge).
local function edgePoints(s, edge, spacing)
	local h = s.half
	local reach = (if edge.axis == 1 then h.Z else h.X) - EDGE_CORNER_INSET
	local offsets = { 0 }
	if reach > 0 then
		local n = math.clamp(math.ceil(2 * reach / spacing), 1, EDGE_MAX_INTERVALS)
		offsets = {}
		for i = 0, n do
			offsets[i + 1] = -reach + 2 * reach * i / n
		end
	end
	local points = {}
	for i, t in offsets do
		local lp = if edge.axis == 1 then Vector3.new(edge.sign * h.X, h.Y, t) else Vector3.new(t, h.Y, edge.sign * h.Z)
		points[i] = s.cf:PointToWorldSpace(lp)
	end
	return points
end

-- The edge probe looks through the part itself, markings, ignored things
-- and vehicles.
local function edgeIgnore(part, ctx)
	return function(instance)
		if instance == part or instance:IsDescendantOf(part) then
			return true
		end
		if not instance:IsA("BasePart") or ctx.world.isTerrain(instance) then
			return false
		end
		return Classify.isLayered(instance) or ctx.isIgnored(instance) or ctx.vehicleOf(instance) ~= nil
	end
end

-- Height of the edge `point` above the ground just outside it (`outward`
-- is flat), or nil when there's nothing to measure: another road or rail
-- there (a join), another part (a kerb, a wall), something taller than
-- connectMaxStep (a cliff, a tunnel wall) or no ground within it (a drop-off).
local function stepAt(ctx, point, outward, config, ignore, drivable)
	local world = ctx.world
	local probe = point + outward * config.edgeProbe
	local reach = config.connectMaxStep + 0.5
	local origin = Vector3.new(probe.X, point.Y + reach, probe.Z)
	if world.isSolidTerrain(origin) or world.partAt(origin, ignore) then
		return nil
	end
	local hit = world.raycast(origin, Vector3.new(0, -2 * reach, 0), ignore)
	if not hit then
		return nil
	end
	local instance = hit.instance
	if not world.isTerrain(instance) then
		local kind = ctx.kindOf(instance)
		if (kind and drivable[kind]) or not Classify.isGroundLike(instance, ctx.config) then
			return nil
		end
	end
	return point.Y - hit.position.Y
end

-- The worst step along each top edge of solid `s`: a list of
-- { name = "+X", step, position, measured, samples }. `step` is positive
-- when the surface is above the ground beside it (nil when no sample was
-- measured); `position` is the edge point where it was found; `measured`
-- counts the samples that found ground.
function Drivability.edgeSteps(ctx, s, config)
	config = config or ctx.configFor(s.part)
	local drivable = kindSet(ctx.config.drivableKinds)
	local ignore = edgeIgnore(s.part, ctx)
	local out = {}
	for _, edge in EDGES do
		local n = s.axes[edge.axis] * edge.sign
		local flat = Vector3.new(n.X, 0, n.Z)
		if flat.Magnitude > 1e-6 then
			local points = edgePoints(s, edge, config.sampleSpacing)
			local worst, at, measured = nil, nil, 0
			for _, point in points do
				local step = stepAt(ctx, point, flat.Unit, config, ignore, drivable)
				if step then
					measured += 1
					if not worst or math.abs(step) > math.abs(worst) then
						worst, at = step, point
					end
				end
			end
			table.insert(out, { name = edge.name, step = worst, position = at, measured = measured, samples = #points })
		end
	end
	return out
end

-- "1.10-stud step from the ground up onto its +Z edge at (x, y, z) (limit 1.00) — ..."
local function edgeText(kind, e, limit)
	local surface = string.lower(kind)
	local at = Util.vector(e.position)
	if e.step > 0 then
		return ("%.2f-stud step from the ground up onto its %s edge at %s %s — use a thinner piece or build the ground up to its edge"):format(
			e.step,
			e.name,
			at,
			limit
		)
	end
	return ("the ground beside its %s edge is %.2f above the %s surface at %s %s — lower the ground there or raise the %s"):format(
		e.name,
		-e.step,
		surface,
		at,
		limit,
		surface
	)
end

local function edgeIssues(ctx, s, kind)
	local config, sources = ctx.configFor(s.part)
	local limit = ("(limit %.2f%s)"):format(config.maxLedge, setOn(ctx, sources, "maxLedge"))
	local issues = {}
	for _, e in Drivability.edgeSteps(ctx, s, config) do
		if e.step and math.abs(e.step) > config.maxLedge + 1e-3 then
			table.insert(issues, {
				check = "edge",
				severity = "warning",
				parts = { s.part },
				position = e.position,
				value = math.abs(e.step),
				step = e.step,
				edge = e.name,
				message = ("%s %s: %s"):format(kind, ctx.path(s.part), edgeText(kind, e, limit)),
			})
		end
	end
	return issues
end

--------------------------------------------------------------------------------
-- Per part and per join
--------------------------------------------------------------------------------

local function routeSlopeIssue(ctx, s, kind)
	local config, sources = ctx.configFor(s.part)
	local tilt = Geometry.tiltDegrees(s)
	if tilt <= config.maxRouteSlope then
		return nil
	end
	return {
		check = "routeslope",
		severity = "warning",
		parts = { s.part },
		position = topCenter(s),
		value = tilt,
		message = ("%s %s slopes %.1f° (limit %.1f°%s)"):format(
			kind,
			ctx.path(s.part),
			tilt,
			config.maxRouteSlope,
			setOn(ctx, sources, "maxRouteSlope")
		),
	}
end

-- Ledge and slope issues for one connected pair; records the join on both.
local function joinIssues(ctx, ra, rb, issues)
	local a, b = ra.solid, rb.solid
	local config, sources = ctx.pairConfig(a.part, b.part)
	if Geometry.polygonSeparation(ra.footprint, rb.footprint) > config.connectMargin then
		return
	end
	local pa, pb = Geometry.closestOnTop(a, topCenter(b)), Geometry.closestOnTop(b, topCenter(a))
	local jx, jz = (pa.X + pb.X) / 2, (pa.Z + pb.Z) / 2
	local ya, yb = Geometry.topHeightAt(a, jx, jz), Geometry.topHeightAt(b, jx, jz)
	if not ya or not yb then
		return
	end
	local step = math.abs(ya - yb)
	if step > config.connectMaxStep then
		return
	end
	local angle = math.deg(math.acos(math.clamp(a.axes[2]:Dot(b.axes[2]), -1, 1)))
	local at = Vector3.new(jx, math.max(ya, yb), jz)
	table.insert(ra.joins, at)
	table.insert(rb.joins, at)
	local pathA, pathB = ctx.path(a.part), ctx.path(b.part)
	if step > config.maxLedge then
		table.insert(issues, {
			check = "ledge",
			severity = "warning",
			parts = { a.part, b.part },
			position = at,
			value = step,
			message = ("Ledge of %.2f studs between %s and %s at %s (limit %.2f%s)"):format(
				step,
				pathA,
				pathB,
				Util.vector(at),
				config.maxLedge,
				setOn(ctx, sources, "maxLedge")
			),
		})
	end
	if angle > config.maxSlopeChange then
		table.insert(issues, {
			check = "slope",
			severity = "warning",
			parts = { a.part, b.part },
			position = at,
			value = angle,
			message = ("Slope change of %.1f° between %s and %s at %s (limit %.1f°%s)"):format(
				angle,
				pathA,
				pathB,
				Util.vector(at),
				config.maxSlopeChange,
				setOn(ctx, sources, "maxSlopeChange")
			),
		})
	end
end

-- Road width, across the driving direction.
local function widthIssue(ctx, r)
	local s = r.solid
	local config, sources = ctx.configFor(s.part)
	local alongX, alongZ = false, false
	for _, at in r.joins do
		local lp = s.cf:PointToObjectSpace(at)
		-- Which end/side of the piece is this join nearest to?
		if math.abs(lp.X) / s.half.X >= math.abs(lp.Z) / s.half.Z then
			alongX = true
		else
			alongZ = true
		end
	end
	local width
	if alongX and not alongZ then
		width = s.size.Z
	elseif alongZ and not alongX then
		width = s.size.X
	else
		width = math.min(s.size.X, s.size.Z)
	end
	if width >= config.minRoadWidth - 1e-3 then
		return nil
	end
	return {
		check = "roadwidth",
		severity = "warning",
		parts = { s.part },
		position = topCenter(s),
		value = width,
		message = ("Road %s is %.1f studs wide (minimum %.1f%s)"):format(
			ctx.path(s.part),
			width,
			config.minRoadWidth,
			setOn(ctx, sources, "minRoadWidth")
		),
	}
end

-- `skipEdges` (optional): a set of parts not to edge-check.
function Drivability.scan(ctx, skipEdges)
	skipEdges = skipEdges or {}
	local drivable = kindSet(ctx.config.drivableKinds)
	local edgeKinds = kindSet(ctx.config.edgeLedgeKinds)
	local roads = {}
	local issues = {}
	local marginXZ, marginY = 0, 0
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind and drivable[kind] then
			table.insert(roads, { solid = s, footprint = footprint(s), kind = kind, joins = {} })
			local config = ctx.configFor(s.part)
			marginXZ = math.max(marginXZ, config.connectMargin)
			marginY = math.max(marginY, config.connectMaxStep)
			local issue = routeSlopeIssue(ctx, s, kind)
			if issue then
				table.insert(issues, issue)
			end
		end
		local edgeChecked = kind and edgeKinds[kind] and not skipEdges[s.part]
		if edgeChecked and Geometry.tiltDegrees(s) <= EDGE_MAX_TILT + 1e-3 then
			for _, issue in edgeIssues(ctx, s, kind) do
				table.insert(issues, issue)
			end
			ctx.yield()
		end
	end

	local hash = SpatialHash.new(16)
	local margin = Vector3.new(marginXZ, marginY, marginXZ)
	for i, r in roads do
		hash:insert(i, r.solid.min, r.solid.max)
	end
	for i, ra in roads do
		local near = hash:query(ra.solid.min - margin, ra.solid.max + margin)
		table.sort(near)
		for _, j in near do
			if j > i and roads[j].kind == ra.kind then
				joinIssues(ctx, ra, roads[j], issues)
			end
		end
	end

	for _, r in roads do
		if r.kind == "Road" then
			local issue = widthIssue(ctx, r)
			if issue then
				table.insert(issues, issue)
			end
		end
	end
	return issues
end

return Drivability
