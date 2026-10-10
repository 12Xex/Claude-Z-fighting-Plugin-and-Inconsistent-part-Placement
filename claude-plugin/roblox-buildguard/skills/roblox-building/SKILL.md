---
name: roblox-building
description: Rules for building or editing parts in a Roblox place through a Roblox Studio MCP server (execute_luau, run_code or similar). Use whenever creating, moving or detailing parts, models, meshes, roads, rails, signs, markings or trim in Studio, or placing imported vehicles. Covers z-fighting (flat faces, round parts, meshes), layering details on surfaces, snapping roads/rails to the ground, road edges and drivability, setting per-model BuildGuard config, and checking the build before finishing.
---

# Building in Roblox Studio with BuildGuard

You change the place by sending Luau to Studio through the Roblox Studio MCP tool that runs code: `execute_luau` on Studio's built-in MCP server, or `run_code` on the older Roblox MCP server. BuildGuard is a library inside the place that prevents and catches the classic build bugs.

**Getting text back:** end each snippet by returning one string, for example `return BG.check(model)`. Returned values come back through both servers; `print` output may only reach Studio's Output window (read it with `get_console_output` if you need it), and only the first returned value survives. Each call is its own chunk: start it with `local BG = require(game.ServerStorage.BuildGuard)` and end it with one `return`.

## 0. Make sure BuildGuard is there and current

Run this first in every session:

```lua
local m = game.ServerStorage:FindFirstChild("BuildGuard")
return if m then "BuildGuard " .. tostring(require(m).VERSION) else "BuildGuard missing"
```

- **Missing:** stop and ask the user to install the BuildGuard Studio plugin and press **Install library** in its panel. Don't build without it.
- **Not `"0.6.0"`:** the place has an old copy. Ask the user to press **Install library** again, then re-run the check.

For the step-by-step order to build each kind of thing (session start, landscape, roads, rails, tunnels and caves, rivers, buildings, signs and details, meshes, vehicles, NPCs) and how to report back, follow [workflows.md](workflows.md).

## 1. Rules while building

- **No flush same-facing faces.** Two parts whose faces point the same way and sit within 0.01 studs flicker (z-fighting). Common causes: a sign half-sunk into a wall, a marking whose top is level with the road, a window exactly as thick as its wall, two walls overlapping at a corner with level tops, a rod and a sleeve of the same radius on one axis, two same-size balls on one centre, and a mesh imported twice.
- **Every detail on a surface goes through Layers.** This covers road markings, signs, plaques, trim, panels, decal-like parts and track sleepers:
  ```lua
  local BG = require(game.ServerStorage.BuildGuard)
  BG.Layers.place(marking, road, { layer = 1, u = -10 })              -- Top face by default
  BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })
  BG.Layers.place(arrow, road, { layer = 2, rotation = 90 })          -- overlaps layer 1
  BG.Layers.place(item, surface, { layer = 1, keepPosition = true })  -- keep where it is
  return "placed 4 items"
  ```
  The item's `Size.Y` is its thickness off the surface. `u`/`v` move it across the face from the centre. Overlapping items need different layers and the same thickness. Layers can't put anything on a WedgePart's slope.
- **Roads, rails and tracks get snapped, not hand-positioned in Y:**
  ```lua
  local BG = require(game.ServerStorage.BuildGuard)
  local plan, skipped = BG.planSnap({ road1, road2 })   -- or BG.planSnap(roadsModel)
  BG.apply(plan)
  return BG.Plan.describe(plan) .. ("\n%d skipped"):format(#skipped)
  ```
  Name them so their **first word** is `Road`/`Street`/`Highway`, `Rail`/`Railroad`, or `Track` (`Road_North_01`, not `HaulRoad_01`), and build them flat side up: a road at least 4 studs wide, top within 45° of level. Or tag them `Road`/`Rail`/`Track`, or set `BuildGuardKind`; tags and the attribute count whatever the shape. Other names and shapes are safe: `StreetLamp`, `RoadSign`, `Highway_Exit` signs, `Road_Guardrail`, `RoadBarrier`, `RailFence`, `StreetLight` heads, `Road_Kerb` strips, `BedRail`, `Railing` and anything placed with Layers (a `RoadLine` marking, a sign on a board) are never treated as roads or rails. Ramps (tilted over 5°) aren't snapped. Snapping leaves roads 0.1 and rails 0.2 above whatever is under them, and never moves ignored parts or parts of a vehicle (they're listed in `skipped`).
