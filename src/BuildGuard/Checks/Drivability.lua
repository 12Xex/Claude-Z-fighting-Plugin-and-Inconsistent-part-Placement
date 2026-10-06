--[[
	Drivability lint for roads and rails (Config.drivableKinds). Report only,
	no fixes.

	Per part:
	  * routeslope: the top surface tilts more than maxRouteSlope
	  * roadwidth:  a road's top surface is narrower than minRoadWidth,
	    measured across the direction it's driven: the axis its connected
	    roads join it along. A piece with joins on both axes (a junction) or
	    none at all is measured across its shorter side.

	Two parts of the same kind are connected when their top surfaces, seen from above,
	touch or overlap (within `connectMargin`). For each connected pair this
	measures, at the junction:
	  * ledge: the height step between the two top surfaces (> maxLedge flags)
	  * slope: the angle between the two top surfaces (> maxSlopeChange flags)

	Surfaces more than `connectMaxStep` apart vertically are treated as an
	overpass and skipped. Each road's driving surface is its Top (+Y) face.

	Limits come from the pair's combined config (Config.combine): a model
	given looser limits with BuildGuard_ attributes governs its own joins,
	including joins to roads outside it.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local SpatialHash = require(script.Parent.Parent.SpatialHash)

local Drivability = {}

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

-- ", set on Model X" when a pair's limit came from a BuildGuard_ attribute.
local function limitNote(ctx, a, b, key, value)
	for _, part in { a, b } do
		local config, sources = ctx.configFor(part)
		if config[key] == value and sources[key] then
			return ", set on " .. sources[key].Name
		end
	end
	return ""
end

function Drivability.scan(ctx)
	local drivable = {}
	for _, kind in ctx.config.drivableKinds do
		drivable[kind] = true
	end
	local roads = {}
	local issues = {}
	local marginXZ, marginY = 0, 0
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind and drivable[kind] then
			table.insert(roads, { solid = s, footprint = footprint(s), kind = kind, joins = {} })
			local config, sources = ctx.configFor(s.part)
			marginXZ = math.max(marginXZ, config.connectMargin)
			marginY = math.max(marginY, config.connectMaxStep)

			local tilt = Geometry.tiltDegrees(s)
			if tilt > config.maxRouteSlope then
				table.insert(issues, {
					check = "routeslope",
					severity = "warning",
					parts = { s.part },
					value = tilt,
					message = ("%s %s slopes %.1f° (limit %.1f°%s)"):format(
						kind,
						s.part.Name,
						tilt,
						config.maxRouteSlope,
						if sources.maxRouteSlope then ", set on " .. sources.maxRouteSlope.Name else ""
					),
				})
			end
		end
	end

	local hash = SpatialHash.new(16)
	local margin = Vector3.new(marginXZ, marginY, marginXZ)
	for i, r in roads do
		hash:insert(i, r.solid.min, r.solid.max)
	end

	for i, ra in roads do
		local a = ra.solid
		local near = hash:query(a.min - margin, a.max + margin)
		table.sort(near)
		for _, j in near do
			if j <= i then
				continue
			end
			local rb = roads[j]
			if rb.kind ~= ra.kind then
				continue
			end
			local b = rb.solid
			local config = ctx.pairConfig(a.part, b.part)
			if Geometry.polygonSeparation(ra.footprint, rb.footprint) > config.connectMargin then
				continue
			end
			local pa, pb = Geometry.closestOnTop(a, topCenter(b)), Geometry.closestOnTop(b, topCenter(a))
			local jx, jz = (pa.X + pb.X) / 2, (pa.Z + pb.Z) / 2
			local ya, yb = Geometry.topHeightAt(a, jx, jz), Geometry.topHeightAt(b, jx, jz)
			if not ya or not yb then
				continue
			end
			local step = math.abs(ya - yb)
			if step > config.connectMaxStep then
				continue
			end
			local angle = math.deg(math.acos(math.clamp(a.axes[2]:Dot(b.axes[2]), -1, 1)))
			local at = Vector3.new(jx, math.max(ya, yb), jz)
			table.insert(ra.joins, at)
			table.insert(rb.joins, at)
			if step > config.maxLedge then
				table.insert(issues, {
					check = "ledge",
					severity = "warning",
					parts = { a.part, b.part },
					position = at,
					value = step,
					message = ("Ledge of %.2f studs between %s and %s (limit %.2f%s)"):format(
						step,
						a.part.Name,
						b.part.Name,
						config.maxLedge,
						limitNote(ctx, a.part, b.part, "maxLedge", config.maxLedge)
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
					message = ("Slope change of %.1f° between %s and %s (limit %.1f°%s)"):format(
						angle,
						a.part.Name,
						b.part.Name,
						config.maxSlopeChange,
						limitNote(ctx, a.part, b.part, "maxSlopeChange", config.maxSlopeChange)
					),
				})
			end
		end
	end
	-- Road width, across the driving direction.
	for _, r in roads do
		if r.kind == "Road" then
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
			if width < config.minRoadWidth - 1e-3 then
				table.insert(issues, {
					check = "roadwidth",
					severity = "warning",
					parts = { s.part },
					value = width,
					message = ("Road %s is %.1f studs wide (minimum %.1f%s)"):format(
						s.part.Name,
						width,
						config.minRoadWidth,
						if sources.minRoadWidth then ", set on " .. sources.minRoadWidth.Name else ""
					),
				})
			end
		end
	end
	return issues
end

return Drivability
