# BuildGuard

A Roblox Studio plugin (and a library you can call from the command bar or an MCP server's `execute_luau` / `run_code`) that catches the problems AI-generated builds keep having:

| Tool | What it does | Fix |
|---|---|---|
| **Z-fight scan** | Finds pairs of parts with faces pointing the same way, within `zFightTolerance` (0.01 studs) of each other, that overlap. Covers blocks, wedges, corner wedges, the round sides of cylinders and balls, and the triangles of meshes the place can load. | Preview, then apply a nudge (undoable) |
| **Meshes** | Duplicates (same mesh, position and size: a double import) and meshes whose boxes nearly coincide. Meshes that can't be loaded and unions are checked by box, and the report says how many. | Report only |
| **Far view** | `zFightViewDistance` on a map-sized model makes its faces keep the gap that still holds at that distance on a phone's 24-bit depth buffer (0.107 at 300 studs); the **Far-view test** rig shows which gaps flicker on a real device | Nudge to that gap |
| **Layer offsets** | `Layers.place(item, surface, { layer = n })` puts markings, signs and trim on a face, lifted `n × layerLift` | Prevents z-fighting in the first place |
| **Buried-part check** | Samples every road/rail/track top surface every 2 studs and flags any spot under terrain or another part | Snap onto the ground if the cover is terrain or ground; otherwise flagged for a person to decide |
| **Snap to ground** | Raycasts down under roads/rails/tracks and puts them their kind's lift above the surface (roads 0.1, rails 0.2) | Preview, then apply (undoable) |
| **Drivability lint** | For roads and rails: ledges above `maxLedge` and slope changes above `maxSlopeChange` between connected pieces, the step from the ground beside a road onto its edge, any piece steeper than `maxRouteSlope`, and roads narrower than `minRoadWidth` | Report only |
| **Headroom** | Flags tunnel roofs, bridges and overhangs lower than a kind's headroom setting (`roadHeadroom` etc.; off until set) | Report only |
| **Vehicle profile** | `BG.checkVehicle(truck)` measures an imported truck (width, height, wheels, clearance, approach/departure/breakover angles) and checks the road limits against it | Report only |
| **Fix report** | `BG.formatChanges(result)` lists every part a fix changed, by path, with its exact move and the line to put in the script that builds it | — |
| **Test scene + self-test** | Builds a messy scene with planted problems for every check and proves each one is found, then fixed (or still flagged, for lint and manual cases), with control parts that must never be flagged | — |

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
- **step-by-step workflows** (`skills/roblox-building/workflows.md`) for each kind of build: landscape, roads, rails, tunnels and caves, rivers, town buildings, details, placing imported vehicles and NPCs, plus how to report back and what to do when something goes wrong. At the start of each session Claude checks that the library in the place is the right version.
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
print(BG.formatChanges(result))            -- each changed part and its exact nudge

local id = BG.startCheck(workspace.Map)    -- a big map in the background...
print(BG.jobStatus(id))                    -- ...poll until it gives the report

BG.apply(BG.planSnap(workspace.Town.Roads)) -- snap every road/rail/track in a model
BG.Layers.place(marking, road, { layer = 1, u = -10 })
BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 2 })

print(BG.selfTest().text)                  -- planted-problem self-test
```

`BG.scan(root, { config = { maxLedge = 0.3 } })` overrides any value for one call. `BG.snapToGrid(cframe)` rounds X and Z to the 4-stud grid (height and rotation untouched).

Messages name parts by their path from the scanned model, with `#n` on the nth of several siblings with the same name (`Map/Tub/TubTop#3`), and say where to look (`at (x, y, z)`); `BG.find(root, path)` returns the part. Scans pause between checks when they can, so Studio stays responsive, and the report ends with the time each check took.

## How parts are classified

- **Road / Rail / Track:** the `BuildGuardKind` attribute (`"Road"`, `"Rail"`, `"Track"` or `"None"`), then a CollectionService tag with the same name, then the part's name: its **first word** must be road/street/highway, rail/railroad/railway or track/trackbed (words split at capitals, digits and punctuation), and the part must be flat and not round. So `Road_01` and `TrackBed` count, but `BedRail`, `RoofRail`, `Railing`, `RoadSign` and `StreetLamp` don't, and nothing inside a vehicle counts by name. `classifyByName = false` uses tags and attributes only. Each road's driving surface is its **Top (+Y) face**.
- **Ground:** Terrain, the `BuildGuardGround` tag or attribute, or a flat part whose first word is `Baseplate`/`Ground`/`Terrain`. Size alone doesn't make a part ground (a big floor slab or roof isn't).
- **Wheels:** the `BuildGuardWheel` tag or attribute; else parts that spin on a hinge or cylindrical constraint through their centre; else names whose first word is wheel/tire/tyre followed only by position words (`Wheel_FL`). A steering wheel, spare wheel or wheel arch is never a wheel.
- **Vehicles** (so their parts never count as roads by name): everything joined to a VehicleSeat or to two or more spinning wheels, and every part of a model holding a VehicleSeat or marked `BuildGuardVehicle`.
- **Layered items:** anything placed with `Layers.place` (it sets `BuildGuardLayer`). These never count as covering a road, and they move with the road when it's snapped.
- **Never moved by fixes:** ground parts, `Locked` parts, and parts with `BuildGuardLocked = true`.
- **Skipped entirely:** anything at or under an instance with the `BuildGuardIgnore` attribute or tag. It also never counts as cover, ground or a ceiling.

