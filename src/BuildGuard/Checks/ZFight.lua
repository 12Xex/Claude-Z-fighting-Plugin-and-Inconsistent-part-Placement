--[[
	Z-fight scan: finds pairs of visible parts whose surfaces lie on top of
	each other and flicker.

	  * Flat faces that point the same way, sit within zFightTolerance of each
	    other and overlap: blocks, wedges, corner wedges, cylinder end caps,
	    and the triangles of meshes the world can read (see Meshes.lua).
	  * Round surfaces: two cylinders on one axis with the same radius (a rod
	    in a sleeve), and two balls with one centre and the same radius.
	  * Duplicates (same class, mesh, position, rotation and size) and mesh
	    boxes that overlap almost completely (Meshes.lua). A duplicate pair is
	    reported once, as a duplicate.

	Faces that touch back-to-back (a part resting on another) point opposite
	ways and are left alone: those faces are hidden, not flickering.

	Far view: in a model seen from far away (zFightViewDistance), same-facing
	faces need 2 * Config.depthStep(distance) between them. Closer than that,
	but beyond zFightTolerance, is a "zgap" warning. Under about 130 studs
	the usual zFightNudge already holds, so there are no zgaps there.

	The fix plan moves one part of each pair (the "mover") so its surface
	clears the other by the pair's face gap (zFightNudge unless the model is
	seen from far away). A pair whose parts are both locked (or ground) has
	no mover: its issue says so and isn't auto-fixable.
	  * Flat faces: the mover is nudged outward. If it z-fights on both
	    opposite sides of one axis, a nudge clears both but sinks one side
	    into the other part. That's fine when the sunk side is hidden anyway (a
	    marking's bottom against the road), so it still nudges. When both
	    sides are visible (a window exactly as thick as its wall) it grows by
	    the gap on each side instead.
	  * Round surfaces: the mover's radius grows. Its CFrame stays, so joints
	    stay valid.
	  * A zgap keeps its order: the surface in front stays in front. A face
	    set behind the other is pushed further back; an inner ball or rod
	    shrinks instead of growing past the outer one.
	  * When the other part is already planned to move (a road snapped to
	    the ground, another mover), the mover clears where it will be.
]]

local Config = require(script.Parent.Parent.Config)
local Geometry = require(script.Parent.Parent.Geometry)
local SpatialHash = require(script.Parent.Parent.SpatialHash)
local Classify = require(script.Parent.Parent.Classify)
local Plan = require(script.Parent.Parent.Plan)
local Util = require(script.Parent.Parent.Util)
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
local NO_FACES = {}

local function boxesNear(a, b, margin)
	return a.min.X <= b.max.X + margin
		and b.min.X <= a.max.X + margin
		and a.min.Y <= b.max.Y + margin
		and b.min.Y <= a.max.Y + margin
		and a.min.Z <= b.max.Z + margin
		and b.min.Z <= a.max.Z + margin
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

-- World bounding box of a face (cached on it).
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

local function boundsTouch(fa, fb, margin)
	local aLo, aHi = bounds(fa)
	local bLo, bHi = bounds(fb)
	return aLo.X <= bHi.X + margin
		and bLo.X <= aHi.X + margin
		and aLo.Y <= bHi.Y + margin
		and bLo.Y <= aHi.Y + margin
		and aLo.Z <= bHi.Z + margin
		and bLo.Z <= aHi.Z + margin
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

-- Same-facing faces of `a` and `b` within `search` of each other that
-- overlap: { faceA, faceB, area, distance, position }. Calls `worked()`
-- once per face pair tested.
local function faceContacts(facesA, facesB, search, minArea, indexOf, worked)
	local contacts = {}
	local function test(fa, fb)
		worked()
		if fa.normal:Dot(fb.normal) < PARALLEL or not boundsTouch(fa, fb, search) then
			return
		end
		local floor = if fa.triangle or fb.triangle then MIN_TRIANGLE_OVERLAP else minArea
		local area, distance, at = Geometry.coplanarOverlap(fa, fb, search, floor)
		if area then
			table.insert(contacts, { faceA = fa, faceB = fb, area = area, distance = distance, position = at })
		end
	end
	if #facesA == 0 or #facesB == 0 then
		return contacts
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

-- Turns a pair's contacts into a "zfight" or "zgap" issue, or nil when the
-- contacts are only close enough for some other, far-viewed model.
local function pairIssue(ctx, a, b, contacts)
	local base = ctx.config
	local tolerance = base.zFightTolerance
	local pairConfig, sources = ctx.pairConfig(a.part, b.part)
	local viewDistance = pairConfig.zFightViewDistance or 0
	local gap = Config.faceGap(pairConfig)
	-- Only the far view's own need counts here: up close (under about 130
	-- studs) the usual nudge already holds, and gaps it leaves are fine.
	local farGap = 2 * Config.depthStep(viewDistance)
	local limit = if viewDistance > 0 then math.max(tolerance, farGap - GAP_SLACK) else tolerance

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

	local pathA, pathB = ctx.path(a.part), ctx.path(b.part)
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
	}
	if fighting then
		issue.message = ("%s and %s z-fight at %s: %s face(s) overlap %.2f studs²"):format(
			pathA,
			pathB,
			Util.vector(largest.position),
			contactNames(kept),
			total
		)
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
			Util.vector(largest.position),
			contactNames(kept),
			total,
			math.floor(holdsTo(closest) + 0.5),
			if source then ctx.path(source) else "the build",
			viewDistance,
			gap
		)
	end
	-- The fix moves one part of the pair; locked and ground parts never move.
	if Classify.isLocked(a.part, base) and Classify.isLocked(b.part, base) then
		issue.planner = nil
		issue.message ..= " — both parts are locked (or ground): move one by hand, or unlock one"
	end
	return issue
