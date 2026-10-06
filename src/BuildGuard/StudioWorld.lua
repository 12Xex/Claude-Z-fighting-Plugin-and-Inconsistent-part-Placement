--[[
	World adapter backed by the live Roblox workspace. The checks only talk to
	the world through this interface, so tests can swap in a fake one:

	  raycast(origin, direction, ignore?) -> { instance, position, normal } | nil
	      ignore(instance) -> true to skip a hit and keep going
	  partAt(point, ignore?) -> BasePart | nil      (solid shapes only)
	  partsInBox(cframe, size) -> { BasePart }
	  isInsideTerrain(point) -> boolean
	  isTerrain(instance) -> boolean
	  hasTag(instance, tag) -> boolean
	  fillTerrain(cframe, size, materialName) / clearTerrain(cframe, size)
	  terrain                                         (the Terrain instance)
]]

local CollectionService = game:GetService("CollectionService")

local Geometry = require(script.Parent.Geometry)

local StudioWorld = {}

local MAX_SKIPS = 64

function StudioWorld.new(worldRoot)
	worldRoot = worldRoot or workspace
	local terrain = workspace.Terrain
	local self = { terrain = terrain }

	function self.raycast(origin, direction, ignore)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.IgnoreWater = true
		local excluded = {}
		for _ = 1, MAX_SKIPS do
			params.FilterDescendantsInstances = excluded
			local result = worldRoot:Raycast(origin, direction, params)
			if not result then
				return nil
			end
			if ignore and result.Instance ~= terrain and ignore(result.Instance) then
				-- Recast from the same origin with the hit excluded, so the
				-- next hit is still measured from the original start.
				table.insert(excluded, result.Instance)
			else
				return { instance = result.Instance, position = result.Position, normal = result.Normal }
			end
		end
		return nil
	end

	function self.partAt(point, ignore)
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { terrain }
		for _, part in worldRoot:GetPartBoundsInRadius(point, 0.01, params) do
			if not (ignore and ignore(part)) and Geometry.containsPoint(Geometry.solid(part), point) then
				return part
			end
		end
		return nil
	end

	function self.partsInBox(cframe, size)
		return worldRoot:GetPartBoundsInBox(cframe, size)
	end

	-- Terrain is stored in 4-stud voxels. A point counts as inside only when
	-- its voxel is completely full and the voxel above it has terrain too, so
	-- surface voxels (partly full) never cause false alarms; shallow burial is
	-- caught by the ray test instead.
	local function occupancyAt(point)
		local min = Vector3.new(math.floor(point.X / 4) * 4, math.floor(point.Y / 4) * 4, math.floor(point.Z / 4) * 4)
		local region = Region3.new(min, min + Vector3.new(4, 4, 4))
		local materials, occupancies = terrain:ReadVoxels(region, 4)
		local material = materials[1][1][1]
		if material == Enum.Material.Air or material == Enum.Material.Water then
			return 0
		end
		return occupancies[1][1][1]
	end

	function self.isInsideTerrain(point)
		return occupancyAt(point) >= 0.99 and occupancyAt(point + Vector3.new(0, 4, 0)) > 0
	end

	function self.isTerrain(instance)
		return instance == terrain
	end

	function self.hasTag(instance, tag)
		return CollectionService:HasTag(instance, tag)
	end

	function self.fillTerrain(cframe, size, materialName)
		terrain:FillBlock(cframe, size, Enum.Material[materialName or "Grass"])
	end

	function self.clearTerrain(cframe, size)
		terrain:FillBlock(cframe, size, Enum.Material.Air)
	end

	return self
end

return StudioWorld
