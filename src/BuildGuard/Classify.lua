--[[
	What kind of part is this?

	Kind ("Road" | "Rail" | "Track" | nil), in priority order:
	  1. BuildGuardKind attribute ("Road", "Rail", "Track", or "None" to opt out)
	  2. A CollectionService tag named Road, Rail or Track
	  3. The part's name, when Config.classifyByName is on: its FIRST word is
	     one of Config.kindNameWords ("Road_01", "RailYard", "TrackBed"; not
	     "BedRail", "RoofRail" or "Railing"), and the part looks like one:
	       * flat: no thicker than kindMaxThickness of its longest side, and
	         not a panel standing on edge (taller than its shorter side and
	         over a stud tall), so not "RoadSign", "Road_Guardrail" or
	         "StreetLamp"; not a ball, cylinder or corner wedge
	       * upright: its top within 45° of level (a block may be upside
	         down; a wedge's slope must face up), so not a sign facing
	         sideways on a wall or post
	       * not a layered item (markings and signs placed with Layers)
	       * a road is at least ROAD_MIN_WIDTH wide (its shorter side), so
	         not a "StreetLight" head or a "Road_Kerb" strip
	       * not part of a vehicle (`inVehicle`)
	     Tag or mark anything else (a ramp steeper than 45°).

	Ground: Terrain, the BuildGuardGround attribute or tag (on the part or
	any ancestor, the nearest one winning, so a floor folder can be tagged
	once), a flat part whose first name word is in Config.groundNames
	("Baseplate", "Ground_Main"), or (only if groundMinFootprint is above 0)
	a part at least that big.

	Wheels: the BuildGuardWheel attribute or tag (true/false), else parts that
	spin on a HingeConstraint/CylindricalConstraint through their centre along
	their round axis, else (only when a model has none of those) a name whose
	first word is wheel/tire/tyre followed only by position words
	("Wheel_FL", "TireRearLeft"; not "SteeringWheel", "SpareWheel" or
	"WheelArch").

	Ignored: anything at or under an instance with the BuildGuardIgnore
	attribute or tag. It's not scanned, and it never counts as cover, ground
	or a hiding surface.

	Road-like slabs: flat parts with no kind, made of a road material
	(Config.roadLikeMaterials), their top within 10° of level and at least
	1.5 by 6 studs across, are listed in the report, so roads, yards and
	shoulders nobody named don't go unchecked silently. Under 4 studs
	across, only strips to drive along (at least 12 long and 6 times longer
	than wide: shoulders, lanes) and slabs named like a road are, so steps,
	lintels, shelves and planks aren't. Not listed: slabs the roads resting
	on them cover (footings, plinths). BuildGuardKind = "None" on a part or
	any ancestor leaves it off that list.
]]

local Util = require(script.Parent.Util)
local Geometry = require(script.Parent.Geometry)
local SpatialHash = require(script.Parent.SpatialHash)

local Classify = {}

local KINDS = { Road = true, Rail = true, Track = true }
-- The setting that says how far above the ground (or a support) each kind
-- rests.
Classify.LIFT_KEY = { Road = "roadLift", Rail = "railLift", Track = "trackLift" }

-- A part named as a road must be at least this wide (studs, its shorter
-- side) to count as one.
Classify.ROAD_MIN_WIDTH = 4
-- ...and its top within 45° of level (or of upside down). Float CFrames
-- land a hair under cos 45° at exactly 45°.
local NAME_MIN_UP = math.cos(math.rad(45)) - 1e-4

-- Is `part` flat enough to be a road/rail/track or ground by its name?
function Classify.isFlat(part, config)
	if part:IsA("Part") then
		local shape = Util.prop(part, "Shape")
		if shape and (shape.Name == "Ball" or shape.Name == "Cylinder") then
			return false
		end
	end
	local size = part.Size
	if size.Y > config.kindMaxThickness * math.max(size.X, size.Z) then
		return false
	end
	-- A panel standing on edge (a sign, a barrier). Rails are taller than
	-- they're wide, but under a stud.
	return not (size.Y > math.min(size.X, size.Z) and size.Y > 1)
end

-- The kind `part`'s name says: its first word is in a rule of
-- config.kindNameWords. Nil if none.
local function namedKind(part, config)
	local first = Util.words(part.Name)[1]
	if not first then
		return nil
	end
	for _, rule in config.kindNameWords do
		if table.find(rule.words, first) then
			return rule.kind
		end
	end
	return nil
end

-- Does `part`'s shape and placement fit a `kind` named by its name?
local function looksLike(part, kind, config)
	if Classify.isLayered(part) or not Classify.isFlat(part, config) then
		return false
	end
	local shape = Geometry.shapeOf(part)
	if shape == "CornerWedge" then
		return false
	end
	local size, cf = part.Size, part.CFrame
	-- A box looks the same either way up; a wedge upside down has no top.
	local up = if shape == "Wedge"
		then cf:VectorToWorldSpace(Vector3.new(0, size.Z, -size.Y).Unit).Y
		else math.abs(cf.UpVector.Y)
	if up < NAME_MIN_UP then
		return false
	end
	return kind ~= "Road" or math.min(size.X, size.Z) >= Classify.ROAD_MIN_WIDTH
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
	local kind = namedKind(part, config)
	if not kind or not looksLike(part, kind, config) or (inVehicle and inVehicle(part)) then
		return nil
	end
	return kind
end

-- Items placed with Layers (markings, signs, trim) carry this attribute.
function Classify.isLayered(part)
	return part:GetAttribute("BuildGuardLayer") ~= nil
end

local UNMARKED = {}

-- BuildGuardGround on `instance` or its nearest marked ancestor: true,
-- false or nil (not set). Pass a table as `cache` to reuse answers.
function Classify.groundMarker(instance, cache)
	cache = cache or {}
	local chain = {}
	local node = instance
	local result = UNMARKED
	while node do
		local known = cache[node]
		if known ~= nil then
			result = known
			break
		end
		table.insert(chain, node)
		local marker = Util.marker(node, "BuildGuardGround")
		if marker ~= nil then
			result = marker
			break
		end
		node = node.Parent
	end
	for _, n in chain do
		cache[n] = result
	end
	if result == UNMARKED then
		return nil
	end
	return result
end

-- Terrain and parts marked or named as ground. `cache` (optional) is
-- passed to Classify.groundMarker.
function Classify.isGroundLike(instance, config, cache)
	if instance:IsA("Terrain") then
		return true
	end
	if not instance:IsA("BasePart") then
		return false
	end
	local marker = Classify.groundMarker(instance, cache)
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

--------------------------------------------------------------------------------
-- Road-like slabs nothing checks
--------------------------------------------------------------------------------

-- Is `instance` at or under an instance whose BuildGuardKind is "None"?
-- Pass a table as `cache` to reuse answers across calls.
function Classify.optedOut(instance, cache)
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
		if node:GetAttribute("BuildGuardKind") == "None" then
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

-- A slab for the note is at least this wide and this long (studs, its
-- shorter and longer horizontal sides): shoulders and lanes count, kerbs
-- and stepping slabs don't.
Classify.NOTE_MIN_WIDTH = 1.5
Classify.NOTE_MIN_LENGTH = 6
-- Under ROAD_MIN_WIDTH across, a slab counts only when it's a strip to
-- drive along, at least this long and this many times longer than wide
-- (a 3x40 shoulder, not a step or a shelf), or is named like a road.
Classify.NOTE_STRIP_LENGTH = 12
Classify.NOTE_STRIP_RATIO = 6
-- ...and its top within this many degrees of level, so pitched roofs don't.
Classify.NOTE_MAX_TILT = 10
local NOTE_MIN_UP = math.cos(math.rad(Classify.NOTE_MAX_TILT)) - 1e-4
-- A slab holds a road up (a footing, a plinth) when the roads resting on
-- it (their bottom within 0.5 studs of its top, plus their kind's lift if
-- positive) cover its top: it lies within one road's footprint plus this
-- margin (studs), or its top's area is at most FOOTING_COVER times the
-- area they cover.
Classify.FOOTING_MARGIN = 1
Classify.FOOTING_COVER = 1.2

-- The plane of a solid's face that's up: a point on it and its normal (a
-- wedge's slope runs through its centre; a block may be upside down).
local function topPlane(s)
	if s.shape == "Wedge" then
		return s.pos, s.cf:VectorToWorldSpace(Vector3.new(0, s.size.Z, -s.size.Y).Unit)
	end
	local up = if s.axes[2].Y < 0 then -s.axes[2] else s.axes[2]
	return s.pos + up * s.half.Y, up
end

-- Is solid `s` shaped like a slab to drive on? Flat by the name rules,
-- not a corner wedge or a layered item, its top within NOTE_MAX_TILT of
-- level, and at least NOTE_MIN_WIDTH by NOTE_MIN_LENGTH across. Under
-- ROAD_MIN_WIDTH across, only a strip (NOTE_STRIP_LENGTH long and
-- NOTE_STRIP_RATIO times longer than wide) or a slab named like a road
-- (its first word one of kindNameWords).
local function slabLike(s, config)
	local part = s.part
	if s.shape == "CornerWedge" or Classify.isLayered(part) or not Classify.isFlat(part, config) then
		return false
	end
	local _, up = topPlane(s)
	if up.Y < NOTE_MIN_UP then
		return false
	end
	local width, length = math.min(s.size.X, s.size.Z), math.max(s.size.X, s.size.Z)
	if width < Classify.NOTE_MIN_WIDTH or length < Classify.NOTE_MIN_LENGTH then
		return false
	end
	return width >= Classify.ROAD_MIN_WIDTH
		or (length >= Classify.NOTE_STRIP_LENGTH and length >= Classify.NOTE_STRIP_RATIO * width)
		or namedKind(part, config) ~= nil
end

-- The two axes of `s` nearest level (indexes into s.axes) and their half sizes.
local function levelAxes(s)
	local half = { s.half.X, s.half.Y, s.half.Z }
	local up = 1
	for i = 2, 3 do
		if math.abs(s.axes[i].Y) > math.abs(s.axes[up].Y) then
			up = i
		end
	end
	local a, b = up % 3 + 1, (up + 1) % 3 + 1
	return a, b, half[a], half[b]
end

-- `s`'s outline seen from above, as { x, z } points.
local function footprint(s)
	local a, b, ha, hb = levelAxes(s)
	local u, v = s.axes[a] * ha, s.axes[b] * hb
	local out = {}
	for _, st in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local p = s.pos + u * st[1] + v * st[2]
		table.insert(out, { p.X, p.Z })
	end
	return out, a, b
end

-- Do roads/rails/tracks (among `kinded`, found through `hash`, each
-- resting its `lifts[i]` above a support) resting on `s`'s top cover it, so
-- `s` holds them up (a footing, a plinth)? A sunk road reaches below that
-- top; one resting on it starts at it, or its lift above it. A yard or
-- turnaround a road runs onto isn't covered.
local function holdsUpKind(s, hash, kinded, lifts)
	local outline = footprint(s)
	local area = Geometry.polygonArea(outline)
	local point, normal = topPlane(s)
	local reach = Classify.FOOTING_MARGIN + 0.05 -- float32 CFrames far out
	local covered = 0
	for _, i in hash:query(s.min, s.max + Vector3.new(0, 0.5, 0)) do
		local k = kinded[i]
		local kOutline, a, b = footprint(k)
		local overlap = Geometry.clipPolygon(outline, kOutline)
		local overlapArea = if #overlap >= 3 then Geometry.polygonArea(overlap) else 0
		if overlapArea > 1e-3 then
			-- The top's height where they overlap.
			local x, z = 0, 0
			for _, p in overlap do
				x += p[1] / #overlap
				z += p[2] / #overlap
			end
			local topY = point.Y - (normal.X * (x - point.X) + normal.Z * (z - point.Z)) / normal.Y
			if k.min.Y <= topY + 0.5 + lifts[i] and k.max.Y >= topY then
				-- Within the road's footprint plus the margin, corner by corner.
				local half = { k.half.X, k.half.Y, k.half.Z }
				local within = true
				for _, corner in outline do
					local lp = k.cf:PointToObjectSpace(Vector3.new(corner[1], topY, corner[2]))
					local c = { lp.X, lp.Y, lp.Z }
					if math.abs(c[a]) > half[a] + reach or math.abs(c[b]) > half[b] + reach then
						within = false
						break
					end
				end
				if within then
					return true
				end
				covered += overlapArea
			end
		end
	end
	return area <= Classify.FOOTING_COVER * covered
end

-- Flat slabs that look like road surfaces but that no check treats as a
-- road, rail or track, in scan order: flat by the name rules, not a corner
-- wedge, top within NOTE_MAX_TILT of level, at least NOTE_MIN_WIDTH by
-- NOTE_MIN_LENGTH across (a strip or named like a road when under
-- ROAD_MIN_WIDTH: see slabLike), and made of a material in
-- config.roadLikeMaterials. Left out: ground, layered and ignored parts,
-- vehicle parts, anything at or under an instance with BuildGuardKind =
-- "None", and slabs the roads/rails/tracks resting on them cover (a
-- footing, a plinth: see holdsUpKind). Reads properties only: no raycasts.
function Classify.unclassified(ctx)
	local config = ctx.config
	local materials = {}
	for _, name in config.roadLikeMaterials do
		materials[name] = true
	end
	local groundCache, noneCache = {}, {}
	local hash, kinded, lifts = nil, nil, nil
	local out = {}
	for i, s in ctx.solids do
		local part = s.part
		local material = Util.prop(part, "Material")
		if
			material
			and materials[material.Name]
			and not ctx.kindOf(part)
			and slabLike(s, config)
			and not Classify.isGroundLike(part, config, groundCache)
			and not ctx.isIgnored(part)
			and not Classify.optedOut(part, noneCache)
			and not ctx.vehicleOf(part)
		then
			if not hash then
				hash, kinded, lifts = SpatialHash.new(16), {}, {}
				for _, other in ctx.solids do
					local kind = ctx.kindOf(other.part)
					if kind then
						-- Its box reaches down by its lift, to the support it rests on.
						local lift = math.max(ctx.configFor(other.part)[Classify.LIFT_KEY[kind]], 0)
						table.insert(kinded, other)
						table.insert(lifts, lift)
						hash:insert(#kinded, other.min - Vector3.new(0, lift, 0), other.max)
					end
				end
			end
			if not holdsUpKind(s, hash, kinded, lifts) then
				table.insert(out, part)
			end
		end
		if i % 2000 == 0 then
			ctx.yield()
		end
	end
	return out
end

-- How many listed slabs to name in the report line.
Classify.UNCLASSIFIED_SHOWN = 10

-- The report line for Classify.unclassified's `parts` (`pathOf` names them).
function Classify.describeUnclassified(parts, pathOf)
	local counts, names = {}, {}
	for _, part in parts do
		local material = Util.prop(part, "Material")
		local name = if material then material.Name else "?"
		if not counts[name] then
			counts[name] = 0
			table.insert(names, name)
		end
		counts[name] += 1
	end
	table.sort(names, function(a, b)
		if counts[a] ~= counts[b] then
			return counts[a] > counts[b]
		end
		return a < b
	end)
	local shown = {}
	for i = 1, math.min(#parts, Classify.UNCLASSIFIED_SHOWN) do
		shown[i] = pathOf(parts[i])
	end
	return ("%d flat slab(s) look like road surfaces (%s) but aren't checked as roads: %s%s — name or tag them Road/Rail/Track (or set BuildGuardKind), or set BuildGuardKind = \"None\" on them or their folder if they aren't roads"):format(
		#parts,
		table.concat(names, ", "),
		table.concat(shown, ", "),
		if #parts > #shown then (" (first %d)"):format(#shown) else ""
	)
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
