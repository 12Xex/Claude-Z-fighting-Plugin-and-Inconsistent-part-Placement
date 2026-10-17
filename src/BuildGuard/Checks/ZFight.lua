--[[
	Z-fight scan: finds pairs of visible parts whose surfaces lie on top of
	each other and flicker:
	  * flat faces pointing the same way, within zFightTolerance and
	    overlapping: blocks, wedges, corner wedges, cylinder end caps, and the
	    triangles of meshes the world can read (Meshes.lua);
	  * round surfaces: two cylinders on one axis, or two balls with one
	    centre, with the same radius (a rod in a sleeve);
	  * duplicates (same class, mesh, position, rotation and size), reported
	    once as such, and mesh boxes that overlap almost completely.

	Faces touching back to back (a part resting on another) are hidden, not
	flickering. So is a same-facing overlap nothing can see: covered all over
	by faces of third parts pointing the other way, or held inside third
	parts or deep in terrain (see `shownFilter`).

	Seams: part faces overlapping only in strips narrower than
	zFightSeamWidth, each strip at most half as wide as either face (pieces
	laid edge to edge, overlapping by a hair), are a "zseam" warning, not
	fixed: they barely show, and a nudge would leave a step. A thin inlay is
	as wide as its overlap, so it still z-fights. Mesh triangles are never
	seams: a thin one can be a sliver of a wide overlap.

	Far view: in a model seen from far away (zFightViewDistance), same-facing
	faces need 2 * Config.depthStep(distance) between them. Closer than that,
	but beyond zFightTolerance, is a "zgap" warning; under about 130 studs the
	usual zFightNudge already holds, so there are none.

	The fix plan moves one part of each pair (the "mover") so its surface
	clears the other by the pair's face gap (zFightNudge, or more when seen
	from far away). A pair of locked (or ground) parts has no mover and isn't
	auto-fixable. Flat faces are nudged outward, or sink into a part hiding
	the mover's other side (see `clearAxis`); round surfaces grow, keeping
	the CFrame so joints stay valid. A zgap keeps its order: a face behind is
	pushed further back, an inner ball or rod shrinks. When the other part
	already has a plan item (a road's snap, another mover), the mover clears
	where it will be.
]]

local Config = require(script.Parent.Parent.Config)
local Geometry = require(script.Parent.Parent.Geometry)
local SpatialHash = require(script.Parent.Parent.SpatialHash)
local Classify = require(script.Parent.Parent.Classify)
local Plan = require(script.Parent.Parent.Plan)
local Util = require(script.Parent.Parent.Util)
local Kinematics = require(script.Parent.Parent.Kinematics)
local Meshes = require(script.Parent.Meshes)

local ZFight = {}

-- Normals this close (dot product) point the same way.
local PARALLEL = 1 - 1e-4
-- Below this many face pairs, test every pair; above, index the faces.
local BRUTE_FORCE_PAIRS = 64
-- Smallest overlap (studs²) one mesh triangle contributes; their sum must
-- still reach zFightMinOverlapArea.
local MIN_TRIANGLE_OVERLAP = 1e-6
-- A fixed pair sits exactly at the face gap; float rounding mustn't flag it.
local GAP_SLACK = 1e-3
-- Pair and face tests between ctx.yield calls.
local WORK_PER_YIELD = 256
-- Moves smaller than this (studs) are float rounding, not a need.
local MIN_NEED = 1e-6
-- A seam's strip is at most this share of each face's width: pieces laid
-- edge to edge each reach well past it, but an inlay is all overlap.
local SEAM_SHARE = 0.5
-- A mover sunk into the part hiding one side keeps its far face more than
-- zFightTolerance plus this clear of the surface it sinks into.
local SINK_MARGIN = 0.005
-- Share of a contact's overlap that may stay uncovered (arithmetic rounding;
-- Geometry.overlapCover already allows for float32 positions), and never
-- more than zFightMinOverlapArea of it.
local COVER_SLACK = 1e-6
-- What's left open of a covered overlap is sampled this far apart (under
-- Studio's 4-stud terrain voxels), up to this many samples per piece.
local OPEN_SPACING = 2
local OPEN_SAMPLES = 256
-- Above this many cover faces near a pair, index them.
local BRUTE_FORCE_COVERS = 16
-- More distinct contact planes than this in one pair (a curved mesh): take
-- every face of the parts nearby as a possible cover.
local MAX_COVER_PLANES = 32
-- Pairs whose contacts span more than this (studs) look up the parts that
-- could hide each contact on its own.
local NEARBY_EXTENT = 256
-- Parts more see-through than this hide nothing behind them (Transparency
-- is stored as float32: 0.05 reads back as 0.0500000007).
local OPAQUE_TRANSPARENCY = 0.05 + 1e-6
local SEE_THROUGH = { Glass = true, ForceField = true }
local NO_FACES = {}

-- Does `part` hide what's behind it? Glass and ForceField draw see-through,
-- and so does any Transparency above 0.05.
local function opaque(part)
	if part.Transparency > OPAQUE_TRANSPARENCY then
		return false
	end
	local material = Util.prop(part, "Material")
	return not (material and SEE_THROUGH[material.Name])
end

-- Do the boxes of `a` and `b` (their `min` and `max`) come within `margin`?
local function boxesNear(a, b, margin)
	return a.min.X <= b.max.X + margin
		and b.min.X <= a.max.X + margin
		and a.min.Y <= b.max.Y + margin
		and b.min.Y <= a.max.Y + margin
		and a.min.Z <= b.max.Z + margin
		and b.min.Z <= a.max.Z + margin
end

-- Does box `b` ({ minX, minY, minZ, maxX, maxY, maxZ }) meet x0..x1, y0..y1,
-- z0..z1? Plain numbers: Vector3 fields are slow to read in hot loops.
local function boxMeets(b, x0, y0, z0, x1, y1, z1)
	return b[1] <= x1 and x0 <= b[4] and b[2] <= y1 and y0 <= b[5] and b[3] <= z1 and z0 <= b[6]
end

