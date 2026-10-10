--[[
	Meshes: what the checks can see of MeshParts and unions, whose real
	surface isn't known from their Size.

	  * Triangles: when the world can read a MeshPart's mesh (EditableMesh in
	    Studio, for meshes the place's owner can load), every triangle becomes
	    a face, so the z-fight check tests the real surface. Meshes it can't
	    read, meshes over meshTriangleLimit triangles and unions (no readable
	    geometry) are only checked by box; `coverage` counts them and says why.
	  * Duplicates: two visible parts of the same class, mesh (or shape),
	    position, rotation and size. The classic double import. Any class.
	  * Box overlap: two meshes or unions whose boxes line up and share most
	    of their volume (meshOverlapRatio). Only a warning: the surfaces inside
	    the boxes may differ, so someone has to look.

	Winding: Roblox doesn't document which way a mesh triangle faces, so each
	mesh is judged on its own. A closed mesh whose triangles wind
	counter-clockwise seen from outside has a positive signed volume (the sum
	of a . (b x c) over its triangles); a negative one means every normal
	flips.
]]

local Util = require(script.Parent.Parent.Util)
local Geometry = require(script.Parent.Parent.Geometry)

local Meshes = {}

local COS_TENTH_DEGREE = math.cos(math.rad(0.1))
local COS_ONE_DEGREE = math.cos(math.rad(1))
-- Triangles smaller than this (studs²) are slivers with no usable normal.
local MIN_TRIANGLE_AREA = 1e-6

Meshes.UNION_REASON = "unions have no readable geometry"

--------------------------------------------------------------------------------
-- Coverage: which meshes were checked by triangles and which by box only
--------------------------------------------------------------------------------

function Meshes.newCoverage()
	return { meshTriangles = 0, meshBoxOnly = 0, reasons = {} }
end

local function boxOnly(coverage, reason)
	coverage.meshBoxOnly += 1
	coverage.reasons[reason] = (coverage.reasons[reason] or 0) + 1
end

-- One line for the report, or nil when no mesh needed checking:
--     "Meshes: 4 checked by their triangles, 3 by box only (unions have no
--      readable geometry: 2; mesh not loadable: 1)"
function Meshes.describeCoverage(coverage)
	if not coverage or coverage.meshTriangles + coverage.meshBoxOnly == 0 then
		return nil
	end
	local text = ("Meshes: %d checked by their triangles, %d by box only"):format(
		coverage.meshTriangles,
		coverage.meshBoxOnly
	)
	local reasons = {}
	for reason, count in coverage.reasons do
		table.insert(reasons, ("%s: %d"):format(reason, count))
	end
	table.sort(reasons)
	if #reasons > 0 then
		text ..= " (" .. table.concat(reasons, "; ") .. ")"
	end
	return text
end

--------------------------------------------------------------------------------
-- Triangles
--------------------------------------------------------------------------------

-- A triangle may come as { a, b, c } or { a = ..., b = ..., c = ... }.
local function corners(t)
	return t[1] or t.a, t[2] or t.b, t[3] or t.c
end

-- Six times the signed volume the triangles enclose about the part's centre.
function Meshes.signedVolume(triangles)
	local sum = 0
	for _, t in triangles do
		local a, b, c = corners(t)
		sum += a:Dot(b:Cross(c))
	end
	return sum
end

-- World-space faces, one per triangle, for part-local `triangles` placed at
-- `cf`: { name = "tri", triangle = true, normal, points, center }.
function Meshes.triangleFaces(triangles, cf)
	local sign = if Meshes.signedVolume(triangles) < 0 then -1 else 1
	local faces = {}
	for _, t in triangles do
		local la, lb, lc = corners(t)
		local a, b, c = cf:PointToWorldSpace(la), cf:PointToWorldSpace(lb), cf:PointToWorldSpace(lc)
		local cross = (b - a):Cross(c - a)
		local length = cross.Magnitude
		if length / 2 >= MIN_TRIANGLE_AREA then
			table.insert(faces, {
				name = "tri",
				triangle = true,
				normal = cross * (sign / length),
				points = { a, b, c },
				center = (a + b + c) / 3,
			})
		end
	end
	return faces
end

