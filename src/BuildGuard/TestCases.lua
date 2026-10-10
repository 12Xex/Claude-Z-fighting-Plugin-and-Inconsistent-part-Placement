--[[
	Planted problems for the v0.6 checks, added to the test scene by
	TestScene.build. Each function gets the scene builder `b`:
	  b.part(name, size, cframe, color?, material?, class?) -> part (in b.folder)
	  b.plant(part, id, check, expect, note) / b.control(part)
	  b.model(name, parent?) -> Model
	  b.config, b.world, b.base (CFrame of the scene origin), b.W (road width)

	  P17 TubCopy            duplicate   flag  a mesh imported twice (same mesh, position, size)
	  P18 Crate_MeshB        meshoverlap flag  two meshes whose boxes nearly coincide
	  P19 Panel_Mesh         zfight      fix   a mesh whose triangles lie flush on a wall
	  P20 Axle_Sleeve        zfight      fix   rod in a sleeve: same radius, same axis
	  P21 Globe_Inner        zfight      fix   two balls, same centre and size
	  P22 Roof_Corner        zfight      fix   corner wedge side flush with a block
	  P23 Billboard_Sign     zgap        fix   0.02 off its board in a model seen from 300 studs
	  P26 TubTop#3           zfight      fix   one of three same-named parts (found by path)

	Controls added here: a wider sleeve, a corner wedge resting on a block,
	the same 0.02 gap seen up close, a StreetLamp, two RoadSigns and a
	RoofRail by the road, a Highway_Exit sign on a post, a RoadSign placed
	on a board with Layers, a StreetLight head on a pole, a layered RoadLine
	on the road, an ignored (tagged) crate on the main road.

	(P24 and P25 were vehicle cases; vehicles are modelled in Blender now,
	so BuildGuard doesn't check vehicle rigs.)
]]

local Layers = require(script.Parent.Layers)

local TestCases = {}

local STEEL = Color3.fromRGB(120, 120, 130)
local DARK = Color3.fromRGB(30, 30, 30)

-- Meshes, round parts, corner wedges, far view, repeated names.
function TestCases.faces(b, origin)
	local o = origin -- local offset of this zone in the scene

	-- P17: a mesh imported twice.
	b.part("Tub", Vector3.new(6, 3, 8), o * CFrame.new(0, 1.5, 0), STEEL, nil, "MeshPart")
	b.plant(b.part("TubCopy", Vector3.new(6, 3, 8), o * CFrame.new(0, 1.5, 0), STEEL, nil, "MeshPart"), "P17", "duplicate", "flag", "same mesh, position and size")

	-- P18: two meshes whose boxes nearly coincide (sizes differ slightly).
	b.part("Crate_MeshA", Vector3.new(4, 4, 4), o * CFrame.new(12, 2, 0), STEEL, nil, "MeshPart")
	b.plant(b.part("Crate_MeshB", Vector3.new(4, 3.9, 4), o * CFrame.new(12, 1.95, 0), STEEL, nil, "MeshPart"), "P18", "meshoverlap", "flag", "boxes 97% the same")

	-- P19: a thin mesh panel set into a wall, its outer face exactly on the
	-- wall's front face (the mesh's triangles are registered with the world,
	-- as EditableMesh would give them for a mesh the place owner owns).
	b.part("PanelWall", Vector3.new(10, 8, 1), o * CFrame.new(24, 4, 0), Color3.fromRGB(150, 150, 140))
	local panel = b.part("Panel_Mesh", Vector3.new(4, 3, 0.2), o * CFrame.new(24, 4, -0.5), Color3.fromRGB(40, 90, 200), nil, "MeshPart")
	-- Local space: the outer face at z = 0 (the wall's front), the back at z = +0.1 inside the wall.
	b.world.setMeshTriangles(panel, TestCases.boxTriangles(Vector3.new(-2, -1.5, 0), Vector3.new(2, 1.5, 0.1)))
	b.plant(panel, "P19", "zfight", "fix", "mesh triangles flush with a wall")

	-- P20: a rod in a sleeve, same radius on the same axis.
	b.part("Axle_Rod", Vector3.new(6, 1, 1), o * CFrame.new(36, 3, 0), STEEL, Enum.Material.Metal, nil, "Cylinder")
	b.plant(b.part("Axle_Sleeve", Vector3.new(2, 1, 1), o * CFrame.new(36, 3, 0), DARK, Enum.Material.Metal, nil, "Cylinder"), "P20", "zfight", "fix", "rod in a sleeve")
	-- Control: a sleeve 0.1 wider on the same axis.
	b.control(b.part("Axle_Rod2", Vector3.new(6, 1, 1), o * CFrame.new(36, 3, 6), STEEL, Enum.Material.Metal, nil, "Cylinder"))
	b.control(b.part("Axle_Sleeve2", Vector3.new(2, 1.2, 1.2), o * CFrame.new(36, 3, 6), DARK, Enum.Material.Metal, nil, "Cylinder"))

	-- P21: two balls on one centre, same size.
	b.part("Globe_Outer", Vector3.new(2, 2, 2), o * CFrame.new(46, 3, 0), Color3.fromRGB(250, 240, 200), nil, nil, "Ball")
	b.plant(b.part("Globe_Inner", Vector3.new(2, 2, 2), o * CFrame.new(46, 3, 0), Color3.fromRGB(250, 200, 120), nil, nil, "Ball"), "P21", "zfight", "fix", "same centre and size")

	-- P22: a corner wedge sunk halfway into a block at its front-right
	-- corner, so its Right and Front faces lie on the block's (1.5 studs²
	-- each).
	b.part("Roof_Block", Vector3.new(4, 2, 4), o * CFrame.new(56, 1, 0), Color3.fromRGB(150, 90, 70))
	b.plant(b.part("Roof_Corner", Vector3.new(2, 2, 2), o * CFrame.new(57, 2, -1), Color3.fromRGB(150, 90, 70), nil, "CornerWedgePart"), "P22", "zfight", "fix", "corner wedge sides flush")
	-- Control: a corner wedge resting on a block (back-to-back faces only).
	b.part("Roof_Block2", Vector3.new(4, 2, 4), o * CFrame.new(56, 1, 8), Color3.fromRGB(150, 90, 70))
	b.control(b.part("Roof_Corner2", Vector3.new(2, 2, 2), o * CFrame.new(56, 3, 8), Color3.fromRGB(150, 90, 70), nil, "CornerWedgePart"))

	-- P23: a model seen from 300 studs. Its sign is sunk into the board with
	-- its front 0.02 in front of the board's front: fine up close, flickers
	-- far away on a phone.
	local far = b.model("Billboard_Far")
	far:SetAttribute("BuildGuard_zFightViewDistance", 300)
	far:SetAttribute("BuildGuardConfigReason", "seen across the quarry")
	b.part("Billboard_Board", Vector3.new(12, 6, 1), o * CFrame.new(70, 6, 0), Color3.fromRGB(230, 230, 230)).Parent = far
	local sign = b.part("Billboard_Sign", Vector3.new(8, 3, 0.4), o * CFrame.new(70, 6, -0.5 - 0.02 + 0.2), Color3.fromRGB(200, 40, 40))
	sign.Parent = far
	b.plant(sign, "P23", "zgap", "fix", "front faces 0.02 apart, seen from 300 studs")
	-- Control: the same 0.02 gap on a board that's only seen up close.
	b.part("Billboard_Board2", Vector3.new(12, 6, 1), o * CFrame.new(70, 6, 10), Color3.fromRGB(230, 230, 230))
	b.control(b.part("Billboard_Sign2", Vector3.new(8, 3, 0.4), o * CFrame.new(70, 6, 9.5 - 0.02 + 0.2), Color3.fromRGB(200, 40, 40)))

	-- P26: three parts all named TubTop; the third is flush with a lip.
	local tubs = b.model("TubRow")
	for i = 1, 3 do
		b.part("TubTop", Vector3.new(3, 0.5, 3), o * CFrame.new(82 + 4 * (i - 1), 1, 0), STEEL).Parent = tubs
	end
	local third = tubs:GetChildren()[3]
	-- TubLip overlaps TubTop#3's end by 0.5 with its faces flush.
	b.part("TubLip", Vector3.new(1, 0.5, 3), o * CFrame.new(91.5, 1, 0), STEEL).Parent = tubs
	b.plant(third, "P26", "zfight", "fix", "TubTop#3 among three TubTops")
	return { far = far, tubs = tubs }
