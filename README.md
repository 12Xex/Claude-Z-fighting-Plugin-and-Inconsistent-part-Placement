# BuildGuard

A Roblox Studio plugin (and a library you can call from the command bar or MCP `run_code`) that catches the problems AI-generated builds keep having:

| Tool | What it does | Fix |
|---|---|---|
| **Z-fight scan** | Finds pairs of parts with faces pointing the same way, within `zFightTolerance` (0.01 studs) of each other, that overlap | Preview, then apply a nudge (undoable) |
| **Layer offsets** | `Layers.place(item, surface, { layer = n })` puts markings, signs and trim on a face, lifted `n × layerLift` | Prevents z-fighting in the first place |
| **Buried-part check** | Samples every road/rail/track top surface every 2 studs and flags any spot under terrain or another part | Snap onto the ground if the cover is terrain or ground; otherwise flagged for a person to decide |
| **Snap to ground** | Raycasts down under roads/rails/tracks and puts them their kind's lift above the surface (roads 0.1, rails 0.2) | Preview, then apply (undoable) |
| **Drivability lint** | For roads and rails: ledges above `maxLedge` and slope changes above `maxSlopeChange` between connected pieces, any piece steeper than `maxRouteSlope`, and roads narrower than `minRoadWidth` | Report only |
| **Cave entrance lint** | Flags cave entrance markers wider than `caveEntranceWidth` | Report only |
| **Test scene + self-test** | Builds a messy scene with 13 planted problems and proves each one is found, then fixed (or still flagged, for lint and manual cases) | — |

## Install

**Plugin:** build with [Rojo](https://rojo.space) and save it into your Plugins folder:

```sh
rojo build default.project.json -o BuildGuard.rbxm
# Windows: %LOCALAPPDATA%\Roblox\Plugins   macOS: ~/Documents/Roblox/Plugins
```

**Library only** (for scripts and agents): `rojo build library.project.json -o BuildGuardLib.rbxm` and insert it into `ServerStorage`. Or press **Install library** in the plugin, which copies it to `ServerStorage.BuildGuard`.

## Claude plugin (so Claude builds with these rules)

This repo is also a Claude Code plugin marketplace. The `roblox-buildguard` plugin gives Claude:

- a **`roblox-building` skill** Claude loads on its own whenever it builds in Studio. It covers using `Layers.place` for details, snapping roads and rails, keeping roads drivable, and running BuildGuard's check before calling a build done.
- a **`/roblox-buildguard:check [path]`** command: report, preview, then apply fixes only after you say yes.

Setup, once:

1. Connect Claude Code to Roblox Studio's MCP server: in Studio, **Assistant Settings → MCP Servers → Quick connect → Claude Code**.
2. Install the BuildGuard Studio plugin (above) and press **Install library** in each place you build in.
3. Install the Claude plugin:
   ```sh
   claude plugin marketplace add 12xex/claude-z-fighting-plugin-and-inconsistent-part-placement
   claude plugin install roblox-buildguard@buildguard
   ```
   Or, to try it from a local clone for one session: `claude --plugin-dir ./claude-plugin/roblox-buildguard`.

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

`BG.scan(root, { config = { maxLedge = 0.3 } })` overrides any value for one call. `BG.snapToGrid(cframe)` rounds X and Z to the 4-stud grid (height and rotation untouched).

## How parts are classified

- **Road / Rail / Track:** the `BuildGuardKind` attribute (`"Road"`, `"Rail"`, `"Track"` or `"None"`), then a CollectionService tag with the same name, then the part's name (`road`, `street`, `highway`; `rail` but not `railing`/`guardrail`/`handrail`; `track`). Each road's driving surface is its **Top (+Y) face**.
- **Cave entrance:** a marker part filling the opening, named `CaveEntrance…` or with `BuildGuardCaveEntrance = true`. Its `Size.X` is the opening's width.
- **Ground:** Terrain, parts named `Baseplate`/`Ground`/`Terrain`, parts with `BuildGuardGround = true`, or anything at least 512×512 studs.
- **Layered items:** anything placed with `Layers.place` (it sets `BuildGuardLayer`). These never count as covering a road, and they move with the road when it's snapped.
- **Never moved by fixes:** ground parts, `Locked` parts, and parts with `BuildGuardLocked = true`.
- **Skipped entirely:** anything under an instance with `BuildGuardIgnore = true`.

## How the fixes decide

- **Z-fighting:** the smaller part of the pair moves (a layered item over a plain one; never a locked or ground part). It is nudged out along the shared face normal until the faces are `zFightNudge` apart. If it fights on both opposite sides of one axis, a nudge clears both but sinks one side into the other part. That's fine when the sunk side is hidden anyway (a marking's underside on a road), so it still nudges. When both sides are visible (a window exactly as thick as its wall), it grows by the nudge on both sides instead.
- **Snap:** samples the part's underside every 2 studs and raycasts down, starting 20 studs above the part so a sunk part still finds the surface over it. It moves the part up or down so its lowest point sits its kind's lift (`roadLift`, `railLift`, `trackLift`, else `groundLift`) above the highest ground hit. Ground means terrain or a part that starts *below* the snapped part's bottom, so markings, crates or rails sitting on it don't count.
- **Buried:** a point is buried when something occupies the space `buriedProbeHeight` (0.25) above the surface, so markings lying on the road don't trigger it, or when something within `buriedClearance` (3 studs) overhead covers it. Bridges and gantries higher than that are fine.

