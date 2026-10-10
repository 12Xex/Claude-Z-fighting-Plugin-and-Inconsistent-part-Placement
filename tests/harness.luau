--[[
	Loads the BuildGuard ModuleScripts under Lune, outside Roblox.

	The modules use Roblox-style `require(script.Parent.X)`. Here `script` is a
	stand-in that maps instance paths onto files (Rojo's layout: Foo.lua is a
	module, Foo/init.lua is a module with children).
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")

local Harness = {}

local baseEnv = {
	Vector3 = roblox.Vector3,
	CFrame = roblox.CFrame,
	Color3 = roblox.Color3,
	UDim2 = roblox.UDim2,
	Enum = roblox.Enum,
	Instance = roblox.Instance,
	typeof = typeof,
	type = type,
	math = math,
	string = string,
	table = table,
	pairs = pairs,
	ipairs = ipairs,
	next = next,
	select = select,
	tostring = tostring,
	tonumber = tonumber,
	pcall = pcall,
	error = error,
	assert = assert,
	print = print,
	setmetatable = setmetatable,
	getmetatable = getmetatable,
	rawget = rawget,
	rawequal = rawequal,
	coroutine = coroutine,
	os = { clock = os.clock, date = os.date, time = os.time },
}

local nodes, cache = {}, {}
local requireShim

local function node(path)
	if nodes[path] then
		return nodes[path]
	end
	local n = setmetatable({ __path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				return node((string.match(path, "^(.*)/[^/]+$")))
			elseif key == "Name" then
				return string.match(path, "([^/]+)$")
			end
			return node(path .. "/" .. key)
		end,
	})
	nodes[path] = n
	return n
end

function requireShim(target)
	local path = target.__path
	if cache[path] ~= nil then
		return cache[path]
	end
	local file = if fs.isFile(path .. ".lua") then path .. ".lua" else path .. "/init.lua"
	assert(fs.isFile(file), "no module at " .. path)
	local env = setmetatable({ script = target, require = requireShim }, { __index = baseEnv })
	local chunk = luau.load(fs.readFile(file), { debugName = file, environment = env, injectGlobals = false })
	local result = chunk()
	cache[path] = result
	return result
end

-- The BuildGuard module (src/BuildGuard/init.lua).
function Harness.load()
	return requireShim(node("src/BuildGuard"))
end

-- One of its modules, e.g. Harness.module("Checks/ZFight").
function Harness.module(path)
	return requireShim(node("src/BuildGuard/" .. path))
end

return Harness
