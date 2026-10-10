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

	A check comparing two parts (a road join, a z-fighting pair) uses the
	settings of the smallest instance containing both. A model's overrides
	cover joins inside it; where it meets roads outside it, the outside
	settings apply.

	Z-fighting detection (tolerance, minimum overlap, ignored transparency) is
	global: no model can loosen it. A model can tighten it for distance
	viewing with zFightViewDistance.

	Place-wide settings are attributes on `workspace` (BG.setProjectConfig).
	They also apply to models outside workspace (ServerStorage, a clone that
	isn't parented yet), under any settings of their own.

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
	-- Distance (studs) the model is seen from. Above 0, same-facing faces
	-- must be at least Config.faceGap apart (bigger than zFightNudge far
	-- away, where the depth buffer is coarser), fixes leave that gap, and
	-- layers lift at least that much. 0 = off.
	zFightViewDistance = 0,

	-- Meshes ---------------------------------------------------------------------
	-- Read MeshPart triangles through EditableMesh (meshes the place's owner
	-- can load), so z-fighting is checked on the real surface. Other meshes
	-- and unions are only checked by box (duplicates and overlapping boxes,
	-- not z-fighting), and the report says how many.
	meshTriangles = true,
	-- Meshes with more triangles than this are checked by box only.
	meshTriangleLimit = 20000,
	-- Two mesh/union boxes in the same orientation that share at least this
	-- fraction of their volume (intersection over union) are flagged: a
	-- likely double import or a z-fighting copy.
	meshOverlapRatio = 0.9,

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
	-- A buried part looks this far up for open air (the surface it should sit
	-- on). Parts in open air never look up, so tunnels are safe...
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
	-- Minimum clear height above each kind's surface (tunnel roofs, bridges).
	-- 0 turns the check off. Set from your vehicle: BG.checkVehicle suggests it.
	roadHeadroom = 0,
	railHeadroom = 0,
	trackHeadroom = 0,
	-- Spacing (studs) of the sample grid across a part's surface for the
	-- buried check and snapping.
	sampleSpacing = 2,

	-- Drivability lint (roads and rails) --------------------------------------
	maxLedge = 1, -- studs of step between connected surfaces (truck-tested)
	maxRouteSlope = 20, -- degrees: steepest any road/rail surface may tilt
	maxSlopeChange = 20, -- degrees between connected surfaces (crests, dips)
	minRoadWidth = 22, -- studs: the approved haul road (two trucks pass)
	-- Kinds whose free edges are checked for the step up from the ground
	-- beside them (grass onto the road).
	edgeLedgeKinds = { "Road" },
	-- How far outside a road edge the ground beside it is measured.
	edgeProbe = 0.5,
	-- Road parts whose top surfaces are within this horizontal distance count
	-- as connected.
	connectMargin = 0.1,
	-- Surfaces further apart vertically than this are an overpass, not a ledge.
	connectMaxStep = 4,

	-- Classification -----------------------------------------------------------
	-- Set false to classify roads/rails/tracks by tag or attribute only.
	classifyByName = true,
	-- A part's name says its kind when its FIRST word is one of these (words
	-- split at capitals, digits and punctuation: "RoadSign" is road + sign).
	-- Checked in this order. Tags (CollectionService) and the BuildGuardKind
	-- attribute take priority, and parts inside vehicles never count by name.
	kindNameWords = {
		{ kind = "Track", words = { "track", "tracks", "trackbed" } },
		{ kind = "Rail", words = { "rail", "rails", "railroad", "railway" } },
		{ kind = "Road", words = { "road", "roads", "roadway", "street", "highway" } },
	},
	-- ...and it is flat: no thicker (local Y) than this fraction of its
	-- longest side, so "StreetLamp" poles don't count (Classify.lua has the
	-- other rules: no standing panels, top near level, not layered...).
	kindMaxThickness = 0.5,
	-- Kinds the drivability lint applies to (pairs are only compared within a kind).
	drivableKinds = { "Road", "Rail" },
	-- Flat parts whose first name word is one of these are ground surfaces.
	-- Prefer the BuildGuardGround tag or attribute.
	groundNames = { "baseplate", "ground", "terrain" },
	-- Parts with an X and Z footprint at least this big also count as ground.
	-- 0 = off (a big floor slab or roof isn't ground; tag real ground).
	groundMinFootprint = 0,
}

