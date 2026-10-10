--[[
	How parts are joined, worked out from the joint instances (no physics run):

	  * Rigid joints (Weld, Motor6D, ManualWeld, Snap, Glue, WeldConstraint,
	    RigidConstraint) put parts in one assembly. Roblox never collides
	    parts of the same assembly with each other.
	  * Mechanical constraints (hinges, sliders, springs, ball sockets...)
	    link assemblies that move against each other, and do collide.
	  * NoCollisionConstraint switches collision off for one pair.

	Vehicles: the parts connected (by joints or constraints) to a VehicleSeat
	or to two or more wheels spinning on constraints, plus every part of a model marked
	BuildGuardVehicle (attribute or tag) or holding a VehicleSeat directly.
	Loose anchored parts in a truck model are still "in the vehicle" that way.
]]

local Util = require(script.Parent.Util)
local Classify = require(script.Parent.Classify)

local Kinematics = {}

-- JointInstance classes that aren't rigid (legacy motors).
local NON_RIGID_JOINTS = { Rotate = true, RotateP = true, RotateV = true, VelocityMotor = true }

local function enabled(instance)
	return Util.prop(instance, "Enabled", true) ~= false
end
Kinematics.enabled = enabled

local function attachmentPart(attachment)
	local parent = attachment and attachment.Parent
	if parent and parent:IsA("BasePart") then
		return parent
	end
	return nil
end
Kinematics.attachmentPart = attachmentPart
Kinematics.attachmentFrame = Classify.attachmentFrame

-- Pair key for two parts (order-free).
local ids = setmetatable({}, { __mode = "k" })
local nextId = 0
local function idOf(part)
	local id = ids[part]
	if not id then
		nextId += 1
		id = nextId
		ids[part] = id
	end
	return id
end
function Kinematics.pairKey(a, b)
	local ia, ib = idOf(a), idOf(b)
	if ia > ib then
		ia, ib = ib, ia
	end
	return ia * 2 ^ 26 + ib
end

-- Joint graph of everything under `roots` (an Instance or a list).
-- Returns {
--   parts       = { BasePart },
--   rigid       = { { a, b, joint } },
--   links       = { { a, b, constraint } },   -- mechanical constraints
--   noCollide   = { [pairKey] = NoCollisionConstraint | HingeConstraint | BallSocketConstraint },
--   constraints = { Constraint },
--   seats       = { VehicleSeat },
-- }
function Kinematics.graph(roots)
	if typeof(roots) == "Instance" then
		roots = { roots }
	end
	local g = { parts = {}, rigid = {}, links = {}, noCollide = {}, constraints = {}, seats = {} }
	local seen = {}
	local function visit(d)
		if seen[d] then
			return
		end
		seen[d] = true
		if d:IsA("BasePart") then
			if not d:IsA("Terrain") then
				table.insert(g.parts, d)
				if d:IsA("VehicleSeat") then
					table.insert(g.seats, d)
				end
			end
		elseif d:IsA("JointInstance") then
			local a, b = Util.prop(d, "Part0"), Util.prop(d, "Part1")
			if a and b and enabled(d) and not NON_RIGID_JOINTS[d.ClassName] then
				table.insert(g.rigid, { a, b, d })
			elseif a and b and enabled(d) then
				table.insert(g.links, { a, b, d })
			end
		elseif d:IsA("WeldConstraint") then
			local a, b = Util.prop(d, "Part0"), Util.prop(d, "Part1")
			if a and b and enabled(d) then
				table.insert(g.rigid, { a, b, d })
			end
		elseif d:IsA("NoCollisionConstraint") then
			local a, b = Util.prop(d, "Part0"), Util.prop(d, "Part1")
			if a and b and enabled(d) then
				g.noCollide[Kinematics.pairKey(a, b)] = d
			end
		elseif d:IsA("Constraint") then
			table.insert(g.constraints, d)
			local a = attachmentPart(Util.prop(d, "Attachment0"))
			local b = attachmentPart(Util.prop(d, "Attachment1"))
			if a and b and enabled(d) then
				table.insert(if d:IsA("RigidConstraint") then g.rigid else g.links, { a, b, d })
				if d:IsA("HingeConstraint") or d:IsA("BallSocketConstraint") then
					g.noCollide[Kinematics.pairKey(a, b)] = g.noCollide[Kinematics.pairKey(a, b)] or d
				end
			end
		end
	end
	for _, root in roots do
		visit(root)
		for _, d in root:GetDescendants() do
			visit(d)
		end
	end
	return g
end

-- Union-find over `pairs` ({ a, b, ... }). Returns rootOf(part) -> part.
local function unionFind(pairs)
	local parent = {}
	local function find(x)
		local p = parent[x]
		if p == nil then
			parent[x] = x
			return x
		end
		if p == x then
			return x
		end
		local r = find(p)
		parent[x] = r
		return r
	end
	for _, pair in pairs do
		local ra, rb = find(pair[1]), find(pair[2])
		if ra ~= rb then
			parent[ra] = rb
		end
	end
	return find
end

-- Assemblies: rigidly joined groups. Returns {
--   of = { [part] = assemblyId },  members = { [assemblyId] = { part } } }
-- assemblyId is one member part.
function Kinematics.assemblies(g)
	local find = unionFind(g.rigid)
	local of, members = {}, {}
	for _, p in g.parts do
		local r = find(p)
		of[p] = r
		members[r] = members[r] or {}
		table.insert(members[r], p)
	end
	return { of = of, members = members }
