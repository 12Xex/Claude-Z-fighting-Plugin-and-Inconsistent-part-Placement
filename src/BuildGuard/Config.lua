--[[
	BuildGuard configuration.

	Every number the checks and fixes use lives here. Three layers, later ones
	winning:

	  1. Config.defaults (this file)
	  2. `options.config` passed to a call, e.g. BG.scan(root, { config = {...} })
	  3. Attributes named "BuildGuard_<key>" on the part or any ancestor
	     (model, folder, workspace). The nearest one wins, so a model can carry
	     its own limits and workspace attributes act as place-wide settings.
	     Set them with BG.setConfig(instance, { key = value }, reason).

	Checks that compare two parts combine the two parts' settings per key (see
	`pair` in the schema): z-fighting always takes the stricter value, and the
	drivability limits take the looser one, so a model allowed steeper joins
	also governs its joins to roads outside it.

	Project numbers (roads, rails, layers, drivability) were approved for the
	mining game; see README "Values".
]]

local Config = {}

Config.defaults = {
	-- Z-fighting ---------------------------------------------------------------
	-- Two faces z-fight when they face the same way, lie within this distance of
	-- each other and overlap.
	zFightTolerance = 0.01,
	-- Overlaps smaller than this (studs²) are edge contacts, not z-fighting.
	zFightMinOverlapArea = 0.01,
	-- Separation a fix nudge leaves between the two faces. Must be larger than
	-- zFightTolerance so the re-scan comes back clean.
	zFightNudge = 0.02,
	-- Parts at or above this transparency are invisible and can't z-fight.
	zFightIgnoreTransparency = 0.99,

	-- Layer offsets (road markings, signs, trim) ------------------------------
	-- Each layer sits this far above the surface it's placed on:
	-- layer 1 = 0.05, layer 2 = 0.1, ...
	layerLift = 0.05,

	-- Roads / rails / tracks ---------------------------------------------------
	-- Gap left between a snapped part and the surface under it, per kind.
	roadLift = 0.1,
	railLift = 0.2, -- rails above their road/track bed
	trackLift = 0.1,
	groundLift = 0.1, -- anything else you snap
	-- Horizontal grid for laying out roads, rails and buildings (BG.snapToGrid).
	-- Matches Roblox's 4-stud terrain voxels. Never applied to heights or detail.
	gridSize = 4,
	-- A road or rail is "off the ground" when its snap would move it more than
	-- this far, up or down.
	groundTolerance = 0.1,
	-- Snapping looks for ground starting this far above the part's top surface
	-- (so a part sunk into the ground still finds the surface above it)...
	snapSearchUp = 20,
	-- ...and down to this far below the part.
	snapSearchDown = 500,
	-- Parts tilted more than this are slopes/ramps. They aren't auto-snapped or
	-- checked for ground contact (a ramp is meant to leave the ground).
	flatTiltDegrees = 5,
	-- Anything occupying the space this high above a road/rail top surface is
	-- burying it. Thin things lying on the surface (markings) sit below it.
	buriedProbeHeight = 0.25,
	-- How far above the surface we look for something covering it.
	buriedClearance = 3,
	-- Spacing (studs) of the sample grid across a part's surface for the
	-- buried check and snapping.
	sampleSpacing = 2,

	-- Drivability lint (roads and rails) --------------------------------------
	maxLedge = 1, -- studs of step between connected surfaces (truck-tested)
	maxRouteSlope = 20, -- degrees: steepest any road/rail surface may tilt
	maxSlopeChange = 20, -- degrees between connected surfaces (crests, dips)
	minRoadWidth = 16, -- studs: one truck plus passing room
	-- Road parts whose top surfaces are within this horizontal distance count
	-- as connected.
	connectMargin = 0.1,
	-- Surfaces further apart vertically than this are an overpass, not a ledge.
	connectMaxStep = 4,

	-- Classification -----------------------------------------------------------
	-- Lowercase name fragments, checked in this order (so "Railroad" is a Rail).
	-- Tags (CollectionService) or the BuildGuardKind attribute take priority.
	kindNamePatterns = {
		{ kind = "Track", patterns = { "track" } },
		{ kind = "Rail", patterns = { "rail" }, exclude = { "railing", "guardrail", "handrail" } },
		{ kind = "Road", patterns = { "road", "street", "highway" } },
	},
	-- Kinds the drivability lint applies to (pairs are only compared within a kind).
	drivableKinds = { "Road", "Rail" },
	-- Parts with these names (case-insensitive) are ground surfaces.
	groundNames = { "baseplate", "ground", "terrain" },
	-- Parts with an X and Z footprint at least this big are also ground.
	groundMinFootprint = 512,
}

