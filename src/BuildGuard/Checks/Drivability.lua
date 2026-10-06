--[[
	Drivability lint for roads. Report only, no fixes.

	Two road parts are connected when their top surfaces, seen from above,
	touch or overlap (within `connectMargin`). For each connected pair this
	measures, at the junction:
	  * ledge: the height step between the two top surfaces (> maxLedge flags)
	  * slope: the angle between the two top surfaces (> maxSlopeChange flags)

	Surfaces more than `connectMaxStep` apart vertically are treated as an
	overpass and skipped. Each road's driving surface is its Top (+Y) face.
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

function Drivability.scan(ctx)
	local config = ctx.config
	local roads = {}
	for _, s in ctx.solids do
		if ctx.kindOf(s.part) == "Road" then
			table.insert(roads, { solid = s, footprint = footprint(s) })
		end
	end

	local hash = SpatialHash.new(16)
	local margin = Vector3.new(config.connectMargin, config.connectMaxStep, config.connectMargin)
	for i, r in roads do
		hash:insert(i, r.solid.min, r.solid.max)
	end

	local issues = {}
	for i, ra in roads do
		local a = ra.solid
		local near = hash:query(a.min - margin, a.max + margin)
		table.sort(near)
		for _, j in near do
			if j <= i then
				continue
			end
			local rb = roads[j]
			local b = rb.solid
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
			if step > config.maxLedge then
				table.insert(issues, {
					check = "ledge",
					severity = "warning",
					parts = { a.part, b.part },
					position = at,
					value = step,
					message = ("Ledge of %.2f studs between %s and %s (limit %.2f)"):format(
						step,
						a.part.Name,
						b.part.Name,
						config.maxLedge
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
					message = ("Slope change of %.1f° between %s and %s (limit %.1f°)"):format(
						angle,
						a.part.Name,
						b.part.Name,
						config.maxSlopeChange
					),
				})
			end
		end
	end
	return issues
end

return Drivability