end

-- Mechanisms: groups connected by any joint or constraint. Same shape as
-- Kinematics.assemblies.
function Kinematics.mechanisms(g)
	local all = table.clone(g.rigid)
	for _, l in g.links do
		table.insert(all, l)
	end
	local find = unionFind(all)
	local of, members = {}, {}
	for _, p in g.parts do
		local r = find(p)
		of[p] = r
		members[r] = members[r] or {}
		table.insert(members[r], p)
	end
	return { of = of, members = members }
end

-- Can `a` and `b` collide with each other physically? (Both CanCollide,
-- different assemblies, no NoCollisionConstraint, collision groups that
-- collide.) `world.groupsCollide(groupA, groupB)` is optional.
function Kinematics.canCollide(a, b, g, assemblies, world)
	if not Util.prop(a, "CanCollide", true) or not Util.prop(b, "CanCollide", true) then
		return false
	end
	if assemblies.of[a] ~= nil and assemblies.of[a] == assemblies.of[b] then
		return false
	end
	if g.noCollide[Kinematics.pairKey(a, b)] then
		return false
	end
	if world and world.groupsCollide then
		local ga, gb = Util.prop(a, "CollisionGroup", "Default"), Util.prop(b, "CollisionGroup", "Default")
		if ga ~= gb or ga ~= "Default" then
			return world.groupsCollide(ga, gb)
		end
	end
	return true
end

-- The nearest Model at or above `instance`.
local function nearestModel(instance)
	local node = instance
	while node do
		if node:IsA("Model") then
			return node
		end
		node = node.Parent
	end
	return nil
end
Kinematics.nearestModel = nearestModel

-- Vehicles under `roots`. Returns a list of { model, parts = { [part] = true },
-- list = { part } } and a lookup partSet -> vehicle.
function Kinematics.vehicles(roots, g)
	g = g or Kinematics.graph(roots)
	local mechanisms = Kinematics.mechanisms(g)
	local inGraph = {}
	for _, p in g.parts do
		inGraph[p] = true
	end
	local seeds = {}
	for _, seat in g.seats do
		table.insert(seeds, seat)
	end
	-- Wheels count when a mechanism has at least two (a windmill's one hub
	-- doesn't make it a vehicle).
	local spinningBy = {}
	for part in Classify.spinningParts(g.constraints) do
		if inGraph[part] then
			local key = mechanisms.of[part]
			spinningBy[key] = spinningBy[key] or {}
			table.insert(spinningBy[key], part)
		end
	end
	for _, list in spinningBy do
		if #list >= 2 then
			for _, part in list do
				table.insert(seeds, part)
			end
		end
	end
	-- Group seeds into vehicles by mechanism.
	local byMechanism, vehicles = {}, {}
	local function vehicleFor(key)
		local v = byMechanism[key]
		if not v then
			v = { parts = {}, list = {}, models = {} }
			byMechanism[key] = v
			table.insert(vehicles, v)
		end
		return v
	end
	local function add(v, p)
		if not v.parts[p] then
			v.parts[p] = true
			table.insert(v.list, p)
		end
	end
	for _, seed in seeds do
		local v = vehicleFor(mechanisms.of[seed])
		for _, p in mechanisms.members[mechanisms.of[seed]] do
			add(v, p)
		end
		local model = nearestModel(seed.Parent)
		if model and seed:IsA("VehicleSeat") then
			v.models[model] = true
		end
	end
	-- Models marked BuildGuardVehicle.
	local marked = {}
	local function considerModel(m)
		if m:IsA("Model") and not marked[m] and Util.marker(m, "BuildGuardVehicle") == true then
			marked[m] = true
			local v = vehicleFor(m)
			v.models[m] = true
		end
	end
	for _, p in g.parts do
		local node = p.Parent
		while node do
			considerModel(node)
			node = node.Parent
		end
	end
	-- Every part under a vehicle's models belongs to it.
	for _, v in vehicles do
		for m in v.models do
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") and inGraph[d] then
					add(v, d)
				end
			end
		end
	end
	-- Merge vehicles that ended up sharing parts, and name each by the
	-- smallest model holding all its parts.
	local owner, result = {}, {}
	for _, v in vehicles do
		local target = nil
		for _, p in v.list do
			if owner[p] then
				target = owner[p]
				break
			end
		end
		if target then
			for _, p in v.list do
				if not target.parts[p] then
					target.parts[p] = true
					table.insert(target.list, p)
				end
				owner[p] = target
			end
		elseif #v.list > 0 then
			table.insert(result, v)
			for _, p in v.list do
				owner[p] = v
			end
		end
	end
	for _, v in result do
		local common = v.list[1]
		for i = 2, #v.list do
			local a, b = common, v.list[i]
			local seen = {}
			local node = a
			while node do
				seen[node] = true
				node = node.Parent
			end
			node = b
			while node and not seen[node] do
				node = node.Parent
			end
			common = node
			if not common then
				break
			end
		end
		v.model = nearestModel(common) or common
		v.models = nil
	end
	return result, owner
end

return Kinematics