## How the fixes decide

- **Z-fighting:** the smaller part of the pair moves (a layered item over a plain one; never a locked or ground part). It is nudged out along the shared face normal until the faces are `zFightNudge` apart. If it fights on both opposite sides of one axis, a nudge clears both but sinks one side into the other part. That's fine when the sunk side is hidden anyway (a marking's underside on a road), so it still nudges. When both sides are visible (a window exactly as thick as its wall), it grows by the nudge on both sides instead.
- **Snap:** samples the part's underside every 2 studs. Each column starts just above the part's own top. If that's open air (the surface, or inside a tunnel), it casts straight down, so tunnel roads land on the tunnel floor, not the mountain above. If the part is buried, it steps up a stud at a time (up to 20) to the first open air and casts down from there. Deeper than that, it's skipped and reported. It moves the part up or down so its lowest point sits its kind's lift (`roadLift`, `railLift`, `trackLift`, else `groundLift`) above the highest ground hit. Ground means terrain or a part that starts *below* the snapped part's bottom, so markings, crates or rails sitting on it don't count.
- **Buried:** a point is buried when something occupies the space `buriedProbeHeight` (0.25) above the surface, so markings lying on the road don't trigger it, or when something within `buriedClearance` (3 studs) overhead covers it. Bridges and gantries higher than that are fine.

- **Round parts:** two same-size cylinders on one axis (a rod in a sleeve) or two same-size balls on one centre: the smaller part's radius grows by the nudge.
- **Moving jointed parts:** after a fix moves a part, any Weld or Motor6D holding it is updated (`C1`) to hold it in its new place. WeldConstraints are toggled off and on so they record the new offset. Revert restores them. Without this, a nudged truck strut would snap back when the game runs. (The WeldConstraint behaviour is untested in Studio.)

## Values

Defaults are in `src/BuildGuard/Config.lua`. Any model, folder or part can override them for itself and everything under it with `BuildGuard_<key>` attributes. You can edit those in Studio's Properties panel, or set them with `BG.setConfig(model, { maxSlopeChange = 25 }, "reason")`, which validates the values and records the reason. The nearest ancestor wins, and attributes on `workspace` are place-wide. Every report lists the overrides in effect with their reasons. An invalid attribute is reported as an error and ignored. When a check compares two parts (a road join, a z-fighting pair), it uses the settings of the smallest model holding both. Overrides cover joins inside a model, and joins to the outside use the outside settings. Z-fighting detection can't be changed per model. The full table of overridable keys and ranges is in `claude-plugin/roblox-buildguard/skills/roblox-building/reference.md`.

Project numbers (approved for the mining game):

| Key | Value | Meaning |
|---|---|---|
| `maxLedge` | 1.0 | Largest step between connected road (or rail) pieces; truck-tested |
| `maxRouteSlope` | 20° | Steepest any road or rail piece may tilt; a loaded truck must climb it |
| `maxSlopeChange` | 20° | Largest angle between connected pieces (catches crests and dips) |
| `minRoadWidth` | 22 | The approved haul road, measured across the driving direction (two trucks pass: 2 × width with mirrors + 2) |
| `gridSize` | 4 | Horizontal layout grid (`BG.snapToGrid`); matches terrain voxels |
| `railLift` | 0.2 | Rails above their road/track bed |
| `roadLift` | 0.1 | Roads above the ground |
| `layerLift` | 0.05 | Lift per decal/marking layer |

Engine values:

| Key | Value | Meaning |
|---|---|---|
| `zFightTolerance` | 0.01 | Same-facing faces this close together z-fight |
| `zFightNudge` | 0.02 | Gap a z-fight fix leaves (must be > tolerance) |
| `trackLift` / `groundLift` | 0.1 | Track beds / anything else you snap |
| `groundTolerance` | 0.1 | Off-ground check fires beyond this |
| `flatTiltDegrees` | 5 | Steeper parts are ramps (not snapped) |

Set project-wide numbers once with `BG.setProjectConfig`, for example the truck's headroom: `BG.setProjectConfig({ roadHeadroom = 10.6 }, "Desperado is 9.6 tall")`. They're attributes on `workspace` and also apply to models outside it.

## Tests

The library runs outside Studio under [Lune](https://github.com/lune-org/lune) with a fake world (box raycasts, box terrain):

```sh
lune run tests/run       # unit tests (tests/unit/*.luau) + self-test with three different configs
lune run tests/run zfight   # only tests whose name contains "zfight"
lune run tests/report    # prints the test scene's report before and after fixAll
```

The Studio-only parts (the plugin UI, `StudioWorld`'s raycasts, terrain voxel reads, EditableMesh loading, ChangeHistoryService undo) can't run there. Check them in Studio with **Run self-test**.
