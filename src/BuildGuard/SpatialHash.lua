--[[
	Uniform grid over axis-aligned boxes, so pair checks only compare parts that
	are near each other. Items covering too many cells (baseplates) go into a
	"big" list that every query returns.

	Cells are keyed by one number (each cell index wrapped to 16 bits), not a
	string, so big maps don't build a string per cell. Cells 65536 apart share
	a key; that only adds candidates, and callers test real overlap anyway.
]]

local SpatialHash = {}
SpatialHash.__index = SpatialHash

local MAX_CELLS_PER_ITEM = 4096
local WRAP = 65536

local function key(x, y, z)
	return ((x % WRAP) * WRAP + (y % WRAP)) * WRAP + (z % WRAP)
end
SpatialHash.key = key

function SpatialHash.new(cellSize)
	return setmetatable({ cellSize = cellSize or 8, cells = {}, big = {} }, SpatialHash)
end

-- The cells x0, y0, z0, x1, y1, z1 a box covers; nil past MAX_CELLS_PER_ITEM.
local function cellRange(cellSize, min, max)
	local c = cellSize
	local x0, y0, z0 = math.floor(min.X / c), math.floor(min.Y / c), math.floor(min.Z / c)
	local x1, y1, z1 = math.floor(max.X / c), math.floor(max.Y / c), math.floor(max.Z / c)
	if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > MAX_CELLS_PER_ITEM then
		return nil
	end
	return x0, y0, z0, x1, y1, z1
end

-- Appends the items of `list` not yet in `seen` to `out`.
local function addUnseen(out, seen, list)
	for _, item in list do
		if not seen[item] then
			seen[item] = true
			table.insert(out, item)
		end
	end
end

function SpatialHash:insert(item, min, max)
	local x0, y0, z0, x1, y1, z1 = cellRange(self.cellSize, min, max)
	if not x0 then
		table.insert(self.big, item)
		return
	end
	for x = x0, x1 do
		for y = y0, y1 do
			for z = z0, z1 do
				local k = key(x, y, z)
				local list = self.cells[k]
				if not list then
					list = {}
					self.cells[k] = list
				end
				table.insert(list, item)
			end
		end
	end
end

-- Unique items whose cells touch the box (a superset of true overlaps).
function SpatialHash:query(min, max)
	local seen, out = {}, {}
	addUnseen(out, seen, self.big)
	local x0, y0, z0, x1, y1, z1 = cellRange(self.cellSize, min, max)
	if not x0 then
		-- Huge query: scan every cell instead of every coordinate.
		for _, list in self.cells do
			addUnseen(out, seen, list)
		end
		return out
	end
	for x = x0, x1 do
		for y = y0, y1 do
			for z = z0, z1 do
				local list = self.cells[key(x, y, z)]
				if list then
					addUnseen(out, seen, list)
				end
			end
		end
	end
	return out
end

return SpatialHash
