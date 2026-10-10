--[[
	BuildGuard Studio plugin: a dock widget around the BuildGuard library.

	Flow: Scan -> Preview fixes (outlines what will change, ghosts the targets)
	-> Apply (one Ctrl+Z step) -> Revert last if you change your mind.

	Scans yield between chunks so Studio stays responsive; the status line
	shows progress, and other buttons wait until the scan is done. Clicking a
	result selects its parts and moves the camera to where the problem is.
	Apply prints the fix report (each part and its exact change) to Output so
	the script that builds the model can be corrected too.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local CollectionService = game:GetService("CollectionService")
local CoreGui = game:GetService("CoreGui")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")

local BuildGuard = require(script.Parent.BuildGuard)
local Plan = BuildGuard.Plan

local COLORS = {
	error = Color3.fromRGB(235, 70, 70),
	warning = Color3.fromRGB(240, 180, 40),
	target = Color3.fromRGB(60, 200, 120),
}
local FACES = { "Top", "Front", "Back", "Right", "Left", "Bottom" }
-- How far from a problem the camera stops when a result row is clicked.
local VIEW_DISTANCE = 25
-- How many of the slowest checks the status line names after a scan.
local SLOWEST_SHOWN = 3
local FAR_VIEW_ORIGIN = Vector3.new(-4096, 0, -4096)

--------------------------------------------------------------------------------
-- Widget
--------------------------------------------------------------------------------

local toolbar = plugin:CreateToolbar("BuildGuard")
local toggleButton = toolbar:CreateButton(
	"BuildGuard",
	"Find and fix z-fighting, buried roads/rails, ground snapping and drivability problems",
	""
)
toggleButton.ClickableWhenViewportHidden = true

local widget = plugin:CreateDockWidgetPluginGui(
	"BuildGuard",
	DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 380, 600, 300, 380)
)
widget.Title = "BuildGuard"
widget.Name = "BuildGuard"

toggleButton.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)
widget:GetPropertyChangedSignal("Enabled"):Connect(function()
	toggleButton:SetActive(widget.Enabled)
end)

local function theme(color)
	return settings().Studio.Theme:GetColor(color)
end

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.BorderSizePixel = 0
root.Parent = widget

local padding = Instance.new("UIPadding")
for _, side in { "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" } do
	padding[side] = UDim.new(0, 6)
end
padding.Parent = root

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 4)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = root

local order = 0
local themed = {}

local function nextOrder()
	order += 1
	return order
end

local function row()
	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1, 0, 0, 26)
	frame.BackgroundTransparency = 1
	frame.LayoutOrder = nextOrder()
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.Padding = UDim.new(0, 4)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = frame
	frame.Parent = root
	return frame
end

local function button(parent, text, widthScale, onClick)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Size = UDim2.new(widthScale, -4, 1, 0)
	b.Font = Enum.Font.SourceSans
	b.TextSize = 15
	b.AutoButtonColor = true
	b.BorderSizePixel = 0
	b.Parent = parent
	table.insert(themed, { b, "button" })
	b.Activated:Connect(onClick)
	return b
end

local function label(parent, text, height)
	local l = Instance.new("TextLabel")
	l.Text = text
	l.Size = UDim2.new(1, 0, 0, height or 20)
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.SourceSans
	l.TextSize = 15
	l.TextWrapped = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Top
	l.LayoutOrder = nextOrder()
	l.Parent = parent
	table.insert(themed, { l, "text" })
	return l
end

local function applyTheme()
	root.BackgroundColor3 = theme(Enum.StudioStyleGuideColor.MainBackground)
	for _, entry in themed do
		local instance, kind = entry[1], entry[2]
		if kind == "button" then
			instance.BackgroundColor3 = theme(Enum.StudioStyleGuideColor.Button)
			instance.TextColor3 = theme(Enum.StudioStyleGuideColor.ButtonText)
		elseif kind == "text" then
			instance.TextColor3 = theme(Enum.StudioStyleGuideColor.MainText)
		elseif kind == "box" then
			instance.BackgroundColor3 = theme(Enum.StudioStyleGuideColor.InputFieldBackground)
			instance.TextColor3 = theme(Enum.StudioStyleGuideColor.MainText)
		elseif kind == "list" then
			instance.BackgroundColor3 = theme(Enum.StudioStyleGuideColor.ScrollBarBackground)
		end
	end
