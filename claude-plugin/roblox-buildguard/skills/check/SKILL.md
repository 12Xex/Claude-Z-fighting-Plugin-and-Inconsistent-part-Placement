---
name: check
description: Check a Roblox build with BuildGuard (z-fighting on parts, round parts and meshes, seams, duplicates, buried or floating roads/rails, gaps under road edges, ledges, road edges, steep joins, road-like slabs nothing checks), preview the fixes, and apply them only after the user agrees.
argument-hint: "[instance path, e.g. workspace.Town]"
disable-model-invocation: true
---

Check the build at `$ARGUMENTS` (use `workspace` if nothing was given) with BuildGuard, through the Roblox Studio MCP tool that runs Luau (`execute_luau` on Studio's built-in server, `run_code` on the older one). Each call is its own chunk: start it with `local BG = require(game.ServerStorage.BuildGuard)` and end it with one `return <text>` so the result comes back.

1. Confirm the library exists and is current:
   `local m = game.ServerStorage:FindFirstChild("BuildGuard") return if m then require(m).VERSION else "missing"`.
   If it's missing or not `0.6.2`, tell the user to install the BuildGuard Studio plugin and press **Install library**, then stop.
2. Run the check. For one model:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   return BG.check(<path>)
   ```
   For `workspace` or a whole map, start it in the background so the call doesn't time out:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   return BG.startCheck(<path>)   -- the job id
   ```
   Then poll in later calls until it returns the report instead of `... running: ...`:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   return (BG.jobStatus("<id>", { page = 1 }))
   ```
   A long report comes a page (120 lines) at a time: ask for the next page until one ends with `(page m of m, the last page)`.
   Show the user the report and the fix preview, grouped by check, with each part's path and position. Mention the `Meshes:` line if any meshes were checked by box only (those weren't checked for z-fighting), and every `[NOTE]`, including the one listing flat road-like slabs that aren't checked as roads (they need a road name or tag, or `BuildGuardKind = "None"`). Only terrain and parts inside `<path>` hide a z-fight, so if it reports the flush sides and bottoms of footings under overlapping road pieces and their ground is parts outside `<path>`, check a model holding both before fixing them.
3. Ask whether to apply the previewed fixes. If the build holds vehicles that aren't tagged `BuildGuardIgnore`, say that fixes would also move their parts, and leave them out (tag them, or fix a smaller model) unless the user says otherwise. Only after they say yes, run:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   local result = BG.fixAll(<path>)
   return ("%d fix pass(es)\n%s\n\n%s"):format(#result.plans, BG.format(result.report), BG.formatChanges(result))
   ```
4. Report what was fixed and list everything still open (ledges, edges, gaps under road edges, seams, slopes, duplicates, mesh overlaps, z-fights between two locked parts, roads under non-ground parts), each with a concrete suggestion. For a `gap`: a footing under the road (keeps its top where it is), a negative `roadLift`, or raising the ground; when it says the gap `shows through invisible <path>`, make that part opaque; `gap above the water` is a road edge low over water, so treat it as a bridge (supports, or `maxHover` on a low bridge's model). For a `zseam`: pull the pieces apart in their plane, or leave it; never nudge land facets up or down. Mention that Ctrl+Z in Studio undoes each fix pass. If the model is built by a script, point out that the fix report's changes need to go into that script, or a rebuild brings the problems back.
