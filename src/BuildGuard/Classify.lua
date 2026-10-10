--[[
	What kind of part is this?

	Kind ("Road" | "Rail" | "Track" | nil), in priority order:
	  1. BuildGuardKind attribute ("Road", "Rail", "Track", or "None" to opt out)
	  2. A CollectionService tag named Road, Rail or Track
	  3. The part's name, when Config.classifyByName is on: its FIRST word is
	     one of Config.kindNameWords ("Road_01", "RailYard", "TrackBed"; not
	     "BedRail", "RoofRail" or "Railing"), it's flat (no thicker than
	     kindMaxThickness of its longest side, so not "RoadSign" or
	     "StreetLamp"), it isn't a ball or cylinder, and it isn't part of a
	     vehicle (`inVehicle`).

	Ground: Terrain, the BuildGuardGround attribute or tag, a flat part whose
	first name word is in Config.groundNames ("Baseplate", "Ground_Main"), or
	(only if groundMinFootprint is above 0) a part at least that big.

	Wheels: the BuildGuardWheel attribute or tag (true/false), else parts that
	spin on a HingeConstraint/CylindricalConstraint through their centre along
	their round axis, else (only when a model has none of those) a name whose
	first word is wheel/tire/tyre followed only by position words
	("Wheel_FL", "TireRearLeft"; not "SteeringWheel", "SpareWheel" or
	"WheelArch").

	Ignored: anything at or under an instance with the BuildGuardIgnore
	attribute or tag. It's not scanned, and it never counts as cover, ground
	or a hiding surface.
]]

local Util = require(script.Parent.Util)

local Classify = {}

local KINDS = { Road = true, Rail = true, Track = true }

-- Is `part` flat enough to be a road/rail/track or ground by its name?
function Classify.isFlat(part, config)
	if part:IsA("Part") then
		local shape = Util.prop(part, "Shape")
		if shape and (shape.Name == "Ball" or shape.Name == "Cylinder") then
			return false
		end
	end
	local size = part.Size
	return size.Y <= config.kindMaxThickness * math.max(size.X, size.Z)
end

-- `inVehicle(part)` (optional) says whether the part belongs to a vehicle.
function Classify.kind(part, config, world, inVehicle)
	local attribute = part:GetAttribute("BuildGuardKind")
	if typeof(attribute) == "string" then
		return if KINDS[attribute] then attribute else nil
	end
	for kind in KINDS do
		if (world and world.hasTag and world.hasTag(part, kind)) or Util.hasTag(part, kind) then
			return kind
		end
	end
	if config.classifyByName == false then
		return nil
	end
	local first = Util.words(part.Name)[1]
	if not first then
		return nil
	end
	for _, rule in config.kindNameWords do
		if table.find(rule.words, first) then
			if not Classify.isFlat(part, config) or (inVehicle and inVehicle(part)) then
				return nil
			end
			return rule.kind
		end
	end
	return nil
end

-- Items placed with Layers (markings, signs, trim) carry this attribute.
function Classify.isLayered(part)
	return part:GetAttribute("BuildGuardLayer") ~= nil
end

-- Terrain and parts marked or named as ground.
function Classify.isGroundLike(instance, config)
	if instance:IsA("Terrain") then
		return true
	end
	if not instance:IsA("BasePart") then
		return false
	end
	local marker = Util.marker(instance, "BuildGuardGround")
	if marker ~= nil then
		return marker
	end
	local first = Util.words(instance.Name)[1]
	if first and table.find(config.groundNames, first) and Classify.isFlat(instance, config) then
		return true
	end
	local footprint = config.groundMinFootprint
	if footprint and footprint > 0 then
		local size = instance.Size
		return size.X >= footprint and size.Z >= footprint
	end
	return false
end

-- Fixes never move these.
function Classify.isLocked(part, config)
	return part.Locked or part:GetAttribute("BuildGuardLocked") == true or Classify.isGroundLike(part, config)
end

-- Does this instance itself carry BuildGuardIgnore (attribute or tag)?
function Classify.ignoresItself(instance)
	return instance:GetAttribute("BuildGuardIgnore") == true or Util.hasTag(instance, "BuildGuardIgnore")
end

-- Is `instance` at or under an ignored instance? Pass a table as `cache` to
-- reuse answers across calls.
function Classify.isIgnored(instance, cache)
	cache = cache or {}
	local chain = {}
	local node = instance
	local result = false
	while node do
		local known = cache[node]
		if known ~= nil then
			result = known
			break
		end
		table.insert(chain, node)
		if Classify.ignoresItself(node) then
			result = true
			break
		end
		node = node.Parent
	end
	for _, n in chain do
		cache[n] = result
	end
	return result
end

-- All BaseParts under `root` (including root), skipping Terrain and anything
-- at or under an ignored instance (BuildGuardIgnore attribute or tag).
function Classify.collectParts(root)
	local out = {}
	local function visit(instance)
		if Classify.ignoresItself(instance) then
			return
		end
		if instance:IsA("BasePart") and not instance:IsA("Terrain") then
			table.insert(out, instance)
		end
		for _, child in instance:GetChildren() do
			visit(child)
		end
	end
	visit(root)
	return out
