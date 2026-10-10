# BuildGuard API reference

`local BG = require(game.ServerStorage.BuildGuard)`

## Checking and fixing

| Call | Does |
|---|---|
| `BG.check(root, options?)` | Report and fix preview as a string. Changes nothing. |
| `BG.scan(root, options?)` | Returns `report`: `report.issues`, `report.counts.error/warning`, `report.partCount`, `report.overrides`, `report.timings` (`{ name, seconds }` per check), `report.coverage` (`meshTriangles`, `meshBoxOnly`, `reasons`, and `notes`: part path → note). `root` can be an Instance or a list. Options: `config` (defaults for this call; `BuildGuard_` attributes still win), `yield = false` (never pause), `onProgress(stage, done, total, check, checks)`: check number `check` of `checks` (named `stage`) is running and has worked through `done` of `total` parts (0 of 0 when it doesn't count them; only `zfight` does). Each check's start comes as `(name, 0, 0)` and the end as `("done", 0, 0)`. |
| `BG.startCheck(root, options?)` | Starts `BG.check` in the background for a big area and returns a job id at once. |
| `BG.jobStatus(id, options?)` | `text, state`. While `"running"`: `BuildGuard check <id> running: zfight 1200/5000 parts (check 3 of 4, 12.3s so far)`. When `"done"` (or `"failed"`): the full report and fix preview, a page at a time with `{ page = n }` (120 lines per page; each page but the last ends `(page n of m; ask for page = n+1 for more)`, the last `(page m of m, the last page)`). The last 5 jobs are kept; read them only through `BG.jobStatus`. |
| `BG.format(report)` | Report as a string: the `Meshes:` line, `[NOTE]` lines, overrides, issues, time per check. |
| `BG.planFixes(report)` | Returns `plan, unfixedIssues`. Nothing moves yet. |
| `BG.Plan.describe(plan)` | Plan preview as a string. |
| `BG.apply(plan, name?)` | Applies as one undo step. Errors (`plan is stale, ... changed since it was made; scan again`) if any part changed since the scan the plan was made from. |
| `BG.revert(plan, name?)` | Puts everything back. |
| `BG.fixAll(root, options?)` | Scan, plan, apply, repeated until nothing more is fixable (`maxPasses`, default 4). Returns `{ report, plans, changes }`. |
| `BG.formatChanges(resultOrPlan)` | The fix report: every changed part (by path) with its exact move in world and own axes, its resize, and the line to put in its builder script. |
| `BG.changes(resultOrPlan)` | The same as a list: `{ part, path, move, moveLocal, resize, rotated, fromCFrame, toCFrame, fromSize, toSize, checks, reasons }`. |
| `BG.find(root, path)` | The instance a report path names (`"Map/Tub/TubTop#3"`; the first segment is `root`'s own name), or nil. |
| `BG.planSnap(partsOrModel)` | Snap plan: for a model or folder, its roads/rails/tracks; for a list, every listed part. Ignored parts (`BuildGuardIgnore`) and parts of a vehicle are never moved. Returns `plan, skipped` (`{ part, reason }` for ramps, parts with no ground or buried too deep, and ignored or vehicle parts). |
| `BG.Layers.place(item, surface, opts)` | Puts an item on a face and returns it. Options: `face` (default `"Top"`), `layer` (default 1), `u`, `v`, `rotation`, `keepPosition`, `config`. Not for a WedgePart's slope. |
| `BG.Layers.lift(layer, config?)` | Studs above the surface for that layer. |
| `BG.setConfig(instance, { key = value }, reason)` | Sets overrides for an instance and everything under it. Validated; reason required. One undo step. |
| `BG.setProjectConfig({ key = value }, reason)` | Place-wide settings (on `workspace`); they also reach models outside workspace. |
| `BG.clearConfig(instance, keys?)` | Removes the listed overrides, or all of them. |
| `BG.getConfig(instance?, options?)` | Returns `config, sources` (`sources[key]` = the instance that set it). `nil` gives the place-wide config. |
| `BG.explainConfig(instance)` | Every setting for the instance and where it comes from, as text. |
| `BG.snapToGrid(cframeOrVector, relativeTo?)` | Rounds X/Z to `gridSize` (`relativeTo`'s config, else the place-wide one). Keeps height and rotation. |
| `BG.withUndo(name, fn, discard?)` | Runs `fn` as one undo step and returns what it returns. `discard = true` rolls all of `fn`'s changes back even when it succeeds. |
| `BG.checkVehicle(model, target?)` | Measures an (imported) vehicle and compares it with the limits for `target` (default workspace), to set road numbers. Returns `text, rows, profile`; each row is ok/check/fail. |
| `BG.measureVehicle(model)` | Width, height, length, wheel radius, wheelbase, clearance, approach/departure/breakover angles (from part boxes). |
| `BG.vehicleLimits(profile)` | `{ maxLedge, maxSlopeChange, minRoadWidth, roadHeadroom }` that vehicle needs. |
| `BG.selfTest(options?)` | Builds the planted-problem scene from the settings at `options.parent` (default workspace), checks and fixes it, and removes it. Returns `{ passed, text, rows }`. It runs as one undo recording that is cancelled at the end, so it leaves no undo steps; `{ keep = true }` keeps the scene as one undo step. |
| `BG.TestScene.buildFarView(parent, origin?)` | Builds the far-view rig at `origin` (default (-4096, 0, -4096)): plate pairs with gaps 0.005–0.2 and spawn pads `View_100`, `View_300`, `View_600`. Publish to a test place and join on a phone (players spawn on the pads; disable the map's own SpawnLocations, or reset to land on another pad) to see which gap stops flickering. Delete it afterwards. |

Every issue has `check`, `severity`, `message`, `parts`, `paths` (each part's path from the scan root; `#n` marks the nth of several siblings with the same name; `%` and `/` in names are written `%25` and `%2F`) and, when it applies, `position` (where to look).

## Checks

| Check | Severity | Meaning | Auto-fix |
|---|---|---|---|
| `config` | error | A `BuildGuard_` attribute is invalid (a `zFightNudge` not above 0.01 is dropped on its own); it's ignored | Fix or clear the attribute |
| `duplicate` | error | Two parts of the same class, mesh (or shape) and look (colour, material, transparency, texture) at the same position, rotation and size (a double import) | Manual: delete one |
| `buried` | error | Something covers a road/rail/track's driving surface | Snap onto the ground if the cover is terrain or ground. Otherwise manual. |
| `offground` | warning | A flat road/rail/track hovers or is sunk more than `groundTolerance` (0.1), or has no ground below it | Snap to ground (none when there's no ground) |
| `zfight` | error | Same-facing faces overlap within 0.01 studs: flat faces, the round sides of same-size cylinders on one axis, same-size balls on one centre, and mesh triangles (meshes the place can load). Overlaps under 0.01 studs² or thinner than about 0.001 studs (rounding where pieces meet edge to edge) don't count. | Nudge the smaller part out (round parts grow their radius instead). It grows instead only when both opposite sides are visible. Welds/Motor6Ds on moved parts are updated. When both parts are locked or ground: manual, and the message says so. |
| `zgap` | warning | In a model with `zFightViewDistance`, same-facing faces closer than the gap that holds at that distance. Only beyond about 130 studs, where that gap is more than `zFightNudge`. | Move to that gap, keeping the face in front in front (push the back one further back, shrink an inner ball or rod) |
| `meshoverlap` | warning | Two meshes/unions whose boxes nearly coincide (a double import or a z-fighting copy) | Manual: check by eye |
| `headroom` | warning | Less clear height above a road/rail/track than its kind's headroom setting: a tunnel roof, bridge, overhang or a road deck crossing above | Manual |
| `ledge` | warning | Step between connected roads (or rails) over `maxLedge` | Manual |
| `edge` | warning | Step from the ground beside a road up onto (or down off) its edge over `maxLedge` | Manual: thinner road, or shape the ground up to it |
| `slope` | warning | Angle between connected roads (or rails) over `maxSlopeChange` | Manual |
| `routeslope` | warning | A road or rail piece's driving surface tilts more than `maxRouteSlope` (a wedge ramp by its slope) | Manual |
| `roadwidth` | warning | A road is narrower than `minRoadWidth` across its driving direction | Manual |

The report's `Meshes:` line says how many meshes were checked by their triangles and how many by their box only, and why (no permission to load the mesh, unions, drawn by a SpecialMesh, BlockMesh or CylinderMesh child, too many triangles). A box-only mesh is **not checked for z-fighting** at all, only for duplicates and overlapping boxes: check it by eye. A `[NOTE]` line under it is something the scan noticed about a mesh (its data isn't centred on its bounds, so its box doesn't match what you see).

## Settings you can override per model

Set with `BG.setConfig` (or `BG.setProjectConfig` for the whole place), stored as `BuildGuard_<key>` attributes. They win over a call's `config` options. Checks that compare two parts (joins, z-fighting pairs) use the settings of the smallest instance holding both. Z-fighting detection (`zFightTolerance` 0.01, `zFightMinOverlapArea` 0.01, `zFightIgnoreTransparency` 0.99) is fixed and can't be set per model.

| Key | Default | Range | Meaning |
|---|---|---|---|
| `zFightNudge` | 0.02 | 0.002–0.5 | Gap a z-fight fix leaves; must be > 0.01 |
| `zFightViewDistance` | 0 (off) | 0–5000 | Distance the model is seen from. Faces must be `2 × d² / (0.1 × 2²⁴)` apart (0.107 at 300 studs; never less than `zFightNudge`), fixes leave that gap, and layers lift at least that much. Under about 130 studs it adds nothing. For map-sized models seen from far away on phones. |
| `layerLift` | 0.05 | 0.002–0.5 | Lift per layer (read from the surface) |
| `roadLift` / `railLift` / `trackLift` | 0.1 / 0.2 / 0.1 | 0–2 | Gap a snap leaves under roads / rails / track beds |
| `groundLift` | 0.1 | 0–2 | Gap a snap leaves under anything else |
| `gridSize` | 4 | 0.05–512 | Horizontal layout grid for `snapToGrid` |
| `groundTolerance` | 0.1 | 0.01–10 | Off-ground check fires beyond this |
| `flatTiltDegrees` | 5 | 0–45 | Steeper parts count as ramps |
| `snapSearchUp` / `snapSearchDown` | 20 / 500 | 0–1000 / 1–10000 | How far a buried part looks up for open air / how far snapping looks down |
| `buriedProbeHeight` | 0.25 | 0.01–10 | Cover must rise this far above the surface |
| `buriedClearance` | 3 | 0.1–100 | How far overhead counts as covering |
| `roadHeadroom` / `railHeadroom` / `trackHeadroom` | 0 (off) | 0–500 | Clear height needed above each kind. Set `roadHeadroom` place-wide from the truck (`checkVehicle` suggests it). |
| `sampleSpacing` | 2 | 0.25–50 | Sample grid spacing for buried/snap/edges |
| `maxLedge` | 1.0 | 0–50 | Step between connected roads/rails, and from the ground onto a road edge |
| `maxSlopeChange` | 20 | 0–90 | Angle between connected roads/rails |
| `maxRouteSlope` | 20 | 0–90 | Steepest tilt of any road/rail piece |
| `minRoadWidth` | 22 | 0–1000 | Road width across the driving direction (the approved haul road) |
| `edgeProbe` | 0.5 | 0.05–4 | How far outside a road edge the ground is measured |
| `connectMargin` | 0.1 | 0–5 | Horizontal gap still counted as connected. Joins use this or `edgeProbe`, whichever is larger (0.5 by default), so a gap the edge probe steps over is checked as a join. |
| `connectMaxStep` | 4 | 0.1–100 | Bigger vertical gaps are overpasses (and drop-offs at road edges) |

Global settings (call options or `Config.lua` only): `classifyByName` (true), `kindNameWords`, `kindMaxThickness` (0.5), `drivableKinds` ({"Road", "Rail"}), `edgeLedgeKinds` ({"Road"}), `groundNames`, `groundMinFootprint` (0 = off), `meshTriangles` (true), `meshTriangleLimit` (20000), `meshOverlapRatio` (0.9).

## How parts are classified

- **Road / Rail / Track:** the `BuildGuardKind` attribute (`"Road"`, `"Rail"`, `"Track"` or `"None"`), then a tag `Road`/`Rail`/`Track`, then the name. By name, its **first word** is road/roads/roadway/street/highway (Road), rail/rails/railroad/railway (Rail) or track/tracks/trackbed (Track), and the part:
  - is flat: no thicker than half its longest side, and not a panel standing on edge (taller than its shorter side and over 1 stud tall; rails under a stud tall are fine);
  - has its top within 45° of level (a block or mesh may be upside down; a WedgePart's slope must face up);
  - isn't a ball, cylinder or corner wedge, and wasn't placed with `Layers.place`;
  - is at least 4 studs across its shorter side, for a road;
  - isn't part of a vehicle.

  Words split at capitals, digits and punctuation, so `Road_01`, `RailYard` and `TrackBed` count; `BedRail`, `RoofRail`, `Railing`, `StreetLamp` (a pole), `RoadSign` (any shape, on a post, a wall or placed with Layers), `Highway_Exit` signs, `Road_Guardrail`, `RoadBarrier`, `RailFence`, `StreetLight` heads, `Road_Kerb` strips and layered `RoadLine` markings don't. Tags and `BuildGuardKind` win whatever the shape or tilt: a ramp steeper than 45° counts only when tagged or marked.
- **Driving surface:** the face that's up: Top, the Bottom of a block or mesh lying upside down, or a WedgePart's slope (a wedge ramp's foot is at ground level, so it has no edge step there). Snapping and `offground` use the face the part rests on (a wedge's flat bottom, an upside-down block's Top), and a snap keeps the rotation.
- **Ground:** Terrain, the `BuildGuardGround` tag or attribute (on the part or any ancestor; the nearest one wins, so tag a floor folder once and set `BuildGuardGround = false` on anything in it that isn't ground), or a flat part whose first word is `Baseplate`/`Ground`/`Terrain`. Size alone doesn't make a part ground, so tag big floors that are ground.
- **Ceilings (headroom):** anything above the probe, including a road, rail or track deck crossing over. Junction pieces overlapping the road, rails resting on their bed, layered items, ignored things and vehicles are never ceilings.
- **Wheels:** the `BuildGuardWheel` attribute or tag; else parts that spin on a HingeConstraint or CylindricalConstraint through their centre along their round axis; else (only when nothing spins) names whose first word is wheel/tire/tyre followed only by position words (`Wheel_FL`, `TireRearLeft`). Used by `checkVehicle`; a steering wheel, spare wheel or wheel arch is never a wheel.
- **Vehicles** are modelled in Blender and kept separate: keep them out of the models you check and fix, or tag them `BuildGuardIgnore` (fixes don't skip vehicle parts). Parts BuildGuard sees as a vehicle's (everything joined to a VehicleSeat or to two or more spinning wheels, plus every part of a model holding a VehicleSeat or marked `BuildGuardVehicle`) never count as roads by name, cover, ground or a ceiling, and are never snapped.

## Attributes and tags

| Attribute / tag | Effect |
|---|---|
| `BuildGuardKind` = `"Road"` / `"Rail"` / `"Track"` / `"None"` (on the part) | Sets or clears the kind (overrides tags and the name) |
| tag `Road` / `Rail` / `Track` (on the part) | Sets the kind |
| `BuildGuardGround` (attribute true/false or tag) | It and everything under it count as ground (or, with false, don't); the nearest one wins |
| `BuildGuardLocked = true` (on the part) | Z-fight fixes never move it (also true for `Locked` parts and ground; snapping roads, rails and tracks doesn't look at it). A z-fight between two such parts isn't auto-fixable. |
| `BuildGuardIgnore` (attribute true or tag) | It and its descendants are skipped, never snapped, and never count as cover, ground or a ceiling |
| `BuildGuardLayer` | Set by `Layers.place`. Marks layered items: never roads by name, cover or ceilings; they ride along when the part under them is snapped. |
| `BuildGuardWheel` (attribute true/false or tag) | Marks (or unmarks) a part as a wheel for `checkVehicle` |
| `BuildGuardVehicle` (attribute true or tag) | Marks a model as a vehicle |
| `BuildGuard_<key>` | A config override (see above) |
| `BuildGuardConfigReason` | Why the overrides on this instance exist (set by `setConfig`) |