-- Triangle faces for a visible mesh or union `s`, or nil when only its box
-- can be checked. Counts the outcome in `coverage`. Reads each part once:
-- the caller keeps the result.
function Meshes.load(ctx, s, coverage)
	local part = s.part
	if not part:IsA("MeshPart") then
		boxOnly(coverage, Meshes.UNION_REASON)
		return nil
	end
	local config, world = ctx.config, ctx.world
	if not config.meshTriangles then
		boxOnly(coverage, "meshTriangles is off")
		return nil
	end
	if not world.meshTriangles then
		boxOnly(coverage, "this world can't read meshes")
		return nil
	end
	-- Reading a mesh can wait on the network in Studio.
	local ok, triangles, reason = pcall(world.meshTriangles, part)
	ctx.yield()
	if not ok then
		triangles, reason = nil, "reading the mesh failed"
	end
	if not triangles then
		boxOnly(coverage, reason or "mesh not readable")
		return nil
	end
	if #triangles > config.meshTriangleLimit then
		boxOnly(coverage, ("more than meshTriangleLimit (%d) triangles"):format(config.meshTriangleLimit))
		return nil
	end
	coverage.meshTriangles += 1
	return Meshes.triangleFaces(triangles, s.cf)
end

--------------------------------------------------------------------------------
-- Duplicates and overlapping boxes
--------------------------------------------------------------------------------

-- What makes two parts of one class the same shape: the mesh for a MeshPart,
-- the shape for a Part, nothing more for other classes.
function Meshes.identity(part)
	if part:IsA("MeshPart") then
		return "mesh " .. tostring(Util.prop(part, "MeshId", ""))
	elseif part:IsA("Part") then
		local shape = Util.prop(part, "Shape")
		return "shape " .. (if shape then shape.Name else "Block")
	end
	return ""
end

-- Are solids `a` and `b` copies: same class and mesh/shape, position and
-- size within `tolerance`, and the same rotation (within 0.1 degree)?
function Meshes.isDuplicate(a, b, tolerance)
	if a.part.ClassName ~= b.part.ClassName or (a.pos - b.pos).Magnitude > tolerance then
		return false
	end
	local d = a.size - b.size
	if math.abs(d.X) > tolerance or math.abs(d.Y) > tolerance or math.abs(d.Z) > tolerance then
		return false
	end
	for i = 1, 3 do
		if a.axes[i]:Dot(b.axes[i]) < COS_TENTH_DEGREE then
			return false
		end
	end
	return Meshes.identity(a.part) == Meshes.identity(b.part)
end

-- How much of their volume two boxes share (intersection over union), when
-- they line up: every axis of `a` within 1 degree of some axis of `b`.
-- nil when they don't line up.
function Meshes.alignedOverlap(a, b)
	local extents = {}
	for i = 1, 3 do
		for j = 1, 3 do
			if math.abs(a.axes[i]:Dot(b.axes[j])) >= COS_ONE_DEGREE then
				extents[i] = Geometry.component(b.half, j)
				break
			end
		end
		if not extents[i] then
			return nil
		end
	end
	local c = a.cf:PointToObjectSpace(b.pos)
	local shared = 1
	for i = 1, 3 do
		local ha, hb, ci = Geometry.component(a.half, i), extents[i], Geometry.component(c, i)
		local overlap = math.min(ha, ci + hb) - math.max(-ha, ci - hb)
		if overlap <= 0 then
			return 0
		end
		shared *= overlap
	end
	return shared / (Geometry.volume(a) + Geometry.volume(b) - shared)
end

function Meshes.duplicateIssue(ctx, a, b)
	local same = if a.part:IsA("MeshPart") then "mesh" elseif a.part:IsA("Part") then "shape" else "class"
	return {
		check = "duplicate",
		severity = "error",
		parts = { a.part, b.part },
		position = a.pos,
		message = ("%s and %s are duplicates at %s (same %s, position and size: a double import?): delete one"):format(
			ctx.path(a.part),
			ctx.path(b.part),
			Util.vector(a.pos),
			same
		),
	}
end

function Meshes.overlapIssue(ctx, a, b, ratio)
	local position = (a.pos + b.pos) / 2
	return {
		check = "meshoverlap",
		severity = "warning",
		parts = { a.part, b.part },
		position = position,
		message = ("%s and %s: their boxes overlap %d%% at %s (a double import or a z-fighting copy?): check them by eye"):format(
			ctx.path(a.part),
			ctx.path(b.part),
			math.floor(ratio * 100),
			Util.vector(position)
		),
	}
end

return Meshes