-- `fn` remembering each key's result (false too), and the table of results.
local function cached(fn)
	local results = {}
	return function(key)
		local result = results[key]
		if result == nil then
			result = fn(key)
			results[key] = result
		end
		return result
	end, results
end

-- The largest face gap any far-viewed model or part asks for (0 when none).
-- Every config a pair can get is the config of some ancestor, so walk them.
local function farViewGap(ctx)
	local best, seen = 0, {}
	for _, s in ctx.solids do
		local node = s.part
		while node and not seen[node] do
			seen[node] = true
			local config = ctx.configFor(node)
			if (config.zFightViewDistance or 0) > 0 then
				best = math.max(best, Config.faceGap(config))
			end
			node = node.Parent
		end
	end
	return best
end

--------------------------------------------------------------------------------
-- Flat faces
--------------------------------------------------------------------------------

-- World bounding box of a face (cached on it as `min`, `max`).
local function bounds(f)
	if not f.min then
		local lo, hi = f.points[1], f.points[1]
		for _, p in f.points do
			lo, hi = lo:Min(p), hi:Max(p)
		end
		f.min, f.max = lo, hi
	end
	return f.min, f.max
end

-- Thinnest extent of a flat face (cached on it), as Geometry.polygonWidth.
local function faceWidth(f)
	if not f.width then
		local points, best = f.points, math.huge
		for i, a in points do
			local edge = points[i % #points + 1] - a
			local length = edge.Magnitude
			if length > 1e-9 then
				local far = 0
				for _, p in points do
					far = math.max(far, (p - a):Cross(edge).Magnitude / length)
				end
				best = math.min(best, far)
			end
		end
		f.width = if best == math.huge then 0 else best
	end
	return f.width
end

-- Area and perimeter of a flat face (cached on it).
local function faceSize(f)
	if not f.surface then
		local points, surface, perimeter = f.points, 0, 0
		for k = 3, #points do
			surface += (points[k - 1] - points[1]):Cross(points[k] - points[1]).Magnitude / 2
		end
		for k, p in points do
			perimeter += (points[k % #points + 1] - p).Magnitude
		end
		f.surface, f.perimeter = surface, perimeter
	end
	return f.surface, f.perimeter
end

-- Do the boxes of faces `fa` and `fb` come within `margin`?
local function boundsTouch(fa, fb, margin)
	bounds(fa)
	bounds(fb)
	return boxesNear(fa, fb, margin)
end

-- A spatial index over many faces (a mesh's triangles), cell size from their
-- average extent.
local function faceIndex(faces)
	local extent = 0
	for _, f in faces do
		local lo, hi = bounds(f)
		local d = hi - lo
		extent += math.max(d.X, d.Y, d.Z)
	end
	local hash = SpatialHash.new(math.clamp(2 * extent / #faces, 0.25, 64))
	for k, f in faces do
		hash:insert(k, bounds(f))
	end
	return hash
end

-- Same-facing faces of `facesA` and `facesB` within `search` of each other
-- that overlap: { faceA, faceB, area, distance, position, width }. Calls
-- `worked()` once per face pair tested.
local function faceContacts(facesA, facesB, search, minArea, indexOf, worked)
	local contacts = {}
	local function test(fa, fb)
		worked()
		if fa.normal:Dot(fb.normal) < PARALLEL or not boundsTouch(fa, fb, search) then
			return
		end
		local floor = if fa.triangle or fb.triangle then MIN_TRIANGLE_OVERLAP else minArea
		local area, distance, at, width = Geometry.coplanarOverlap(fa, fb, search, floor)
		if area then
			table.insert(contacts, { faceA = fa, faceB = fb, area = area, distance = distance, position = at, width = width })
		end
	end
	local margin = Vector3.one * search
	if #facesA * #facesB <= BRUTE_FORCE_PAIRS then
		for _, fa in facesA do
			for _, fb in facesB do
				test(fa, fb)
			end
		end
	elseif #facesB >= #facesA then
		local index = indexOf(facesB)
		for _, fa in facesA do
			local lo, hi = bounds(fa)
			for _, k in index:query(lo - margin, hi + margin) do
				test(fa, facesB[k])
			end
		end
	else
		local index = indexOf(facesA)
		for _, fb in facesB do
			local lo, hi = bounds(fb)
			for _, k in index:query(lo - margin, hi + margin) do
				test(facesA[k], fb)
			end
		end
	end
	return contacts
end

--------------------------------------------------------------------------------
-- Round surfaces
--------------------------------------------------------------------------------

local ROUND_FACE = { name = "Round" }

local function radius(s)
	if s.shape == "Ball" then
		return math.min(s.half.X, s.half.Y, s.half.Z)
	end
	return math.min(s.half.Y, s.half.Z)
end

-- Two cylinders on one axis (within `tolerance`) or two balls with one
-- centre, whose radii differ by at most `search`. Returns a contact with the
-- radii, or nil.
local function roundContact(a, b, tolerance, search, minArea)
	if a.shape ~= b.shape or (a.shape ~= "Cylinder" and a.shape ~= "Ball") then
		return nil
	end
	local ra, rb = radius(a), radius(b)
	if math.abs(ra - rb) > search then
		return nil
	end
	local area, position
	if a.shape == "Ball" then
		if (b.pos - a.pos).Magnitude > tolerance then
			return nil
		end
		area, position = 4 * math.pi * math.min(ra, rb) ^ 2, a.pos
	else
		local axis = a.axes[1]
		if math.abs(axis:Dot(b.axes[1])) < PARALLEL then
			return nil
		end
		local offset = b.pos - a.pos
		local along = offset:Dot(axis)
		if (offset - axis * along).Magnitude > tolerance then
			return nil
		end
		-- The stretch of axis both cylinders cover.
		local from = math.max(-a.half.X, along - b.half.X)
		local to = math.min(a.half.X, along + b.half.X)
		if to <= from then
			return nil
		end
		area, position = 2 * math.pi * math.min(ra, rb) * (to - from), a.pos + axis * ((from + to) / 2)
	end
	if area < minArea then
		return nil
	end
	return {
		round = a.shape,
		faceA = ROUND_FACE,
		faceB = ROUND_FACE,
		area = area,
		distance = rb - ra,
		position = position,
		radiusA = ra,
		radiusB = rb,
	}
end

--------------------------------------------------------------------------------
-- Issues
--------------------------------------------------------------------------------

-- "Front/Front, tri/Top x12"
local function contactNames(contacts)
	local order, counts = {}, {}
	for _, c in contacts do
		local name = c.faceA.name .. "/" .. c.faceB.name
		if not counts[name] then
			counts[name] = 0
			table.insert(order, name)
		end
		counts[name] += 1
	end
	for i, name in order do
		if counts[name] > 1 then
			order[i] = ("%s x%d"):format(name, counts[name])
		end
	end
	return table.concat(order, ", ")
end

-- How far away a face gap stops flickering (Config.faceGap the other way).
local function holdsTo(gap)
	return math.sqrt(gap * Config.NEAR_PLANE * Config.DEPTH_STEPS / 2)
end

-- "0.012" or "2.00" (studs).
local function widthText(width)
	return if width < 1 then ("%.3f"):format(width) else ("%.2f"):format(width)
end

-- ", a strip 0.050 wide" for a contact at least four times as long as it
-- is wide, else ", 2.00 wide"; "" without a contact.
local function widthNote(c)
	if not c then
		return ""
	end
	local strip = if c.area >= 4 * c.width * c.width then "a strip " else ""
	return (", %s%s wide"):format(strip, widthText(c.width))
end

-- Turns a pair's contacts into a "zfight", "zgap" or "zseam" issue, or nil
-- when the contacts are only close enough for some other, far-viewed model.
local function pairIssue(ctx, a, b, contacts)
	local base = ctx.config
	local tolerance = base.zFightTolerance
	local pairConfig, sources = ctx.pairConfig(a.part, b.part)
	local viewDistance = pairConfig.zFightViewDistance or 0
	-- Past the tolerance, only the far view's own need counts: up close
	-- (under about 130 studs) the usual nudge already holds.
	local limit = tolerance
	if viewDistance > 0 then
		limit = math.max(tolerance, 2 * Config.depthStep(viewDistance) - GAP_SLACK)
	end

	local kept, total, fighting, closest, largest = {}, 0, false, math.huge, nil
	for _, c in contacts do
		local d = math.abs(c.distance)
		if d <= tolerance or d < limit then
			table.insert(kept, c)
			total += c.area
			fighting = fighting or d <= tolerance
			closest = math.min(closest, d)
			if not largest or c.area > largest.area then
				largest = c
			end
		end
	end
	if #kept == 0 or total < base.zFightMinOverlapArea then
		return nil
	end
	-- The widest overlap between flat part faces, and whether each is a thin
	-- slice of both faces (`slivers`). Round surfaces have no width, and a
	-- thin mesh triangle may be one sliver of a wide overlap: neither counts.
	local flat, widest, slivers = 0, nil, true
	for _, c in kept do
		if c.width and not (c.faceA.triangle or c.faceB.triangle) then
			flat += 1
			if not widest or c.width > widest.width then
				widest = c
			end
			slivers = slivers and c.width <= SEAM_SHARE * faceWidth(c.faceA) and c.width <= SEAM_SHARE * faceWidth(c.faceB)
		end
	end

	local pathA, pathB = ctx.path(a.part), ctx.path(b.part)
	local names, where = contactNames(kept), Util.vector(largest.position)
	local issue = {
		check = "zfight",
		severity = "error",
		planner = "zfight",
		parts = { a.part, b.part },
		paths = { pathA, pathB },
		solids = { a, b },
		contacts = kept,
		-- The fix's gap comes from the pair's settings.
		config = pairConfig,
		position = largest.position,
		width = widest and widest.width,
	}
	if widest and flat == #kept and slivers and widest.width < base.zFightSeamWidth then
		-- Only thin strips overlap: barely visible, and a nudge would leave
		-- a step between pieces meant to be flush, so it's left to a person.
		issue.check, issue.severity, issue.planner = "zseam", "warning", nil
		issue.message = (
			"%s and %s overlap in a strip %s studs wide along their shared edge (%s faces, %.2f studs²) at %s: "
			.. "barely visible; pull the pieces apart in their plane (often a generator overlapping pieces by a hair)"
		):format(pathA, pathB, widthText(widest.width), names, total, where)
		return issue
	end
	if fighting then
		local text = "%s and %s z-fight at %s: %s face(s) overlap %.2f studs²%s"
		issue.message = text:format(pathA, pathB, where, names, total, widthNote(widest))
	else
		local source = sources and sources.zFightViewDistance
		issue.check, issue.severity = "zgap", "warning"
		issue.message = (
			"%s and %s are %.3f studs apart at %s (%s face(s), %.2f studs²): a gap that small flickers "
			.. "beyond about %d studs, but %s is seen from %g studs (zFightViewDistance): leave at least %.3f"
		):format(
			pathA,
			pathB,
			closest,
			where,
			names,
			total,
			math.floor(holdsTo(closest) + 0.5),
			if source then ctx.path(source) else "the build",
			viewDistance,
			Config.faceGap(pairConfig)
		)
	end
	-- The fix moves one part of the pair; locked and ground parts never move.
	if Classify.isLocked(a.part, base) and Classify.isLocked(b.part, base) then
		issue.planner = nil
		issue.message ..= " — both parts are locked (or ground): move one by hand, or unlock one"
	end
	return issue
end

--------------------------------------------------------------------------------
-- Hidden contacts
--------------------------------------------------------------------------------

-- World bounds of a contact's overlap (cached on it).
local function overlapBounds(c)
	if not c.lo then
		local aLo, aHi = bounds(c.faceA)
		local bLo, bHi = bounds(c.faceB)
		local lo, hi = aLo:Max(bLo), aHi:Min(bHi)
		c.lo, c.hi = lo:Min(hi), lo:Max(hi)
	end
	return c.lo, c.hi
end

-- World bounds of every overlap in `contacts`.
local function contactsBounds(contacts)
	local lo, hi = overlapBounds(contacts[1])
	for _, c in contacts do
		local cLo, cHi = overlapBounds(c)
		lo, hi = lo:Min(cLo), hi:Max(cHi)
	end
	return lo, hi
end

-- The planes of flat `contacts`, { normal, at }; nil past MAX_COVER_PLANES.
local function contactPlanes(contacts, tolerance)
	local planes = {}
	for _, c in contacts do
		local f = c.faceA
		local known = false
		for _, plane in planes do
			if f.normal:Dot(plane.normal) >= PARALLEL and math.abs((f.center - plane.at):Dot(plane.normal)) <= tolerance then
				known = true
				break
			end
		end
		if not known then
			if #planes >= MAX_COVER_PLANES then
				return nil
			end
			table.insert(planes, { normal = f.normal, at = f.center })
		end
	end
	return planes
end

-- Could face `f` cover a contact on one of `planes`: pointing against it, on
-- it or up to `reach` in front? Any face could when `planes` is nil.
local function coversPlane(f, planes, reach, tolerance)
	if not planes then
		return true
	end
	for _, plane in planes do
		if f.normal:Dot(plane.normal) <= -PARALLEL then
			local d = (f.center - plane.at):Dot(plane.normal)
			if d >= -2 * tolerance and d <= reach + tolerance then
				return true
			end
		end
	end
	return false
end

-- Returns shown(contacts, i, j): the flat contacts between candidates `i`
-- and `j` less those nothing can see. A contact is hidden when it is
--   * inside third parts or deep in terrain, just in front and just behind
--     (footings of overlapping road pieces in the ground, a contact sunk
--     inside a road), or
--   * covered all over by third parts' faces pointing the other way, on it
--     or up to their reach in front (a footing's top flush with the pad it
--     passes through, both under the road; two layer-0 items' bottoms on the
--     road), with what parts hold (see `hidden`).
-- A contact partly in view still counts, all of it.
local function shownFilter(ctx, candidates, hash, isMeshLike, worked, search)
	local tolerance, minArea = ctx.config.zFightTolerance, ctx.config.zFightMinOverlapArea

	-- Only parts that stay put hide anything (a loose crate or a parked cart
	-- moves off): anchored ones, or ones rigidly joined to an anchored part.
	local anchoredAssembly, assemblyOf = nil, nil
	local function staysPut(part)
		if Util.prop(part, "Anchored", true) or not ctx.graph then
			return true
		end
		if not anchoredAssembly then
			anchoredAssembly = {}
			assemblyOf = Kinematics.assemblies(ctx.graph()).of
			for p, id in assemblyOf do
				if Util.prop(p, "Anchored", true) then
					anchoredAssembly[id] = true
				end
			end
		end
		local id = assemblyOf[part]
		return id ~= nil and anchoredAssembly[id] == true
	end
	local function inVehicle(part)
		return ctx.vehicleOf ~= nil and ctx.vehicleOf(part) ~= nil
	end
	-- What can hide a contact: opaque candidates that stay put, outside
	-- vehicles, and not meshes (their triangles aren't read for it).
	local hides = cached(function(k)
		local s = candidates[k]
		return opaque(s.part) and not isMeshLike(s) and not inVehicle(s.part) and staysPut(s.part)
	end)

	-- How far in front of a contact a cover's face may lie: up to its own
	-- zFightNudge, the gap a fix leaves when it lifts the cover (a road
	-- nudged off its footing and the pad around it still hides their tops).
	local reach, coverMargin = {}, search
	for k, s in candidates do
		worked()
		reach[k] = math.max(tolerance, ctx.configFor(s.part).zFightNudge) + GAP_SLACK
		coverMargin = math.max(coverMargin, reach[k])
	end
	local coverBox = Vector3.one * coverMargin
	-- Open overlap is tested this far in front of and behind its plane, so a
	-- part only resting on it (its face a cover) doesn't count as holding it.
	local depth = tolerance / 2
	local insideTerrain = ctx.world and ctx.world.isInsideTerrain
	local function inTerrain(p)
		return insideTerrain ~= nil and insideTerrain(p) == true
	end

	local boxOf = cached(function(s)
		local lo, hi = s.min, s.max
		return { lo.X, lo.Y, lo.Z, hi.X, hi.Y, hi.Z }
	end)

	-- The parts other than `i` and `j` that can hide something, whose boxes
	-- meet lo..hi.
	local function hidersIn(lo, hi, i, j)
		local x0, y0, z0, x1, y1, z1 = lo.X, lo.Y, lo.Z, hi.X, hi.Y, hi.Z
		local out = {}
		for _, k in hash:query(lo, hi) do
			worked()
			if k ~= i and k ~= j and boxMeets(boxOf(candidates[k]), x0, y0, z0, x1, y1, z1) and hides(k) then
				table.insert(out, candidates[k])
			end
		end
		return out
	end

	-- Is `p` inside one of `solids`, or deep in terrain?
	local function inside(p, solids)
		local x, y, z = p.X, p.Y, p.Z
		for _, s in solids do
			if boxMeets(boxOf(s), x, y, z, x, y, z) and Geometry.containsPoint(s, p) then
				return true
			end
		end
		return inTerrain(p)
	end

	-- Does one of `solids` have its box on the stretch from `depth` to
	-- `coverMargin` in front of `p` (along `n`), or is terrain deep just in
	-- front? Anything covering or holding `p` does.
	local function shaded(p, n, solids)
		local x, y, z, nx, ny, nz = p.X, p.Y, p.Z, n.X, n.Y, n.Z
		local ax, ay, az = x + nx * depth, y + ny * depth, z + nz * depth
		local bx, by, bz = x + nx * coverMargin, y + ny * coverMargin, z + nz * coverMargin
		-- Grown by the float sliver, as overlapCover grows covers: a hairline
		-- joint between two covers still counts as covered.
		local grow = Geometry.floatSliver(p)
		local x0, x1 = math.min(ax, bx) - grow, math.max(ax, bx) + grow
		local y0, y1 = math.min(ay, by) - grow, math.max(ay, by) + grow
		local z0, z1 = math.min(az, bz) - grow, math.max(az, bz) + grow
		for _, s in solids do
			if boxMeets(boxOf(s), x0, y0, z0, x1, y1, z1) then
				return true
			end
		end
		return inTerrain(Vector3.new(ax, ay, az))
	end

	-- Do `solids` (or terrain) hold every one of `samples`, just in front of
	-- and just behind it (along `n`)?
	local function held(samples, solids, n)
		local ahead = n * depth
		for _, p in samples do
			worked()
			if not inside(p + ahead, solids) or not inside(p - ahead, solids) then
				return false
			end
		end
		return true
	end

	-- Does one of `solids` hold every one of `samples` just in front (along
	-- `n`), and one (maybe another) every one just behind? Parts are convex,
	-- so they then hold the whole polygon the samples outline.
	local function heldWhole(samples, solids, n)
		local function oneHolds(offset)
			for _, s in solids do
				local all = true
				for _, p in samples do
					worked()
					if not Geometry.containsPoint(s, p + offset) then
						all = false
						break
					end
				end
				if all then
					return true
				end
			end
			return false
		end
		return oneHolds(n * depth) and oneHolds(n * -depth)
	end

	-- What could hide contact `c`: "inside" when its overlap is inside an
	-- opaque part, "maybe" when covers or what holds it could (see `hidden`),
	-- nil when it shows: some sample of the overlap has no hiding part's box
	-- just in front (in the open, usually its middle). Also returns the
	-- hiding parts near it (`nearby`, the pair's, when they're few).
	local function whatHides(c, i, j, nearby)
		local n = c.faceA.normal
		local back, front = n * -depth, n * coverMargin
		local below, above = back:Min(front), back:Max(front)
		local solids = nearby
		if not solids or #solids > BRUTE_FORCE_COVERS then
			local middle = c.position
			if not shaded(middle, n, hidersIn(middle + below, middle + above, i, j)) then
				return nil
			end
			local lo, hi = overlapBounds(c)
			solids = hidersIn(lo + below, hi + above, i, j)
		elseif not shaded(c.position, n, solids) then
			return nil
		end
		local overlap = Geometry.overlapPolygon(c.faceA, c.faceB)
		if #overlap < 3 then
			return nil
		end
		local samples = Geometry.polygonSamples(overlap, 2 * Geometry.floatSliver(c.faceA.center))
		if heldWhole(samples, solids, n) then
			return "inside", solids
		end
		for _, p in samples do
			worked()
			if not shaded(p, n, solids) then
				return nil
			end
		end
		return "maybe", solids
	end

	-- Faces of hiding parts other than `i` and `j` that could cover the flat
	-- `contacts`: { faces, reaches, index? } (indexed when there are many).
	local function coversNear(contacts, i, j)
		local lo, hi = contactsBounds(contacts)
		local box = { min = lo, max = hi }
		local planes = contactPlanes(contacts, tolerance)
		local faces, reaches = {}, {}
		for _, k in hash:query(lo - coverBox, hi + coverBox) do
			worked()
			local s = candidates[k]
			if k ~= i and k ~= j and boxesNear(s, box, coverMargin) and hides(k) then
				for _, f in Geometry.faces(s) do
					if coversPlane(f, planes, reach[k], tolerance) then
						table.insert(faces, f)
						table.insert(reaches, reach[k])
					end
				end
			end
		end
		return { faces = faces, reaches = reaches, index = if #faces > BRUTE_FORCE_COVERS then faceIndex(faces) else nil }
	end

	-- The faces of `covers` back to back with contact `c`: on both its faces
	-- or up to their reach in front.
	local function coversOn(c, covers)
		local fa, fb = c.faceA, c.faceB
		local lo, hi = overlapBounds(c)
		local found = if covers.index then covers.index:query(lo - coverBox, hi + coverBox) else nil
		local matched = {}
		for m = 1, if found then #found else #covers.faces do
			worked()
			local n = if found then found[m] else m
			local f, r = covers.faces[n], covers.reaches[n]
			if f.normal:Dot(fa.normal) <= -PARALLEL then
				local inFrontA = (f.center - fa.center):Dot(fa.normal)
				local inFrontB = (f.center - fb.center):Dot(fa.normal)
				if
					inFrontA >= -tolerance
					and inFrontA <= r
					and inFrontB >= -tolerance
					and inFrontB <= r
					and boundsTouch(f, fa, r)
					and boundsTouch(f, fb, r)
				then
					table.insert(matched, f)
				end
			end
		end
		return matched
	end

	-- The most area `polygons` can cover once overlapCover grows them by
	-- `grow`.
	local function coverable(polygons, grow)
		local sum = 0
		for _, f in polygons do
			worked()
			local surface, perimeter = faceSize(f)
			sum += surface + perimeter * grow + 8 * #f.points * grow * grow
		end
		return sum
	end

	-- Is contact `c` hidden all the same? Its overlap is covered by the
	-- union of `covers` back to back with it and the sections of it that
	-- `solids` hold (footings in ground made of several slabs), and what's
	-- left open, if any, is deep in terrain or round parts.
	local function hidden(c, covers, solids)
		local fa, fb = c.faceA, c.faceB
		local matched = coversOn(c, covers)
		local sections = {}
		for _, s in solids do
			worked()
			local section = Geometry.heldSection(s, fa.center, fa.normal, depth)
			if section then
				table.insert(sections, { points = section })
			end
		end
		local grow = Geometry.floatSliver(fa.center)
		if #matched > BRUTE_FORCE_COVERS and coverable(matched, grow) + coverable(sections, grow) < c.area * (1 - COVER_SLACK) then
			-- Many small covers (crates on a slab) that, with the held
			-- sections, add up to less than the overlap can't cover it: skip
			-- their union; the held sections still count.
			matched = {}
		end
		table.move(sections, 1, #sections, #matched + 1, matched)
		local covered, total, open = Geometry.overlapCover(fa, fb, matched)
		if total <= 0 then
			return false
		elseif total - covered <= math.min(total * COVER_SLACK, minArea) then
			return true
		end
		-- What's left open must be deep in terrain or round parts all over:
		-- sampled on a grid, so a tunnel under it or the gap between two
		-- boulders shows.
		for _, piece in open do
			if not held(Geometry.polygonGrid(piece, 2 * grow, OPEN_SPACING, OPEN_SAMPLES), solids, fa.normal) then
				return false
			end
		end
		return true
	end

	return function(contacts, i, j)
		if #contacts == 0 then
			return contacts
		end
		local lo, hi = contactsBounds(contacts)
		-- One query for the pair's few neighbours; contacts as big as a
		-- map's slabs query their own.
		local nearby = if (hi - lo).Magnitude <= NEARBY_EXTENT then hidersIn(lo - coverBox, hi + coverBox, i, j) else nil
		local gone, open, near = {}, {}, {}
		for _, c in contacts do
			worked()
			local how, solids = whatHides(c, i, j, nearby)
			if how == "inside" then
				gone[c] = true
			elseif how == "maybe" then
				table.insert(open, c)
				near[c] = solids
			end
		end
		if #open > 0 then
			local covers = coversNear(open, i, j)
			for _, c in open do
				gone[c] = hidden(c, covers, near[c])
			end
		end
		if next(gone) == nil then
			return contacts
		end
		local kept = {}
		for _, c in contacts do
			if not gone[c] then
				table.insert(kept, c)
			end
		end
		return kept
	end
end

--------------------------------------------------------------------------------
-- Scan
--------------------------------------------------------------------------------

function ZFight.scan(ctx)
	-- Detection settings are global (no model can loosen them); far-viewed
	-- models widen the search so their bigger gaps are seen.
	local config = ctx.config
	local tolerance = config.zFightTolerance
	local search = math.max(tolerance, farViewGap(ctx))
	local minArea = config.zFightMinOverlapArea
	local coverage = Meshes.newCoverage()
	ctx.coverage = coverage

	local candidates = {}
	for _, s in ctx.solids do
		if s.part.Transparency < config.zFightIgnoreTransparency then
			table.insert(candidates, s)
		end
	end
	local hash = SpatialHash.new(8)
	for i, s in candidates do
		hash:insert(i, s.min, s.max)
	end

	-- Mesh triangles are read once per part, the first time it's near
	-- something (a mesh alone can't z-fight).
	local isMeshLike = cached(function(s)
		return Geometry.isMeshLike(s.part)
	end)
	local meshFaces = {}
	local function facesOf(s)
		if not isMeshLike(s) then
			return Geometry.faces(s)
		end
		if meshFaces[s] == nil then
			meshFaces[s] = Meshes.load(ctx, s, coverage) or false
		end
		return meshFaces[s] or NO_FACES
	end
	local indexOf, indexes = cached(faceIndex)

	-- One part can touch thousands (a slab under a town) and two big meshes
	-- make millions of face tests, so yield as the work piles up (ctx.yield
	-- only waits once Studio's time slice is used).
	local work = 0
	local function worked()
		work += 1
		if work >= WORK_PER_YIELD then
			work = 0
			ctx.yield()
		end
	end

	local shown = shownFilter(ctx, candidates, hash, isMeshLike, worked, search)
	local margin = Vector3.one * search
	local issues, copyOf = {}, {}
	for i, a in candidates do
		if i % 200 == 0 then
			ctx.progress("zfight", i, #candidates)
		end
		local near = hash:query(a.min - margin, a.max + margin)
		table.sort(near)
		for _, j in near do
			local b = candidates[j]
			if j <= i or not boxesNear(a, b, search) then
				continue
			end
			worked()
			if Meshes.isDuplicate(a, b, tolerance) then
				-- Report each copy once, against the first part it copies.
				if not copyOf[j] then
					copyOf[j] = i
					table.insert(issues, Meshes.duplicateIssue(ctx, a, b))
				end
				continue
			end
			local facesA, facesB = facesOf(a), facesOf(b)
			if isMeshLike(a) and isMeshLike(b) and not (meshFaces[a] and meshFaces[b]) then
				local ratio = Meshes.alignedOverlap(a, b)
				if ratio and ratio >= config.meshOverlapRatio then
					table.insert(issues, Meshes.overlapIssue(ctx, a, b, ratio))
				end
			end
			local contacts = shown(faceContacts(facesA, facesB, search, minArea, indexOf, worked), i, j)
			local round = roundContact(a, b, tolerance, search, minArea)
			if round then
				table.insert(contacts, round)
			end
			if #contacts > 0 then
				local issue = pairIssue(ctx, a, b, contacts)
				if issue then
					table.insert(issues, issue)
				end
			end
		end
		-- Pairs are (i, j > i): `a` never comes up again, so its triangles
		-- can go (issues keep only the faces in their contacts).
		local done = meshFaces[a]
		if done then
			indexes[done] = nil
			meshFaces[a] = false
		end
	end
	return issues
end

--------------------------------------------------------------------------------
-- Fix plan
--------------------------------------------------------------------------------

-- Which part of a pair should move? nil when both are locked.
local function pickMover(a, b, config)
	local lockedA, lockedB = Classify.isLocked(a.part, config), Classify.isLocked(b.part, config)
	if lockedA and lockedB then
		return nil
	elseif lockedA then
		return b
	elseif lockedB then
		return a
	end
	-- A layered item belongs on top of whatever it's fighting with.
	local layerA, layerB = a.part:GetAttribute("BuildGuardLayer"), b.part:GetAttribute("BuildGuardLayer")
	if layerA and not layerB then
		return a
	elseif layerB and not layerA then
		return b
	end
	-- Otherwise the smaller part is the detail.
	if Geometry.volume(a) < Geometry.volume(b) then
		return a
	end
	return b
end

-- The face of solid `s` on the `sign` side of its local `axis`, or nil.
local function ownFace(s, axis, sign)
	for _, f in Geometry.faces(s) do
		if f.axis == axis and f.sign == sign then
			return f
		end
	end
	return nil
end

-- The opaque part other than `exclude` filling the area just beyond
-- `face`, or nil.
local function partBeyond(face, distance, world, exclude)
	if not world or not face then
		return nil
	end
	local probe = face.center + face.normal * distance
	return world.partAt(probe, function(instance)
		return exclude[instance] == true or not opaque(instance)
	end)
end

-- Can mover `s` shift `by` along its local `axis` into `hider`, the part
-- hiding that side? Not when its far face would end within zFightTolerance
-- (plus SINK_MARGIN) of the surface it sinks into (a marking no thicker than
-- the nudge), nor when any face of it would end newly flush on a face of a
-- part it then touches (a rib across a road's full width; a road sunk into
-- the pad it rests on and its footing, sides in line).
local function canSink(s, axis, by, hider, world, config)
	local tolerance, minArea = config.zFightTolerance, config.zFightMinOverlapArea
	if Geometry.component(s.size, axis) - math.abs(by) <= tolerance + SINK_MARGIN then
		return false
	end
	local offset = s.axes[axis] * by
	local parts = { hider }
	if world.partsInBox then
		parts = world.partsInBox(s.cf + offset, s.size + Vector3.one * (2 * tolerance))
		if not table.find(parts, hider) then
			table.insert(parts, hider)
		end
	end
	local faces, moved = Geometry.faces(s), {}
	for k, f in faces do
		local points = table.create(#f.points)
		for i, p in f.points do
			points[i] = p + offset
		end
		moved[k] = { normal = f.normal, center = f.center + offset, points = points }
	end
	for _, part in parts do
		if
			part ~= s.part
			and part.Transparency < config.zFightIgnoreTransparency
			and not (world.isTerrain and world.isTerrain(part))
		then
			for _, h in Geometry.faces(Geometry.solid(part)) do
				for k, m in moved do
					if Geometry.coplanarOverlap(m, h, tolerance, minArea) and not Geometry.coplanarOverlap(faces[k], h, tolerance, minArea) then
						return false
					end
				end
			end
		end
	end
	return true
end

-- Records that the mover must move `need` along `normal`. Many contacts can
-- share a direction (a wedge slope against two roofs, a mesh's triangles):
-- they need the largest move once, not the sum.
local function addMove(moves, normal, need)
	for _, m in moves do
		if m.normal:Dot(normal) >= PARALLEL then
			m.need = math.max(m.need, need)
			return
		end
	end
	table.insert(moves, { normal = normal, need = need })
end

-- One translation meeting every move (d . normal >= need), starting from
-- `start`: steps along each unmet move in turn until all are met. Moves at
-- right angles simply add up (one pass); slanted ones (a corner wedge's
-- slopes beside its sides) take a few passes. nil when no translation can
-- meet them all (a mesh pressed flush on two opposite sides).
local function solveMoves(moves, start)
	local d = start
	for _ = 1, 100 do
		local short = 0
		for _, m in moves do
			local missing = m.need - d:Dot(m.normal)
			if missing > 1e-6 then
				d += m.normal * missing
				short = math.max(short, missing)
			end
		end
		if short <= 1e-5 then
			return d
		end
	end
	return nil
end

-- One side (+ or -) of the mover, per local axis: how far its face there
-- must move out (`need`), that face, and how far the mover must go the other
-- way to put that face behind the other's instead (`back`).
local function newSide()
	return { need = { 0, 0, 0 }, face = {}, back = { 0, 0, 0 } }
end

local function newRequest(mover)
	return {
		solid = mover,
		pos = newSide(),
		neg = newSide(),
		moves = {}, -- for solveMoves: slopes, triangles, zgap faces pushed back
		roundGrow = 0,
		roundShrink = 0,
		pushedBack = false,
		against = {}, -- paths of the parts it clears, for the reason
		exclude = { [mover.part] = true }, -- parts partBeyond skips
		gap = 0,
		fights = false,
		entries = {}, -- { issue, other, gap } per issue
		done = false,
	}
end

-- Where face `f` of solid `s` will be once `item` (its plan item, if it has
-- one) moves or resizes it: center, normal.
local function plannedFace(f, s, item)
	if not item then
		return f.center, f.normal
	end
	local ratio = item.toSize / s.size
	local center = item.toCFrame:PointToWorldSpace(s.cf:PointToObjectSpace(f.center) * ratio)
	local normal = item.toCFrame:VectorToWorldSpace((s.cf:VectorToObjectSpace(f.normal) / ratio).Unit)
	return center, normal
end

-- Adds one issue's needs to the mover's request. When the other part
-- already has a plan item (a road's snap, an earlier mover), the mover
-- clears where that part will be, not where it is.
local function addContacts(request, entry, tolerance, item)
	local issue, other, gap = entry.issue, entry.other, entry.gap
	local moverIsA = request.solid == issue.solids[1]
	for _, contact in issue.contacts do
		-- A zgap's surfaces are clearly apart, so which one shows is meant:
		-- widen the gap the way it runs instead of swapping them.
		local keepOrder = math.abs(contact.distance) > tolerance
		if contact.round then
			local rMover = if moverIsA then contact.radiusA else contact.radiusB
			local rOther = if moverIsA then contact.radiusB else contact.radiusA
			local inner = keepOrder and rMover < rOther
			if item then
				rOther = radius({ shape = other.shape, half = item.toSize / 2 })
			end
			if inner then
				request.roundShrink = math.max(request.roundShrink, gap - (rOther - rMover))
			else
				request.roundGrow = math.max(request.roundGrow, gap - (rMover - rOther))
			end
			continue
		end
		local moverFace = if moverIsA then contact.faceA else contact.faceB
		local baseFace = if moverIsA then contact.faceB else contact.faceA
		local baseCenter, normal = plannedFace(baseFace, other, item)
		local ahead = (moverFace.center - baseCenter):Dot(normal)
		if keepOrder and (moverFace.center - baseFace.center):Dot(baseFace.normal) < 0 then
			-- Behind the other face: push it further back.
			if gap + ahead > MIN_NEED then
				addMove(request.moves, -moverFace.normal, gap + ahead)
				request.pushedBack = true
			end
		elseif gap - ahead > MIN_NEED then
			local need, axis = gap - ahead, moverFace.axis
			if axis then
				local side = if moverFace.sign > 0 then request.pos else request.neg
				side.need[axis] = math.max(side.need[axis], need)
				side.face[axis] = moverFace
				-- A zgap's face stays in front: never sunk behind.
				side.back[axis] = math.max(side.back[axis], if keepOrder then math.huge else gap + ahead)
			else
				addMove(request.moves, moverFace.normal, need)
			end
		end
	end
end

-- How the mover clears its faces on local `axis`: returns its shift and
-- growth along the axis, or adds a move to `moves` and returns 0, 0.
-- When an opaque third part hides one side (a layer-0 item's bottom on the
-- road), moving that side off it would open a gap of light, so the mover
-- sinks into it instead, its face just behind the other's (see canSink).
-- Fighting on both sides, it moves away from a hidden side, else grows by
-- the gap on each (a window as thick as its wall).
local function clearAxis(request, axis, moves, world, config)
	local s, pos, neg = request.solid, request.pos, request.neg
	local p, n = pos.need[axis], neg.need[axis]
	if p <= 0 and n <= 0 then
		return 0, 0
	end
	local probe = request.gap + 0.01
	local posHider = partBeyond(pos.face[axis] or ownFace(s, axis, 1), probe, world, request.exclude)
	local negHider = partBeyond(neg.face[axis] or ownFace(s, axis, -1), probe, world, request.exclude)
	local down, up = math.max(n, pos.back[axis]), math.max(p, neg.back[axis])
	if negHider and not posHider and canSink(s, axis, -down, negHider, world, config) then
		return -down, 0
	elseif posHider and not negHider and canSink(s, axis, up, posHider, world, config) then
		return up, 0
	elseif p > 0 and n > 0 then
		if negHider and not posHider then
			return p, 0
		elseif posHider and not negHider then
			return -n, 0
		end
		return (p - n) / 2, p + n
	elseif p > 0 then
		addMove(moves, s.axes[axis], p)
	else
		addMove(moves, -s.axes[axis], n)
	end
	return 0, 0
end

-- The Size change that moves a round surface's radius by `r`.
local function radiusChange(s, r)
	return if s.shape == "Ball" then Vector3.new(2 * r, 2 * r, 2 * r) else Vector3.new(0, 2 * r, 2 * r)
end

-- The planned CFrame and Size for one mover, and what was done; nil when
-- no move clears every face.
local function resolveRequest(request, world, config)
	local s = request.solid
	local moves = table.clone(request.moves)
	local shift, grow, grew = {}, {}, false
	for axis = 1, 3 do
		shift[axis], grow[axis] = clearAxis(request, axis, moves, world, config)
		grew = grew or grow[axis] > 0
	end
	local move = solveMoves(moves, s.cf:VectorToWorldSpace(Vector3.new(shift[1], shift[2], shift[3])))
	if not move then
		return nil
	end
	local toCFrame = s.cf + move
	local toSize = s.size + Vector3.new(grow[1], grow[2], grow[3])
	local g, k = request.roundGrow, request.roundShrink
	if g > 0 and k > 0 then
		-- Inside one round surface and outside another: no size clears both.
		return nil
	elseif g > 0 then
		toSize += radiusChange(s, g)
	elseif k > 0 then
		if k >= radius(s) then
			return nil
		end
		toSize -= radiusChange(s, k)
	end
	local action = if grew
		then "grow past both faces"
		elseif g > 0 then "grow its round surface clear"
		elseif k > 0 then "shrink its round surface clear"
		elseif request.pushedBack then "nudge further back"
		else "nudge clear"
	return toCFrame, toSize, action
end

-- Adds the fixes for `issues` (z-fights and too-small gaps) to `plan` and
-- returns the issues it couldn't fix. `config` is the scan's base config
-- (for locking rules); each issue's gap comes from its pair config. `world`
-- (optional) tells whether a side is hidden. Movers clear where items
-- already in `plan` (snaps to ground) put their parts. Each item starts
-- from the scan's snapshot of its part, so applying it refuses (stale plan)
-- if the part was edited after the scan.
function ZFight.plan(issues, config, plan, world)
	local requests, order, unfixable = {}, {}, {}

	for _, issue in issues do
		local a, b = issue.solids[1], issue.solids[2]
		local mover = pickMover(a, b, config)
		if not mover then
			table.insert(unfixable, issue)
			continue
		end
		local other = if mover == a then b else a
		local request = requests[mover.part]
		if not request then
			request = newRequest(mover)
			requests[mover.part] = request
			table.insert(order, mover.part)
		end
		local otherPath = issue.paths and issue.paths[if mover == a then 2 else 1]
		request.against[otherPath or other.part.Name] = true
		request.exclude[other.part] = true
		local gap = Config.faceGap(issue.config or config)
		request.gap = math.max(request.gap, gap)
		request.fights = request.fights or issue.check ~= "zgap"
		table.insert(request.entries, { issue = issue, other = other, gap = gap })
	end

	local function resolve(part)
		local request = requests[part]
		request.done = true
		for _, entry in request.entries do
			addContacts(request, entry, config.zFightTolerance, plan.byPart[entry.other.part])
		end
		local toCFrame, toSize, action = resolveRequest(request, world, config)
		if not toCFrame then
			for _, entry in request.entries do
				table.insert(unfixable, entry.issue)
			end
			return
		end
		local against = {}
		for name in request.against do
			table.insert(against, name)
		end
		table.sort(against)
		local reason = ("%s with %s: %s"):format(if request.fights then "z-fight" else "z-gap", table.concat(against, ", "), action)
		local s = request.solid
		Plan.add(plan, Plan.item(part, "zfight", reason, toCFrame, toSize, s.cf, s.size))
	end

	-- A mover up against another mover waits for that one's plan, so it
	-- clears the other's new place (two crossing stripes). Movers that wait
	-- on each other in a ring go as things stand; the next scan sees the rest.
	local function waiting(part)
		for _, entry in requests[part].entries do
			local r = requests[entry.other.part]
			if r and not r.done then
				return true
			end
		end
		return false
	end
	local pending = order
	while #pending > 0 do
		local rest = {}
		for _, part in pending do
			if waiting(part) then
				table.insert(rest, part)
			else
				resolve(part)
			end
		end
		if #rest == #pending then
			resolve(table.remove(rest, 1))
		end
		pending = rest
	end
	return unfixable
end

return ZFight
