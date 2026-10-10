--[[
	World adapter backed by the live Roblox workspace. The checks only talk to
	the world through this interface, so tests can swap in a fake one
	(tests/FakeWorld.luau):

	  raycast(origin, direction, ignore?) -> { instance, position, normal } | nil
	      ignore(instance) -> true to skip a hit and keep going
	  partAt(point, ignore?) -> BasePart | nil
	      the part the point is inside: primitive shapes exactly, meshes and
	      unions by the shape the engine collides with
	  partsInBox(cframe, size) -> { BasePart }
	  isInsideTerrain(point) -> boolean   (strict: deep inside, for the buried check)
	  isSolidTerrain(point) -> boolean    (loose: voxel at least half full)
	  isTerrain(instance) -> boolean
	  hasTag(instance, tag) -> boolean
	  meshTriangles(part) -> triangles, nil, note? | nil, reason
	      a MeshPart's triangles { a, b, c } (Vector3s, counter-clockwise seen
	      from outside) in the part's local space, in studs, fitted to its Size.
	      Read through EditableMesh, so only meshes the place owner or you can
	      load. Loading a mesh yields; each mesh is loaded once per session.
	      `note` is set when the mesh data isn't centred on its bounds.
	  setMeshTriangles(part, triangles)   gives a part triangles by hand (the
	      test scene's planted mesh, which has no mesh of its own); they win
	      over the part's mesh for this world
	  groupsCollide(groupA, groupB) -> boolean   (collision group names)
	  yield()   waits a frame once about 30 ms of work have passed since the
	            last wait (does nothing where the caller can't yield)
	  fillTerrain(cframe, size, materialName) / clearTerrain(cframe, size)
	  terrain                                         (the Terrain instance)
]]

local AssetService = game:GetService("AssetService")
local CollectionService = game:GetService("CollectionService")

local Geometry = require(script.Parent.Geometry)
local Util = require(script.Parent.Util)

local StudioWorld = {}

local MAX_SKIPS = 64
local EPSILON = 1e-6

--------------------------------------------------------------------------------
-- Yielding: long scans hand Studio a frame every time slice
--------------------------------------------------------------------------------

local TIME_SLICE = 0.03
local lastYield = os.clock()

local function yieldIfDue()
	if os.clock() - lastYield <= TIME_SLICE or not coroutine.isyieldable() then
		return
	end
	pcall(function()
		task.wait()
	end)
	lastYield = os.clock()
end

--------------------------------------------------------------------------------
-- Points inside parts
--------------------------------------------------------------------------------

-- Within 1e-4 studs counts as "returned as-is" (on or inside the surface).
local INSIDE_TOLERANCE = 1e-4

local function insideBox(s, point)
	local lp = s.cf:PointToObjectSpace(point)
	local h = s.half
	return math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z
end

-- Meshes, unions and other shapes Geometry can't model: ask the engine.
-- GetClosestPointOnSurface returns the point itself when it is inside the
-- part's collision shape (which follows the part's CollisionFidelity), and
-- it needs no helper part in the workspace.
local function engineContains(part, point)
	local ok, closest = pcall(function()
		return part:GetClosestPointOnSurface(point)
	end)
	return ok and typeof(closest) == "Vector3" and (closest - point).Magnitude <= INSIDE_TOLERANCE
end

local function contains(part, point)
	local s = Geometry.solid(part)
	if s.shape ~= "Other" then
		return Geometry.containsPoint(s, point)
	end
	return insideBox(s, point) and engineContains(part, point)
end

--------------------------------------------------------------------------------
-- Mesh triangles (EditableMesh)
--------------------------------------------------------------------------------

local REASON = {
	union = "unions have no readable geometry",
	notMesh = "only MeshParts have readable triangles",
	noMesh = "the MeshPart has no mesh",
	noYield = "can't load meshes here (the call can't yield)",
	permission = "no permission to load this mesh (not owned by you or the game owner)",
	budget = "editable memory budget exhausted",
	unsupported = "this Studio version can't read meshes",
	throttled = "mesh loading was throttled; scan again later",
	failed = "mesh failed to load",
}

-- Loaded meshes for the whole Studio session, by mesh URI, so each asset is
-- downloaded once: { corners, center, size } or { failed = reason }.
-- `corners` are mesh-space positions, three per triangle.
local meshCache = {}
local cachedCorners = 0
local MAX_CACHED_CORNERS = 3000000

local function remember(key, entry)
	local count = if entry.corners then #entry.corners else 0
	if cachedCorners + count > MAX_CACHED_CORNERS then
		-- Huge maps: start over rather than hold every mesh in memory.
		table.clear(meshCache)
		cachedCorners = 0
	end
	meshCache[key] = entry
	cachedCorners += count