end

--------------------------------------------------------------------------------
-- Wheels
--------------------------------------------------------------------------------

local WHEEL_WORDS = { "wheel", "wheels", "tire", "tires", "tyre", "tyres" }
local POSITION_WORDS = {
	"f", "r", "l", "fl", "fr", "rl", "rr", "lf", "rf", "lr", "lb", "rb", "bl", "br",
	"front", "rear", "back", "left", "right", "middle", "mid", "center", "centre",
	"inner", "outer", "inside", "outside", "drive", "steer", "axle",
}

-- Does the name alone say "wheel"? First word wheel/tire/tyre, then only
-- position words or numbers.
function Classify.isWheelName(name)
	local words = Util.words(name)
	if not words[1] or not table.find(WHEEL_WORDS, words[1]) then
		return false
	end
	for i = 2, #words do
		local w = words[i]
		if not (string.match(w, "^%d+$") or table.find(POSITION_WORDS, w)) then
			return false
		end
	end
	return true
end

-- World CFrame of an attachment on a part (Lune can't read WorldCFrame).
function Classify.attachmentFrame(attachment)
	local parent = attachment and attachment.Parent
	if parent and parent:IsA("BasePart") then
		return parent.CFrame * attachment.CFrame
	end
	return nil
end

-- If `part` spins about the axis `axis` (world) through `point`, is that its
-- round axis through its centre?
local function spinsOnAxis(part, point, axis)
	local cf, size = part.CFrame, part.Size
	local centre = cf.Position
	local offset = point - centre
	local alongAxis = offset:Dot(axis)
	local off = (offset - axis * alongAxis).Magnitude
	if off > 0.15 * math.min(size.X, size.Y, size.Z) + 0.05 then
		return false
	end
	local shape = if part:IsA("Part") then Util.prop(part, "Shape") else nil
	local shapeName = shape and shape.Name
	if shapeName == "Ball" then
		return true
	end
	local axes = { cf.RightVector, cf.UpVector, cf.LookVector }
	local sizes = { size.X, size.Y, size.Z }
	for i = 1, 3 do
		if math.abs(axes[i]:Dot(axis)) >= 0.98 then
			if shapeName == "Cylinder" then
				return i == 1
			elseif shapeName == "Block" or shapeName == "Wedge" or shapeName == "CornerWedge" then
				return false
			end
			-- Mesh or union: round across the axis (the other two sizes match).
			local a, b = sizes[i % 3 + 1], sizes[(i + 1) % 3 + 1]
			return math.abs(a - b) <= 0.1 * math.max(a, b)
		end
	end
	return false
end

-- Parts that spin on a hinge or cylindrical constraint (structural wheels)
-- among `instances` (constraints found anywhere in the list). Returns a set.
function Classify.spinningParts(constraints)
	local out = {}
	for _, c in constraints do
		if (c:IsA("HingeConstraint") or c:IsA("CylindricalConstraint")) and Util.prop(c, "Enabled", true) then
			local a0, a1 = Util.prop(c, "Attachment0"), Util.prop(c, "Attachment1")
			local f0 = Classify.attachmentFrame(a0)
			local f1 = Classify.attachmentFrame(a1)
			if f0 and f1 then
				local axis = f0.RightVector
				if c:IsA("CylindricalConstraint") then
					-- It slides along Attachment0's X and turns about an axis
					-- InclinationAngle from X towards Y.
					axis = (f0 * CFrame.Angles(0, 0, math.rad(Util.prop(c, "InclinationAngle", 0)))).RightVector
				end
				local p0 = if spinsOnAxis(a0.Parent, f0.Position, axis) then a0.Parent else nil
				local p1 = if spinsOnAxis(a1.Parent, f1.Position, axis) then a1.Parent else nil
				if p0 and p1 then
					-- Both round about the axle (a wheel on a stub axle): the bigger one rolls.
					local v0, v1 = p0.Size.X * p0.Size.Y * p0.Size.Z, p1.Size.X * p1.Size.Y * p1.Size.Z
					if v0 >= v1 then
						p1 = nil
					else
						p0 = nil
					end
				end
				if p0 then
					out[p0] = true
				end
				if p1 then
					out[p1] = true
				end
			end
		end
	end
	return out
end

-- The wheels of `model`: list of parts. Markers win; then parts spinning on
-- constraints; names only if nothing spins.
function Classify.wheels(model)
	local parts, constraints = {}, {}
	if model:IsA("BasePart") then
		table.insert(parts, model)
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		elseif d:IsA("Constraint") then
			table.insert(constraints, d)
		end
	end
	local spinning = Classify.spinningParts(constraints)
	local anySpinning = next(spinning) ~= nil
	local out = {}
	for _, p in parts do
		local marker = Util.marker(p, "BuildGuardWheel")
		local isWheel
		if marker ~= nil then
			isWheel = marker
		elseif anySpinning then
			isWheel = spinning[p] == true
		else
			isWheel = Classify.isWheelName(p.Name)
		end
		if isWheel then
			table.insert(out, p)
		end
	end
	return out
end

return Classify
