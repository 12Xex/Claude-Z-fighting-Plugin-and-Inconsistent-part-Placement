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

	-- Solids are cached per part and rebuilt only when its CFrame or Size
	-- changes; a coarse grid over their boxes narrows each query. Every query
	-- still walks the root, so parts added, moved or removed between queries
	-- are seen.
	local CELL = 32
	local isPart = setmetatable({}, { __mode = "k" })
	local cached = setmetatable({}, { __mode = "k" })
	local list, grid = {}, {}
	local function cellRange(min, max)
		return math.floor(min.X / CELL), math.floor(min.Z / CELL), math.floor(max.X / CELL), math.floor(max.Z / CELL)
	end
	local function refresh()
		local fresh, changed = {}, false
		for _, d in root:GetDescendants() do
			local partLike = isPart[d]
			if partLike == nil then
				partLike = d:IsA("BasePart")
				isPart[d] = partLike
			end
			if partLike then
				local cf, size = d.CFrame, d.Size
				local c = cached[d]
				if not c or c.cf ~= cf or c.size ~= size then
					c = { cf = cf, size = size, solid = Geometry.solid(d) }
					cached[d] = c
					changed = true
				end
				table.insert(fresh, c.solid)
				if list[#fresh] ~= c.solid then
					changed = true
				end
			end
		end
		if changed or #fresh ~= #list then
			list, grid = fresh, {}
			for index, s in fresh do
				local x0, z0, x1, z1 = cellRange(s.min, s.max)
				for x = x0, x1 do
					for z = z0, z1 do
						local key = x * 65536 + z
						grid[key] = grid[key] or {}
						table.insert(grid[key], index)
					end
				end
			end
		end
	end
	-- The solids whose boxes may touch the box min..max, in child order.
	local function near(min, max)
		refresh()
		local x0, z0, x1, z1 = cellRange(min, max)
		if (x1 - x0 + 1) * (z1 - z0 + 1) > 4 * #list then
			return list
		end
		local seen, indices = {}, {}
		for x = x0, x1 do
			for z = z0, z1 do
				for _, index in grid[x * 65536 + z] or {} do
					if not seen[index] then
						seen[index] = true
						table.insert(indices, index)
					end
				end
			end
		end
		table.sort(indices)
		local out = table.create(#indices)
		for i, index in indices do
			out[i] = list[index]
		end
		return out
	end

	function self.raycast(origin, direction, ignore)
		local length = direction.Magnitude
		local unit = direction.Unit
		local finish = origin + direction
		local best, bestInstance
		for _, s in near(origin:Min(finish), origin:Max(finish)) do
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
		for _, s in near(point, point) do
			if not (ignore and ignore(s.part)) and Geometry.containsPoint(s, point) then
				return s.part
			end
		end
		return nil
	end

	function self.partsInBox(cframe, size)
		local q = Geometry.solidFrom(cframe, size, "Block")
		local out = {}
		for _, s in near(q.min, q.max) do
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
