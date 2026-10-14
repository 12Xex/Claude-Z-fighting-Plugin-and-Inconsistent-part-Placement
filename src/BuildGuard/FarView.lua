--[[
	Far-view rig: how big must a gap between two same-facing faces be so it
	doesn't flicker from far away on a real device?

	Builds a row of plate pairs. In each pair a thin red plate lies on a white
	one, so their top faces are exactly `gap` apart (0.005 to 0.2 studs), and a
	matching pair stands upright so the gap is also seen edge-on. Each pair is
	labelled with its gap. Viewing pads (View_100, View_300, View_600) sit
	that many studs away; each is a neutral SpawnLocation, since the rig is
	far from the map's own spawns.

	Publish the place to a test place (phones can't join Team Test) and join
	it on a phone: players spawn on the View_ pads. Disable the map's own
	SpawnLocations while testing, or reset to land on another pad. Look at
	the rig from each pad: every pair that shimmers or shows white through
	red is a gap too small for that distance. Use the smallest clean gap for
	map-sized models (BuildGuard_zFightViewDistance on the model sets it
	from a distance). Delete the rig afterwards, so nobody spawns there.

	The whole rig carries BuildGuardIgnore, so scans skip it. It is only
	built where nothing is (no parts, terrain or water in its box); otherwise
	build errors, saying what is in the way.

	FarView.build(parent, origin?, world?)   world: StudioWorld by default
]]

local Geometry = require(script.Parent.Geometry)
local Util = require(script.Parent.Util)

local FarView = {}

FarView.GAPS = { 0.005, 0.01, 0.02, 0.03, 0.05, 0.08, 0.1, 0.15, 0.2 }
FarView.DISTANCES = { 100, 300, 600 }
-- Far off any usual map and clear of SelfTest.DEFAULT_ORIGIN, on the 8-stud grid.
FarView.DEFAULT_ORIGIN = Vector3.new(-24576, 0, -24576)

local WHITE = Color3.fromRGB(240, 240, 240)
local RED = Color3.fromRGB(220, 40, 40)
-- Room left around the rig when checking that its spot is empty.
local MARGIN = 8

-- The box around every part in `folder`, MARGIN bigger on each side.
local function box(folder)
	local min, max = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			local s = Geometry.solid(d)
			min, max = min:Min(s.min), max:Max(s.max)
		end
	end
	min, max = min - Vector3.one * MARGIN, max + Vector3.one * MARGIN
	return CFrame.new((min + max) / 2), max - min
end

function FarView.build(parent, origin, world)
	origin = origin or FarView.DEFAULT_ORIGIN
	local base = CFrame.new(origin)
	local folder = Instance.new("Folder")
	folder.Name = "BuildGuardFarViewRig"
	folder:SetAttribute("BuildGuardIgnore", true)

	local function part(name, size, cframe, color, className)
		local p = Instance.new(className or "Part")
		p.Name = name
		p.Size = size
		p.CFrame = base * cframe
		p.Anchored = true
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = folder
		return p
	end

	local spacing = 14
	local width = (#FarView.GAPS - 1) * spacing
	local farthest = FarView.DISTANCES[#FarView.DISTANCES]
	part("Floor", Vector3.new(width + 40, 1, farthest + 60), CFrame.new(0, -0.5, -(farthest / 2) + 20), Color3.fromRGB(90, 140, 70))

	for i, gap in FarView.GAPS do
		local x = (i - 1) * spacing - width / 2
		-- Lying pair: the red plate's top face sits `gap` above the white one's.
		part(("Flat_%g"):format(gap), Vector3.new(10, 1, 10), CFrame.new(x, 0.5, 0), WHITE)
		part(("FlatOverlay_%g"):format(gap), Vector3.new(8, gap, 8), CFrame.new(x, 1 + gap / 2, 0), RED)
		-- Standing pair facing the viewing spots (-Z): front faces `gap` apart.
		part(("Wall_%g"):format(gap), Vector3.new(10, 10, 1), CFrame.new(x, 6, 8), WHITE)
		part(("WallOverlay_%g"):format(gap), Vector3.new(8, 8, gap), CFrame.new(x, 6, 7.5 - gap / 2), RED)
		-- Label.
		local anchor = part(("Label_%g"):format(gap), Vector3.new(1, 1, 1), CFrame.new(x, 13, 8), WHITE)
		anchor.Transparency = 1
		anchor.CanCollide = false
		local board = Instance.new("BillboardGui")
		board.Size = UDim2.fromScale(8, 3)
		board.AlwaysOnTop = true
		board.Parent = anchor
		local text = Instance.new("TextLabel")
		text.Size = UDim2.fromScale(1, 1)
		text.BackgroundTransparency = 1
		text.TextScaled = true
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextStrokeTransparency = 0
		text.Text = ("%g"):format(gap)
		text.Parent = board
	end

	for _, distance in FarView.DISTANCES do
		local spot = part(("View_%d"):format(distance), Vector3.new(8, 1, 8), CFrame.new(0, 0.5, -distance), Color3.fromRGB(60, 120, 230), "SpawnLocation")
		spot.Material = Enum.Material.Neon
		spot.Neutral = true
		spot.Enabled = true
	end

	-- Checked before the rig goes in, so it never lands on a map.
	world = world or require(script.Parent.StudioWorld).new()
	local cframe, size = box(folder)
	local empty, what = world.isAreaEmpty(cframe, size)
	if not empty then
		folder:Destroy()
		error(
			("BuildGuard: far-view rig not built: %s is in its area at %s, the box from %s to %s. Build it on an "
				.. "empty spot: BG.FarView.build(workspace, Vector3.new(x, 0, z))"):format(
				tostring(what),
				Util.vector(origin, 0),
				Util.vector(cframe.Position - size / 2, 0),
				Util.vector(cframe.Position + size / 2, 0)
			),
			0
		)
	end
	folder.Parent = parent
	return { folder = folder }
end

return FarView
