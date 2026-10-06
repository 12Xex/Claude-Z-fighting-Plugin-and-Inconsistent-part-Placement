--[[
	Z-fight scan: finds pairs of parts with faces that point the same way, sit
	within `zFightTolerance` of each other and overlap.

	Faces that touch back-to-back (a part resting on another) point opposite
	ways and are left alone: those faces are hidden, not flickering.

	The fix plan nudges one part of each pair (the "mover") outward so its face
	clears the other by `zFightNudge`. If a mover z-fights on both opposite
	sides of one axis, a nudge clears both but sinks one side into the other
	part. That's fine when the sunk side is hidden anyway (a marking's bottom
	against the road), so it still nudges. When both sides are visible (a
	window exactly as thick as its wall) it grows by the nudge on each side
	instead.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local SpatialHash = require(script.Parent.Parent.SpatialHash)
local Classify = require(script.Parent.Parent.Classify)
local Plan = require(script.Parent.Parent.Plan)

local ZFight = {}

local function boxesNear(a, b, margin)
	return a.min.X <= b.max.X + margin
		and b.min.X <= a.max.X + margin
		and a.min.Y <= b.max.Y + margin
		and b.min.Y <= a.max.Y + margin
		and a.min.Z <= b.max.Z + margin
		and b.min.Z <= a.max.Z + margin
end

function ZFight.scan(ctx)
	-- Detection settings are global (no model can loosen them).
	local config = ctx.config
	local tolerance = config.zFightTolerance
	local candidates = {}
	for _, s in ctx.solids do
		if s.part.Transparency < config.zFightIgnoreTransparency and #Geometry.faces(s) > 0 then
			table.insert(candidates, s)
		end
	end

	local hash = SpatialHash.new(8)
	for i, s in candidates do
		hash:insert(i, s.min, s.max)
	end

	local margin = Vector3.new(tolerance, tolerance, tolerance)
	local issues = {}
	for i, a in candidates do
		local near = hash:query(a.min - margin, a.max + margin)
		table.sort(near)
		for _, j in near do
			local b = candidates[j]
			if j > i and boxesNear(a, b, tolerance) then
				local contacts = {}
				for _, fa in Geometry.faces(a) do
					for _, fb in Geometry.faces(b) do
						local area, distance =
							Geometry.coplanarOverlap(fa, fb, config.zFightTolerance, config.zFightMinOverlapArea)
						if area then
							table.insert(contacts, { faceA = fa, faceB = fb, area = area, distance = distance })
						end
					end
				end
				if #contacts > 0 then
					local names, total = {}, 0
					for _, c in contacts do
						table.insert(names, c.faceA.name .. "/" .. c.faceB.name)
						total += c.area
					end
					table.insert(issues, {
						check = "zfight",
						severity = "error",
						parts = { a.part, b.part },
						solids = { a, b },
						contacts = contacts,
						-- The fix's nudge size comes from the pair's settings.
						config = (ctx.pairConfig(a.part, b.part)),
						message = ("%s and %s z-fight: %s face(s) overlap %.2f studs²"):format(
							a.part.Name,
							b.part.Name,
							table.concat(names, ", "),
							total
						),
					})
				end
			end
		end
	end
	return issues
end

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

-- Adds the nudges for `issues` to `plan`. Returns the issues it couldn't fix.
-- `config` is the scan's base config (for locking rules); each issue's nudge
-- comes from its own pair config. `world` (optional) lets it check whether a
-- sunk face would be hidden.
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
			request = {
				solid = mover,
				pos = { 0, 0, 0 },
				neg = { 0, 0, 0 },
				posFace = {},
				negFace = {},
				extra = Vector3.zero,
				against = {},
				exclude = { [mover.part] = true },
				nudge = 0,
			}
			requests[mover.part] = request
			table.insert(order, mover.part)
		end
		request.against[other.part.Name] = true
		request.exclude[other.part] = true
		local nudge = (issue.config or config).zFightNudge
		request.nudge = math.max(request.nudge, nudge)
		for _, contact in issue.contacts do
			local moverFace = if mover == a then contact.faceA else contact.faceB
			local baseFace = if mover == a then contact.faceB else contact.faceA
			local need = nudge - (moverFace.center - baseFace.center):Dot(baseFace.normal)
			if need > 0 then
				if moverFace.axis then
					local side = if moverFace.sign > 0 then request.pos else request.neg
					local faces = if moverFace.sign > 0 then request.posFace else request.negFace
					side[moverFace.axis] = math.max(side[moverFace.axis], need)
					faces[moverFace.axis] = moverFace
				else
					request.extra += moverFace.normal * need
				end
			end
		end
	end

	for _, part in order do
		local request = requests[part]
		local s = request.solid
		local shift, grow = { 0, 0, 0 }, { 0, 0, 0 }
		local grew = false
		for axis = 1, 3 do
			local p, n = request.pos[axis], request.neg[axis]
			if p > 0 and n > 0 then
				local probe = request.nudge + 0.01
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
			else
				shift[axis] = p - n
			end
		end
		local toCFrame = s.cf * CFrame.new(shift[1], shift[2], shift[3]) + request.extra
		local toSize = s.size + Vector3.new(grow[1], grow[2], grow[3])
		local against = {}
		for name in request.against do
			table.insert(against, name)
		end
		table.sort(against)
		local reason = ("z-fight with %s: %s"):format(
			table.concat(against, ", "),
			if grew then "grow past both faces" else "nudge clear"
		)
		Plan.add(plan, Plan.item(part, "zfight", reason, toCFrame, toSize))
	end
	return unfixable
end

return ZFight
