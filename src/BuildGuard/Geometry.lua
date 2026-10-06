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

local function vec(axis, value)
	if axis == 1 then
		return Vector3.new(value, 0, 0)
	elseif axis == 2 then
		return Vector3.new(0, value, 0)
	end
	return Vector3.new(0, 0, value)
end
Geometry.axisVector = vec

-- "Block" | "Wedge" | "Cylinder" | "Ball" | "Other" (mesh, union, truss, corner wedge)
function Geometry.shapeOf(part)
	if part:IsA("WedgePart") then
		return "Wedge"
	end
	if part:IsA("Part") then
		local ok, shape = pcall(function()
			return part.Shape.Name
		end)
		if ok then
			if shape == "Ball" or shape == "Cylinder" or shape == "Wedge" then
				return shape
			elseif shape == "CornerWedge" then
				return "Other"
			end
		end
		return "Block"
	end
	return "Other"
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

local function rectFace(h, axis, sign)
	local b, c = axis % 3 + 1, (axis + 1) % 3 + 1
	local points = {}
	for _, st in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		local coords = { 0, 0, 0 }
		coords[axis] = sign * component(h, axis)
		coords[b] = st[1] * component(h, b)
		coords[c] = st[2] * component(h, c)
		table.insert(points, Vector3.new(coords[1], coords[2], coords[3]))
	end
	return points
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
			normal = normal or vec(axis, sign),
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
		local points = {}
		local sum = Vector3.zero
		for i, p in f.points do
			local wp = s.cf:PointToWorldSpace(p)
			points[i] = wp
			sum += wp
		end
		table.insert(result, {
			name = f.name,
			axis = f.axis,
			sign = f.sign,
			normal = s.cf:VectorToWorldSpace(f.normal),
			points = points,
			center = sum / #points,
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
				local pMin, pMax, qMin, qMax = math.huge, -math.huge, math.huge, -math.huge
				for _, v in p do
					local d = v[1] * nx + v[2] * ny
					pMin, pMax = math.min(pMin, d), math.max(pMax, d)
				end
				for _, v in q do
					local d = v[1] * nx + v[2] * ny
					qMin, qMax = math.min(qMin, d), math.max(qMax, d)
				end
				best = math.max(best, qMin - pMax, pMin - qMax)
			end
		end
	end
	return best
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

-- If faces `fa` and `fb` point the same way, lie within `tolerance` of each
-- other and overlap, returns (overlapArea, distance) where distance is how far
-- fb's plane sits in front of fa's along fa's normal. Otherwise nil.
function Geometry.coplanarOverlap(fa, fb, tolerance, minArea)
	if fa.normal:Dot(fb.normal) < 1 - 1e-4 then
		return nil
	end
	local distance = (fb.center - fa.center):Dot(fa.normal)
	if math.abs(distance) > tolerance then
		return nil
	end
	local u, v = planeBasis(fa.normal)
	local clipped = Geometry.clipPolygon(project(fb.points, fa.center, u, v), project(fa.points, fa.center, u, v))
	if #clipped < 3 then
		return nil
	end
	local area = Geometry.polygonArea(clipped)
	if area < minArea then
		return nil
	end
	return area, distance
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
	local as = Geometry.FACE_AXIS[faceName]
	local axis, sign = as[1], as[2]
	local b, c = axis % 3 + 1, (axis + 1) % 3 + 1
	local hb, hc = component(s.half, b), component(s.half, c)
	local ib = math.max(hb - math.min(hb * inset, maxInset), 0)
	local ic = math.max(hc - math.min(hc * inset, maxInset), 0)
	-- An even number of intervals keeps the centre in the grid.
	local function count(extent)
		local n = math.clamp(math.ceil(2 * extent / spacing), 2, 64)
		return if n % 2 == 1 then n + 1 else n
	end
	local nb, nc = count(ib), count(ic)
	local samples = {}
	for i = 0, nb do
		for j = 0, nc do
			local coords = { 0, 0, 0 }
			coords[axis] = sign * component(s.half, axis)
			coords[b] = -ib + 2 * ib * i / nb
			coords[c] = -ic + 2 * ic * j / nc
			table.insert(samples, s.cf:PointToWorldSpace(Vector3.new(coords[1], coords[2], coords[3])))
		end
	end
	return samples
end

-- The top (+Y) face as world corner points.
function Geometry.topCorners(s)
	local h = s.half
	local out = {}
	for _, st in { { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } } do
		table.insert(out, s.cf:PointToWorldSpace(Vector3.new(st[1] * h.X, h.Y, st[2] * h.Z)))
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