end

local function vertexPosition(positions, slot, id)
	local p = positions[slot[id]]
	if typeof(p) ~= "Vector3" then
		error("missing vertex position")
	end
	return p
end

-- Faces may be triangles or quads; a quad (1, 2, 3, 4) becomes the two
-- triangles (1, 2, 3) and (1, 3, 4), keeping the winding.
local function addFan(out, vertices, at)
	for k = 2, #vertices - 1 do
		table.insert(out, at(vertices[1]))
		table.insert(out, at(vertices[k]))
		table.insert(out, at(vertices[k + 1]))
	end
end

-- Fast path: two batch calls for the whole mesh.
local function readCornersBatched(em, faces)
	local faceVertices = em:BatchGetFaceAttributes(Enum.MeshAttribute.Vertex, faces)
	local ids, slot = {}, {}
	for _, vertices in faceVertices do
		for _, id in vertices do
			if slot[id] == nil then
				table.insert(ids, id)
				slot[id] = #ids
			end
		end
	end
	local positions = em:BatchGetValues(ids)
	local out = {}
	local function at(id)
		return vertexPosition(positions, slot, id)
	end
	for _, vertices in faceVertices do
		addFan(out, vertices, at)
	end
	return out
end

-- Slow path: one call per face and per vertex.
local function readCornersOneByOne(em, faces)
	local known = {}
	local function at(id)
		local p = known[id]
		if p == nil then
			p = em:GetPosition(id)
			known[id] = p
		end
		return p
	end
	local out = {}
	for _, face in faces do
		addFan(out, em:GetFaceVertices(face), at)
	end
	return out
end

local function readMesh(em)
	local faces = em:GetFaces()
	local ok, corners = pcall(readCornersBatched, em, faces)
	if not ok then
		corners = readCornersOneByOne(em, faces)
	end
	return { corners = corners, center = em:GetCenter(), size = em:GetSize() }
end

-- reason, worth caching? (a throttled load may work next time)
local function failureReason(message)
	local lower = string.lower(tostring(message))
	local function has(text)
		return string.find(lower, text, 1, true) ~= nil
	end
	if has("permission") or has("owned by") then
		return REASON.permission, true
	elseif has("throttl") or has("too many requests") or has("rate limit") then
		return REASON.throttled, false
	elseif has("not a valid member") then
		return REASON.unsupported, true
	end
	return REASON.failed, true
end

-- Downloads a mesh into a temporary EditableMesh, reads it and frees it.
-- Returns data | nil, reason, worth caching?
local function download(content)
	local ok, em = pcall(function()
		return AssetService:CreateEditableMeshAsync(content)
	end)
	if not ok then
		local reason, keep = failureReason(em)
		if reason == REASON.failed then
			warn(("BuildGuard: couldn't load mesh %s (%s); it is checked by its box only"):format(
				tostring(content.Uri),
				tostring(em)
			))
		end
		return nil, reason, keep
	end
	if em == nil then
		return nil, REASON.budget, false
	end
	local readOk, data = pcall(readMesh, em)
	pcall(function()
		em:Destroy()
	end)
	if not readOk then
		return nil, REASON.failed, true
	end
	return data, nil, true
end

-- A mesh shown from an EditableMesh in the place (not uploaded yet): read
-- it where it is. It belongs to the place, so it is never destroyed here,
-- and never cached since it can be edited at any time.
local function readInPlace(object)
	local ok, isMesh = pcall(function()
		return object:IsA("EditableMesh")
	end)
	if not (ok and isMesh) then
		return nil, REASON.noMesh
	end
	local readOk, data = pcall(readMesh, object)
	if not readOk then
		return nil, REASON.failed
	end
	return data
end

local function meshContent(part)
	local content = Util.prop(part, "MeshContent", nil)
	if content == nil and Content ~= nil then
		local id = Util.prop(part, "MeshId", "")
		if id ~= "" then
			content = Content.fromUri(id)
		end
	end
	return content
end

-- Mesh-space data for a part's mesh: data | nil, reason.
local function loadMesh(part)
	if part:IsA("PartOperation") then
		return nil, REASON.union
	elseif not part:IsA("MeshPart") then
		return nil, REASON.notMesh
	end
	local content = meshContent(part)
	if content == nil or content.SourceType == Enum.ContentSourceType.None then
		return nil, REASON.noMesh
	elseif content.SourceType == Enum.ContentSourceType.Object then
		return readInPlace(content.Object)
	end
	local key = content.Uri -- nil for opaque content, which isn't cached
	local cached = key and meshCache[key]
	if cached then
		if cached.failed then
			return nil, cached.failed
		end
		return cached
	end
	if not coroutine.isyieldable() then
		return nil, REASON.noYield
	end
	local data, reason, keep = download(content)
	if key and keep then
		remember(key, data or { failed = reason })
	end
	return data, reason
