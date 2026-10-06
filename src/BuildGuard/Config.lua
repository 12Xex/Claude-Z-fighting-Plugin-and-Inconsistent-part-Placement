--[[
	BuildGuard configuration.

	Every number the checks and fixes use lives here, so a build can be audited
	against one agreed set of values. Override per call with
	`BuildGuard.scan(root, { config = { maxLedge = 0.3 } })`.

	Values marked PROVISIONAL are placeholders that still need sign-off.
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
	-- layer 1 = 0.02, layer 2 = 0.04, ...
	layerLift = 0.02,

	-- Roads / rails / tracks ---------------------------------------------------
	-- Gap left between a snapped road or rail and the ground surface under it.
	groundLift = 0.05,
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

	-- Drivability lint (roads only) -------------------------------------------
	-- PROVISIONAL: replace with the agreed numbers.
	maxLedge = 0.5, -- studs of step between connected road surfaces
	maxSlopeChange = 15, -- degrees between connected road surfaces
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
	-- Parts with these names (case-insensitive) are ground surfaces.
	groundNames = { "baseplate", "ground", "terrain" },
	-- Parts with an X and Z footprint at least this big are also ground.
	groundMinFootprint = 512,
}

-- Returns a new config table: defaults overlaid with `overrides`.
function Config.merge(overrides)
	local result = table.clone(Config.defaults)
	if overrides then
		for key, value in overrides do
			if Config.defaults[key] == nil then
				error(("BuildGuard: unknown config key %q"):format(tostring(key)), 2)
			end
			result[key] = value
		end
	end
	if result.zFightNudge <= result.zFightTolerance then
		error("BuildGuard: zFightNudge must be larger than zFightTolerance", 2)
	end
	return result
end

return Config
