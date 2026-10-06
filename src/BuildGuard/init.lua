--[[
	BuildGuard: catches z-fighting, buried roads/rails and bad road joins in
	Roblox builds, and fixes what can be fixed safely.

	Every fix is a plan first: scan, preview the plan, then apply it (one undo
	step in Studio).

	    local BG = require(game.ServerStorage.BuildGuard)
	    print(BG.check(workspace.Town))          -- report + planned fixes
	    local report = BG.scan(workspace.Town)
	    local plan = BG.planFixes(report)
	    print(BG.Plan.describe(plan))            -- preview
	    BG.apply(plan)                           -- apply (Ctrl+Z undoes it)

	    BG.apply(BG.planSnap({ road1, road2 }))  -- snap roads/rails to ground
	    BG.Layers.place(marking, road, { layer = 1 })
]]

local Config = require(script.Config)
local Geometry = require(script.Geometry)
local Classify = require(script.Classify)
local Plan = require(script.Plan)
local Layers = require(script.Layers)
local TestScene = require(script.TestScene)
local Vehicle = require(script.Vehicle)
local ZFight = require(script.Checks.ZFight)
local Buried = require(script.Checks.Buried)
local Ground = require(script.Checks.Ground)
local Drivability = require(script.Checks.Drivability)

local BuildGuard = {}

-- Matches the Claude plugin's version; the skill checks it so an old copy in
-- ServerStorage gets reinstalled.
BuildGuard.VERSION = "0.5.0"

BuildGuard.Config = Config
BuildGuard.Geometry = Geometry
BuildGuard.Classify = Classify
BuildGuard.Plan = Plan
BuildGuard.Layers = Layers
BuildGuard.TestScene = TestScene

local SEVERITY_ORDER = { error = 1, warning = 2 }
local CHECK_ORDER = {
	config = 0,
	buried = 1,
	offground = 2,
	zfight = 3,
	headroom = 4,
	ledge = 5,
	slope = 6,
	routeslope = 7,
	roadwidth = 8,
}

local function defaultWorld()
	if game then
		return require(script.StudioWorld).new()
	end
	error("BuildGuard: no Roblox workspace here; pass options.world", 3)
end

local function newContext(root, options)
	options = options or {}
	local config = Config.merge(options.config)
	local world = options.world or defaultWorld()
	local kinds = {}
	local resolver = Config.resolver(config)
	local ctx = { config = config, world = world, root = root, resolver = resolver }
	-- Effective config for one part (call options + BuildGuard_ attributes on
	-- it and its ancestors). Returns config, sources (key -> setting instance).
	function ctx.configFor(part)
		return resolver.resolve(part)
	end
	-- Config for a check comparing two parts: the smallest instance holding both.
	function ctx.pairConfig(a, b)
		return resolver.resolve(Config.commonAncestor(a, b))
	end
	function ctx.kindOf(part)
		local kind = kinds[part]
		if kind == nil then
			kind = Classify.kind(part, config, world) or false
			kinds[part] = kind
		end
		return kind or nil
	end
	ctx.solids = {}
	if root then
		local seen = {}
		for _, r in (if typeof(root) == "Instance" then { root } else root) do
			for _, part in Classify.collectParts(r) do
				if not seen[part] then
					seen[part] = true
					table.insert(ctx.solids, Geometry.solid(part))
					resolver.resolve(part)
				end
			end
		end
	end
	return ctx
end
BuildGuard.newContext = newContext