end

-- Mesh space -> the part's local space in studs. The engine stretches the
-- mesh's own size (MeshSize) to the part's Size about the part's centre. An
-- axis with no MeshSize (an old part, a flat mesh) uses the mesh's measured
-- size, and keeps its scale when that is flat too.
local function meshScale(part, data)
	local meshSize = Util.prop(part, "MeshSize", Vector3.zero)
	local size = part.Size
	local function axis(s, m, measured)
		if m < EPSILON then
			m = measured
		end
		return if m < EPSILON then 1 else s / m
	end
	return Vector3.new(
		axis(size.X, meshSize.X, data.size.X),
		axis(size.Y, meshSize.Y, data.size.Y),
		axis(size.Z, meshSize.Z, data.size.Z)
	)
end

local function fitToPart(data, part)
	local scale = meshScale(part, data)
	local corners = data.corners
	local triangles = table.create(math.floor(#corners / 3))
	for i = 1, #corners - 2, 3 do
		table.insert(triangles, { corners[i] * scale, corners[i + 1] * scale, corners[i + 2] * scale })
	end
	-- The box (Size) only matches the drawn mesh when the mesh data is
	-- centred on its own bounds.
	local offset = data.center * scale
	local note = nil
	if offset.Magnitude > math.max(1e-3, 1e-3 * part.Size.Magnitude) then
		note = ("mesh data isn't centred on its bounds (off by %s studs), so its box doesn't match what you see"):format(
			Util.vector(offset, 3)
		)
	end
	return triangles, nil, note
end

local function meshTriangles(part)
	local data, reason = loadMesh(part)
	if not data then
		return nil, reason
	end
	return fitToPart(data, part)
end

--------------------------------------------------------------------------------
-- Collision groups
--------------------------------------------------------------------------------

-- Workspace (or the WorldModel scanned) answers for its own groups; the
-- deprecated PhysicsService call forwards to Workspace in newer Studios and
-- is the fallback for older ones. Unknown: assume they collide.
local function askGroupsCollide(worldRoot, a, b)
	local ok, result = pcall(function()
		return worldRoot:CollisionGroupsAreCollidable(a, b)
	end)
	if ok and type(result) == "boolean" then
		return result
	end
	ok, result = pcall(function()
		return game:GetService("PhysicsService"):CollisionGroupsAreCollidable(a, b)
	end)
	if ok and type(result) == "boolean" then
		return result
	end
	return true
end

--------------------------------------------------------------------------------
-- The adapter
--------------------------------------------------------------------------------

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

	-- Candidates come from a bounds query with default OverlapParams, which
	-- skips parts the engine leaves out of queries (CanQuery off on a part
	-- that doesn't collide).
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { terrain }

	function self.partAt(point, ignore)
		for _, part in worldRoot:GetPartBoundsInRadius(point, 0.01, overlap) do
			if not (ignore and ignore(part)) and contains(part, point) then
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

	-- Looser test used while searching for open air: the point's voxel is
	-- at least half full.
	function self.isSolidTerrain(point)
		return occupancyAt(point) >= 0.5
	end

	function self.isTerrain(instance)
		return instance == terrain
	end

	function self.hasTag(instance, tag)
		local ok, result = pcall(function()
			return CollectionService:HasTag(instance, tag)
		end)
		if ok then
			return result == true
		end
		return Util.hasTag(instance, tag)
	end

	local given = setmetatable({}, { __mode = "k" })
	function self.setMeshTriangles(part, triangles)
		given[part] = triangles
	end
	function self.meshTriangles(part)
		local triangles = given[part]
		if triangles then
			return triangles
		end
		return meshTriangles(part)
	end

	-- Answers are kept for this world (one scan), since a scan asks about
	-- the same few groups over and over.
	local groupAnswers = {}
	function self.groupsCollide(a, b)
		a, b = a or "Default", b or "Default"
		local key = if a < b then a .. "|" .. b else b .. "|" .. a
		local answer = groupAnswers[key]
		if answer == nil then
			answer = askGroupsCollide(worldRoot, a, b)
			groupAnswers[key] = answer
		end
		return answer
	end

	self.yield = yieldIfDue

	function self.fillTerrain(cframe, size, materialName)
		terrain:FillBlock(cframe, size, Enum.Material[materialName or "Grass"])
	end

	function self.clearTerrain(cframe, size)
		terrain:FillBlock(cframe, size, Enum.Material.Air)
	end

	return self
end

return StudioWorld
