# BuildGuard

A Roblox Studio plugin (and a library you can call from the command bar or MCP `run_code`) that catches the problems AI-generated builds keep having:

| Tool | What it does | Fix |
|---|---|---|
| **Z-fight scan** | Finds pairs of parts with faces pointing the same way, within `zFightTolerance` (0.01 studs) of each other, that overlap | Preview, then apply a nudge (undoable) |
| **Layer offsets** | `Layers.place(item, surface, { layer = n })` puts markings, signs and trim on a face, lifted `n × layerLift` | Prevents z-fighting in the first place |
| **Buried-part check** | Samples every road/rail/track top surface every 2 studs and flags any spot under terrain or another part | Snap onto the ground if the cover is terrain or ground; otherwise flagged for a person to decide |
| **Snap to ground** | Raycasts down under roads/rails/tracks and puts them `groundLift` above the surface | Preview, then apply (undoable) |
| **Drivability lint** | Flags ledges above `maxLedge` and slope changes above `maxSlopeChange` between connected road parts | Report only |
| **Test scene + self-test** | Builds a messy scene with 10 planted problems and proves each one is found, then fixed (or still flagged, for lint and manual cases) | — |

## Install

**Plugin:** build with [Rojo](https://rojo.space) and save it into your Plugins folder:

```sh
rojo build default.project.json -o BuildGuard.rbxm
# Windows: %LOCALAPPDATA%\Roblox\Plugins   macOS: ~/Documents/Roblox/Plugins
```

**Library only** (for scripts and agents): `rojo build library.project.json -o BuildGuardLib.rbxm` and insert it into `ServerStorage`. Or press **Install library** in the plugin, which copies it to `ServerStorage.BuildGuard`.

## Using the plugin

1. Select a model or folder (or switch scope to Workspace) and press **Scan**. Click any row to select its parts. Red outlines are errors, yellow are warnings.
2. **Preview fixes** shows every planned change and ghosts each part's new position in green. Nothing moves yet.
3. **Apply** applies everything as one undo step (Ctrl+Z). **Revert last** also undoes it. If you edit any of those parts after previewing, Apply refuses and asks you to preview again.
4. **Snap selection to ground** previews a snap for the selected roads/rails/tracks. Ramps (tilted over 5°) are skipped and listed.
5. **Place items on surface**: select the items, then Ctrl+click the surface last. Choose the face and layer number. Items keep their position and heading on the face.
6. **Build test scene** builds the planted-problem scene at (4096, 0, 4096) so you can try the tools by hand. **Run self-test** builds it, checks it, fixes it, prints a pass/fail table to Output and removes it again.

## Using the library (command bar / MCP)

```lua
local BG = require(game.ServerStorage.BuildGuard)

print(BG.check(workspace.Town))            -- report + fix preview, changes nothing
local result = BG.fixAll(workspace.Town)   -- scan → plan → apply, repeated until clean
print(BG.format(result.report))            -- what's left (lint and manual items)

BG.apply(BG.planSnap(workspace.Town.Roads)) -- snap every road/rail/track in a model
BG.Layers.place(marking, road, { layer = 1, u = -10 })
BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })

print(BG.selfTest().text)                  -- planted-problem self-test
```

`BG.scan(root, { config = { maxLedge = 0.3 } })` overrides any value for one call.

## How parts are classified

- **Road / Rail / Track:** the `BuildGuardKind` attribute (`"Road"`, `"Rail"`, `"Track"` or `"None"`), then a CollectionService tag with the same name, then the part's name (`road`, `street`, `highway`; `rail` but not `railing`/`guardrail`/`handrail`; `track`). Each road's driving surface is its **Top (+Y) face**.
- **Ground:** Terrain, parts named `Baseplate`/`Ground`/`Terrain`, parts with `BuildGuardGround = true`, or anything at least 512×512 studs.
- **Layered items:** anything placed with `Layers.place` (it sets `BuildGuardLayer`). These never count as covering a road, and they move with the road when it's snapped.
- **Never moved by fixes:** ground parts, `Locked` parts, and parts with `BuildGuardLocked = true`.
- **Skipped entirely:** anything under an instance with `BuildGuardIgnore = true`.

## How the fixes decide

- **Z-fighting:** the smaller part of the pair moves (a layered item over a plain one; never a locked or ground part). It is nudged out along the shared face normal until the faces are `zFightNudge` apart. If it fights on both opposite sides of one axis, a nudge clears both but sinks one side into the other part. That's fine when the sunk side is hidden anyway (a marking's underside on a road), so it still nudges. When both sides are visible (a window exactly as thick as its wall), it grows by the nudge on both sides instead.
- **Snap:** samples the part's underside every 2 studs and raycasts down, starting 20 studs above the part so a sunk part still finds the surface over it. It moves the part up or down so its lowest point sits `groundLift` above the highest ground hit. Ground means terrain or a part that starts *below* the snapped part's bottom, so markings, crates or rails sitting on it don't count.
- **Buried:** a point is buried when something occupies the space `buriedProbeHeight` (0.25) above the surface, so markings lying on the road don't trigger it, or when something within `buriedClearance` (3 studs) overhead covers it. Bridges and gantries higher than that are fine.

## Values

All numbers are in `src/BuildGuard/Config.lua`.

| Key | Value | Meaning |
|---|---|---|
| `zFightTolerance` | 0.01 | Same-facing faces this close together z-fight |
| `zFightNudge` | 0.02 | Gap a z-fight fix leaves (must be > tolerance) |
| `layerLift` | 0.02 | Lift per layer |
| `groundLift` | 0.05 | Gap between a snapped road/rail and the ground |
| `groundTolerance` | 0.1 | Off-ground check fires beyond this |
| `flatTiltDegrees` | 5 | Steeper parts are ramps (not snapped) |
| `maxLedge` | **0.5 (provisional)** | Drivability: max step between connected roads |
| `maxSlopeChange` | **15° (provisional)** | Drivability: max angle between connected roads |

## Tests

The library runs outside Studio under [Lune](https://github.com/lune-org/lune) with a fake world (box raycasts, box terrain):

```sh
lune run tests/run       # unit tests + self-test with three different configs
lune run tests/report    # prints the test scene's report before and after fixAll
```

The Studio-only parts (the plugin UI, `StudioWorld`'s raycasts and terrain voxel reads, ChangeHistoryService undo) can't run there. Check them in Studio with **Run self-test**.
