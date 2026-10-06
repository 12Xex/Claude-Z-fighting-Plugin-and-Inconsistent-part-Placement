--[[
	Buried-part check for roads, rails and tracks.

	Samples a grid of points (every `sampleSpacing` studs) across each part's
	top surface and probes
	`buriedProbeHeight` above each one. A point is buried when the probe is
	inside terrain or another part, or a ray cast down from `buriedClearance`
	above it hits something before reaching it.

	Other roads/rails/tracks and layered items never count as cover: rails sit
	on track beds, and markings lie on roads.

	Fix: when everything covering the part is ground (terrain, baseplate...),
	the fix is a snap onto that ground's surface. When it's an ordinary part
	(a crate, a building) there's no safe automatic answer, so it's only flagged.
]]

local Geometry = require(script.Parent.Parent.Geometry)
local Classify = require(script.Parent.Parent.Classify)
local Ground = require(script.Parent.Ground)

local Buried = {}

local function coverIgnore(part, ctx)
	return function(instance)
		if instance == part or instance:IsDescendantOf(part) then
			return true
		end
		if not instance:IsA("BasePart") or ctx.world.isTerrain(instance) then
			return false
		end
		return Classify.isLayered(instance) or ctx.kindOf(instance) ~= nil
	end
end

function Buried.scan(ctx)
	local config, world = ctx.config, ctx.world
	local issues = {}
	for _, s in ctx.solids do
		local kind = ctx.kindOf(s.part)
		if kind then
			local ignore = coverIgnore(s.part, ctx)
			local up = s.axes[2]
			local covered, covers, coverOrder = 0, {}, {}
			local samples = Geometry.faceSamples(s, "Top", 0.05, 0.25, config.sampleSpacing)
			for _, point in samples do
				local probe = point + up * config.buriedProbeHeight
				local cover
				if world.isInsideTerrain(probe) then
					cover = world.terrain
				else
					cover = world.partAt(probe, ignore)
					if not cover then
						local hit = world.raycast(probe + up * config.buriedClearance, -up * config.buriedClearance, ignore)
						cover = hit and hit.instance
					end
				end
				if cover then
					covered += 1
					if not covers[cover] then
						covers[cover] = true
						table.insert(coverOrder, cover)
					end
				end
			end
			if covered > 0 then
				local names, allGround = {}, true
				for _, cover in coverOrder do
					table.insert(names, cover.Name)
					if not Classify.isGroundLike(cover, config) and not world.isTerrain(cover) then
						allGround = false
					end
				end
				local issue = {
					check = "buried",
					severity = "error",
					parts = { s.part },
					covers = coverOrder,
					message = ("%s %s is buried under %s (%d/%d sample points)"):format(
						kind,
						s.part.Name,
						table.concat(names, ", "),
						covered,
						#samples
					),
				}
				if allGround then
					local m = Ground.measure(s, ctx)
					if m.delta and m.delta > 0 then
						issue.fixItems = Ground.items(s, ctx, m.delta, "buried", ("lift onto ground (%+.3f)"):format(m.delta))
					end
				end
				if not issue.fixItems then
					issue.message ..= " — move the cover or the " .. string.lower(kind) .. " by hand"
				end
				table.insert(issues, issue)
			end
		end
	end
	return issues
end

return Buried