-- Per-key rules. `scope = "global"` keys can't be set by attributes (tables,
-- or settings about other parts). `pair` is how two parts' values combine.
Config.schema = {
	zFightTolerance = { min = 0.001, max = 0.1, pair = "max" },
	zFightMinOverlapArea = { min = 0, max = 10, pair = "min" },
	zFightNudge = { min = 0.002, max = 0.5, pair = "max" },
	zFightIgnoreTransparency = { min = 0, max = 1 },
	layerLift = { min = 0.002, max = 0.5 },
	roadLift = { min = 0, max = 2 },
	railLift = { min = 0, max = 2 },
	trackLift = { min = 0, max = 2 },
	groundLift = { min = 0, max = 2 },
	gridSize = { min = 0.05, max = 512 },
	groundTolerance = { min = 0.01, max = 10 },
	snapSearchUp = { min = 0, max = 1000 },
	snapSearchDown = { min = 1, max = 10000 },
	flatTiltDegrees = { min = 0, max = 45 },
	buriedProbeHeight = { min = 0.01, max = 10 },
	buriedClearance = { min = 0.1, max = 100 },
	sampleSpacing = { min = 0.25, max = 50 },
	maxLedge = { min = 0, max = 50, pair = "max" },
	maxSlopeChange = { min = 0, max = 90, pair = "max" },
	maxRouteSlope = { min = 0, max = 90 },
	minRoadWidth = { min = 0, max = 1000 },
	connectMargin = { min = 0, max = 5, pair = "max" },
	connectMaxStep = { min = 0.1, max = 100, pair = "max" },
	kindNamePatterns = { scope = "global" },
	groundNames = { scope = "global" },
	drivableKinds = { scope = "global" },
	groundMinFootprint = { scope = "global", min = 1, max = 1e6 },
}

Config.ATTRIBUTE_PREFIX = "BuildGuard_"
Config.REASON_ATTRIBUTE = "BuildGuardConfigReason"

-- Is `value` acceptable for `key`? Returns true, or false and a message.
-- `fromAttribute` rejects global keys, which attributes can't set.
function Config.check(key, value, fromAttribute)
	local spec = Config.schema[key]
	if spec == nil then
		return false, ("unknown config key %q"):format(tostring(key))
	end
	if fromAttribute and spec.scope == "global" then
		return false, ("%s can only be set in Config.lua or a call's options, not per model"):format(key)
	end
	if spec.min then
		if type(value) ~= "number" or value ~= value then
			return false, ("%s must be a number, got %s"):format(key, tostring(value))
		end
		if value < spec.min or value > spec.max then
			return false, ("%s must be between %s and %s, got %s"):format(key, spec.min, spec.max, value)
		end
	elseif type(value) ~= "table" then
		return false, ("%s must be a table"):format(key)
	end
	return true
end

local function checkNudge(config)
	if config.zFightNudge <= config.zFightTolerance then
		return false, "zFightNudge must be larger than zFightTolerance"
	end
	return true
end

-- Returns a new config table: defaults overlaid with `overrides`.
function Config.merge(overrides)
	local result = table.clone(Config.defaults)
	if overrides then
		for key, value in overrides do
			local ok, message = Config.check(key, value)
			if not ok then
				error("BuildGuard: " .. message, 2)
			end
			result[key] = value
		end
	end
	local ok, message = checkNudge(result)
	if not ok then
		error("BuildGuard: " .. message, 2)
	end
	return result
end

-- The "BuildGuard_<key>" attributes set directly on `instance`.
-- Returns overrides, errors ({ instance, attribute, message }).
function Config.ownOverrides(instance)
	local overrides, errors = {}, {}
	local prefix = Config.ATTRIBUTE_PREFIX
	for name, value in instance:GetAttributes() do
		if string.sub(name, 1, #prefix) == prefix then
			local key = string.sub(name, #prefix + 1)
			local ok, message = Config.check(key, value, true)
			if ok then
				overrides[key] = value
			else
				table.insert(errors, { instance = instance, attribute = name, message = message })
			end
		end
	end
	return overrides, errors
end

-- Resolves the effective config for any instance from `base` plus attributes
-- on it and its ancestors. Caches per instance, so make a new one per scan.
--   resolver.resolve(instance) -> config, sources (key -> instance that set it)
--   resolver.errors            -> invalid attributes seen so far
--   resolver.owners            -> instances seen carrying valid overrides
function Config.resolver(base)
	local cache = {}
	local self = { errors = {}, owners = {} }
	local emptySources = {}

	function self.resolve(instance)
		if instance == nil then
			return base, emptySources
		end
		local hit = cache[instance]
		if hit then
			return hit[1], hit[2]
		end
		local config, sources = self.resolve(instance.Parent)
		local own, errors = Config.ownOverrides(instance)
		for _, e in errors do
			table.insert(self.errors, e)
		end
		if next(own) then
			local merged, mergedSources = table.clone(config), table.clone(sources)
			for key, value in own do
				merged[key] = value
				mergedSources[key] = instance
			end
			local ok, message = checkNudge(merged)
			if ok then
				config, sources = merged, mergedSources
				table.insert(self.owners, instance)
			else
				table.insert(self.errors, { instance = instance, attribute = "BuildGuard_zFightNudge", message = message })
			end
		end
		cache[instance] = { config, sources }
		return config, sources
	end

	return self
end

-- One config for a check comparing two parts (see `pair` in the schema).
function Config.combine(a, b)
	if a == b then
		return a
	end
	local out = table.clone(a)
	for key, spec in Config.schema do
		if spec.pair == "max" then
			out[key] = math.max(a[key], b[key])
		elseif spec.pair == "min" then
			out[key] = math.min(a[key], b[key])
		end
	end
	return out
end

return Config