end

--------------------------------------------------------------------------------
-- Markers (outlines + target ghosts), kept in CoreGui so they're never saved
--------------------------------------------------------------------------------

local markers = Instance.new("Folder")
markers.Name = "BuildGuardMarkers"
markers.Archivable = false
markers.Parent = CoreGui

local function clearMarkers()
	markers:ClearAllChildren()
end

local function outline(part, color)
	local box = Instance.new("SelectionBox")
	box.Adornee = part
	box.Color3 = color
	box.SurfaceColor3 = color
	box.SurfaceTransparency = 0.85
	box.LineThickness = 0.04
	box.Parent = markers
end

local function ghost(cframe, size)
	local box = Instance.new("BoxHandleAdornment")
	box.Adornee = workspace.Terrain -- Terrain's CFrame is the identity, so CFrame is world space
	box.CFrame = cframe
	box.Size = size
	box.Color3 = COLORS.target
	box.Transparency = 0.55
	box.AlwaysOnTop = false
	box.ZIndex = 0
	box.Parent = markers
end

--------------------------------------------------------------------------------
-- State + list
--------------------------------------------------------------------------------

local state = {
	scope = "Selection", -- or "Workspace"
	report = nil,
	roots = nil, -- what the last Scan covered; Preview/Apply/Revert re-scan these
	pending = nil, -- previewed plan, not applied
	applied = nil, -- last applied plan (for Revert)
	layer = 1,
	face = 1,
	testScene = nil,
	farView = nil, -- the far-view rig's folder, if built this session
	busy = nil, -- name of the action running now (a scan yields, so clicks can arrive mid-way)
}

local status, list

local function setStatus(text)
	status.Text = text
end

local function clearList()
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function listRow(text, color, onClick)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, -8, 0, 0)
	b.AutomaticSize = Enum.AutomaticSize.Y
	b.BackgroundTransparency = 1
	b.Font = Enum.Font.SourceSans
	b.TextSize = 14
	b.TextWrapped = true
	b.TextXAlignment = Enum.TextXAlignment.Left
	b.Text = text
	b.TextColor3 = color or theme(Enum.StudioStyleGuideColor.MainText)
	b.LayoutOrder = #list:GetChildren()
	b.Parent = list
	if onClick then
		b.Activated:Connect(onClick)
	end
	return b
end

local function scopeRoots()
	if state.scope == "Workspace" then
		return { workspace }
	end
	local roots = Selection:Get()
	if #roots == 0 then
		return nil
	end
	return roots
end

-- Moves the editor camera so `position` sits in the middle of the view,
-- VIEW_DISTANCE studs away, keeping the direction it looks in. Orbiting
-- then turns around the problem.
local function lookAt(position)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local view = camera.CFrame
	camera.CFrame = (view - view.Position) + (position - view.LookVector * VIEW_DISTANCE)
	camera.Focus = CFrame.new(position)
end