end

-- Parts named like roads/rails that aren't, beside a road, and an ignored
-- crate dumped on a road. `road` is a road part to stand them next to.
function TestCases.names(b, road)
	local cf, half = road.CFrame, road.Size / 2
	local edge = cf * CFrame.new(0, -half.Y, half.Z + 3)
	local function stand(name, size, offset)
		local x = b.part(name, size, CFrame.new(), STEEL)
		x.CFrame = edge * CFrame.new(offset, size.Y / 2, 0)
		return b.control(x)
	end
	stand("StreetLamp", Vector3.new(1, 12, 1), -8)
	stand("RoadSign", Vector3.new(6, 4, 0.2), 0)
	-- Flat and long like a rail, but its first word is "roof".
	stand("RoofRail", Vector3.new(8, 0.3, 0.3), 10)

	-- A second row: signs and lamp heads named like roads that are flat
	-- enough by their longest side, mounted the way they're really built.
	local row = cf * CFrame.new(0, -half.Y, half.Z + 10)
	local function at(name, size, x, y, z)
		local p = b.part(name, size, CFrame.new(), STEEL)
		p.CFrame = row * CFrame.new(x, y, z or 0)
		return p
	end
	b.control(at("RoadSign", Vector3.new(6, 3, 0.2), -14, 1.5))
	at("SignPost", Vector3.new(0.5, 12, 0.5), -2, 6)
	b.control(at("Highway_Exit", Vector3.new(12, 4, 0.5), -2, 10, -0.5))
	-- Placed on a board's front with Layers, as the skill says to.
	local board = at("SignBoard", Vector3.new(8, 6, 0.4), 12, 3)
	b.control(Layers.place(b.part("RoadSign", Vector3.new(6, 0.2, 4), CFrame.new(), Color3.fromRGB(40, 140, 60)), board, { face = "Front", config = b.config }))
	at("LampPole", Vector3.new(0.6, 10, 0.6), 22, 5)
	b.control(at("StreetLight", Vector3.new(4, 0.5, 1.5), 22, 10.25, -0.4))
	-- A lane line on the road.
	b.control(Layers.place(b.part("RoadLine", Vector3.new(6, 0.1, 0.5), CFrame.new(), Color3.fromRGB(240, 240, 235)), road, { layer = 1, u = -3, config = b.config }))
	local crate = b.part("IgnoredCrate", Vector3.new(3, 3, 3), CFrame.new(), Color3.fromRGB(160, 120, 70))
	crate.CFrame = cf * CFrame.new(-half.X + 4, half.Y + 1.5, 0) -- clear of the stop line
	crate:AddTag("BuildGuardIgnore")
