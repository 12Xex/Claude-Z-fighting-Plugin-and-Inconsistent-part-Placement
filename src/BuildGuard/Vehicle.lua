--[[
	Vehicle profile: measures a vehicle model and compares it with the road
	limits, so the limits can come from the truck instead of guesses.

	Orientation: the model's PrimaryPart (or `options.frame`, or else its
	biggest non-wheel part). Front is the frame's -Z (LookVector), up is +Y.

	Wheels: parts named *wheel*, *tire* or *tyre*, or with the attribute
	BuildGuardWheel = true (false excludes a part). Their radius is half the
	smaller of a cylinder's Y/Z size (cylinders roll about X), or half their
	height for other shapes.

	All measurements use part bounding boxes, so round parts (springs, hubs)
	count as slightly lower than they are. The ledge figure is an estimate:
	the wheel radius is the geometric limit, and in Roblox physics trucks
	usually manage about half of it.
]]

local Vehicle = {}

local WHEEL_NAMES = { "wheel", "tire", "tyre" }

local function isWheel(part)
	local flag = part:GetAttribute("BuildGuardWheel")
	if flag ~= nil then
		return flag == true
	end
	local name = string.lower(part.Name)
	for _, fragment in WHEEL_NAMES do
		if string.find(name, fragment, 1, true) then
			return true
		end
	end
	return false
end

local function corners(part, frame)
	local half = part.Size / 2
	local out = {}
	for _, x in { -1, 1 } do
		for _, y in { -1, 1 } do
			for _, z in { -1, 1 } do
				local world = part.CFrame:PointToWorldSpace(Vector3.new(x * half.X, y * half.Y, z * half.Z))
				table.insert(out, frame:PointToObjectSpace(world))
			end
		end
	end
	return out
end

local function wheelRadius(part, frame)
	local ok, shape = pcall(function()
		return part.Shape.Name
	end)
	if ok and shape == "Cylinder" then
		return math.min(part.Size.Y, part.Size.Z) / 2
	elseif ok and shape == "Ball" then
		return math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2
	end
	local low, high = math.huge, -math.huge
	for _, c in corners(part, frame) do
		low, high = math.min(low, c.Y), math.max(high, c.Y)
	end
	return (high - low) / 2
end

