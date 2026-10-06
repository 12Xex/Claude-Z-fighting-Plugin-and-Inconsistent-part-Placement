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
| `BG.selfTest()` | Builds the planted-problem scene, checks and fixes it, then removes it. Returns `{ passed, text }`. |

## Checks

| Check | Severity | Meaning | Auto-fix |
|---|---|---|---|
| `zfight` | error | Same-facing coplanar faces overlap | Nudge the smaller part 0.02 out. It grows instead only when both opposite sides are visible. |
| `buried` | error | Something covers a road/rail/track top | Snap onto the ground if the cover is terrain or ground. Otherwise manual. |
| `offground` | warning | A flat road/rail/track hovers or is sunk more than 0.1 studs | Snap to ground |
| `ledge` | warning | Step between connected roads over `maxLedge` | Manual |
| `slope` | warning | Angle between connected roads over `maxSlopeChange` | Manual |

## Attributes

| Attribute | Effect |
|---|---|
| `BuildGuardKind` = `"Road"` / `"Rail"` / `"Track"` / `"None"` | Sets or clears the kind (overrides the name) |
| `BuildGuardGround = true` | Counts as ground (like Baseplate/Terrain) |
| `BuildGuardLocked = true` | Fixes never move it (also true for `Locked` parts and ground) |
| `BuildGuardIgnore = true` | It and its descendants are skipped |
| `BuildGuardLayer` | Set by `Layers.place`. Marks layered items. |