- **Roads must be thin enough to drive onto.** The step from the ground beside a road up onto its top must stay within the 1-stud ledge limit. A snapped road sits 0.1 above the ground, so make road parts **0.8 studs thick** (never more than 0.9), or shape the terrain up to the road's top.
- **Nothing sits on top of a road, rail or track bed** except layered items (markings, sleepers). Buildings, crates, terrain and props must stay off them.
- **Roads and rails must be drivable by a loaded truck.** The project limits are:
  - every road at least **22 studs wide** across its driving direction;
  - no road or rail piece tilted more than **20°**;
  - at most a **1-stud step** and a **20° angle change** where two pieces join, and at most a 1-stud step from the ground onto a road edge.

  Check the limits for a model with `return BG.explainConfig(workspace.YourBuild)`. To climb more than 20°, build switchbacks; don't make a steeper ramp.
- **Ground:** Terrain is ground. A big part that is ground (a floor slab under the map) must be tagged `BuildGuardGround`; size alone doesn't make it ground. Tag a folder or model and every part in it is ground.
- **Tunnels and caves:** build the tunnel floor first, then snap roads and rails onto it. Snapping finds the tunnel floor, not the mountain above. A road or rail buried deeper than 20 studs isn't moved; carve its tunnel instead. Headroom comes from the place-wide `roadHeadroom` (set from the truck), or from the tunnel's model: `BG.setConfig(mine, { roadHeadroom = 14 }, "13-stud haul truck")`. A road deck crossing above a road counts as its ceiling too.
- **Meshes:** don't import a mesh twice (duplicates are errors). BuildGuard checks the triangles of meshes the place owner owns. Other meshes, unions and parts drawn by a SpecialMesh are checked by their box only: for duplicates and overlapping boxes, **not for z-fighting**. The report's `Meshes:` line says how many and why; tell the user, and check those by eye. Flat details on a mesh still go through Layers.
- **Vehicles (trucks, minecarts) are modelled in Blender** and kept separate. Don't build or rework them in Studio. Keep vehicle models out of the models you check and fix (for example under `workspace.Vehicles`), or tag them `BuildGuardIgnore`: `fixAll` would otherwise nudge their parts, and the next import brings the problem back. If a report names vehicle parts, tell the user so they fix it in Blender. To set road numbers from a truck, measure it with `return (BG.checkVehicle(workspace.Vehicles.Truck))` and show the user every `FAIL` and `check` line. Don't change the project limits without their OK.
- **Lay out roads, rails and buildings on the 4-stud grid:** `part.CFrame = BG.snapToGrid(cf)`. This rounds X and Z only (to the place-wide `gridSize`). Heights come from the snap and from layers, so never round heights or small detail to the grid.
- **Labels, helpers and NPCs** that BuildGuard shouldn't check: tag the model or folder `BuildGuardIgnore` (CollectionService) or set the attribute.
- Set `Size` and `CFrame` before `Parent`, and anchor static parts.
- Do the build in a few calls, not one per part, and return a short summary of what each call made.

## 2. Adjust the config for what you're building

Each model can carry its own settings. Set them on the model you're building, before you check it, when its design really needs different numbers. Examples: a mountain road with steeper joins, a rail line with more ground clearance, a stage whose trim needs a bigger layer lift, a quarry-wide model seen from far away.