-- Measures `model`. Returns a profile table (all lengths in studs, angles
-- in degrees).
function Vehicle.measure(model, options)
	options = options or {}
	local parts = {}
	if model:IsA("BasePart") then
		table.insert(parts, model)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local wheels, body = {}, {}
	for _, p in parts do
		table.insert(if isWheel(p) then wheels else body, p)
	end
	if #wheels == 0 then
		error("BuildGuard: no wheels found in " .. model:GetFullName() .. "; name them Wheel/Tire or set BuildGuardWheel = true", 2)
	end

	local frame = options.frame or (model:IsA("Model") and model.PrimaryPart and model.PrimaryPart.CFrame)
	if not frame then
		local biggest, volume = nil, -1
		for _, p in (if #body > 0 then body else wheels) do
			local v = p.Size.X * p.Size.Y * p.Size.Z
			if v > volume then
				biggest, volume = p, v
			end
		end
		frame = biggest.CFrame
	end
	frame = frame - frame.Position

	local ground, radius = math.huge, math.huge
	local frontAxle, rearAxle = math.huge, -math.huge
	for _, w in wheels do
		local r = wheelRadius(w, frame)
		local c = frame:PointToObjectSpace(w.CFrame.Position)
		ground = math.min(ground, c.Y - r)
		radius = math.min(radius, r)
		frontAxle = math.min(frontAxle, c.Z)
		rearAxle = math.max(rearAxle, c.Z)
	end

	local minV, maxV = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local clearance, midClearance = math.huge, math.huge
	local approach, departure = 90, 90
	for _, p in parts do
		-- The part's bounding box in the vehicle's frame.
		local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, c in corners(p, frame) do
			lo = Vector3.new(math.min(lo.X, c.X), math.min(lo.Y, c.Y), math.min(lo.Z, c.Z))
			hi = Vector3.new(math.max(hi.X, c.X), math.max(hi.Y, c.Y), math.max(hi.Z, c.Z))
		end
		minV = Vector3.new(math.min(minV.X, lo.X), math.min(minV.Y, lo.Y), math.min(minV.Z, lo.Z))
		maxV = Vector3.new(math.max(maxV.X, hi.X), math.max(maxV.Y, hi.Y), math.max(maxV.Z, hi.Z))
		if not isWheel(p) then
			local h = lo.Y - ground
			clearance = math.min(clearance, h)
			-- Any part of it between the axles limits breakover.
			if hi.Z >= frontAxle and lo.Z <= rearAxle then
				midClearance = math.min(midClearance, h)
			end
			-- Its lowest, furthest-forward point limits approach (and rear for departure).
			if lo.Z < frontAxle then
				approach = math.min(approach, math.deg(math.atan2(h, frontAxle - lo.Z)))
			end
			if hi.Z > rearAxle then
				departure = math.min(departure, math.deg(math.atan2(h, hi.Z - rearAxle)))
			end
		end
	end
	local wheelbase = rearAxle - frontAxle
	local breakover = 180
	if wheelbase > 1e-3 and midClearance < math.huge then
		breakover = math.deg(2 * math.atan(2 * math.max(midClearance, 0) / wheelbase))
	end

	return {
		name = model.Name,
		width = maxV.X - minV.X,
		length = maxV.Z - minV.Z,
		height = maxV.Y - ground,
		wheelCount = #wheels,
		wheelRadius = radius,
		wheelbase = wheelbase,
		groundClearance = if clearance < math.huge then clearance else 0,
		approachAngle = approach,
		departureAngle = departure,
		breakoverAngle = breakover,
	}
end

-- Road limits this vehicle needs. Pass the result to BG.setConfig if you
-- want to adopt them.
function Vehicle.limits(profile)
	return {
		maxLedge = profile.wheelRadius * 0.5,
		maxSlopeChange = math.min(profile.breakoverAngle, profile.approachAngle, profile.departureAngle),
		minRoadWidth = 2 * profile.width + 2,
		roadHeadroom = profile.height + 1,
	}
end

-- Compares a profile with `config`. Returns rows { ok, key, text } and the
-- whole report as text.
function Vehicle.compare(profile, config)
	local limits = Vehicle.limits(profile)
	local rows = {}
	local function row(state, key, text)
		table.insert(rows, { state = state, key = key, text = text })
	end

	if config.maxLedge > profile.wheelRadius then
		row("fail", "maxLedge", ("maxLedge %.2f is taller than the wheel radius (%.2f): it can't climb that"):format(config.maxLedge, profile.wheelRadius))
	elseif config.maxLedge > limits.maxLedge then
		row("check", "maxLedge", ("maxLedge %.2f is above half the wheel radius (%.2f): confirm in play mode"):format(config.maxLedge, limits.maxLedge))
	else
		row("ok", "maxLedge", ("maxLedge %.2f is within half the wheel radius (%.2f)"):format(config.maxLedge, limits.maxLedge))
	end

	local worst = if profile.breakoverAngle <= math.min(profile.approachAngle, profile.departureAngle)
		then "crests (breakover)"
		else "dips (approach/departure)"
	if config.maxSlopeChange > limits.maxSlopeChange then
		row("fail", "maxSlopeChange", ("maxSlopeChange %.1f° allows %s this truck grounds on beyond %.1f°"):format(config.maxSlopeChange, worst, limits.maxSlopeChange))
	else
		row("ok", "maxSlopeChange", ("maxSlopeChange %.1f° is within %.1f° (%s)"):format(config.maxSlopeChange, limits.maxSlopeChange, worst))
	end

	if config.minRoadWidth < profile.width then
		row("fail", "minRoadWidth", ("minRoadWidth %.1f is narrower than the truck (%.1f)"):format(config.minRoadWidth, profile.width))
	elseif config.minRoadWidth < limits.minRoadWidth then
		row("check", "minRoadWidth", ("minRoadWidth %.1f fits one truck; two passing need %.1f"):format(config.minRoadWidth, limits.minRoadWidth))
	else
		row("ok", "minRoadWidth", ("minRoadWidth %.1f lets two trucks pass (needs %.1f)"):format(config.minRoadWidth, limits.minRoadWidth))
	end

	if config.roadHeadroom <= 0 then
		row("check", "roadHeadroom", ("roadHeadroom is off; set it to at least %.1f for this truck"):format(limits.roadHeadroom))
	elseif config.roadHeadroom < limits.roadHeadroom then
		row("fail", "roadHeadroom", ("roadHeadroom %.1f is lower than this truck needs (%.1f)"):format(config.roadHeadroom, limits.roadHeadroom))
	else
		row("ok", "roadHeadroom", ("roadHeadroom %.1f clears the truck (needs %.1f)"):format(config.roadHeadroom, limits.roadHeadroom))
	end

	row("check", "maxRouteSlope", ("maxRouteSlope %.1f° depends on engine power and grip, which can't be measured from the model: test a loaded climb"):format(config.maxRouteSlope))

	local lines = {
		("Vehicle %s: %.1f wide, %.1f tall, %.1f long, %d wheels (radius %.2f), wheelbase %.1f"):format(
			profile.name,
			profile.width,
			profile.height,
			profile.length,
			profile.wheelCount,
			profile.wheelRadius,
			profile.wheelbase
		),
		("  ground clearance %.2f, approach %.1f°, departure %.1f°, breakover %.1f°"):format(
			profile.groundClearance,
			profile.approachAngle,
			profile.departureAngle,
			profile.breakoverAngle
		),
	}
	local marks = { ok = "ok   ", check = "check", fail = "FAIL " }
	for _, r in rows do
		table.insert(lines, ("  %s %s"):format(marks[r.state], r.text))
	end
	return rows, table.concat(lines, "\n")
end

return Vehicle
