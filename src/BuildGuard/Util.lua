--[[
	Small helpers shared by the checks: the words in a name, safe property
	reads, tags, and readable paths for parts whose names repeat.
]]

local Util = {}

local function charClass(ch)
	if string.match(ch, "%l") then
		return "lower"
	elseif string.match(ch, "%u") then
		return "upper"
	elseif string.match(ch, "%d") then
		return "digit"
	end
	return nil
end

-- The lowercase words in a name. Splits on anything that isn't a letter or
-- digit, between a lowercase and an uppercase letter, and between letters
-- and digits:
--     "RoadSign_02" -> { "road", "sign", "02" }
--     "HTTPServer"  -> { "http", "server" }
--     "Wheel_FL"    -> { "wheel", "fl" }
function Util.words(name)
	local out = {}
	local current = ""
	local previous = nil
	local function flush()
		if #current > 0 then
			table.insert(out, string.lower(current))
		end
		current = ""
	end
	for i = 1, #name do
		local ch = string.sub(name, i, i)
		local class = charClass(ch)
		if not class then
			flush()
			previous = nil
		else
			local boundary = false
			if previous then
				if (class == "digit") ~= (previous == "digit") or (class == "upper" and previous == "lower") then
					boundary = true
				elseif class == "upper" and previous == "upper" then
					-- "HTTPServer": the last capital of a run starts the next word.
					boundary = charClass(string.sub(name, i + 1, i + 1)) == "lower"
				end
			end
			if boundary then
				flush()
			end
			current ..= ch
			previous = class
		end
	end
	flush()
	return out
end

-- instance[name], or `default` when the property doesn't exist or can't be
-- read (Lune leaves some engine-computed properties unreadable).
function Util.prop(instance, name, default)
	local ok, value = pcall(function()
		return instance[name]
	end)
	if ok and value ~= nil then
		return value
	end
	return default
end

-- Does `instance` carry CollectionService tag `tag`?
function Util.hasTag(instance, tag)
	local ok, result = pcall(function()
		return instance:HasTag(tag)
	end)
	return ok and result == true
end

-- A yes/no marker that can be set either way: the attribute `name` (true or
-- false) wins, then a tag with the same name. Returns true, false or nil
-- (not set).
function Util.marker(instance, name)
	local attribute = instance:GetAttribute(name)
	if attribute == true or attribute == false then
		return attribute
	end
	if Util.hasTag(instance, name) then
		return true
	end
	return nil
end

local function segment(node)
	local parent = node.Parent
	local name = node.Name
	if parent then
		local index, count = 0, 0
		for _, sibling in parent:GetChildren() do
			if sibling.Name == name then
				count += 1
				if sibling == node then
					index = count
				end
			end
		end
		if count > 1 then
			name ..= "#" .. index
		end
	end
	return name
end

-- A path that finds one instance even when names repeat: segments from the
-- scan root (or the top of the place), and "#n" on a name shared by
-- siblings, n counting those siblings in child order.
--     Util.path(tubTop, workspace.Map) -> "Map/Desperado/Tub/TubTop#3"
-- `roots` is an Instance or a list (the first one holding `instance` wins).
function Util.path(instance, roots)
	if typeof(roots) == "Instance" then
		roots = { roots }
	end
	local root = nil
	for _, r in roots or {} do
		if instance == r or instance:IsDescendantOf(r) then
			root = r
			break
		end
	end
	local segments = {}
	local node = instance
	while node do
		local parent = node.Parent
		if node == root then
			table.insert(segments, 1, node.Name)
			break
		end
		if parent == nil or parent.ClassName == "DataModel" then
			table.insert(segments, 1, node.Name)
			break
		end
		table.insert(segments, 1, segment(node))
		node = parent
	end
	return table.concat(segments, "/")
end

-- The instance a Util.path names, searching from `root` (whose own name is
-- the path's first segment). nil if it isn't there.
function Util.find(root, path)
	local node = nil
	for piece in string.gmatch(path, "[^/]+") do
		if node == nil then
			if piece ~= root.Name then
				return nil
			end
			node = root
		else
			local name, index = string.match(piece, "^(.-)#(%d+)$")
			if not name then
				name, index = piece, "1"
			end
			local wanted, count, found = tonumber(index), 0, nil
			for _, child in node:GetChildren() do
				if child.Name == name then
					count += 1
					if count == wanted then
						found = child
						break
					end
				end
			end
			if not found then
				return nil
			end
			node = found
		end
	end
	return node
end

-- "(12.40, 5.10, -3.00)"
function Util.vector(v, digits)
	local f = "%." .. (digits or 2) .. "f"
	return ("(" .. f .. ", " .. f .. ", " .. f .. ")"):format(v.X, v.Y, v.Z)
end

-- Seconds from a monotonic clock (0 where there is none).
function Util.clock()
	if os and os.clock then
		return os.clock()
	end
	return 0
end

-- Today's date as YYYY-MM-DD (UTC), or nil where there's no clock.
function Util.today()
	if DateTime then
		local ok, text = pcall(function()
			return DateTime.now():FormatUniversalTime("YYYY-MM-DD", "en-us")
		end)
		if ok then
			return text
		end
	end
	if os and os.date then
		local ok, text = pcall(os.date, "!%Y-%m-%d")
		if ok then
			return text
		end
	end
	return nil
end

return Util
