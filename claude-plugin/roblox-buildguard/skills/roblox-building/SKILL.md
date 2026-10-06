---
name: roblox-building
description: Rules for building or editing parts in a Roblox place through a Roblox Studio MCP server (run_code or similar). Use whenever creating, moving or detailing parts, models, roads, rails, signs, markings, trim or cave entrances in Studio. Covers z-fighting, layering details on surfaces, snapping roads/rails to the ground, the fixed route numbers (ledge, slope, road width, grid, lifts, cave entrance width), setting per-model BuildGuard config for what is being built, and checking the build before finishing.
---

# Building in Roblox Studio with BuildGuard

You change the place by sending Luau to Studio through the Roblox Studio MCP tool that runs code (for example `run_code`). BuildGuard is a library inside the place that prevents and catches the classic build bugs.

## 0. Make sure BuildGuard is there

Run this first in every session:

```lua
print(game.ServerStorage:FindFirstChild("BuildGuard") and "BuildGuard ready" or "BuildGuard missing")
```

If it's missing, stop and ask the user to install the BuildGuard Studio plugin and press **Install library** in its panel. Don't build without it.

## 1. Fixed numbers

Every road and rail must pass these, so a loaded truck can always climb the route. They are BuildGuard's defaults and its checks enforce them.

| Number | Value | Key |
|---|---|---|
| Max ledge the truck must climb | 1.0 stud | `maxLedge` |
| Max route slope (and max change at a join) | 20° | `maxRouteSlope`, `maxSlopeChange` |
| Road width | 16 studs minimum | `minRoadWidth` |
| Grid | 4 studs | `gridSize` |
| Rail lift above the road bed | 0.2 stud | `railLift` |
| Road lift above the ground | 0.1 stud | `groundLift` |
| Decal / marking layer lift | 0.05 stud per layer | `layerLift` |
| Cave entrance width | 6 studs maximum | `caveEntranceWidth` |

- Put level road edges on the 4-stud grid: positions, lengths and widths in multiples of 4 (a 16-wide road centred on a multiple of 4 has its edges on the grid).
- A road's width is the shorter side of its top face, so build road pieces at least 16 studs long too.
- Don't type the lifts by hand: snapping and `Layers.place` apply them.
- Mark every cave entrance with a part filling the opening, named `CaveEntrance…` (or with the attribute `BuildGuardCaveEntrance = true`), Transparency 1, CanCollide off, its local X spanning the opening's width. Minecarts and players fit through 6 studs; trucks don't.

## 2. Rules while building

- **No flush same-facing faces.** Two parts whose faces point the same way and sit within 0.01 studs flicker (z-fighting). Common causes: a sign half-sunk into a wall, a marking whose top is level with the road, a window exactly as thick as its wall, two walls overlapping at a corner with level tops.
- **Every detail on a surface goes through Layers.** This covers road markings, signs, plaques, trim, panels and decal-like parts:
  ```lua
  local BG = require(game.ServerStorage.BuildGuard)
  BG.Layers.place(marking, road, { layer = 1, u = -10 })              -- Top face by default
  BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })
  BG.Layers.place(arrow, road, { layer = 2, rotation = 90 })          -- overlaps layer 1
  BG.Layers.place(item, surface, { layer = 1, keepPosition = true })  -- keep where it is
  ```
  The item's `Size.Y` is its thickness off the surface. `u`/`v` move it across the face from the centre. Overlapping items need different layers and the same thickness. Layer n sits n × 0.05 studs off the face.
- **Roads, rails and tracks get snapped, not hand-positioned in Y:**
  ```lua
  BG.apply(BG.planSnap({ road1, road2 }))   -- or BG.planSnap(roadsModel)
  ```
  Name them `Road…`/`Street…`/`Highway…`, `Rail…` or `Track…`, or set the attribute `BuildGuardKind = "Road" | "Rail" | "Track"`. The driving surface is the part's **Top** face, so build road parts flat side up. Roads and tracks land 0.1 above what's under them, rails 0.2 above their bed. Ramps (tilted over 5°) aren't snapped.
- **Nothing sits on top of a road or rail** except layered items. Buildings, crates, terrain and props must stay off them.
- **Connected road pieces must be drivable.** Keep the step and the angle at each join within `maxLedge` and `maxSlopeChange`, and every road, rail and track no steeper than `maxRouteSlope`, for that model. See them with `print(BG.explainConfig(workspace.YourBuild))`.
- Set `Size` and `CFrame` before `Parent`, and anchor static parts.
- Do the build in a few `run_code` calls, not one per part, and `print` what you made so you can see it.

## 3. Adjust the config for what you're building

Each model can carry its own settings. Set them on the model you're building, before you check it, when its design really needs different numbers. Examples: a mountain road with steeper joins, a rail line with more ground clearance, a stage whose trim needs a bigger layer lift.

```lua
local BG = require(game.ServerStorage.BuildGuard)
BG.setConfig(workspace.MountainPass, { maxSlopeChange = 25, maxRouteSlope = 25 }, "switchback road up the cliff")
print(BG.explainConfig(workspace.MountainPass))   -- every setting and where it comes from
BG.clearConfig(workspace.MountainPass, { "maxSlopeChange" })   -- or clearConfig(model) for all
```

- Settings apply to the instance and everything under it, and the nearest one wins. A part can override its model, and `workspace` holds place-wide settings.
- Use the narrowest instance that needs it: one model, not `workspace`.
- A reason is required. It's shown in every report next to the override, so write it for the user.
- **Never loosen a limit just to make a report pass.** Only change a limit when the design calls for it. If something fails because the build is wrong, fix the build. Don't loosen z-fighting settings at all. The fixed numbers above are agreed with the user: ask them before overriding any of them.
- Joins between two parts: z-fighting uses the stricter of the two parts' settings. Ledge and slope limits use the looser, so a model you loosen also governs where it joins other roads. Mention that to the user when it applies.
- Only the keys in the reference's settings table can be set per model. Classification (name patterns, ground names) stays in `Config.lua`.

## 4. Before saying the build is done

```lua
local BG = require(game.ServerStorage.BuildGuard)
print(BG.check(workspace.YourBuild))   -- report + fix preview; changes nothing
```

Read the report. Fix what you can by changing your build, or apply the automatic fixes (one Ctrl+Z step for the user):

```lua
local BG = require(game.ServerStorage.BuildGuard)
local result = BG.fixAll(workspace.YourBuild)
print(BG.format(result.report))
```

The build is only done when the final report shows **0 errors**. Invalid config attributes also count as errors. Tell the user about every line under "Config overrides in effect". Warnings left over (ledges, slopes, grades, narrow or off-grid roads, wide cave entrances, roads under non-ground parts) must be fixed in the build, or listed to the user by name with the reason. Never say a build is clean without having run the check.

For the full API and what each check means, see [reference.md](reference.md).
