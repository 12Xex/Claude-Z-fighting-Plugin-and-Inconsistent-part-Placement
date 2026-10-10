# BuildGuard API reference

`local BG = require(game.ServerStorage.BuildGuard)`

## Checking and fixing

| Call | Does |
|---|---|
| `BG.check(root)` | Report and fix preview as a string. Changes nothing. |
| `BG.scan(root, options)` | Returns `report` (`report.issues`, `report.counts.error/warning`, `report.timings`, `report.coverage`). `root` can be an Instance or a list. Options: `config`, `yield = false` (never pause), `onProgress(stage, done, total)`. |
| `BG.startCheck(root)` | Starts `BG.check` in the background for a big area and returns an id at once. |
| `BG.jobStatus(id)` | `text, state`: progress while `"running"`, the full report when `"done"`. The last 5 jobs are kept in `ServerStorage.BuildGuardJobs` (not saved with the place). |
| `BG.format(report)` | Report as a string: mesh coverage, overrides, issues, vehicle notes, time per check. |
| `BG.planFixes(report)` | Returns `plan, unfixedIssues`. Nothing moves yet. |
| `BG.Plan.describe(plan)` | Plan preview as a string. |
| `BG.apply(plan)` | Applies as one undo step. Errors if any part changed since the plan was made. |
| `BG.revert(plan)` | Puts everything back. |
| `BG.fixAll(root)` | Scan, plan, apply, repeated until nothing more is fixable. Returns `{ report, plans, changes }`. |
| `BG.formatChanges(resultOrPlan)` | The fix report: every changed part (by path) with its exact move in world and own axes, its resize, and the line to put in its builder script. |
| `BG.changes(resultOrPlan)` | The same as a list: `{ part, path, move, moveLocal, resize, rotated, fromCFrame, toCFrame, fromSize, toSize, checks, reasons }`. |
| `BG.find(root, path)` | The instance a report path names (`"Map/Tub/TubTop#3"`). |
| `BG.planSnap(partsOrModel)` | Snap plan for roads/rails/tracks. Returns `plan, skipped`. |
| `BG.Layers.place(item, surface, opts)` | Puts an item on a face. Options: `face`, `layer`, `u`, `v`, `rotation`, `keepPosition`. |
| `BG.Layers.lift(layer, config?)` | Studs above the surface for that layer. |
| `BG.setConfig(instance, { key = value }, reason)` | Sets overrides for an instance and everything under it. Validated; reason required. One undo step. |
| `BG.setProjectConfig({ key = value }, reason)` | Place-wide settings (on `workspace`); they also reach models outside workspace. |
| `BG.clearConfig(instance, keys?)` | Removes the listed overrides, or all of them |
| `BG.getConfig(instance)` | Returns `config, sources` (`sources[key]` = the instance that set it) |
| `BG.explainConfig(instance)` | Every setting for the instance and where it comes from, as text |
| `BG.snapToGrid(cframeOrVector, relativeTo?)` | Rounds X/Z to `gridSize` (from `relativeTo`'s config). Keeps height and rotation. |
| `BG.checkVehicle(model, target?)` | Measures a vehicle and compares it with the limits for `target` (default workspace). Also runs the vehicle's collision and wheel-sweep checks. Returns `text, rows, profile`; each row is ok / check / tested / fail. |
| `BG.measureVehicle(model)` | Two profiles. Colliding parts: wheels, wheel radius, wheelbase, ground clearance, approach/departure/breakover angles, `collisionWidth`. Visible parts: `width` (with mirrors), length. `height` covers both. |
| `BG.vehicleLimits(profile)` | `{ maxLedge, maxSlopeChange, minRoadWidth, roadHeadroom }` that vehicle needs (`minRoadWidth` = 2 × width with mirrors + 2) |
| `BG.markTested(model, key, reason, { value? })` | Records that a limit was drive-tested on this vehicle (value defaults to the current setting, date to today). Its "check" row then shows "tested" while the setting stays within the tested value. Keys: `maxLedge`, `maxRouteSlope`, `maxSlopeChange`, `minRoadWidth`, `roadHeadroom`. |
| `BG.clearTested(model, key?)` | Removes a test record, or all of them. |
| `BG.selfTest()` | Builds the planted-problem scene, checks and fixes it, then removes it. Returns `{ passed, text }`. |
| `BG.TestScene.buildFarView(parent)` | Builds the far-view rig: plate pairs with gaps 0.005–0.2 and viewing spots at 100, 300 and 600 studs, for checking on a phone which gap stops flickering. |

Every issue has `check`, `severity`, `message`, `parts`, `paths` (each part's path from the scan root; `#n` marks the nth of several siblings with the same name) and, when it applies, `position` (where to look).

## Checks

| Check | Severity | Meaning | Auto-fix |
|---|---|---|---|
| `config` | error | A `BuildGuard_` attribute is invalid; it's ignored | Fix or clear the attribute |
| `duplicate` | error | Two parts of the same class and mesh at the same position and size (a double import) | Manual: delete one |
| `buried` | error | Something covers a road/rail/track top | Snap onto the ground if the cover is terrain or ground. Otherwise manual. |
| `collision` | error | Two colliding parts of a vehicle overlap at rest (different assemblies, no NoCollisionConstraint). Invisible collision boxes included. | Manual: NoCollisionConstraint, weld, or move one |
| `offground` | warning | A flat road/rail/track hovers or is sunk more than 0.1 studs | Snap to ground |
| `zfight` | error | Same-facing faces overlap within 0.01 studs: flat faces, the round sides of same-size cylinders on one axis, same-size balls on one centre, and mesh triangles (meshes the place can load) | Nudge the smaller part out (round parts grow their radius instead). It grows instead only when both opposite sides are visible. Welds/Motor6Ds on moved parts are updated. |
| `zgap` | warning | In a model with `zFightViewDistance`, same-facing faces closer than the gap that holds at that distance | Nudge to that gap |
| `meshoverlap` | warning | Two meshes/unions whose boxes nearly coincide (a double import or a z-fighting copy) | Manual: check by eye |
| `wheelsweep` | warning | A wheel hits a colliding part somewhere in its suspension travel or steering lock (read from the constraint limits) | Manual |
| `headroom` | warning | Less clear height above a road/rail/track than its kind's headroom setting | Manual |
| `ledge` | warning | Step between connected roads (or rails) over `maxLedge` | Manual |
| `edge` | warning | Step from the ground beside a road up onto (or down off) its edge over `maxLedge` | Manual: thinner road, or shape the ground up to it |
| `slope` | warning | Angle between connected roads (or rails) over `maxSlopeChange` | Manual |
| `routeslope` | warning | A road or rail piece tilts more than `maxRouteSlope` | Manual |
| `roadwidth` | warning | A road is narrower than `minRoadWidth` across its driving direction | Manual |

The report's `Meshes:` line says how many MeshParts were checked by their triangles and how many by their box only, and why (not owned by you or the game owner, unions, too many triangles). A box-only mesh can still z-fight unseen.

## Settings you can override per model

Set with `BG.setConfig` (or `BG.setProjectConfig` for the whole place), stored as `BuildGuard_<key>` attributes. Checks that compare two parts (joins, z-fighting pairs, vehicle collisions) use the settings of the smallest instance holding both. Z-fighting detection (`zFightTolerance` 0.01, `zFightMinOverlapArea`, `zFightIgnoreTransparency`) is fixed and can't be set per model.

| Key | Default | Range | Meaning |
|---|---|---|---|
| `zFightNudge` | 0.02 | 0.002–0.5 | Gap a z-fight fix leaves; must be > 0.01 |
| `zFightViewDistance` | 0 (off) | 0–5000 | Distance the model is seen from. Faces must be `2 × d² / (0.1 × 2²⁴)` apart (0.107 at 300 studs), fixes leave that gap, and layers lift at least that much. For map-sized models seen from far away on phones. |
| `layerLift` | 0.05 | 0.002–0.5 | Lift per layer (read from the surface) |
| `roadLift` / `railLift` / `trackLift` | 0.1 / 0.2 / 0.1 | 0–2 | Gap a snap leaves under roads / rails / track beds |
| `groundLift` | 0.1 | 0–2 | Gap a snap leaves under anything else |
| `gridSize` | 4 | 0.05–512 | Horizontal layout grid for `snapToGrid` |
| `groundTolerance` | 0.1 | 0.01–10 | Off-ground check fires beyond this |
| `flatTiltDegrees` | 5 | 0–45 | Steeper parts count as ramps |
| `snapSearchUp` / `snapSearchDown` | 20 / 500 | | How far a buried part looks up for open air / how far snapping looks down |
| `buriedProbeHeight` | 0.25 | 0.01–10 | Cover must rise this far above the surface |
| `buriedClearance` | 3 | 0.1–100 | How far overhead counts as covering |
| `roadHeadroom` / `railHeadroom` / `trackHeadroom` | 0 (off) | 0–500 | Clear height needed above each kind. Set `roadHeadroom` place-wide from the truck (`checkVehicle` suggests it). |
| `sampleSpacing` | 2 | 0.25–50 | Sample grid spacing for buried/snap/edges |
| `maxLedge` | 1.0 | 0–50 | Step between connected roads/rails, and from the ground onto a road edge |
| `maxSlopeChange` | 20 | 0–90 | Angle between connected roads/rails |
| `maxRouteSlope` | 20 | 0–90 | Steepest tilt of any road/rail piece |
| `minRoadWidth` | 22 | 0–1000 | Road width across the driving direction (the approved haul road) |
| `edgeProbe` | 0.5 | 0.05–4 | How far outside a road edge the ground is measured |
| `connectMargin` | 0.1 | 0–5 | Horizontal gap still counted as connected |
| `connectMaxStep` | 4 | 0.1–100 | Bigger vertical gaps are overpasses (and drop-offs at road edges) |
| `collisionTolerance` | 0.02 | 0–1 | Vehicle parts overlapping less than this are just touching |
| `sweepSteps` | 5 | 2–21 | Poses per joint when sweeping wheels (ends and rest included) |
| `steerLock` | 0 (unknown) | 0–90 | Steering lock in degrees each way for steering hinges with no limits (e.g. a Servo driven by a script) |

Global settings (call options or `Config.lua` only): `classifyByName` (true), `kindNameWords`, `kindMaxThickness` (0.5), `drivableKinds`, `edgeLedgeKinds` ({"Road"}), `groundNames`, `groundMinFootprint` (0 = off), `meshTriangles` (true), `meshTriangleLimit` (20000), `meshOverlapRatio` (0.9).

## How parts are classified

- **Road / Rail / Track:** the `BuildGuardKind` attribute (`"Road"`, `"Rail"`, `"Track"` or `"None"`), then a tag `Road`/`Rail`/`Track`, then the name: its **first word** is road/street/highway (Road), rail/railroad/railway (Rail) or track/trackbed (Track), and the part is flat (no thicker than half its longest side) and not a ball or cylinder. Words split at capitals, digits and punctuation, so `Road_01`, `RailYard` and `TrackBed` count; `BedRail`, `RoofRail`, `Railing`, `RoadSign` (a standing panel) and `StreetLamp` (a pole) don't. Parts of a vehicle never count by name.
- **Ground:** Terrain, the `BuildGuardGround` tag or attribute, or a flat part whose first word is `Baseplate`/`Ground`/`Terrain`. Size alone no longer makes a part ground, so tag big floors that are ground.
- **Wheels:** the `BuildGuardWheel` attribute or tag; else parts that spin on a HingeConstraint or CylindricalConstraint through their centre along their round axis; else (only when nothing spins) names whose first word is wheel/tire/tyre followed only by position words (`Wheel_FL`, `TireRearLeft`). Only colliding wheels touch the ground.
- **Vehicles:** everything joined to a VehicleSeat or to two or more spinning wheels, plus every part of a model holding a VehicleSeat or marked `BuildGuardVehicle`.

## Attributes and tags

| Attribute / tag | Effect |
|---|---|
| `BuildGuardKind` = `"Road"` / `"Rail"` / `"Track"` / `"None"` | Sets or clears the kind (overrides tags and the name) |
| tag `Road` / `Rail` / `Track` | Sets the kind |
| `BuildGuardGround` (attribute true/false or tag) | Counts as ground (or, with false, doesn't) |
| `BuildGuardLocked = true` | Fixes never move it (also true for `Locked` parts and ground) |
| `BuildGuardIgnore` (attribute true or tag) | It and its descendants are skipped, and never count as cover, ground or a ceiling |
| `BuildGuardLayer` | Set by `Layers.place`. Marks layered items. |
| `BuildGuardWheel` (attribute true/false or tag) | Marks (or unmarks) a part as a wheel |
| `BuildGuardVehicle` (attribute true or tag) | Marks a model as a vehicle |
| `BuildGuard_<key>` | A config override (see above) |
| `BuildGuardConfigReason` | Why the overrides on this instance exist (set by `setConfig`) |
| `BuildGuardTested_<key>`, `BuildGuardTestedNote_<key>` | A drive-test record (set by `markTested`) |