```lua
local BG = require(game.ServerStorage.BuildGuard)
BG.setConfig(workspace.MountainPass, { maxSlopeChange = 25 }, "switchback road up the cliff")
return BG.explainConfig(workspace.MountainPass)   -- every setting and where it comes from
```

To remove overrides again (one call):

```lua
local BG = require(game.ServerStorage.BuildGuard)
BG.clearConfig(workspace.MountainPass, { "maxSlopeChange" })   -- or clearConfig(model) for all
return BG.explainConfig(workspace.MountainPass)
```

- Settings apply to the instance and everything under it, and the nearest one wins. A part can override its model.
- Project numbers that every model needs (the truck's headroom) are place-wide: `BG.setProjectConfig({ roadHeadroom = 10.6 }, "Desperado is 9.6 tall")`, only with the user's OK.
- Use the narrowest instance that needs it: one model, not `workspace`.
- A reason is required. It's shown in every report next to the override, so write it for the user.
- Attributes win over a call's `{ config = ... }` options, so a one-off `BG.scan(root, { config = ... })` can't override a model's settings.
- **Never loosen a limit just to make a report pass.** Only change a limit when the design calls for it. If something fails because the build is wrong, fix the build.
- Z-fighting detection can't be loosened per model; attempts are reported as errors. A model can be made stricter for distance viewing with `zFightViewDistance` (only after the user has checked the far-view rig on a phone).
- A join between two pieces uses the settings of the smallest model holding both. Overrides on your model cover joins inside it. Where it meets roads outside it, the outside limits apply, so build those joins to the outside limits.
- Only the keys in the reference's settings table can be set per model. Classification (name words, ground names) stays in `Config.lua`.

## 3. Before saying the build is done

```lua
local BG = require(game.ServerStorage.BuildGuard)
return BG.check(workspace.YourBuild)   -- report + fix preview; changes nothing
```

For a big area (a whole map), start it in the background and poll, so the call doesn't time out. First call:

```lua
local BG = require(game.ServerStorage.BuildGuard)
return BG.startCheck(workspace.Map)   -- the job id
```

Then, in later calls, until it returns the report:

```lua
local BG = require(game.ServerStorage.BuildGuard)
return (BG.jobStatus("<id>", { page = 1 }))   -- progress, or the report a page (120 lines) at a time
```

While it runs you get `BuildGuard check <id> running: zfight 1200/5000 parts (check 3 of 4, 12.3s so far)`. A long report ends each page with `(page n of m; ask for page = n+1 for more)`; ask for the next page until one ends with `(page m of m, the last page)`.

Read the report. Every message names parts by their path from the checked model (`Map/Tub/TubTop#3` is the third sibling named TubTop) and says where (`at (x, y, z)`); `BG.find(root, path)` gets the instance. Fix what you can by changing your build, or apply the automatic fixes (one Ctrl+Z step for the user):

```lua
local BG = require(game.ServerStorage.BuildGuard)
local result = BG.fixAll(workspace.YourBuild)
return BG.format(result.report) .. "\n\n" .. BG.formatChanges(result)   -- what's left, and each change made
```

If a script builds the model, copy every change from the fix report into that script (each line gives the `part.CFrame *=` or `part.Size +=` to add). Otherwise the next rebuild brings the problems back. If `fixAll` stops with `plan is stale`, something changed during the scan: run it again.

The build is only done when the final report shows **0 errors**. Invalid config attributes also count as errors, and so does a z-fight marked `(not auto-fixable)` because both parts are locked or ground: move one by hand. Tell the user about every line under "Config overrides in effect", the `Meshes:` line when meshes were checked by box only (not for z-fighting), and every `[NOTE]` (a mesh whose box doesn't match what you see). Warnings left over (ledges, edges, slopes, headroom, gaps for far viewing, roads under non-ground parts) must be fixed in the build, or listed to the user by name with the reason. Never say a build is clean without having run the check.

For the full API and what each check means, see [reference.md](reference.md).
