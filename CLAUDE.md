# Building in Roblox with BuildGuard

These rules apply whenever you build or edit parts in a Roblox place (for example through Roblox Studio MCP `run_code`). BuildGuard is installed at `game.ServerStorage.BuildGuard`. If it's missing, ask the user to press **Install library** in the BuildGuard plugin.

## While building

- **Never place two parts so their faces are flush and facing the same way.** That is z-fighting. A sign half-sunk into a wall, a marking whose top is level with the road, or a window exactly as thick as its wall all flicker.
- **Anything sitting on a surface goes through Layers.** This covers road markings, signs, decals-as-parts, trim and panels:
  ```lua
  local BG = require(game.ServerStorage.BuildGuard)
  BG.Layers.place(marking, road, { layer = 1, u = -10 })        -- Top face by default
  BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })
  ```
  The item's `Size.Y` is its thickness off the surface. Items that overlap on the same face need different layer numbers and the same thickness.
- **Roads, rails and tracks go on the ground with the snap,** never with a hand-computed Y:
  ```lua
  BG.apply(BG.planSnap({ road1, road2 }))   -- or BG.planSnap(roadsModel)
  ```
  Name them so they're recognised (`Road…`, `Street…`, `Rail…`, `Track…`) or set the `BuildGuardKind` attribute. The driving surface is the part's Top face.
- **Don't let parts cover a road or rail.** Buildings, crates and hills on top of a road are flagged and can't be fixed automatically.
- **Keep connected road pieces drivable.** The step and angle between joined road parts must stay within `maxLedge` and `maxSlopeChange` (see `src/BuildGuard/Config.lua`).
- Set `Anchored = true` and `Parent` last, after `Size` and `CFrame`.

## Before you say a build is done

```lua
local BG = require(game.ServerStorage.BuildGuard)
print(BG.check(workspace.YourBuild))      -- report + preview of fixes, changes nothing
local result = BG.fixAll(workspace.YourBuild)
print(BG.format(result.report))
```

Read the output. It's only done when the final report has **no errors**. If anything remains (buried under a non-ground part, ledges, slopes), fix it by changing the build, or tell the user exactly which items are left and why. Never report a build as clean without running this.

## Working on this repo

- Library: `src/BuildGuard` (pure Luau; Studio-only code is confined to `StudioWorld.lua` and `withUndo`). Plugin UI: `src/Plugin`.
- Run `lune run tests/run` before committing. It must print `0 failed`.
- Any new check needs a planted problem in `TestScene.lua` (with the expected outcome) and a control that must not be flagged.
