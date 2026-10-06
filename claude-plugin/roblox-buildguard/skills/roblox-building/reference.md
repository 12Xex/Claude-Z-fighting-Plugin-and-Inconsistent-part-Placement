# BuildGuard API reference

`local BG = require(game.ServerStorage.BuildGuard)`

## Checking and fixing

| Call | Does |
|---|---|
| `BG.check(root)` | Report and fix preview as a string. Changes nothing. |
| `BG.scan(root, { config = {...} })` | Returns `report` (`report.issues`, `report.counts.error/warning`). `root` can be an Instance or a list of them. |
| `BG.format(report)` | Report as a string. |
| `BG.planFixes(report)` | Returns `plan, unfixedIssues`. Nothing moves yet. |
| `BG.Plan.describe(plan)` | Plan preview as a string. |
| `BG.apply(plan)` | Applies as one undo step. Errors if any part changed since the plan was made. |
| `BG.revert(plan)` | Puts everything back. |
| `BG.fixAll(root)` | Scan, plan, apply, repeated until nothing more is fixable. Returns `{ report, plans }`. |
| `BG.planSnap(partsOrModel)` | Snap plan for roads/rails/tracks. Returns `plan, skipped`. |
| `BG.Layers.place(item, surface, opts)` | Puts an item on a face. Options: `face`, `layer`, `u`, `v`, `rotation`, `keepPosition`. |
| `BG.Layers.lift(layer)` | Studs above the surface for that layer. |
| `BG.setConfig(instance, { key = value }, reason)` | Sets overrides for an instance and everything under it. Validated; reason required. One undo step. |
| `BG.clearConfig(instance, keys?)` | Removes the listed overrides, or all of them |
| `BG.getConfig(instance)` | Returns `config, sources` (`sources[key]` = the instance that set it) |
| `BG.explainConfig(instance)` | Every setting for the instance and where it comes from, as text |
| `BG.selfTest()` | Builds the planted-problem scene, checks and fixes it, then removes it. Returns `{ passed, text }`. |

## Checks

| Check | Severity | Meaning | Auto-fix |
|---|---|---|---|
| `config` | error | A `BuildGuard_` attribute is invalid; it's ignored | Fix or clear the attribute |
| `zfight` | error | Same-facing coplanar faces overlap | Nudge the smaller part 0.02 out. It grows instead only when both opposite sides are visible. |
| `buried` | error | Something covers a road/rail/track top | Snap onto the ground if the cover is terrain or ground. Otherwise manual. |
| `offground` | warning | A flat road/rail/track hovers or is sunk more than 0.1 studs | Snap to ground |
| `ledge` | warning | Step between connected roads over `maxLedge` | Manual |
| `slope` | warning | Angle between connected roads over `maxSlopeChange` | Manual |

## Settings you can override per model

Set with `BG.setConfig`, stored as `BuildGuard_<key>` attributes. "Pair" is how two parts' values combine when a check compares them.

| Key | Default | Range | Pair | Meaning |
|---|---|---|---|---|
| `zFightTolerance` | 0.01 | 0.001–0.1 | stricter (max) | Same-facing faces this close z-fight |
| `zFightNudge` | 0.02 | 0.002–0.5 | max | Gap a fix leaves; must be > tolerance |
| `zFightMinOverlapArea` | 0.01 | 0–10 | stricter (min) | Smaller overlaps are edge contacts |
| `zFightIgnoreTransparency` | 0.99 | 0–1 | — | Parts at or above this are skipped |
| `layerLift` | 0.02 | 0.002–0.5 | — | Lift per layer (read from the surface) |
| `groundLift` | 0.05 | 0–2 | — | Gap between a snapped road/rail and the ground |
| `groundTolerance` | 0.1 | 0.01–10 | — | Off-ground check fires beyond this |
| `flatTiltDegrees` | 5 | 0–45 | — | Steeper parts count as ramps |
| `snapSearchUp` / `snapSearchDown` | 20 / 500 | | — | How far snapping looks above/below |
| `buriedProbeHeight` | 0.25 | 0.01–10 | — | Cover must rise this far above the surface |
| `buriedClearance` | 3 | 0.1–100 | — | How far overhead counts as covering |
| `sampleSpacing` | 2 | 0.25–50 | — | Sample grid spacing for buried/snap |
| `maxLedge` | 0.5 (provisional) | 0–50 | looser (max) | Step between connected roads |
| `maxSlopeChange` | 15 (provisional) | 0–90 | looser (max) | Angle between connected roads |
| `connectMargin` | 0.1 | 0–5 | max | Horizontal gap still counted as connected |
| `connectMaxStep` | 4 | 0.1–100 | max | Bigger vertical gaps are overpasses |

## Attributes

| Attribute | Effect |
|---|---|
| `BuildGuardKind` = `"Road"` / `"Rail"` / `"Track"` / `"None"` | Sets or clears the kind (overrides the name) |
| `BuildGuardGround = true` | Counts as ground (like Baseplate/Terrain) |
| `BuildGuardLocked = true` | Fixes never move it (also true for `Locked` parts and ground) |
| `BuildGuardIgnore = true` | It and its descendants are skipped |
| `BuildGuardLayer` | Set by `Layers.place`. Marks layered items. |
| `BuildGuard_<key>` | A config override (see above) |
| `BuildGuardConfigReason` | Why the overrides on this instance exist (set by `setConfig`) |