-- Selects an issue's parts (the ones still in the place) and, when the
-- issue says where the problem is, looks at that spot, so one of many
-- parts with the same name is easy to find.
local function showIssue(issue)
	local targets = {}
	for _, instance in (if #issue.parts > 0 then issue.parts else { issue.instance }) do
		if instance.Parent then
			table.insert(targets, instance)
		end
	end
	Selection:Set(targets)
	if typeof(issue.position) == "Vector3" then
		lookAt(issue.position)
	end
end

local function showReport(report)
	clearMarkers()
	clearList()
	for _, issue in report.issues do
		local color = COLORS[issue.severity]
		for _, part in issue.parts do
			outline(part, color)
		end
		local fixable = BuildGuard.isFixable(issue)
		listRow(
			("[%s] %s%s"):format(issue.check, issue.message, if fixable then "" else " (manual)"),
			color,
			function()
				showIssue(issue)
			end
		)
	end
	if #report.issues == 0 then
		listRow("No problems found.")
	end
end

local function progressText(stage, done, total, seconds)
	return ("Scanning: %s %s/%s (%.1fs)"):format(tostring(stage), tostring(done or 0), tostring(total or "?"), seconds)
end

-- "zfight 1.2s, buried 0.4s, offground 0.1s": the slowest steps of a scan.
local function slowestSteps(timings, count)
	local sorted = table.clone(timings)
	table.sort(sorted, function(a, b)
		return a.seconds > b.seconds
	end)
	local parts = {}
	for i = 1, math.min(count, #sorted) do
		table.insert(parts, ("%s %.1fs"):format(sorted[i].name, sorted[i].seconds))
	end
	return table.concat(parts, ", ")
end

-- Every step's time, and why meshes were checked by box only, in Output.
local function printScanDetails(report)
	if report.timings then
		local parts = {}
		for _, t in report.timings do
			table.insert(parts, ("%s %.3fs"):format(t.name, t.seconds))
		end
		print("BuildGuard scan times: " .. table.concat(parts, ", "))
	end
	local coverage = report.coverage
	if coverage and (coverage.meshBoxOnly or 0) > 0 then
		local reasons = {}
		for reason, count in coverage.reasons or {} do
			table.insert(reasons, ("%s (%d)"):format(reason, count))
		end
		table.sort(reasons)
		print(
			("BuildGuard: %d mesh(es) checked by their box only%s"):format(
				coverage.meshBoxOnly,
				if #reasons > 0 then ": " .. table.concat(reasons, "; ") else ""
			)
		)
	end
end

local function scanSummary(report, seconds)
	local text = ("%d part(s) in %.2fs — %d error(s), %d warning(s)."):format(
		report.partCount,
		seconds,
		report.counts.error,
		report.counts.warning
	)
	if report.timings and #report.timings > 0 then
		text ..= " Slowest: " .. slowestSteps(report.timings, SLOWEST_SHOWN) .. " (all times in Output)."
	end
	local boxOnly = if report.coverage then report.coverage.meshBoxOnly or 0 else 0
	if boxOnly > 0 then
		text ..= (" %d mesh(es) checked by box only (reasons in Output)."):format(boxOnly)
	end
	return text .. " Click a row to select its parts and look at the problem."
end

-- `fresh` = take roots from the current scope (the Scan button). Otherwise
-- re-scan what the last Scan covered: clicking a result row changes the
-- selection, and that mustn't shrink the scan.
local function scan(fresh)
	local roots = if fresh or not state.roots then scopeRoots() else state.roots
	if not roots then
		setStatus("Select a model/folder/parts to scan, or switch scope to Workspace.")
		return nil
	end
	state.roots = roots
	local started = os.clock()
	setStatus("Scanning…")
	local ok, report = pcall(BuildGuard.scan, roots, {
		onProgress = function(stage, done, total)
			setStatus(progressText(stage, done, total, os.clock() - started))
		end,
	})
	if not ok then
		setStatus("Scan failed: " .. tostring(report))
		return nil
	end
	state.report = report
	state.pending = nil
	showReport(report)
	printScanDetails(report)
	setStatus(scanSummary(report, os.clock() - started))
	return report
end

local function preview(plan, heading)
	state.pending = plan
	clearMarkers()
	clearList()
	for _, item in plan.items do
		outline(item.part, COLORS.warning)
		ghost(item.toCFrame, item.toSize)
		listRow(Plan.describeItem(item), nil, function()
			Selection:Set({ item.part })
		end)
	end
	if plan.deferred > 0 then
		listRow(("%d more change(s) wait for the next scan."):format(plan.deferred))
	end
	setStatus(
		("%s: %d change(s) previewed (green = where parts will go). Nothing has moved yet — press Apply."):format(
			heading,
			#plan.items
		)
	)
end

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

local function onPreviewFixes()
	local report = scan()
	if not report then
		return
	end
	local plan, unfixed = BuildGuard.planFixes(report)
	if #plan.items == 0 then
		setStatus(("Nothing auto-fixable. %d issue(s) need a manual decision."):format(#unfixed))
		return
	end
	preview(plan, "Fix preview")
end

-- Fixes made here are lost when a script rebuilds the model, so the fix
-- report (each part and its exact move or resize) goes to Output for
-- correcting that script. Returns true if it was printed.
local function printFixReport(plan)
	if not BuildGuard.formatChanges then
		return false
	end
	local ok, text = pcall(BuildGuard.formatChanges, plan)
	if not ok then
		warn("BuildGuard: couldn't write the fix report: " .. tostring(text))
		return false
	end
	print(text)
	return true
end

local function onApply()
	local plan = state.pending
	if not plan then
		setStatus("Nothing previewed. Use Preview fixes or Snap to ground first.")
		return
	end
	if #Plan.staleParts(plan) > 0 then
		state.pending = nil
		clearMarkers()
		setStatus("Parts changed since the preview, so it was dropped. Preview again.")
		return
	end
	BuildGuard.apply(plan, "BuildGuard: apply fixes")
	state.applied = plan
	state.pending = nil
	local reported = printFixReport(plan)
	scan()
	setStatus(
		("Applied %d change(s) (Ctrl+Z or Revert last undoes them). "):format(#plan.items)
			.. (if reported
				then "Fix report printed to Output: each part and its exact nudge, for correcting builder scripts. "
				else "")
			.. status.Text
	)
end

local function onRevert()
	if not state.applied then
		setStatus("Nothing applied yet in this session.")
		return
	end
	local stale = 0
	for _, item in state.applied.items do
		if item.part.Parent == nil then
			stale += 1
		end
	end
	if stale > 0 then
		setStatus("Some fixed parts were deleted since; use Ctrl+Z instead.")
		return
	end
	BuildGuard.revert(state.applied, "BuildGuard: revert fixes")
	state.applied = nil
	scan()
	setStatus("Reverted the last applied fixes. " .. status.Text)
end

local function onSnap()
	local parts, seen = {}, {}
	local tags = {
		hasTag = function(instance, tag)
			return CollectionService:HasTag(instance, tag)
		end,
	}
	local function add(part)
		if not seen[part] then
			seen[part] = true
			table.insert(parts, part)
		end
	end
	for _, selected in Selection:Get() do
		if selected:IsA("BasePart") then
			add(selected)
		end
		for _, d in selected:GetDescendants() do
			if d:IsA("BasePart") and BuildGuard.Classify.kind(d, BuildGuard.Config.defaults, tags) then
				add(d)
			end
		end
	end
	if #parts == 0 then
		setStatus("Select road/rail/track parts (or a model containing them) to snap.")
		return
	end
	local plan, skipped = BuildGuard.planSnap(parts)
	preview(plan, "Snap preview")
	for _, s in skipped do
		listRow(("skipped %s: %s"):format(s.part.Name, s.reason), COLORS.warning, function()
			Selection:Set({ s.part })
		end)
	end
end

local layerBox, faceButton, scopeButton

local function onLayer()
	local selected = Selection:Get()
	local surface = selected[#selected]
	if #selected < 2 or not surface:IsA("BasePart") then
		setStatus("Select the item(s) first, then the surface part last (Ctrl+click).")
		return
	end
	local layer = tonumber(layerBox.Text)
	if not layer or layer < 1 or layer % 1 ~= 0 then
		setStatus("Layer must be a whole number >= 1.")
		return
	end
	local face = FACES[state.face]
	local placed = 0
	BuildGuard.withUndo("BuildGuard: place on layer", function()
		for i = 1, #selected - 1 do
			local item = selected[i]
			if item:IsA("BasePart") then
				BuildGuard.Layers.place(item, surface, { face = face, layer = layer, keepPosition = true })
				placed += 1
			end
		end
	end)
	setStatus(
		("Placed %d item(s) on %s's %s face at layer %d (+%.3f studs)."):format(
			placed,
			surface.Name,
			face,
			layer,
			BuildGuard.Layers.lift(layer)
		)
	)
end

local function removeTestScene()
	if state.testScene then
		local scene = state.testScene
		state.testScene = nil
		BuildGuard.withUndo("BuildGuard: remove test scene", function()
			BuildGuard.TestScene.destroy(scene, require(script.Parent.BuildGuard.StudioWorld).new())
		end)
	end
end

local function onBuildScene()
	removeTestScene()
	-- Drop any earlier scan/preview so the list matches the new selection.
	state.pending = nil
	state.report = nil
	clearMarkers()
	clearList()
	local world = require(script.Parent.BuildGuard.StudioWorld).new()
	BuildGuard.withUndo("BuildGuard: build test scene", function()
		state.testScene = BuildGuard.TestScene.build(
			workspace,
			world,
			BuildGuard.Config.merge(),
			require(script.Parent.BuildGuard.SelfTest).DEFAULT_ORIGIN
		)
	end)
	Selection:Set({ state.testScene.folder })
	state.scope = "Selection"
	state.roots = { state.testScene.folder }
	scopeButton.Text = "Scope: Selection"
	setStatus("Test scene built at (4096, 0, 4096) and selected. Scan it, preview, apply.")
end

local function onSelfTest()
	removeTestScene()
	setStatus("Running self-test…")
	local ok, result = pcall(BuildGuard.selfTest)
	clearMarkers()
	clearList()
	if not ok then
		setStatus("Self-test errored: " .. tostring(result))
		return
	end
	print(result.text)
	for _, r in result.rows do
		listRow((if r.ok then "ok    " else "FAIL  ") .. r.text, if r.ok then nil else COLORS.error)
	end
	setStatus(
		(if result.passed then "Self-test PASSED" else "Self-test FAILED")
			.. " — full table printed to Output. The scene was removed again."
	)
end

local function onInstall()
	local existing = ServerStorage:FindFirstChild("BuildGuard")
	BuildGuard.withUndo("BuildGuard: install library", function()
		if existing then
			existing:Destroy()
		end
		local copy = script.Parent.BuildGuard:Clone()
		copy.Parent = ServerStorage
	end)
	setStatus("Installed ServerStorage.BuildGuard. From the command bar / MCP run_code: "
		.. "print(require(game.ServerStorage.BuildGuard).check(workspace.YourModel))")
end

-- Builds the far-view rig (replacing one built earlier this session) so the
-- z-fight gap can be judged from far away on a real device.
local function onFarView()
	local build = BuildGuard.TestScene and BuildGuard.TestScene.buildFarView
	if not build then
		setStatus("This BuildGuard version has no far-view rig. Update the plugin.")
		return
	end
	local origin = if BuildGuard.FarView and BuildGuard.FarView.DEFAULT_ORIGIN
		then BuildGuard.FarView.DEFAULT_ORIGIN
		else FAR_VIEW_ORIGIN
	local old = state.farView
	local rig = BuildGuard.withUndo("BuildGuard: build far-view rig", function()
		if old and old.Parent then
			old:Destroy()
		end
		return build(workspace, origin)
	end)
	state.farView = rig and rig.folder
	if state.farView then
		Selection:Set({ state.farView })
	end
	setStatus(
		"Far-view rig built: pairs of plates with gaps from 0.005 to 0.2 studs, labelled, with camera spots at "
			.. "100, 300 and 600 studs. Publish or Team Test it and look from each spot on a phone: the smallest "
			.. "gap that doesn't flicker at your viewing distance is the one to use (set "
			.. "BuildGuard_zFightViewDistance on map-sized models). "
			.. ("It's at (%.0f, %.0f, %.0f) and selected: press F to look at it."):format(origin.X, origin.Y, origin.Z)
	)
end

-- Runs a button's action unless another one is still going: a scan yields
-- so Studio stays responsive, which lets clicks arrive before it ends.
local function guarded(name, action)
	return function()
		if state.busy then
			setStatus(("Still busy with %s; wait for it to finish."):format(state.busy))
			return
		end
		state.busy = name
		local ok, err = pcall(action)
		state.busy = nil
		if not ok then
			warn(("BuildGuard: error in %s: %s"):format(name, tostring(err)))
			setStatus(("Stopped by an error (%s): %s"):format(name, tostring(err)))
		end
	end
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local scopeRow = row()
scopeButton = button(scopeRow, "Scope: Selection", 1, function()
	state.scope = if state.scope == "Selection" then "Workspace" else "Selection"
	scopeButton.Text = "Scope: " .. state.scope
end)

local mainRow = row()
button(
	mainRow,
	"Scan",
	0.25,
	guarded("the scan", function()
		scan(true)
	end)
)
button(mainRow, "Preview fixes", 0.25, guarded("the fix preview", onPreviewFixes))
button(mainRow, "Apply", 0.25, guarded("applying fixes", onApply))
button(mainRow, "Revert last", 0.25, guarded("the revert", onRevert))

local snapRow = row()
button(snapRow, "Snap selection to ground (preview)", 1, guarded("the snap preview", onSnap))

local layerRow = row()
layerBox = Instance.new("TextBox")
layerBox.Text = "1"
layerBox.PlaceholderText = "layer"
layerBox.Size = UDim2.new(0.15, -4, 1, 0)
layerBox.Font = Enum.Font.SourceSans
layerBox.TextSize = 15
layerBox.BorderSizePixel = 0
layerBox.ClearTextOnFocus = false
layerBox.Parent = layerRow
table.insert(themed, { layerBox, "box" })
faceButton = button(layerRow, "Face: Top", 0.3, function()
	state.face = state.face % #FACES + 1
	faceButton.Text = "Face: " .. FACES[state.face]
end)
button(layerRow, "Place items on surface", 0.55, guarded("placing items", onLayer))

local testRow = row()
button(testRow, "Build test scene", 0.5, guarded("the test scene", onBuildScene))
button(testRow, "Run self-test", 0.5, guarded("the self-test", onSelfTest))

local toolRow = row()
button(toolRow, "Far-view test rig", 0.5, guarded("the far-view rig", onFarView))
button(toolRow, "Install library", 0.5, guarded("installing", onInstall))

-- The status grows with its text; the list takes the height that is left.
status = label(root, "Select something and press Scan.", 36)
status.AutomaticSize = Enum.AutomaticSize.Y

list = Instance.new("ScrollingFrame")
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.CanvasSize = UDim2.new()
list.ScrollBarThickness = 6
list.BorderSizePixel = 0
list.LayoutOrder = nextOrder()
list.Parent = root
table.insert(themed, { list, "list" })
local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 2)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list

-- Rows have fixed heights; the status line's height depends on its text
-- (and reads 0 until the widget is first shown).
local function fitList()
	local used = 0
	for _, child in root:GetChildren() do
		if child ~= list and child:IsA("GuiObject") then
			local height = child.Size.Y.Offset
			if child == status then
				height = math.max(height, child.AbsoluteSize.Y)
			end
			used += height + layout.Padding.Offset
		end
	end
	list.Size = UDim2.new(1, 0, 1, -used)
end
status:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitList)
fitList()

applyTheme()
settings().Studio.ThemeChanged:Connect(applyTheme)

-- A previewed plan goes stale as soon as anything is undone or redone.
ChangeHistoryService.OnUndo:Connect(function()
	if state.pending then
		state.pending = nil
		clearMarkers()
		setStatus("Undo happened — preview cleared. Scan again.")
	end
end)

plugin.Unloading:Connect(function()
	markers:Destroy()
end)
