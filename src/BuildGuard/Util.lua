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

-- Does a new word start at a `class` character after a `previous` one?
local function isBoundary(previous, class, nextChar)
	if (class == "digit") ~= (previous == "digit") or (class == "upper" and previous == "lower") then
		return true
	end
	-- "HTTPServer": the last capital of a run starts the next word.
	return class == "upper" and previous == "upper" and charClass(nextChar) == "lower"
end

-- The lowercase words in a name. Splits on anything that isn't a letter or
-- digit, between a lowercase and an uppercase letter, and between letters
-- and digits:
--     "RoadSign_02" -> { "road", "sign", "02" }
--     "HTTPServer"  -> { "http", "server" }
--     "Wheel_FL"    -> { "wheel", "fl" }
function Util.words(name)
	local out = {}
	local current, previous = "", nil
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
			if previous and isBoundary(previous, class, string.sub(name, i + 1, i + 1)) then
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

-- One path segment: the name with "%" and "/" escaped, then "#n" when
-- siblings share the name, or when the name is empty or already ends in
-- "#<digits>" (so Util.find reads it back as a name, not an index).
local function segmentText(name, index, count)
	local text = string.gsub(string.gsub(name, "%%", "%%25"), "/", "%%2F")
	if count > 1 or name == "" or string.find(name, "#%d+$") then
		text ..= "#" .. index
	end
	return text
end

-- Every child's segment under `parent`, in one pass over its children.
local function childSegments(parent)
	local children = parent:GetChildren()
	local counts, seen, out = {}, {}, {}
	for _, child in children do
		counts[child.Name] = (counts[child.Name] or 0) + 1
	end
	for _, child in children do
		local name = child.Name
		seen[name] = (seen[name] or 0) + 1
		out[child] = segmentText(name, seen[name], counts[name])
	end
	return out
end

-- A path that finds one instance even when names repeat: segments from the
-- scan root (or the top of the place), and "#n" on a name shared by
-- siblings, n counting those siblings in child order.
--     Util.path(tubTop, workspace.Map) -> "Map/Desperado/Tub/TubTop#3"
-- `roots` is an Instance or a list (the first one holding `instance` wins).
-- `cache` (optional, a table kept for one scan and one `roots`) keeps each
-- parent's segments, so naming many parts reads each parent's children once.
function Util.path(instance, roots, cache)
	if typeof(roots) == "Instance" then
		roots = { roots }
	end
	local rank = cache and cache.rank
	if not rank then
		rank = {}
		for i, r in roots or {} do
			rank[r] = rank[r] or i
		end
		if cache then
			cache.rank = rank
		end
	end
	local root, best = nil, math.huge
	local node = instance
	while node do
		local i = rank[node]
		if i and i < best then
			root, best = node, i
		end
		node = node.Parent
	end
	local segments = {}
	node = instance
	while node do
		local parent = node.Parent
		if node == root or parent == nil or parent.ClassName == "DataModel" then
			table.insert(segments, 1, segmentText(node.Name, 1, 1))
			break
		end
		local siblings = cache and cache[parent]
		if not (siblings and siblings[node]) then
			siblings = childSegments(parent)
			if cache then
				cache[parent] = siblings
			end
		end
		table.insert(segments, 1, siblings[node])
		node = parent
	end
	return table.concat(segments, "/")
end

-- The `n`th child of `parent` named `name`, or nil.
local function nthChild(parent, name, n)
	local count = 0
	for _, child in parent:GetChildren() do
		if child.Name == name then
			count += 1
			if count == n then
				return child
			end
		end
	end
	return nil
end

-- The instance a Util.path names, searching from `root` (whose own name is
-- the path's first segment). nil if it isn't there.
function Util.find(root, path)
	local node = nil
	for _, piece in string.split(path, "/") do
		local name, index = string.match(piece, "^(.-)#(%d+)$")
		if not name then
			if piece == "" then
				return nil
			end
			name, index = piece, "1"
		end
		name = string.gsub(name, "%%(%x%x)", function(hex)
			return string.char(tonumber(hex, 16))
		end)
		local wanted = tonumber(index)
		if node == nil then
			if name ~= root.Name or wanted ~= 1 then
				return nil
			end
			node = root
		else
			node = nthChild(node, name, wanted)
			if not node then
				return nil
			end
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
