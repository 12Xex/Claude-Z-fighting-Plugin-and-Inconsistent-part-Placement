--[[
	Uniform grid over axis-aligned boxes, so pair checks only compare parts that
	are near each other. Items covering too many cells (baseplates) go into a
	"big" list that every query returns.
]]

local SpatialHash = {}
SpatialHash.__index = SpatialHash

local MAX_CELLS_PER_ITEM = 4096

function SpatialHash.new(cellSize)
	return setmetatable({ cellSize = cellSize or 8, cells = {}, big = {} }, SpatialHash)
end

function SpatialHash:_range(min, max)
	local c = self.cellSize
	return math.floor(min.X / c),
		math.floor(min.Y / c),
		math.floor(min.Z / c),
		math.floor(max.X / c),
		math.floor(max.Y / c),
		math.floor(max.Z / c)
end

function SpatialHash:insert(item, min, max)
	local x0, y0, z0, x1, y1, z1 = self:_range(min, max)
	if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > MAX_CELLS_PER_ITEM then
		table.insert(self.big, item)
		return
	end
	for x = x0, x1 do
		for y = y0, y1 do
			for z = z0, z1 do
				local key = x .. "," .. y .. "," .. z
				local list = self.cells[key]
				if not list then
					list = {}
					self.cells[key] = list
				end
				table.insert(list, item)
			end
		end
	end
end

-- Unique items whose cells touch the box (a superset of true overlaps).
function SpatialHash:query(min, max)
	local seen, out = {}, {}
	for _, item in self.big do
		seen[item] = true
		table.insert(out, item)
	end
	local x0, y0, z0, x1, y1, z1 = self:_range(min, max)
	if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) > MAX_CELLS_PER_ITEM then
		-- Huge query: scan every cell instead of every coordinate.
		for _, list in self.cells do
			for _, item in list do
				if not seen[item] then
					seen[item] = true
					table.insert(out, item)
				end
			end
		end
		return out
	end
	for x = x0, x1 do
		for y = y0, y1 do
			for z = z0, z1 do
				local list = self.cells[x .. "," .. y .. "," .. z]
				if list then
					for _, item in list do
						if not seen[item] then
							seen[item] = true
							table.insert(out, item)
						end
					end
				end
			end
		end
	end
	return out
end

return SpatialHash