end

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
	local meshLike, meshFaces = {}, {}
	local function isMeshLike(s)
		local m = meshLike[s]
		if m == nil then
			m = Geometry.isMeshLike(s.part)
			meshLike[s] = m
		end
		return m
	end
	local function facesOf(s)
		if not isMeshLike(s) then
			return Geometry.faces(s)
		end
		if meshFaces[s] == nil then
			meshFaces[s] = Meshes.load(ctx, s, coverage) or false
		end
		return meshFaces[s] or NO_FACES
	end
	local indexes = {}
	local function indexOf(faces)
		local index = indexes[faces]
		if not index then
			index = faceIndex(faces)
			indexes[faces] = index
		end
		return index
	end

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

	local issues = {}
	local copyOf = {}
	local margin = Vector3.one * search
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
			local contacts = faceContacts(facesA, facesB, search, minArea, indexOf, worked)
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

-- Is the area just beyond `face` filled by some part other than `exclude`?
local function hiddenBeyond(face, distance, world, exclude)
	if not world then
		return false
	end
	local probe = face.center + face.normal * distance
	return world.partAt(probe, function(instance)
		return exclude[instance] == true
	end) ~= nil
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

local function newRequest(mover)
	return {
		solid = mover,
		pos = { 0, 0, 0 },
		neg = { 0, 0, 0 },
		posFace = {},
		negFace = {},
		moves = {},
		roundGrow = 0,
		roundShrink = 0,
		-- a zgap face pushed further back
		back = false,
		against = {},
		exclude = { [mover.part] = true },
		gap = 0,
		issues = {},
		-- { issue, other, gap } per issue
		entries = {},
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
		local moverFace = if moverIsA then contact.faceA else contact.faceB
		local baseFace = if moverIsA then contact.faceB else contact.faceA
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
		else
			local baseCenter, normal = plannedFace(baseFace, other, item)
			local ahead = (moverFace.center - baseCenter):Dot(normal)
			if keepOrder and (moverFace.center - baseFace.center):Dot(baseFace.normal) < 0 then
				-- Behind the other face: push it further back.
				if gap + ahead > MIN_NEED then
					addMove(request.moves, -moverFace.normal, gap + ahead)
					request.back = true
				end
			elseif gap - ahead > MIN_NEED then
				local need = gap - ahead
				if moverFace.axis then
					local side = if moverFace.sign > 0 then request.pos else request.neg
					local faces = if moverFace.sign > 0 then request.posFace else request.negFace
					side[moverFace.axis] = math.max(side[moverFace.axis], need)
					faces[moverFace.axis] = moverFace
				else
					addMove(request.moves, moverFace.normal, need)
				end
			end
		end
	end
end

-- The planned CFrame and Size for one mover, and what was done; nil when
-- no move clears every face.
local function resolveRequest(request, world)
	local s = request.solid
	local shift, grow = { 0, 0, 0 }, { 0, 0, 0 }
	local moves = table.clone(request.moves)
	local grew = false
	for axis = 1, 3 do
		local p, n = request.pos[axis], request.neg[axis]
		if p > 0 and n > 0 then
			local probe = request.gap + 0.01
			local posHidden = hiddenBeyond(request.posFace[axis], probe, world, request.exclude)
			local negHidden = hiddenBeyond(request.negFace[axis], probe, world, request.exclude)
			if negHidden and not posHidden then
				shift[axis] = p
			elseif posHidden and not negHidden then
				shift[axis] = -n
			else
				grow[axis] = p + n
				shift[axis] = (p - n) / 2
				grew = true
			end
		elseif p > 0 then
			addMove(moves, s.axes[axis], p)
		elseif n > 0 then
			addMove(moves, -s.axes[axis], n)
		end
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
		toSize += if s.shape == "Ball" then Vector3.new(2 * g, 2 * g, 2 * g) else Vector3.new(0, 2 * g, 2 * g)
	elseif k > 0 then
		if k >= radius(s) then
			return nil
		end
		toSize -= if s.shape == "Ball" then Vector3.new(2 * k, 2 * k, 2 * k) else Vector3.new(0, 2 * k, 2 * k)
	end
	local action = if grew
		then "grow past both faces"
		elseif g > 0 then "grow its round surface clear"
		elseif k > 0 then "shrink its round surface clear"
		elseif request.back then "nudge further back"
		else "nudge clear"
	return toCFrame, toSize, action
end

-- Adds the fixes for `issues` (z-fights and too-small gaps) to `plan`.
-- Returns the issues it couldn't fix. `config` is the scan's base config (for
-- locking rules); each issue's gap comes from its own pair config. `world`
-- (optional) lets it check whether a sunk face would be hidden.
-- Items already in `plan` (snaps to ground) are where their parts will be,
-- so movers clear those places. Each item starts from the scan's snapshot
-- of its part, so applying it refuses (stale plan) if the part was edited
-- after the scan.
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
		table.insert(request.issues, issue)
		table.insert(request.entries, { issue = issue, other = other, gap = gap })
	end

	local function resolve(part)
		local request = requests[part]
		request.done = true
		for _, entry in request.entries do
			addContacts(request, entry, config.zFightTolerance, plan.byPart[entry.other.part])
		end
		local toCFrame, toSize, action = resolveRequest(request, world)
		if not toCFrame then
			for _, issue in request.issues do
				table.insert(unfixable, issue)
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