end

-- The 12 triangles of a closed box from `min` to `max` (local space),
-- wound counter-clockwise seen from outside.
function TestCases.boxTriangles(min, max)
	local function corner(x, y, z)
		return Vector3.new(if x > 0 then max.X else min.X, if y > 0 then max.Y else min.Y, if z > 0 then max.Z else min.Z)
	end
	local centre = (min + max) / 2
	local quads = {
		{ corner(0, 0, 0), corner(1, 0, 0), corner(1, 1, 0), corner(0, 1, 0) },
		{ corner(0, 0, 1), corner(1, 0, 1), corner(1, 1, 1), corner(0, 1, 1) },
		{ corner(0, 0, 0), corner(0, 1, 0), corner(0, 1, 1), corner(0, 0, 1) },
		{ corner(1, 0, 0), corner(1, 1, 0), corner(1, 1, 1), corner(1, 0, 1) },
		{ corner(0, 0, 0), corner(1, 0, 0), corner(1, 0, 1), corner(0, 0, 1) },
		{ corner(0, 1, 0), corner(1, 1, 0), corner(1, 1, 1), corner(0, 1, 1) },
	}
	local out = {}
	for _, q in quads do
		local a, b2, c, d = q[1], q[2], q[3], q[4]
		local faceCentre = (a + b2 + c + d) / 4
		if (b2 - a):Cross(c - a):Dot(faceCentre - centre) < 0 then
			a, b2, c, d = d, c, b2, a
		end
		table.insert(out, { a, b2, c })
		table.insert(out, { a, c, d })
	end
	return out
end

return TestCases
