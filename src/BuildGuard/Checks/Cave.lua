--[[
	Cave entrance lint. Report only, no fixes.

	A cave entrance is marked by a part filling the opening, its local X
	spanning the opening's width (see Classify.isCaveEntrance). It's flagged
	when that width is over caveEntranceWidth: minecarts and players must fit,
	trucks must not.
]]

local Classify = require(script.Parent.Parent.Classify)

local Cave = {}

function Cave.scan(ctx)
	local issues = {}
	for _, s in ctx.solids do
		if Classify.isCaveEntrance(s.part) then
			local config, sources = ctx.configFor(s.part)
			if s.size.X > config.caveEntranceWidth + 1e-3 then
				table.insert(issues, {
					check = "cave",
					severity = "warning",
					parts = { s.part },
					value = s.size.X,
					message = ("Cave entrance %s is %.1f studs wide, trucks could fit (maximum %.1f%s)"):format(
						s.part.Name,
						s.size.X,
						config.caveEntranceWidth,
						if sources.caveEntranceWidth then ", set on " .. sources.caveEntranceWidth.Name else ""
					),
				})
			end
		end
	end
	return issues
end

return Cave