-- Per-key rules. `scope = "global"` keys can't be set by attributes: tables,
-- settings about other parts, and z-fighting detection.
Config.schema = {
	zFightTolerance = { scope = "global", min = 0.001, max = 0.1 },
	zFightMinOverlapArea = { scope = "global", min = 0, max = 10 },
	zFightNudge = { min = 0.002, max = 0.5 },
	zFightIgnoreTransparency = { scope = "global", min = 0, max = 1 },
	zFightViewDistance = { min = 0, max = 5000 },
	meshTriangles = { scope = "global", type = "boolean" },
	meshTriangleLimit = { scope = "global", min = 0, max = 1e6 },
	meshOverlapRatio = { scope = "global", min = 0.5, max = 1 },
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
	roadHeadroom = { min = 0, max = 500 },
	railHeadroom = { min = 0, max = 500 },
	trackHeadroom = { min = 0, max = 500 },
	maxLedge = { min = 0, max = 50 },
	maxSlopeChange = { min = 0, max = 90 },
	maxRouteSlope = { min = 0, max = 90 },
	minRoadWidth = { min = 0, max = 1000 },
	edgeLedgeKinds = { scope = "global" },
	edgeProbe = { min = 0.05, max = 4 },
	classifyByName = { scope = "global", type = "boolean" },
	kindNameWords = { scope = "global" },
	kindMaxThickness = { scope = "global", min = 0.01, max = 10 },
	connectMargin = { min = 0, max = 5 },
	connectMaxStep = { min = 0.1, max = 100 },
	groundNames = { scope = "global" },
	drivableKinds = { scope = "global" },
	groundMinFootprint = { scope = "global", min = 0, max = 1e6 },
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
	if spec.type == "boolean" then
		if type(value) ~= "boolean" then
			return false, ("%s must be true or false, got %s"):format(key, tostring(value))
		end
	elseif spec.min ~= nil then
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

-- The instance holding place-wide settings: workspace in Studio, nil elsewhere.
function Config.place()
	if game then
		return workspace
	end
	return nil
end

-- Resolves the effective config for any instance from `base` plus attributes
-- on it and its ancestors. Caches per instance, so make a new one per scan.
-- `place` (default Config.place()) holds place-wide settings: they apply
-- under everything, including instances outside it.
--   resolver.resolve(instance) -> config, sources (key -> instance that set it)
--   resolver.errors            -> invalid attributes seen so far
--   resolver.owners            -> instances seen carrying valid overrides
--                                 (the place first, when it has any)
function Config.resolver(base, place)
	local cache = {}
	local self = { errors = {}, owners = {} }
	if place == nil then
		place = Config.place()
	end

	-- `instance`'s own overrides on top of what it inherits. A zFightNudge
	-- not above zFightTolerance is dropped on its own; the rest still apply.
	local function overlay(instance, config, sources)
		local own, errors = Config.ownOverrides(instance)
		for _, e in errors do
			table.insert(self.errors, e)
		end
		if own.zFightNudge ~= nil then
			local ok, message = checkNudge({ zFightNudge = own.zFightNudge, zFightTolerance = config.zFightTolerance })
			if not ok then
				own.zFightNudge = nil
				table.insert(self.errors, { instance = instance, attribute = Config.ATTRIBUTE_PREFIX .. "zFightNudge", message = message })
			end
		end
		if next(own) == nil then
			return config, sources
		end
		local merged, mergedSources = table.clone(config), table.clone(sources)
		for key, value in own do
			merged[key] = value
			mergedSources[key] = instance
		end
		table.insert(self.owners, instance)
		return merged, mergedSources
	end

	local rootConfig, rootSources = base, {}
	if place then
		rootConfig, rootSources = overlay(place, base, {})
	end

	function self.resolve(instance)
		if instance == nil then
			return rootConfig, rootSources
		end
		local hit = cache[instance]
		if hit then
			return hit[1], hit[2]
		end
		local config, sources = self.resolve(instance.Parent)
		-- The place's own settings are already under everything.
		if instance ~= place then
			config, sources = overlay(instance, config, sources)
		end
		cache[instance] = { config, sources }
		return config, sources
	end

	return self
end

-- Smallest gap two same-facing faces need to not flicker for `config`:
-- zFightNudge, or more when the model is seen from zFightViewDistance.
-- Depth precision assumed is the worst case among Roblox's renderers: a
-- 24-bit depth buffer with a 0.1-stud near plane (older Android/GLES
-- phones; desktop and most iOS use a float reversed-Z buffer that is far
-- finer). One depth step at distance d is d² / (0.1 × 2^24), and the gap
-- needs two: 0.02 holds to about 130 studs, 0.05 to 205, 0.107 to 300.
Config.NEAR_PLANE = 0.1
Config.DEPTH_STEPS = 2 ^ 24
function Config.depthStep(distance)
	return distance * distance / (Config.NEAR_PLANE * Config.DEPTH_STEPS)
end
function Config.faceGap(config)
	local distance = config.zFightViewDistance or 0
	if distance <= 0 then
		return config.zFightNudge
	end
	return math.max(config.zFightNudge, 2 * Config.depthStep(distance))
end

-- The smallest instance that contains both `a` and `b` (or nil).
function Config.commonAncestor(a, b)
	local seen = {}
	local node = a
	while node do
		seen[node] = true
		node = node.Parent
	end
	node = b
	while node do
		if seen[node] then
			return node
		end
		node = node.Parent
	end
	return nil
end

return Config
