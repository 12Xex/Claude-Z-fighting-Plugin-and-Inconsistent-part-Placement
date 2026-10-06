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
local ZFight = require(script.Checks.ZFight)
local Buried = require(script.Checks.Buried)
local Ground = require(script.Checks.Ground)
local Drivability = require(script.Checks.Drivability)

local BuildGuard = {}

BuildGuard.Config = Config
BuildGuard.Geometry = Geometry
BuildGuard.Classify = Classify
BuildGuard.Plan = Plan
BuildGuard.Layers = Layers
BuildGuard.TestScene = TestScene

local SEVERITY_ORDER = { error = 1, warning = 2 }
local CHECK_ORDER = { buried = 1, offground = 2, zfight = 3, ledge = 4, slope = 5 }

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
	local ctx = { config = config, world = world, root = root }
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
		flagged[issue.parts[1]] = true
	end
	add(buried)
	add(Ground.scan(ctx, flagged))
	add(ZFight.scan(ctx))
	add(Drivability.scan(ctx))

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
