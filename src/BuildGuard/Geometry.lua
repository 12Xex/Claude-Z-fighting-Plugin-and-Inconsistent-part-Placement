--[[
	Pure geometry on parts: oriented boxes, face polygons, coplanar overlap,
	point containment and ray tests. Works on CFrame/Vector3 only, so it runs
	the same in Studio and in the Lune test runner.
]]

local Geometry = {}

-- Local axis index (1 = X, 2 = Y, 3 = Z) and sign for each NormalId name.
Geometry.FACE_AXIS = {
	Right = { 1, 1 },
	Left = { 1, -1 },
	Top = { 2, 1 },
	Bottom = { 2, -1 },
	Back = { 3, 1 },
	Front = { 3, -1 },
}

local function component(v, axis)
	if axis == 1 then
		return v.X
	elseif axis == 2 then
		return v.Y
	end
	return v.Z
end
Geometry.component = component

local function axisVector(axis, value)
	if axis == 1 then
		return Vector3.new(value, 0, 0)
	elseif axis == 2 then
		return Vector3.new(0, value, 0)
	end
	return Vector3.new(0, 0, value)
end
Geometry.axisVector = axisVector

-- Part.Shape values that aren't drawn as a block.
local PART_SHAPES = { Ball = true, Cylinder = true, Wedge = true, CornerWedge = true }

-- "Block" | "Wedge" | "CornerWedge" | "Cylinder" | "Ball" | "Other"
-- (Other = mesh, union, truss: only its box is known)
function Geometry.shapeOf(part)
	if part:IsA("WedgePart") then
		return "Wedge"
	elseif part:IsA("CornerWedgePart") then
		return "CornerWedge"
	elseif not part:IsA("Part") then
		return "Other"
	end
	local ok, shape = pcall(function()
		return part.Shape.Name
	end)
	return if ok and PART_SHAPES[shape] then shape else "Block"
end

-- The SpecialMesh, BlockMesh or CylinderMesh child that draws a part in
-- place of its own shape, or nil. A BlockMesh at its default scale and
-- offset draws the part's box, so it doesn't count.
function Geometry.meshChild(part)
	local mesh = part:FindFirstChildWhichIsA("DataModelMesh")
	if mesh and mesh:IsA("BlockMesh") and mesh.Scale == Vector3.one and mesh.Offset == Vector3.zero then
		return nil
	end
	return mesh
end

-- Meshes, unions and parts drawn by a mesh child: parts whose real surface
-- isn't known from Size alone.
function Geometry.isMeshLike(part)
	return part:IsA("MeshPart") or part:IsA("PartOperation") or Geometry.meshChild(part) ~= nil
end

-- A snapshot of a part's box. Fixes change parts, so take fresh solids after.
function Geometry.solidFrom(cf, size, shape, part)
	local half = size / 2
	local ax = { cf.RightVector, cf.UpVector, -cf.LookVector }
	local ext = Vector3.new(
		math.abs(ax[1].X) * half.X + math.abs(ax[2].X) * half.Y + math.abs(ax[3].X) * half.Z,
		math.abs(ax[1].Y) * half.X + math.abs(ax[2].Y) * half.Y + math.abs(ax[3].Y) * half.Z,
		math.abs(ax[1].Z) * half.X + math.abs(ax[2].Z) * half.Y + math.abs(ax[3].Z) * half.Z
	)
	local pos = cf.Position
	return {
		part = part,
		cf = cf,
		size = size,
		half = half,
		shape = shape,
		axes = ax,
		pos = pos,
		min = pos - ext,
		max = pos + ext,
	}
end

function Geometry.solid(part)
	return Geometry.solidFrom(part.CFrame, part.Size, Geometry.shapeOf(part), part)
end

function Geometry.volume(s)
	return s.size.X * s.size.Y * s.size.Z
end

-- Angle in degrees between the part's up vector and world up.
function Geometry.tiltDegrees(s)
	return math.deg(math.acos(math.clamp(s.axes[2].Y, -1, 1)))
end

--------------------------------------------------------------------------------
-- Faces
--------------------------------------------------------------------------------

-- A rectangle's corners in order round it, as signs on its two axes.
local RECT_CORNERS = { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }

