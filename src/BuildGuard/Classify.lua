--[[
	What kind of part is this?

	Kind ("Road" | "Rail" | "Track" | nil), in priority order:
	  1. BuildGuardKind attribute ("Road", "Rail", "Track", or "None" to opt out)
	  2. A CollectionService tag named Road, Rail or Track
	  3. The part's name (Config.kindNamePatterns)
]]

local Classify = {}

local KINDS = { Road = true, Rail = true, Track = true }

function Classify.kind(part, config, world)
	local attribute = part:GetAttribute("BuildGuardKind")
	if typeof(attribute) == "string" then
		return if KINDS[attribute] then attribute else nil
	end
	if world and world.hasTag then
		for kind in KINDS do
			if world.hasTag(part, kind) then
				return kind
			end
		end
	end
	local name = string.lower(part.Name)
	for _, rule in config.kindNamePatterns do
		local excluded = false
		for _, fragment in rule.exclude or {} do
			if string.find(name, fragment, 1, true) then
				excluded = true
				break
			end
		end
		if not excluded then
			for _, fragment in rule.patterns do
				if string.find(name, fragment, 1, true) then
					return rule.kind
				end
			end
		end
	end
	return nil
end

-- Items placed with Layers (markings, signs, trim) carry this attribute.
function Classify.isLayered(part)
	return part:GetAttribute("BuildGuardLayer") ~= nil
end

-- Cave entrance markers: a part filling the opening, its local X spanning
-- the opening's width. BuildGuardCaveEntrance = true, or a name containing
-- "CaveEntrance" (spaces and underscores ignored).
function Classify.isCaveEntrance(part)
	local attribute = part:GetAttribute("BuildGuardCaveEntrance")
	if attribute ~= nil then
		return attribute == true
	end
	local name = string.gsub(string.lower(part.Name), "[%s_]", "")
	return string.find(name, "caveentrance", 1, true) ~= nil
end

-- Terrain, baseplates and other big ground surfaces.
function Classify.isGroundLike(instance, config)
	if instance:IsA("Terrain") then
		return true
	end
	if not instance:IsA("BasePart") then
		return false
	end
	if instance:GetAttribute("BuildGuardGround") == true then
		return true
	end
	local name = string.lower(instance.Name)
	for _, groundName in config.groundNames do
		if name == groundName then
			return true
		end
	end
	local size = instance.Size
	return size.X >= config.groundMinFootprint and size.Z >= config.groundMinFootprint
end

-- Fixes never move these.
function Classify.isLocked(part, config)
	return part.Locked or part:GetAttribute("BuildGuardLocked") == true or Classify.isGroundLike(part, config)
end

-- All BaseParts under `root` (including root), skipping Terrain and anything
-- under an instance with the BuildGuardIgnore attribute.
function Classify.collectParts(root)
	local out = {}
	local function visit(instance)
		if instance:GetAttribute("BuildGuardIgnore") == true then
			return
		end
		if instance:IsA("BasePart") and not instance:IsA("Terrain") then
			table.insert(out, instance)
		end
		for _, child in instance:GetChildren() do
			visit(child)
		end
	end
	visit(root)
	return out
end

return Classify
