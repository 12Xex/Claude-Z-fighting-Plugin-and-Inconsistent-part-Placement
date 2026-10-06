---
name: roblox-building
description: Rules for building or editing parts in a Roblox place through a Roblox Studio MCP server (run_code or similar). Use whenever creating, moving or detailing parts, models, roads, rails, signs, markings or trim in Studio. Covers z-fighting, layering details on surfaces, snapping roads/rails to the ground and checking the build with BuildGuard before finishing.
---

# Building in Roblox Studio with BuildGuard

You change the place by sending Luau to Studio through the Roblox Studio MCP tool that runs code (for example `run_code`). BuildGuard is a library inside the place that prevents and catches the classic build bugs.

## 0. Make sure BuildGuard is there

Run this first in every session:

```lua
print(game.ServerStorage:FindFirstChild("BuildGuard") and "BuildGuard ready" or "BuildGuard missing")
```

If it's missing, stop and ask the user to install the BuildGuard Studio plugin and press **Install library** in its panel. Don't build without it.

## 1. Rules while building

- **No flush same-facing faces.** Two parts whose faces point the same way and sit within 0.01 studs flicker (z-fighting). Common causes: a sign half-sunk into a wall, a marking whose top is level with the road, a window exactly as thick as its wall, two walls overlapping at a corner with level tops.
- **Every detail on a surface goes through Layers.** This covers road markings, signs, plaques, trim, panels and decal-like parts:
  ```lua
  local BG = require(game.ServerStorage.BuildGuard)
  BG.Layers.place(marking, road, { layer = 1, u = -10 })              -- Top face by default
  BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })
  BG.Layers.place(arrow, road, { layer = 2, rotation = 90 })          -- overlaps layer 1
  BG.Layers.place(item, surface, { layer = 1, keepPosition = true })  -- keep where it is
  ```
  The item's `Size.Y` is its thickness off the surface. `u`/`v` move it across the face from the centre. Overlapping items need different layers and the same thickness.
- **Roads, rails and tracks get snapped, not hand-positioned in Y:**
  ```lua
  BG.apply(BG.planSnap({ road1, road2 }))   -- or BG.planSnap(roadsModel)
  ```
  Name them `Road…`/`Street…`/`Highway…`, `Rail…` or `Track…`, or set the attribute `BuildGuardKind = "Road" | "Rail" | "Track"`. The driving surface is the part's **Top** face, so build road parts flat side up. Ramps (tilted over 5°) aren't snapped.
- **Nothing sits on top of a road or rail** except layered items. Buildings, crates, terrain and props must stay off them.
- **Connected road pieces must be drivable.** Keep the step and the angle at each join within the project's `maxLedge` and `maxSlopeChange`. Read them with `print(BG.Config.defaults.maxLedge, BG.Config.defaults.maxSlopeChange)`.
- Set `Size` and `CFrame` before `Parent`, and anchor static parts.
- Do the build in a few `run_code` calls, not one per part, and `print` what you made so you can see it.

## 2. Before saying the build is done

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

The build is only done when the final report shows **0 errors**. Warnings left over (ledges, slopes, roads under non-ground parts) must be fixed in the build, or listed to the user by name with the reason. Never say a build is clean without having run the check.

For the full API and what each check means, see [reference.md](reference.md).