-- Scans everything under `root` (an Instance or a list of them).
-- Options: { world?, config? }.
-- Returns { issues, partCount, config, counts = { error, warning } }.
function BuildGuard.scan(root, options)
	local ctx = newContext(root, options)
	local issues = {}
	local function add(list)
		for _, issue in list do
			table.insert(issues, issue)
		end
	end

	local buried = Buried.scan(ctx)
	local flagged = {}
	for _, issue in buried do
		if issue.check == "buried" then
			flagged[issue.parts[1]] = true
		end
	end
	add(buried)
	add(Ground.scan(ctx, flagged))
	add(ZFight.scan(ctx))
	add(Drivability.scan(ctx))
	-- Invalid BuildGuard_ attributes found while resolving (they're ignored,
	-- and the part falls back to its parent's settings).
	local badConfig = {}
	for _, e in ctx.resolver.errors do
		local key = e.instance:GetFullName() .. "." .. e.attribute
		if not badConfig[key] then
			badConfig[key] = true
			table.insert(issues, {
				check = "config",
				severity = "error",
				parts = if e.instance:IsA("BasePart") then { e.instance } else {},
				instance = e.instance,
				message = ("%s attribute %s ignored: %s"):format(e.instance:GetFullName(), e.attribute, e.message),
			})
		end
	end

	table.sort(issues, function(a, b)
		if a.severity ~= b.severity then
			return SEVERITY_ORDER[a.severity] < SEVERITY_ORDER[b.severity]
		end
		if a.check ~= b.check then
			return CHECK_ORDER[a.check] < CHECK_ORDER[b.check]
		end
		return a.message < b.message
	end)

	local counts = { error = 0, warning = 0 }
	for _, issue in issues do
		counts[issue.severity] += 1
	end
	return {
		issues = issues,
		partCount = #ctx.solids,
		config = ctx.config,
		world = ctx.world,
		counts = counts,
		root = root,
		overrides = BuildGuard.describeOverrides(ctx.resolver.owners),
	}
end

-- Builds one plan fixing every fixable issue in `report` (or just `issues`).
-- Returns plan, unfixedIssues. Ledge/slope issues are lint and never fixed.
function BuildGuard.planFixes(report, issues)
	issues = issues or report.issues
	local plan = Plan.new()
	local unfixed, zfights = {}, {}
	for _, issue in issues do
		if issue.fixItems then
			for _, item in issue.fixItems do
				Plan.add(plan, item)
			end
		elseif issue.check == "zfight" then
			table.insert(zfights, issue)
		else
			table.insert(unfixed, issue)
		end
	end
	for _, issue in ZFight.plan(zfights, report.config, plan, report.world) do
		table.insert(unfixed, issue)
	end
	return plan, unfixed
end

-- Snap plan for parts (or every road/rail/track under a root instance).
-- Returns plan, skipped ({ part, reason } for ramps and parts with no ground).
function BuildGuard.planSnap(target, options)
	local ctx = newContext(nil, options)
	local solids = {}
	if typeof(target) == "Instance" then
		for _, part in Classify.collectParts(target) do
			if ctx.kindOf(part) then
				table.insert(solids, Geometry.solid(part))
			end
		end
	else
		for _, part in target do
			table.insert(solids, Geometry.solid(part))
		end
	end
	local plan = Plan.new()
	local skipped = Ground.planSnap(solids, ctx, plan)
	return plan, skipped
end

-- Runs `fn` as one undoable Studio action (if there's a Studio to undo in).
function BuildGuard.withUndo(name, fn)
	local history = game and game:GetService("ChangeHistoryService")
	if not history then
		return fn()
	end
	local ok, recording = pcall(history.TryBeginRecording, history, name)
	if ok and recording then
		local success, err = pcall(fn)
		history:FinishRecording(
			recording,
			if success then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
		)
		if not success then
			error(err, 0)
		end
		return
	end
	-- Outside a plugin (command bar, MCP run_code) recordings aren't allowed;
	-- waypoints still give a single Ctrl+Z step.
	history:SetWaypoint("Before " .. name)
	fn()
	history:SetWaypoint(name)
end

-- Applies a plan as one undo step. Refuses if any part changed since the plan
-- was made (re-scan and re-plan instead).
function BuildGuard.apply(plan, name)
	local stale = Plan.staleParts(plan)
	if #stale > 0 then
		error(("BuildGuard: plan is stale, %s changed since it was made; scan again"):format(stale[1]:GetFullName()), 2)
	end
	BuildGuard.withUndo(name or "BuildGuard fixes", function()
		Plan.apply(plan)
	end)
	return plan
end

function BuildGuard.revert(plan, name)
	BuildGuard.withUndo(name or "Revert BuildGuard fixes", function()
		Plan.revert(plan)
	end)
end

-- Scan, plan, apply; repeat until nothing more can be fixed (a fix can expose
-- another problem, e.g. a part nudged into a new neighbour).
-- Returns { report = final report, plans = { ... } }.
function BuildGuard.fixAll(root, options)
	options = options or {}
	local plans = {}
	local report = BuildGuard.scan(root, options)
	for _ = 1, options.maxPasses or 4 do
		local plan = BuildGuard.planFixes(report)
		if #plan.items == 0 then
			break
		end
		BuildGuard.apply(plan, "BuildGuard fix all")
		table.insert(plans, plan)
		report = BuildGuard.scan(root, options)
	end
	return { report = report, plans = plans }
end

function BuildGuard.format(report)
	local lines = {
		("BuildGuard: %d part(s) scanned — %d error(s), %d warning(s)"):format(
			report.partCount,
			report.counts.error,
			report.counts.warning
		),
	}
	if #report.overrides > 0 then
		table.insert(lines, "  Config overrides in effect:")
		for _, o in report.overrides do
			table.insert(lines, "    " .. o.text)
		end
	end
	for _, issue in report.issues do
		local fixable = issue.fixItems ~= nil or issue.check == "zfight"
		table.insert(
			lines,
			("  [%s] %-9s %s%s"):format(
				string.upper(issue.severity),
				issue.check,
				issue.message,
				if fixable then "" else "  (not auto-fixable)"
			)
		)
	end
	return table.concat(lines, "\n")
end

-- Snaps a position (Vector3) or CFrame to the horizontal grid (gridSize,
-- per-model via `relativeTo`'s config). Only X and Z move; height and
-- rotation are kept, since heights come from snapping to ground and layers.
function BuildGuard.snapToGrid(value, relativeTo)
	local grid = (if relativeTo then BuildGuard.getConfig(relativeTo) else Config.defaults).gridSize
	local function round(n)
		return math.floor(n / grid + 0.5) * grid
	end
	if typeof(value) == "Vector3" then
		return Vector3.new(round(value.X), value.Y, round(value.Z))
	end
	local p = value.Position
	return value + Vector3.new(round(p.X) - p.X, 0, round(p.Z) - p.Z)
end

--------------------------------------------------------------------------------
-- Per-model config (BuildGuard_<key> attributes)
--------------------------------------------------------------------------------

-- Sets config overrides on `instance` (a model, folder, part or workspace).
-- They apply to it and everything under it, and every report lists them with
-- `reason`, so say why the build needs them. One undo step in Studio.
--     BG.setConfig(workspace.MountainPass, { maxSlopeChange = 25 }, "switchback road")
function BuildGuard.setConfig(instance, overrides, reason)
	assert(typeof(instance) == "Instance", "BuildGuard.setConfig: instance expected")
	assert(type(reason) == "string" and #reason > 0, "BuildGuard.setConfig: give a reason for the override")
	local proposed = table.clone((Config.ownOverrides(instance)))
	for key, value in overrides do
		local ok, message = Config.check(key, value, true)
		if not ok then
			error("BuildGuard.setConfig: " .. message, 2)
		end
		proposed[key] = value
	end
	-- Validate the combination against what it inherits.
	local inherited = Config.resolver(Config.defaults).resolve(instance.Parent)
	local merged = table.clone(inherited)
	for key, value in proposed do
		merged[key] = value
	end
	if merged.zFightNudge <= merged.zFightTolerance then
		error("BuildGuard.setConfig: zFightNudge must be larger than zFightTolerance", 2)
	end
	BuildGuard.withUndo("BuildGuard: set config", function()
		for key, value in overrides do
			instance:SetAttribute(Config.ATTRIBUTE_PREFIX .. key, value)
		end
		instance:SetAttribute(Config.REASON_ATTRIBUTE, reason)
	end)
end

-- Removes overrides from `instance`: the listed keys, or all of them.
function BuildGuard.clearConfig(instance, keys)
	BuildGuard.withUndo("BuildGuard: clear config", function()
		local remaining = false
		for name in instance:GetAttributes() do
			if string.sub(name, 1, #Config.ATTRIBUTE_PREFIX) == Config.ATTRIBUTE_PREFIX then
				local key = string.sub(name, #Config.ATTRIBUTE_PREFIX + 1)
				if keys == nil or table.find(keys, key) then
					instance:SetAttribute(name, nil)
				else
					remaining = true
				end
			end
		end
		if not remaining then
			instance:SetAttribute(Config.REASON_ATTRIBUTE, nil)
		end
	end)
end

-- Effective config for `instance`: config, sources (key -> instance that set it).
function BuildGuard.getConfig(instance, options)
	local base = Config.merge(options and options.config)
	return Config.resolver(base).resolve(instance)
end

-- Every setting for `instance` with where it comes from, as text.
function BuildGuard.explainConfig(instance, options)
	local config, sources = BuildGuard.getConfig(instance, options)
	local keys = {}
	for key, spec in Config.schema do
		if spec.min and spec.scope ~= "global" then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local lines = { "BuildGuard config for " .. instance:GetFullName() .. ":" }
	for _, key in keys do
		local source = sources[key]
		table.insert(
			lines,
			("  %-24s %-8s %s"):format(
				key,
				tostring(config[key]),
				if source then "set on " .. source:GetFullName() else "default"
			)
		)
	end
	return table.concat(lines, "\n")
end

-- { instance, overrides, reason, text } for each instance carrying overrides.
function BuildGuard.describeOverrides(instances)
	local out = {}
	for _, instance in instances do
		local overrides = Config.ownOverrides(instance)
		local keys = {}
		for key in overrides do
			table.insert(keys, key)
		end
		table.sort(keys)
		local parts = {}
		for _, key in keys do
			table.insert(parts, key .. "=" .. tostring(overrides[key]))
		end
		local reason = instance:GetAttribute(Config.REASON_ATTRIBUTE)
		table.insert(out, {
			instance = instance,
			overrides = overrides,
			reason = reason,
			text = ("%s: %s%s"):format(
				instance:GetFullName(),
				table.concat(parts, ", "),
				if reason then (" — %q"):format(reason) else " — no reason given"
			),
		})
	end
	table.sort(out, function(a, b)
		return a.text < b.text
	end)
	return out
end

--------------------------------------------------------------------------------
-- Vehicles
--------------------------------------------------------------------------------

-- Measures a vehicle model (see Vehicle.lua for what's measured and how).
function BuildGuard.measureVehicle(model, options)
	return Vehicle.measure(model, options)
end

-- The road limits a measured vehicle needs: { maxLedge, maxSlopeChange,
-- minRoadWidth, roadHeadroom }. Adopt them with BG.setConfig if you agree.
function BuildGuard.vehicleLimits(profile)
	return Vehicle.limits(profile)
end

-- Measures `model` and compares it with the settings that apply to `target`
-- (default: workspace in Studio). Returns text, rows.
function BuildGuard.checkVehicle(model, target, options)
	local profile = Vehicle.measure(model, options)
	local config = if target
		then (BuildGuard.getConfig(target, options))
		elseif game then (BuildGuard.getConfig(workspace, options))
		else Config.merge(options and options.config)
	local rows, text = Vehicle.compare(profile, config)
	return text, rows, profile
end

-- One call for agents: the report plus a preview of the fixes (not applied).
function BuildGuard.check(root, options)
	local report = BuildGuard.scan(root, options)
	local plan = BuildGuard.planFixes(report)
	return BuildGuard.format(report) .. "\n\nFix preview (BuildGuard.fixAll applies it):\n" .. Plan.describe(plan)
end

-- Builds the planted-problem test scene and proves every problem is found and
-- fixed (or flagged, for lint). See SelfTest.lua.
function BuildGuard.selfTest(options)
	return require(script.SelfTest).run(BuildGuard, options)
end

return BuildGuard