-- The local point `along` on `axis` and `b`, `c` on the next two (X->Y->Z->X).
local function facePoint(axis, along, b, c)
	local coords = { 0, 0, 0 }
	coords[axis] = along
	coords[axis % 3 + 1] = b
	coords[(axis + 1) % 3 + 1] = c
	return Vector3.new(coords[1], coords[2], coords[3])
end

local function rectFace(h, axis, sign)
	local along = sign * component(h, axis)
	local hb, hc = component(h, axis % 3 + 1), component(h, (axis + 1) % 3 + 1)
	local points = {}
	for i, st in RECT_CORNERS do
		points[i] = facePoint(axis, along, st[1] * hb, st[2] * hc)
	end
	return points
end

-- A corner wedge's base corners A, B, C, D and its apex E, above B (+X, -Z).
local function cornerWedgeCorners(h)
	local A = Vector3.new(-h.X, -h.Y, -h.Z)
	local B = Vector3.new(h.X, -h.Y, -h.Z)
	local C = Vector3.new(-h.X, -h.Y, h.Z)
	local D = Vector3.new(h.X, -h.Y, h.Z)
	local E = Vector3.new(h.X, h.Y, -h.Z)
	return A, B, C, D, E
end

local function worldPoints(cf, points)
	local out = table.create(#points)
	for i, p in points do
		out[i] = cf:PointToWorldSpace(p)
	end
	return out
end

local function average(points)
	local sum = Vector3.zero
	for _, p in points do
		sum += p
	end
	return sum / #points
end

-- Faces in local space: { name, axis?, sign?, normal, points }.
-- `axis`/`sign` are nil for faces that aren't aligned to a local axis (wedge slope).
local function localFaces(shape, h)
	local faces = {}
	local function add(name, axis, sign, points, normal)
		table.insert(faces, {
			name = name,
			axis = axis,
			sign = sign,
			points = points,
			normal = normal or axisVector(axis, sign),
		})
	end
	if shape == "Block" then
		for name, as in Geometry.FACE_AXIS do
			add(name, as[1], as[2], rectFace(h, as[1], as[2]))
		end
	elseif shape == "Wedge" then
		-- The high side is Back (+Z); the slope faces Front and up.
		add("Bottom", 2, -1, rectFace(h, 2, -1))
		add("Back", 3, 1, rectFace(h, 3, 1))
		for _, sign in { 1, -1 } do
			local x = sign * h.X
			add(sign > 0 and "Right" or "Left", 1, sign, {
				Vector3.new(x, -h.Y, -h.Z),
				Vector3.new(x, -h.Y, h.Z),
				Vector3.new(x, h.Y, h.Z),
			})
		end
		add("Slope", nil, nil, {
			Vector3.new(-h.X, h.Y, h.Z),
			Vector3.new(h.X, h.Y, h.Z),
			Vector3.new(h.X, -h.Y, -h.Z),
			Vector3.new(-h.X, -h.Y, -h.Z),
		}, Vector3.new(0, h.Z, -h.Y).Unit)
	elseif shape == "CornerWedge" then
		-- A pyramid on a full rectangular base.
		local A, B, C, D, E = cornerWedgeCorners(h)
		add("Bottom", 2, -1, { A, B, D, C })
		add("Right", 1, 1, { B, E, D })
		add("Front", 3, -1, { B, A, E })
		add("SlopeLeft", nil, nil, { A, C, E }, Vector3.new(-h.Y, h.X, 0).Unit)
		add("SlopeBack", nil, nil, { C, D, E }, Vector3.new(0, h.Z, h.Y).Unit)
	elseif shape == "Cylinder" then
		-- End caps (the cylinder runs along X), approximated as octagons.
		local r = math.min(h.Y, h.Z)
		for _, sign in { 1, -1 } do
			local points = {}
			for i = 0, 7 do
				local a = i * math.pi / 4
				table.insert(points, Vector3.new(sign * h.X, r * math.cos(a), r * math.sin(a)))
			end
			add(sign > 0 and "Right" or "Left", 1, sign, points)
		end
	end
	return faces
end

-- World-space faces of a solid (cached on the solid).
function Geometry.faces(s)
	if s.faces then
		return s.faces
	end
	local result = {}
	for _, f in localFaces(s.shape, s.half) do
		local points = worldPoints(s.cf, f.points)
		table.insert(result, {
			name = f.name,
			axis = f.axis,
			sign = f.sign,
			normal = s.cf:VectorToWorldSpace(f.normal),
			points = points,
			center = average(points),
		})
	end
	s.faces = result
	return result
end

--------------------------------------------------------------------------------
-- 2D polygon helpers (points are { x, y } arrays)
--------------------------------------------------------------------------------

local function signedArea(poly)
	local area = 0
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		area += a[1] * b[2] - b[1] * a[2]
	end
	return area / 2
end

function Geometry.polygonArea(poly)
	return math.abs(signedArea(poly))
end

local function counterClockwise(poly)
	if signedArea(poly) >= 0 then
		return poly
	end
	local reversed = {}
	for i = #poly, 1, -1 do
		table.insert(reversed, poly[i])
	end
	return reversed
end

-- Sutherland–Hodgman: clip `subject` by the convex polygon `clip`.
function Geometry.clipPolygon(subject, clip)
	clip = counterClockwise(clip)
	local output = subject
	for i = 1, #clip do
		if #output == 0 then
			break
		end
		local a, b = clip[i], clip[i % #clip + 1]
		local function inside(p)
			return (b[1] - a[1]) * (p[2] - a[2]) - (b[2] - a[2]) * (p[1] - a[1]) >= -1e-9
		end
		local function intersect(p, q)
			local dx1, dy1 = q[1] - p[1], q[2] - p[2]
			local dx2, dy2 = b[1] - a[1], b[2] - a[2]
			local denom = dx1 * dy2 - dy1 * dx2
			if math.abs(denom) < 1e-12 then
				return p
			end
			local t = ((a[1] - p[1]) * dy2 - (a[2] - p[2]) * dx2) / denom
			return { p[1] + t * dx1, p[2] + t * dy1 }
		end
		local input = output
		output = {}
		local prev = input[#input]
		for _, cur in input do
			if inside(cur) then
				if not inside(prev) then
					table.insert(output, intersect(prev, cur))
				end
				table.insert(output, cur)
			elseif inside(prev) then
				table.insert(output, intersect(prev, cur))
			end
			prev = cur
		end
	end
	return output
end

-- The lowest and highest of `poly`'s corners along the direction (nx, ny).
local function span(poly, nx, ny)
	local lo, hi = math.huge, -math.huge
	for _, v in poly do
		local d = v[1] * nx + v[2] * ny
		lo, hi = math.min(lo, d), math.max(hi, d)
	end
	return lo, hi
end

-- Largest separating gap between two convex polygons (negative = overlapping).
function Geometry.polygonSeparation(p, q)
	local best = -math.huge
	for _, poly in { p, q } do
		for i = 1, #poly do
			local a, b = poly[i], poly[i % #poly + 1]
			local nx, ny = b[2] - a[2], a[1] - b[1]
			local len = math.sqrt(nx * nx + ny * ny)
			if len > 1e-9 then
				nx, ny = nx / len, ny / len
				local pMin, pMax = span(p, nx, ny)
				local qMin, qMax = span(q, nx, ny)
				best = math.max(best, qMin - pMax, pMin - qMax)
			end
		end
	end
	return best
end

-- Thinnest extent of a convex polygon: the narrowest gap two parallel lines
-- holding it can have. One of those lines always runs along an edge, so
-- it's the smallest, over the edges, of the furthest vertex from that edge.
function Geometry.polygonWidth(poly)
	local best = math.huge
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local len = math.sqrt(dx * dx + dy * dy)
		if len > 1e-9 then
			local far = 0
			for _, p in poly do
				far = math.max(far, math.abs(dx * (p[2] - a[2]) - dy * (p[1] - a[1])) / len)
			end
			best = math.min(best, far)
		end
	end
	return if best == math.huge then 0 else best
end

local function planeBasis(n)
	local ref = if math.abs(n.Y) < 0.9 then Vector3.new(0, 1, 0) else Vector3.new(1, 0, 0)
	local u = ref:Cross(n).Unit
	return u, n:Cross(u)
end

local function project(points, origin, u, v)
	local out = {}
	for i, p in points do
		local d = p - origin
		out[i] = { d:Dot(u), d:Dot(v) }
	end
	return out
end

local function polygonCentroid(poly)
	local area, cx, cy = 0, 0, 0
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		local cross = a[1] * b[2] - b[1] * a[2]
		area += cross
		cx += (a[1] + b[1]) * cross
		cy += (a[2] + b[2]) * cross
	end
	if math.abs(area) < 1e-12 then
		local sx, sy = 0, 0
		for _, p in poly do
			sx += p[1]
			sy += p[2]
		end
		return sx / #poly, sy / #poly
	end
	return cx / (3 * area), cy / (3 * area)
end

-- Overlaps thinner than this (studs) are float rounding along a shared edge.
local MIN_OVERLAP_WIDTH = 1e-3
-- Part positions are float32: about 4 rounding steps of a coordinate this big.
local FLOAT_STEPS = 4 * 2 ^ -23

-- How far apart float rounding can put two edges meant to meet near `c`.
local function floatSliver(c)
	return math.max(MIN_OVERLAP_WIDTH, FLOAT_STEPS * math.max(math.abs(c.X), math.abs(c.Y), math.abs(c.Z)))
end
Geometry.floatSliver = floatSliver

-- Faces `fa` and `fb` projected on fa's plane (fa.center is the origin of
-- u, v) and their overlap there: overlap, pa, pb, u, v.
local function overlapOnPlane(fa, fb)
	local u, v = planeBasis(fa.normal)
	local pa, pb = project(fa.points, fa.center, u, v), project(fb.points, fa.center, u, v)
	return Geometry.clipPolygon(pb, pa), pa, pb, u, v
end

-- If faces `fa` and `fb` point the same way, lie within `tolerance` of each
-- other and overlap, returns overlapArea, distance (how far fb's plane sits
-- in front of fa's, along fa's normal), centroid (the overlap's middle, on
-- fa's plane) and width (its thinnest extent); otherwise nil.
-- Faces laid edge to edge far from the origin overlap by a float-rounding
-- sliver that never flickers, so an overlap that moving a face by less than
-- floatSliver would clear doesn't count.
function Geometry.coplanarOverlap(fa, fb, tolerance, minArea)
	if fa.normal:Dot(fb.normal) < 1 - 1e-4 then
		return nil
	end
	local distance = (fb.center - fa.center):Dot(fa.normal)
	if math.abs(distance) > tolerance then
		return nil
	end
	local clipped, pa, pb, u, v = overlapOnPlane(fa, fb)
	if #clipped < 3 then
		return nil
	end
	local area = Geometry.polygonArea(clipped)
	if area < minArea then
		return nil
	end
	if Geometry.polygonSeparation(pa, pb) > -floatSliver(fa.center) then
		return nil
	end
	local cx, cy = polygonCentroid(clipped)
	return area, distance, fa.center + u * cx + v * cy, Geometry.polygonWidth(clipped)
end

-- The inverse of `project`: plane points back to world points.
local function toWorld(poly, origin, u, v)
	local points = table.create(#poly)
	for i, p in poly do
		points[i] = origin + u * p[1] + v * p[2]
	end
	return points
end

-- The overlap of faces `fa` and `fb` (as coplanarOverlap finds it) as world
-- points on fa's plane: a convex polygon, empty when they don't overlap.
function Geometry.overlapPolygon(fa, fb)
	local overlap, _, _, u, v = overlapOnPlane(fa, fb)
	if #overlap < 3 then
		return {}
	end
	return toWorld(overlap, fa.center, u, v)
end

-- A convex polygon grown by `d`: each edge moved out by d. Corners sharper
-- than about 30° are cut off rather than drawn out to a long point.
local function grownPolygon(poly, d)
	poly = counterClockwise(poly)
	-- Each edge's start and outward normal, skipping repeated points.
	local starts, normals = {}, {}
	for i = 1, #poly do
		local a, b = poly[i], poly[i % #poly + 1]
		local dx, dy = b[1] - a[1], b[2] - a[2]
		local length = math.sqrt(dx * dx + dy * dy)
		if length > 1e-9 then
			table.insert(starts, a)
			table.insert(normals, { dy / length, -dx / length })
		end
	end
	if #starts < 3 then
		return poly
	end
	local out = {}
	for i, p in starts do
		local n0, n1 = normals[(i - 2) % #normals + 1], normals[i]
		local k = 1 + n0[1] * n1[1] + n0[2] * n1[2]
		if k >= 1 / 8 then
			table.insert(out, { p[1] + d * (n0[1] + n1[1]) / k, p[2] + d * (n0[2] + n1[2]) / k })
		else
			table.insert(out, { p[1] + d * n0[1], p[2] + d * n0[2] })
			table.insert(out, { p[1] + d * n1[1], p[2] + d * n1[2] })
		end
	end
	return out
end

-- Convex `poly` split by the line through a and b: the part left of a -> b
-- (inside a counter-clockwise polygon with that edge) and the part right.
local function splitPolygon(poly, a, b)
	local dx, dy = b[1] - a[1], b[2] - a[2]
	local left, right = {}, {}
	local prev = poly[#poly]
	local prevSide = dx * (prev[2] - a[2]) - dy * (prev[1] - a[1])
	for _, cur in poly do
		local side = dx * (cur[2] - a[2]) - dy * (cur[1] - a[1])
		if (side >= 0) ~= (prevSide >= 0) then
			local t = prevSide / (prevSide - side)
			local cut = { prev[1] + t * (cur[1] - prev[1]), prev[2] + t * (cur[2] - prev[2]) }
			table.insert(left, cut)
			table.insert(right, cut)
		end
		table.insert(if side >= 0 then left else right, cur)
		prev, prevSide = cur, side
	end
	return left, right
end

local function polygonBounds(poly)
	local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in poly do
		x0, y0, x1, y1 = math.min(x0, p[1]), math.min(y0, p[2]), math.max(x1, p[1]), math.max(y1, p[2])
	end
	return x0, y0, x1, y1
end

-- Open pieces smaller than this (studs²) are float rounding along a cut.
local MIN_PIECE_AREA = 1e-9
-- Cutting stops once the open part is in this many pieces (thousands of
-- small covers over a huge overlap); what's left then counts as open.
local MAX_OPEN_PIECES = 512

-- Cuts the convex, counter-clockwise `cut` out of the convex `piece`: what
-- lies right of one of its edges stays open and goes into `rest`.
local function cutOut(piece, cut, rest)
	local inside = piece
	for i = 1, #cut do
		local outside
		inside, outside = splitPolygon(inside, cut[i], cut[i % #cut + 1])
		if #outside >= 3 and Geometry.polygonArea(outside) > MIN_PIECE_AREA then
			table.insert(rest, outside)
		end
		if #inside < 3 then
			break
		end
	end
end

-- How much of the overlap of same-facing faces `fa` and `fb` (as
-- coplanarOverlap finds it) the faces `covers` hide: faces pointing the
-- other way, back to back on it (a road resting on both). Each cover is cut
-- out of the open pieces in turn, so covers overlapping each other count
-- once. Each is first grown by the float rounding coplanarOverlap ignores,
-- so covers built flush with the overlap's edges, or with each other, leave
-- no slit, far from the origin too.
-- Returns coveredArea, overlapArea and the pieces left open (convex polygons
-- of world points on fa's plane); 0, 0, {} without an overlap.
function Geometry.overlapCover(fa, fb, covers)
	local overlap, _, _, u, v = overlapOnPlane(fa, fb)
	if #overlap < 3 then
		return 0, 0, {}
	end
	local area = Geometry.polygonArea(overlap)
	local grow = floatSliver(fa.center)
	local open = { counterClockwise(overlap) }
	for _, f in covers do
		if #open == 0 or #open > MAX_OPEN_PIECES then
			break
		end
		-- A face pointing the other way winds the other way round once
		-- projected on fa's plane; grownPolygon turns it counter-clockwise.
		local cut = grownPolygon(project(f.points, fa.center, u, v), grow)
		local cx0, cy0, cx1, cy1 = polygonBounds(cut)
		local rest = {}
		for _, piece in open do
			local x0, y0, x1, y1 = polygonBounds(piece)
			if x0 >= cx1 or cx0 >= x1 or y0 >= cy1 or cy0 >= y1 then
				table.insert(rest, piece)
			else
				cutOut(piece, cut, rest)
			end
		end
		open = rest
	end
	local left = 0
	local pieces = table.create(#open)
	for k, piece in open do
		left += Geometry.polygonArea(piece)
		pieces[k] = toWorld(piece, fa.center, u, v)
	end
	return math.max(area - left, 0), area, pieces
end

local function turn(o, a, b)
	return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
end

-- Adds `p` to half a hull, dropping the points it leaves without a left turn.
local function extendHull(half, p)
	while #half >= 2 and turn(half[#half - 1], half[#half], p) <= 1e-12 do
		table.remove(half)
	end
	table.insert(half, p)
end

-- Convex hull of 2D points, counter-clockwise (Andrew's monotone chain).
local function convexHull(points)
	table.sort(points, function(a, b)
		return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
	end)
	local lower, upper = {}, {}
	for _, p in points do
		extendHull(lower, p)
	end
	for i = #points, 1, -1 do
		extendHull(upper, points[i])
	end
	-- Each half ends where the other starts.
	table.remove(lower)
	table.remove(upper)
	for _, p in upper do
		table.insert(lower, p)
	end
	return lower
end

-- Where the plane through `at` (normal `n`) cuts the convex hull of
-- `vertices`: a convex polygon in the basis u, v around `origin`, or nil.
local function section(vertices, at, n, origin, u, v)
	local side = table.create(#vertices)
	for k, p in vertices do
		side[k] = (p - at):Dot(n)
	end
	local points = {}
	local function add(p)
		local r = p - origin
		table.insert(points, { r:Dot(u), r:Dot(v) })
	end
	for a, p in vertices do
		if side[a] == 0 then
			add(p)
		end
		for b = a + 1, #vertices do
			if side[a] ~= 0 and side[b] ~= 0 and (side[a] < 0) ~= (side[b] < 0) then
				add(p + (vertices[b] - p) * (side[a] / (side[a] - side[b])))
			end
		end
	end
	if #points < 3 then
		return nil
	end
	local hull = convexHull(points)
	return if #hull >= 3 then hull else nil
end

-- The part of the plane through `at` (normal `n`) that the block or wedge
-- `s` holds from `depth` behind the plane to `depth` in front: a convex
-- polygon of world points on the plane, or nil (also for round shapes and
-- meshes, whose sections aren't polygons).
function Geometry.heldSection(s, at, n, depth)
	if s.shape ~= "Block" and s.shape ~= "Wedge" and s.shape ~= "CornerWedge" then
		return nil
	end
	-- Its box has to reach past both: parts resting on the plane don't.
	local middle = (s.pos - at):Dot(n)
	local h, axes = s.half, s.axes
	local extent = math.abs(axes[1]:Dot(n)) * h.X + math.abs(axes[2]:Dot(n)) * h.Y + math.abs(axes[3]:Dot(n)) * h.Z
	if middle - extent > -depth or middle + extent < depth then
		return nil
	end
	local vertices = Geometry.vertices(s)
	local u, v = planeBasis(n)
	local back = section(vertices, at - n * depth, n, at, u, v)
	local front = back and section(vertices, at + n * depth, n, at, u, v)
	if not front then
		return nil
	end
	local both = Geometry.clipPolygon(front, back)
	if #both < 3 then
		return nil
	end
	return toWorld(both, at, u, v)
end

-- Points to test whether a convex polygon (world points) is inside
-- something: its corners pulled `inset` studs toward its middle (at most
-- halfway), then the middle.
function Geometry.polygonSamples(points, inset)
	local middle = average(points)
	local samples = table.create(#points + 1)
	for i, p in points do
		local toward = middle - p
		local length = toward.Magnitude
		samples[i] = if length > 1e-9 then p + toward * math.min(inset / length, 0.5) else p
	end
	table.insert(samples, middle)
	return samples
end

-- Is (x, y) on the same side of every edge of convex `poly` (either winding),
-- at least `inset` from each?
local function insideBy(poly, x, y, inset)
	local sign = 0
	for i, a in poly do
		local b = poly[i % #poly + 1]
		local ex, ey = b[1] - a[1], b[2] - a[2]
		local length = math.sqrt(ex * ex + ey * ey)
		if length > 1e-9 then
			local d = (ex * (y - a[2]) - ey * (x - a[1])) / length
			if math.abs(d) < inset then
				return false
			end
			local s = if d > 0 then 1 else -1
			if sign == 0 then
				sign = s
			elseif s ~= sign then
				return false
			end
		end
	end
	return true
end

-- polygonSamples plus a grid over the (convex, planar) polygon at most
-- `spacing` apart, coarser if that would pass `maxSamples`: enough to find
-- a hole a terrain tunnel or the gap between two boulders leaves.
function Geometry.polygonGrid(points, inset, spacing, maxSamples)
	local samples = Geometry.polygonSamples(points, inset)
	if #points < 3 then
		return samples
	end
	local n = (points[2] - points[1]):Cross(points[3] - points[1])
	for i = 4, #points do
		if n.Magnitude > 1e-9 then
			break
		end
		n = (points[2] - points[1]):Cross(points[i] - points[1])
	end
	if n.Magnitude < 1e-9 then
		return samples
	end
	local u, v = planeBasis(n.Unit)
	local origin = points[1]
	local flat = project(points, origin, u, v)
	local u0, v0, u1, v1 = polygonBounds(flat)
	local step = math.max(spacing, math.sqrt((u1 - u0) * (v1 - v0) / math.max(maxSamples, 1)))
	local x = u0 + step / 2
	while x < u1 do
		local y = v0 + step / 2
		while y < v1 do
			if insideBy(flat, x, y, inset) then
				table.insert(samples, origin + u * x + v * y)
			end
			y += step
		end
		x += step
	end
	return samples
end

--------------------------------------------------------------------------------
-- Vertices and support points (for convex overlap tests)
--------------------------------------------------------------------------------

local BOX_CORNERS = {}
for _, x in { -1, 1 } do
	for _, y in { -1, 1 } do
		for _, z in { -1, 1 } do
			table.insert(BOX_CORNERS, Vector3.new(x, y, z))
		end
	end
end

-- Local-space corner points of a solid's shape (nil for round shapes).
-- "Other" (meshes, unions) gives its box corners.
function Geometry.localVertices(shape, h)
	if shape == "Block" or shape == "Other" then
		local out = {}
		for i, c in BOX_CORNERS do
			out[i] = c * h
		end
		return out
	elseif shape == "Wedge" then
		return {
			Vector3.new(-h.X, -h.Y, -h.Z),
			Vector3.new(h.X, -h.Y, -h.Z),
			Vector3.new(h.X, -h.Y, h.Z),
			Vector3.new(-h.X, -h.Y, h.Z),
			Vector3.new(-h.X, h.Y, h.Z),
			Vector3.new(h.X, h.Y, h.Z),
		}
	elseif shape == "CornerWedge" then
		return { cornerWedgeCorners(h) }
	end
	return nil
end

-- World-space corner points of a solid (cached; nil for round shapes).
function Geometry.vertices(s)
	if s.vertices == nil then
		local lv = Geometry.localVertices(s.shape, s.half)
		s.vertices = if lv then worldPoints(s.cf, lv) else false
	end
	return s.vertices or nil
end

-- The point of the solid furthest along world direction `dir` (its support
-- point). Exact for every shape BuildGuard knows; meshes and unions use
-- their box, or `s.hull` (world points) when set.
function Geometry.support(s, dir)
	local points = s.hull or Geometry.vertices(s)
	if points then
		local best, bestDot = points[1], -math.huge
		for _, p in points do
			local d = p:Dot(dir)
			if d > bestDot then
				best, bestDot = p, d
			end
		end
		return best
	end
	local h = s.half
	if s.shape == "Ball" then
		local r = math.min(h.X, h.Y, h.Z)
		local m = dir.Magnitude
		if m < 1e-12 then
			return s.pos
		end
		return s.pos + dir * (r / m)
	end
	-- Cylinder along local X.
	local axis = s.axes[1]
	local r = math.min(h.Y, h.Z)
	local along = dir:Dot(axis)
	local point = s.pos + axis * (if along >= 0 then h.X else -h.X)
	local radial = dir - axis * along
	local m = radial.Magnitude
	if m > 1e-12 then
		point += radial * (r / m)
	end
	return point
end

--------------------------------------------------------------------------------
-- Points and rays
--------------------------------------------------------------------------------

-- Is `p` inside the solid? Only answers for shapes we know exactly; "Other"
-- (meshes, unions) returns false so it can never cause a false alarm.
function Geometry.containsPoint(s, p)
	local lp = s.cf:PointToObjectSpace(p)
	local h = s.half
	if math.abs(lp.X) > h.X or math.abs(lp.Y) > h.Y or math.abs(lp.Z) > h.Z then
		return false
	end
	if s.shape == "Block" then
		return true
	elseif s.shape == "Wedge" then
		return lp.Y / h.Y <= lp.Z / h.Z
	elseif s.shape == "CornerWedge" then
		local y = lp.Y / h.Y
		return y <= lp.X / h.X and y <= -lp.Z / h.Z
	elseif s.shape == "Cylinder" then
		local r = math.min(h.Y, h.Z)
		return lp.Y * lp.Y + lp.Z * lp.Z <= r * r
	elseif s.shape == "Ball" then
		local r = math.min(h.X, h.Y, h.Z)
		return lp.Magnitude <= r
	end
	return false
end

-- Distance along `direction` (a unit vector) to where the ray enters the
-- solid's box, or nil. Rays that start inside don't hit, as in Roblox.
function Geometry.rayBox(s, origin, direction, maxDistance)
	local o = s.cf:PointToObjectSpace(origin)
	local d = s.cf:VectorToObjectSpace(direction)
	local tMin, tMax = -math.huge, math.huge
	for axis = 1, 3 do
		local oa, da, ha = component(o, axis), component(d, axis), component(s.half, axis)
		if math.abs(da) < 1e-12 then
			if math.abs(oa) > ha then
				return nil
			end
		else
			local t1, t2 = (-ha - oa) / da, (ha - oa) / da
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tMin, tMax = math.max(tMin, t1), math.min(tMax, t2)
			if tMin > tMax then
				return nil
			end
		end
	end
	if tMin < 0 or tMin > maxDistance then
		return nil
	end
	return tMin
end

-- A grid of points across a face rectangle, at most `spacing` studs apart
-- (always including the corners and centre), pulled in from the edges by
-- `inset` (fraction of each half-extent, capped at `maxInset` studs).
function Geometry.faceSamples(s, faceName, inset, maxInset, spacing)
	local axis, sign = table.unpack(Geometry.FACE_AXIS[faceName])
	local hb, hc = component(s.half, axis % 3 + 1), component(s.half, (axis + 1) % 3 + 1)
	local ib = math.max(hb - math.min(hb * inset, maxInset), 0)
	local ic = math.max(hc - math.min(hc * inset, maxInset), 0)
	-- An even number of intervals keeps the centre in the grid.
	local function count(extent)
		local n = math.clamp(math.ceil(2 * extent / spacing), 2, 64)
		return if n % 2 == 1 then n + 1 else n
	end
	local nb, nc = count(ib), count(ic)
	local along = sign * component(s.half, axis)
	local samples = {}
	for i = 0, nb do
		for j = 0, nc do
			local p = facePoint(axis, along, -ib + 2 * ib * i / nb, -ic + 2 * ic * j / nc)
			table.insert(samples, s.cf:PointToWorldSpace(p))
		end
	end
	return samples
end

-- The top (+Y) face as world corner points.
function Geometry.topCorners(s)
	local h = s.half
	local out = {}
	for i, st in RECT_CORNERS do
		out[i] = s.cf:PointToWorldSpace(Vector3.new(st[1] * h.X, h.Y, st[2] * h.Z))
	end
	return out
end

-- Closest point on the top (+Y) face rectangle to `p`.
function Geometry.closestOnTop(s, p)
	local lp = s.cf:PointToObjectSpace(p)
	local h = s.half
	return s.cf:PointToWorldSpace(Vector3.new(math.clamp(lp.X, -h.X, h.X), h.Y, math.clamp(lp.Z, -h.Z, h.Z)))
end

-- Height of the top face's plane at world (x, z), or nil if it's near-vertical.
function Geometry.topHeightAt(s, x, z)
	local n = s.axes[2]
	if n.Y < 0.2 then
		return nil
	end
	local p = s.cf:PointToWorldSpace(Vector3.new(0, s.half.Y, 0))
	return p.Y - (n.X * (x - p.X) + n.Z * (z - p.Z)) / n.Y
end

return Geometry