## Values

Defaults are in `src/BuildGuard/Config.lua`. Any model, folder or part can override them for itself and everything under it with `BuildGuard_<key>` attributes. You can edit those in Studio's Properties panel, or set them with `BG.setConfig(model, { maxSlopeChange = 25 }, "reason")`, which validates the values and records the reason. The nearest ancestor wins, and attributes on `workspace` are place-wide. Every report lists the overrides in effect with their reasons. An invalid attribute is reported as an error and ignored. When a check compares two parts, z-fighting uses the stricter setting and ledge/slope limits use the looser one. The full table of overridable keys and ranges is in `claude-plugin/roblox-buildguard/skills/roblox-building/reference.md`.

Project numbers (approved for the mining game):

| Key | Value | Meaning |
|---|---|---|
| `maxLedge` | 1.0 | Largest step between connected road (or rail) pieces; truck-tested |
| `maxRouteSlope` | 20° | Steepest any road or rail piece may tilt; a loaded truck must climb it |
| `maxSlopeChange` | 20° | Largest angle between connected pieces (catches crests and dips) |
| `minRoadWidth` | 16 | One truck plus passing room, measured across the driving direction |
| `gridSize` | 4 | Horizontal layout grid (`BG.snapToGrid`); matches terrain voxels |
| `railLift` | 0.2 | Rails above their road/track bed |
| `roadLift` | 0.1 | Roads above the ground |
| `layerLift` | 0.05 | Lift per decal/marking layer |
| `caveEntranceWidth` | 6 | Widest cave entrance: minecarts and players fit, trucks don't |

Engine values:

| Key | Value | Meaning |
|---|---|---|
| `zFightTolerance` | 0.01 | Same-facing faces this close together z-fight |
| `zFightNudge` | 0.02 | Gap a z-fight fix leaves (must be > tolerance) |
| `trackLift` / `groundLift` | 0.1 | Track beds / anything else you snap |
| `groundTolerance` | 0.1 | Off-ground check fires beyond this |
| `flatTiltDegrees` | 5 | Steeper parts are ramps (not snapped) |

## Tests

The library runs outside Studio under [Lune](https://github.com/lune-org/lune) with a fake world (box raycasts, box terrain):

```sh
lune run tests/run       # unit tests + self-test with three different configs
lune run tests/report    # prints the test scene's report before and after fixAll
```

The Studio-only parts (the plugin UI, `StudioWorld`'s raycasts and terrain voxel reads, ChangeHistoryService undo) can't run there. Check them in Studio with **Run self-test**.
