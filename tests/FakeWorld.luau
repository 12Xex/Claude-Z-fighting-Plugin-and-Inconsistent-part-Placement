--[[
	A world adapter for tests: brute-force raycasts against the parts under a
	root folder, plus box-shaped "terrain" blocks. Same interface as
	src/BuildGuard/StudioWorld.lua.
]]

local roblox = require("@lune/roblox")

local FakeWorld = {}

function FakeWorld.new(root, Geometry)
	local terrain = roblox.Instance.new("Folder")
	terrain.Name = "Terrain"
	local blocks = {}
	local self = { terrain = terrain, blocks = blocks }

	local function solids()
		local out = {}
		for _, d in root:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(out, Geometry.solid(d))
			end
		end
		return out
	end

	function self.raycast(origin, direction, ignore)
		local length = direction.Magnitude
		local unit = direction.Unit
		local best, bestInstance
		for _, s in solids() do
			if not (ignore and ignore(s.part)) then
				local t = Geometry.rayBox(s, origin, unit, length)
				if t and (not best or t < best) then
					best, bestInstance = t, s.part
				end
			end
		end
		for _, b in blocks do
			local t = Geometry.rayBox(b, origin, unit, length)
			if t and (not best or t < best) then
				best, bestInstance = t, terrain
			end
		end
		if best then
			return { instance = bestInstance, position = origin + unit * best, normal = -unit }
		end
		return nil
	end

	function self.partAt(point, ignore)
		for _, s in solids() do
			if not (ignore and ignore(s.part)) and Geometry.containsPoint(s, point) then
				return s.part
			end
		end
		return nil
	end

	function self.partsInBox(cframe, size)
		local q = Geometry.solidFrom(cframe, size, "Block")
		local out = {}
		for _, s in solids() do
			if
				s.min.X <= q.max.X
				and q.min.X <= s.max.X
				and s.min.Y <= q.max.Y
				and q.min.Y <= s.max.Y
				and s.min.Z <= q.max.Z
				and q.min.Z <= s.max.Z
			then
				table.insert(out, s.part)
			end
		end
		return out
	end

	function self.isInsideTerrain(point)
		for _, b in blocks do
			if Geometry.containsPoint(b, point) then
				return true
			end
		end
		return false
	end

	self.isSolidTerrain = self.isInsideTerrain

	function self.isTerrain(instance)
		return instance == terrain
	end

	function self.fillTerrain(cframe, size)
		table.insert(blocks, Geometry.solidFrom(cframe, size, "Block"))
	end

	-- Mesh triangles: tests register them per part, in the part's local space
	-- (studs, already fitted to its Size). Studio reads them from EditableMesh.
	local meshes = {}
	function self.setMeshTriangles(part, triangles)
		meshes[part] = triangles
	end
	function self.meshTriangles(part)
		local triangles = meshes[part]
		if not triangles then
			return nil, "mesh not loadable"
		end
		return triangles
	end

	-- Collision groups: everything collides unless a test says otherwise.
	self.nonColliding = {}
	function self.groupsCollide(a, b)
		return not (self.nonColliding[a .. "|" .. b] or self.nonColliding[b .. "|" .. a])
	end

	-- Scans call this between chunks of work; tests count the calls.
	self.yields = 0
	function self.yield()
		self.yields += 1
	end

	function self.clearTerrain(cframe)
		for i = #blocks, 1, -1 do
			if (blocks[i].pos - cframe.Position).Magnitude < 1e-3 then
				table.remove(blocks, i)
			end
		end
	end

	return self
end

return FakeWorld
