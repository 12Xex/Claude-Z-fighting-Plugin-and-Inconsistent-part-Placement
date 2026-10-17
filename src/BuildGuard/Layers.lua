--[[
	Layer offsets: put an item flat on a face of a surface part with a fixed
	small lift, so it can never sit coplanar with the surface.

	    Layers.place(marking, road, { layer = 1, u = -10 })
	    Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })
	    Layers.place(arrow, road, { layer = 2, rotation = 90 }) -- on top of layer 1
	    Layers.place(rib, road, { layer = 0, rotation = 90 })   -- flush on the road

	The item's Size.Y is its thickness off the surface. Its X axis runs along
	the face's `u` direction (the surface's Z axis on Right/Left faces, its X
	axis on the others), turned `rotation` degrees about the face normal.
	`u`/`v` move the item across the face from its centre.

	Layer n sits n * layerLift above the face; in a model seen from far away
	(zFightViewDistance) each layer lifts at least Config.faceGap, so the
	layers don't flicker at that distance. Items that overlap each other on
	the same face need different layers.

	Layer 0 rests flush on the face, for raised details that overlap no other
	layered item (washboard ribs, plates, pads): its bottom is hidden against
	the surface, so it can't flicker there. Two overlapping layer-0 items still
	z-fight (their bottoms are coplanar) and are reported. Snapping a road
	carries its layer-0 items along like any other layer.
]]

local Config = require(script.Parent.Config)
local Geometry = require(script.Parent.Geometry)

local Layers = {}

-- The surface axis each face's `u` runs along.
local U_AXIS = { Top = 1, Bottom = 1, Front = 1, Back = 1, Right = 3, Left = 3 }

local function faceName(face)
	if face == nil then
		return "Top"
	elseif typeof(face) == "EnumItem" then
		return face.Name
	end
	assert(Geometry.FACE_AXIS[face], "Layers: unknown face " .. tostring(face))
	return face
end

-- How far layer `layer` sits above the surface (0 for layer 0).
function Layers.lift(layer, config)
	config = config or Config.defaults
	assert(type(layer) == "number" and layer >= 0 and layer % 1 == 0, "Layers: layer must be a whole number >= 0")
	local step = config.layerLift
	if (config.zFightViewDistance or 0) > 0 then
		step = math.max(step, Config.faceGap(config))
	end
	return layer * step
end

-- CFrame on the face of `surface` (offset by u/v), with UpVector = face normal.
function Layers.faceCFrame(surface, face, u, v, rotation)
	local name = faceName(face)
	local axis, sign = table.unpack(Geometry.FACE_AXIS[name])
	local cf, half = surface.CFrame, surface.Size / 2
	local axes = { cf.RightVector, cf.UpVector, -cf.LookVector }
	local normal = axes[axis] * sign
	local uDir = axes[U_AXIS[name]]
	local vDir = uDir:Cross(normal)
	local center = cf.Position + normal * Geometry.component(half, axis) + uDir * (u or 0) + vDir * (v or 0)
	local frame = CFrame.fromMatrix(center, uDir, normal)
	if rotation and rotation ~= 0 then
		frame *= CFrame.Angles(0, math.rad(rotation), 0)
	end
	return frame
end

-- Places `item` on `surface` and returns it. Options: face, layer (default
-- 1; 0 rests flush), u, v, rotation, keepPosition (take u/v/rotation from
-- where the item is now) and config (default: the surface's own settings,
-- so BuildGuard_layerLift on it or an ancestor counts).
function Layers.place(item, surface, options)
	options = options or {}
	local config = options.config or Config.resolver(Config.defaults).resolve(surface)
	local layer = options.layer or 1
	local u, v, rotation = options.u, options.v, options.rotation
	if options.keepPosition then
		local base = Layers.faceCFrame(surface, options.face)
		local lp = base:PointToObjectSpace(item.CFrame.Position)
		local right = base:VectorToObjectSpace(item.CFrame.RightVector)
		u, v, rotation = lp.X, lp.Z, math.deg(math.atan2(-right.Z, right.X))
	end
	local frame = Layers.faceCFrame(surface, options.face, u, v, rotation)
	item.CFrame = frame * CFrame.new(0, Layers.lift(layer, config) + item.Size.Y / 2, 0)
	item.Anchored = true
	item:SetAttribute("BuildGuardLayer", layer)
	return item
end

return Layers
