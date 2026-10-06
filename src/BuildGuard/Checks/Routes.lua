--[[
	Route lint: the fixed numbers every road and rail must pass. Report only,
	no fixes.

	  * grade:   a road/rail/track top surface tilted more than maxRouteSlope
	  * width:   a road whose top face is narrower than minRoadWidth (the
	             shorter side of the top face is its width)
	  * offgrid: a level road, square to the world axes, whose edges aren't on
	             multiples of gridSize. Tilted or turned roads are skipped.
	  * cave:    a cave entrance marker wider than caveEntranceWidth (its local
	             X spans the opening; see Classify.isCaveEntrance)
]]

local Geometry = require(script.Parent.Parent.Geometry)
local Classify = require(script.Parent.Parent.Classify)

local Routes = {}

local EPSILON = 1e-3

-- ", set on Model X" when the limit came from a BuildGuard_ attribute.
local function limitNote(ctx, part, key)
	local _, sources = ctx.configFor(part)
	return if sources[key] then ", set on " .. sources[key].Name else ""
end

local function onGrid(value, grid)
	local r = value % grid
	return r < EPSILON or grid - r < EPSILON
end

local function snapped(value, grid)
	return math.floor(value / grid + 0.5) * grid
end

-- Level and turned in steps of 90°, so its footprint is an axis-aligned box.
local function squareOn(s)
	local right = s.axes[1]
	return s.axes[2].Y > 1 - 1e-6 and (math.abs(right.X) > 1 - 1e-6 or math.abs(right.Z) > 1 - 1e-6)
end

local function offGrid(s, grid)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, p in Geometry.topCorners(s) do
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
	end
	for _, v in { minX, maxX, minZ, maxZ } do
		if not onGrid(v, grid) then
			return ("x %.2f..%.2f, z %.2f..%.2f; nearest grid x %g..%g, z %g..%g"):format(
				minX,
				maxX,
				minZ,
				maxZ,
				snapped(minX, grid),
				snapped(maxX, grid),
				snapped(minZ, grid),
				snapped(maxZ, grid)
			)
		end
	end
	return nil
end

function Routes.scan(ctx)
	local issues = {}
	local function add(check, s, value, message)
		table.insert(issues, { check = check, severity = "warning", parts = { s.part }, value = value, message = message })
	end
	for _, s in ctx.solids do
		local part = s.part
		local config = ctx.configFor(part)
		local kind = ctx.kindOf(part)
		if kind then
			local tilt = Geometry.tiltDegrees(s)
			if tilt > config.maxRouteSlope + EPSILON then
				add(
					"grade",
					s,
					tilt,
					("%s %s slopes %.1f° (limit %.1f°%s)"):format(
						kind,
						part.Name,
						tilt,
						config.maxRouteSlope,
						limitNote(ctx, part, "maxRouteSlope")
					)
				)
			end
		end
		if kind == "Road" then
			local width = math.min(s.size.X, s.size.Z)
			if width < config.minRoadWidth - EPSILON then
				add(
					"width",
					s,
					width,
					("Road %s is %.2f studs wide (minimum %.2f%s)"):format(
						part.Name,
						width,
						config.minRoadWidth,
						limitNote(ctx, part, "minRoadWidth")
					)
				)
			end
			if config.gridSize > 0 and squareOn(s) then
				local where = offGrid(s, config.gridSize)
				if where then
					add(
						"offgrid",
						s,
						config.gridSize,
						("Road %s edges are off the %g-stud grid (%s)"):format(part.Name, config.gridSize, where)
					)
				end
			end
		end
		if Classify.isCaveEntrance(part) and s.size.X > config.caveEntranceWidth + EPSILON then
			add(
				"cave",
				s,
				s.size.X,
				("Cave entrance %s is %.2f studs wide, trucks could fit (maximum %.2f%s)"):format(
					part.Name,
					s.size.X,
					config.caveEntranceWidth,
					limitNote(ctx, part, "caveEntranceWidth")
				)
			)
		end
	end
	return issues
end

return Routes
