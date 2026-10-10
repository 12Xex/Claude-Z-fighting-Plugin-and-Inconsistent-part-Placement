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
local Util = require(script.Util)
local Geometry = require(script.Geometry)
local Classify = require(script.Classify)
local Kinematics = require(script.Kinematics)
local Plan = require(script.Plan)
local Layers = require(script.Layers)
local TestScene = require(script.TestScene)
local FarView = require(script.FarView)
local Vehicle = require(script.Vehicle)
local ZFight = require(script.Checks.ZFight)
local Buried = require(script.Checks.Buried)
local Ground = require(script.Checks.Ground)
local Drivability = require(script.Checks.Drivability)

local BuildGuard = {}

-- Matches the Claude plugin's version; the skill checks it so an old copy in
-- ServerStorage gets reinstalled.
BuildGuard.VERSION = "0.6.0"

BuildGuard.Config = Config
BuildGuard.Geometry = Geometry
BuildGuard.Classify = Classify
BuildGuard.Plan = Plan
BuildGuard.Layers = Layers
BuildGuard.TestScene = TestScene
BuildGuard.FarView = FarView
-- The far-view rig is built from the plugin's test row like the test scene.
TestScene.buildFarView = FarView.build

local SEVERITY_ORDER = { error = 1, warning = 2 }
local CHECK_ORDER = {
	config = 0,
	duplicate = 1,
	buried = 2,
	offground = 3,
	zfight = 4,
	zgap = 5,
	meshoverlap = 6,
	headroom = 7,
	ledge = 8,
	edge = 9,
	slope = 10,
	routeslope = 11,
	roadwidth = 12,
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
	local resolver = Config.resolver(config, options.place)
	local roots = if root == nil then {} elseif typeof(root) == "Instance" then { root } else root
	local ctx = { config = config, world = world, root = root, roots = roots, resolver = resolver, options = options }
	-- Effective config for one part (call options + BuildGuard_ attributes on
	-- it and its ancestors). Returns config, sources (key -> setting instance).
	function ctx.configFor(part)
		return resolver.resolve(part)
	end
	-- Config for a check comparing two parts: the smallest instance holding both.
	function ctx.pairConfig(a, b)
		return resolver.resolve(Config.commonAncestor(a, b))
	end

	-- Readable path from the scan root ("Map/Truck/TubTop#3"); see Util.path.
	local paths = {}
	function ctx.path(instance)
		local p = paths[instance]
		if not p then
			p = Util.path(instance, roots)
			paths[instance] = p
		end
		return p
	end

	-- At or under a BuildGuardIgnore instance (never scanned, never cover/ground).
	local ignoredCache = {}
	function ctx.isIgnored(instance)
		return Classify.isIgnored(instance, ignoredCache)
	end

	-- Joints, assemblies and vehicles under the scan roots (worked out once).
	local graph, vehicles, vehicleOwner
	function ctx.graph()
		if not graph then
			graph = Kinematics.graph(roots)
		end
		return graph
	end
	function ctx.vehicles()
		if not vehicles then
			vehicles, vehicleOwner = Kinematics.vehicles(roots, ctx.graph())
		end
		return vehicles
	end
	function ctx.vehicleOf(part)
		if #roots == 0 then
			return nil
		end
		ctx.vehicles()
		return vehicleOwner[part]
	end
	local function inVehicle(part)
		return ctx.vehicleOf(part) ~= nil
	end
	function ctx.kindOf(part)
		local kind = kinds[part]
		if kind == nil then
			kind = Classify.kind(part, config, world, inVehicle) or false
			kinds[part] = kind
		end
		return kind or nil
	end

	-- Long checks call ctx.yield() between pieces of work. It lets Studio
	-- breathe (world.yield waits a frame once its time slice is used) unless
	-- options.yield is false or the caller can't yield.
	local canYield = options.yield ~= false and world.yield ~= nil and coroutine.isyieldable()
	function ctx.yield()
		if canYield then
			world.yield()
		end
	end
	-- Progress for long scans: options.onProgress(stage, done, total).
	function ctx.progress(stage, done, total)
		if options.onProgress then
			options.onProgress(stage, done, total)
		end
		ctx.yield()
	end

	ctx.solids = {}
	if root then
		local seen = {}
		for _, r in roots do
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

-- The checks a scan runs, in order. Buried runs first: parts it flags are
-- skipped by the off-ground check, and parts either flags are skipped by
-- the edge check (one issue per part is enough).
local CHECKS = {
	{ name = "buried", run = function(ctx, state)
		local issues = Buried.scan(ctx)
		for _, issue in issues do
			if issue.check == "buried" then
				state.flagged[issue.parts[1]] = true
			end
		end
		return issues
	end },
	{ name = "offground", run = function(ctx, state)
		local issues = Ground.scan(ctx, state.flagged)
		for _, issue in issues do
			state.flagged[issue.parts[1]] = true
		end
		return issues
	end },
	{ name = "zfight", run = function(ctx)
		return ZFight.scan(ctx)
	end },
	-- Roads already reported as buried or off the ground get no edge
	-- warnings: snapping them changes their edges anyway.
	{ name = "drivability", run = function(ctx, state)
		return Drivability.scan(ctx, state.flagged)
	end },
}
BuildGuard.CHECKS = CHECKS

-- Scans everything under `root` (an Instance or a list of them).
-- Options: {
--   world?, config?,
--   yield?       -- false: never yield (default: yield between chunks when the
--                   caller can, so Studio stays responsive)
--   onProgress?  -- function(stage, done, total)
-- }
-- Returns { issues, partCount, config, world, counts = { error, warning },
--   root, overrides, timings = { { name, seconds } }, seconds, coverage? }.
-- Every issue has `paths` (its parts' paths from the scan root).
function BuildGuard.scan(root, options)
	options = options or {}
	local started = Util.clock()
	local timings = {}
	local ctx = newContext(root, options)
	table.insert(timings, { name = "collect", seconds = Util.clock() - started })
	local issues = {}
	local state = { flagged = {} }
	for i, check in CHECKS do
		ctx.progress(check.name, i - 1, #CHECKS)
		local t = Util.clock()
		for _, issue in check.run(ctx, state) do
			table.insert(issues, issue)
		end
		table.insert(timings, { name = check.name, seconds = Util.clock() - t })
	end
	ctx.progress("done", #CHECKS, #CHECKS)
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
				message = ("%s attribute %s ignored: %s"):format(ctx.path(e.instance), e.attribute, e.message),
			})
		end
	end

	table.sort(issues, function(a, b)
		if a.severity ~= b.severity then
			return SEVERITY_ORDER[a.severity] < SEVERITY_ORDER[b.severity]
		end
		if a.check ~= b.check then
			return (CHECK_ORDER[a.check] or 99) < (CHECK_ORDER[b.check] or 99)
		end
		return a.message < b.message
	end)

	local counts = { error = 0, warning = 0 }
	for _, issue in issues do
		counts[issue.severity] += 1
		issue.paths = {}
		for i, part in issue.parts do
			issue.paths[i] = ctx.path(part)
		end
	end
	return {
		issues = issues,
		partCount = #ctx.solids,
		config = ctx.config,
		world = ctx.world,
		counts = counts,
		root = root,
		roots = ctx.roots,
		overrides = BuildGuard.describeOverrides(ctx.resolver.owners, ctx.path),
		timings = timings,
		seconds = Util.clock() - started,
		coverage = ctx.coverage,
		path = ctx.path,
	}
end

-- Is this issue fixed automatically (by its own fix items or a planner)?
function BuildGuard.isFixable(issue)
	return issue.fixItems ~= nil or issue.planner ~= nil
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
		elseif issue.planner == "zfight" then
			table.insert(zfights, issue)
		else
			table.insert(unfixed, issue)
		end
	end
	for _, issue in ZFight.plan(zfights, report.config, plan, report.world) do
		table.insert(unfixed, issue)
	end
	for _, item in plan.items do
		item.path = if report.path then report.path(item.part) else Util.path(item.part, report.roots)
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
	for _, item in plan.items do
		item.path = Util.path(item.part, if typeof(target) == "Instance" then { target } else nil)
	end
	return plan, skipped
end

-- Runs `fn` as one undoable Studio action (if there's a Studio to undo in)
-- and returns what it returns. When a recording can't be opened (an MCP
-- call or the command bar already records the whole call, or there's no
-- plugin security), `fn` just runs and the caller's recording covers it.
function BuildGuard.withUndo(name, fn)
	local history = game and game:GetService("ChangeHistoryService")
	local ok, recording = false, nil
	if history then
		ok, recording = pcall(history.TryBeginRecording, history, name)
	end
	if not (ok and recording) then
		return fn()
	end
	local results = table.pack(pcall(fn))
	pcall(
		history.FinishRecording,
		history,
		recording,
		if results[1] then Enum.FinishRecordingOperation.Commit else Enum.FinishRecordingOperation.Cancel
	)
	if not results[1] then
		error(results[2], 0)
	end
	return table.unpack(results, 2, results.n)
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
-- Returns { report = final report, plans = { ... }, changes = Plan.changes }.
-- Print BG.formatChanges(result) for the fix report.
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
	return { report = report, plans = plans, changes = Plan.changes(plans) }
end

-- Every part a fix changed, with its exact move/resize (net over all passes).
-- Takes a plan, a list of plans, or a fixAll result.
function BuildGuard.changes(planOrResult)
	if planOrResult.changes then
		return planOrResult.changes
	end
	return Plan.changes(planOrResult.plans or planOrResult)
end

-- The fix report as text, with the line to change in a builder script for
-- each part (so a rebuild doesn't bring the problem back).
function BuildGuard.formatChanges(planOrResult)
	return Plan.formatChanges(BuildGuard.changes(planOrResult))
end

function BuildGuard.format(report)
	local lines = {
		("BuildGuard: %d part(s) scanned — %d error(s), %d warning(s)%s"):format(
			report.partCount,
			report.counts.error,
			report.counts.warning,
			if report.seconds then (" in %.2fs"):format(report.seconds) else ""
		),
	}
	local coverage = report.coverage
	if coverage and (coverage.meshTriangles or 0) + (coverage.meshBoxOnly or 0) > 0 then
		local reasons = {}
		for reason, count in coverage.reasons or {} do
			table.insert(reasons, ("%s: %d"):format(reason, count))
		end
		table.sort(reasons)
		table.insert(
			lines,
			("  Meshes: %d checked by their triangles, %d by their box only%s"):format(
				coverage.meshTriangles or 0,
				coverage.meshBoxOnly or 0,
				if #reasons > 0 then " (" .. table.concat(reasons, "; ") .. ")" else ""
			)
		)
	end
	if #report.overrides > 0 then
		table.insert(lines, "  Config overrides in effect:")
		for _, o in report.overrides do
			table.insert(lines, "    " .. o.text)
		end
	end
	for _, issue in report.issues do
		local fixable = BuildGuard.isFixable(issue)
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
	if report.timings then
		local parts = {}
		for _, t in report.timings do
			table.insert(parts, ("%s %.2fs"):format(t.name, t.seconds))
		end
		table.insert(lines, "  Time: " .. table.concat(parts, ", "))
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

-- Place-wide settings: attributes on workspace, which also apply to models
-- outside workspace. Use this for the project's own numbers (the approved
-- road width, the haul truck's headroom) so every model gets them.
--     BG.setProjectConfig({ roadHeadroom = 10.6 }, "Desperado is 9.6 tall")
function BuildGuard.setProjectConfig(overrides, reason)
	local place = Config.place()
	assert(place, "BuildGuard.setProjectConfig: no workspace here")
	BuildGuard.setConfig(place, overrides, reason)
end

-- The instance a report path ("Map/Tub/TubTop#3") names, or nil.
function BuildGuard.find(root, path)
	return Util.find(root, path)
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
function BuildGuard.describeOverrides(instances, pathOf)
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
				if pathOf then pathOf(instance) else instance:GetFullName(),
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

--------------------------------------------------------------------------------
-- Long checks: start one, then poll it
--------------------------------------------------------------------------------

-- A full-map check can take longer than a remote (MCP) call may wait. Start
-- it, and it runs in the background, yielding between chunks so Studio
-- stays responsive; poll it with BG.jobStatus(id).
--     local id = BG.startCheck(workspace.Map)
--     print(BG.jobStatus(id))   -- "running: zfight (3/4 checks, 12.3s)" or the report
-- Jobs are kept as StringValues in a BuildGuardJobs folder (in CoreGui when
-- the caller may write there, else ServerStorage; never saved with the
-- place), so any later call can read them. The last 5 are kept. A long
-- report can be read a page at a time: BG.jobStatus(id, { page = 2 }).
local MAX_JOBS = 5
local MAX_TEXT = 190000
local jobs = {}
local jobCount = 0

local function jobFolder(options)
	if options.jobParent then
		return options.jobParent
	end
	if not game then
		return nil
	end
	-- CoreGui isn't part of the place, so job records stay out of undo
	-- history; ServerStorage is the fallback when CoreGui is off limits.
	for _, service in { "CoreGui", "ServerStorage" } do
		local ok, folder = pcall(function()
			local container = game:GetService(service)
			local existing = container:FindFirstChild("BuildGuardJobs")
			if existing then
				return existing
			end
			local created = Instance.new("Folder")
			created.Name = "BuildGuardJobs"
			created.Archivable = false
			created.Parent = container
			return created
		end)
		if ok and folder then
			return folder
		end
	end
	return nil
end

local function newJobId()
	jobCount += 1
	if game then
		local ok, guid = pcall(function()
			return game:GetService("HttpService"):GenerateGUID(false)
		end)
		if ok then
			return "check-" .. string.sub(guid, 1, 8)
		end
	end
	return ("check-%d"):format(jobCount)
end

function BuildGuard.startCheck(root, options)
	options = table.clone(options or {})
	local id = newJobId()
	local folder = jobFolder(options)
	local record
	if folder then
		local existing = {}
		for _, child in folder:GetChildren() do
			if child:IsA("StringValue") then
				table.insert(existing, child)
			end
		end
		table.sort(existing, function(a, b)
			return (a:GetAttribute("Started") or 0) < (b:GetAttribute("Started") or 0)
		end)
		for i = 1, #existing - MAX_JOBS + 1 do
			existing[i]:Destroy()
		end
		record = Instance.new("StringValue")
		record.Name = id
		record.Archivable = false
		record:SetAttribute("State", "running")
		record:SetAttribute("Stage", "starting")
		record:SetAttribute("Started", Util.clock())
		record.Parent = folder
	end
	local job = { id = id, state = "running", stage = "starting", done = 0, total = 0, started = Util.clock(), record = record }
	jobs[id] = job
	local onProgress = options.onProgress
	options.onProgress = function(stage, done, total)
		job.stage, job.done, job.total = stage, done, total
		if record then
			record:SetAttribute("Stage", stage)
			record:SetAttribute("Done", done)
			record:SetAttribute("Total", total)
			record:SetAttribute("Seconds", Util.clock() - job.started)
		end
		if onProgress then
			onProgress(stage, done, total)
		end
	end
	local function run()
		local ok, text = pcall(BuildGuard.check, root, options)
		job.state = if ok then "done" else "failed"
		job.text = if ok then text else ("BuildGuard check %s failed: %s"):format(id, tostring(text))
		job.seconds = Util.clock() - job.started
		if record then
			local stored = job.text
			if #stored > MAX_TEXT then
				stored = string.sub(stored, 1, MAX_TEXT) .. "\n... (report cut short; check smaller models for the rest)"
			end
			record.Value = stored
			record:SetAttribute("Seconds", job.seconds)
			record:SetAttribute("State", job.state)
		end
	end
	if task then
		task.spawn(run)
	else
		run()
	end
	return id
end

-- One page of a long text: lines (page - 1) * size + 1 .. page * size, with
-- a "page n of m" line when there's more than one page.
function BuildGuard.page(text, page, size)
	size = size or 120
	local lines = string.split(text, "\n")
	local pages = math.max(1, math.ceil(#lines / size))
	page = math.clamp(page or 1, 1, pages)
	if pages == 1 then
		return text
	end
	local out = {}
	for i = (page - 1) * size + 1, math.min(page * size, #lines) do
		table.insert(out, lines[i])
	end
	table.insert(out, ("(page %d of %d; ask for page = %d for more)"):format(page, pages, math.min(page + 1, pages)))
	return table.concat(out, "\n")
end

-- Status of a started check: text, state ("running" | "done" | "failed" |
-- "unknown"). When done, the text is the full report and fix preview, a
-- page at a time if options.page is given (120 lines per page).
function BuildGuard.jobStatus(id, options)
	options = options or {}
	local job = jobs[id]
	local record = job and job.record
	if not record then
		local folder = jobFolder(options)
		record = folder and folder:FindFirstChild(id)
	end
	local function finished(text, state)
		if options.page then
			return BuildGuard.page(text, options.page), state
		end
		return text, state
	end
	if job and job.state ~= "running" then
		return finished(job.text, job.state)
	end
	if record and record:GetAttribute("State") ~= "running" then
		return finished(record.Value, record:GetAttribute("State"))
	end
	if job or record then
		local stage = if job then job.stage else record:GetAttribute("Stage")
		local done = if job then job.done else record:GetAttribute("Done") or 0
		local total = if job then job.total else record:GetAttribute("Total") or 0
		local seconds = if job then Util.clock() - job.started else record:GetAttribute("Seconds") or 0
		return ("BuildGuard check %s running: %s (%d/%d checks done, %.1fs so far)"):format(id, tostring(stage), done, total, seconds),
			"running"
	end
	return ("No BuildGuard check %s (only the last %d are kept)"):format(tostring(id), MAX_JOBS), "unknown"
end

-- Builds the planted-problem test scene and proves every problem is found and
-- fixed (or flagged, for lint). See SelfTest.lua.
function BuildGuard.selfTest(options)
	return require(script.SelfTest).run(BuildGuard, options)
end

return BuildGuard
