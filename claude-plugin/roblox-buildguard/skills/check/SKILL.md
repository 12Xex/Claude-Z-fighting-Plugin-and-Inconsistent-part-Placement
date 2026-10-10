---
name: check
description: Check a Roblox build with BuildGuard (z-fighting on parts, round parts and meshes, duplicates, buried or floating roads/rails, ledges, road edges, steep joins), preview the fixes, and apply them only after the user agrees.
argument-hint: "[instance path, e.g. workspace.Town]"
disable-model-invocation: true
---

Check the build at `$ARGUMENTS` (use `workspace` if nothing was given) with BuildGuard, through the Roblox Studio MCP tool that runs Luau (`execute_luau` on Studio's built-in server, `run_code` on the older one). Each call is its own chunk: start it with `local BG = require(game.ServerStorage.BuildGuard)` and end it with one `return <text>` so the result comes back.

1. Confirm the library exists and is current:
   `local m = game.ServerStorage:FindFirstChild("BuildGuard") return if m then require(m).VERSION else "missing"`.
   If it's missing or not `0.6.0`, tell the user to install the BuildGuard Studio plugin and press **Install library**, then stop.
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
   Show the user the report and the fix preview, grouped by check, with each part's path and position. Mention the `Meshes:` line if any meshes were checked by box only (those weren't checked for z-fighting), and every `[NOTE]`.
3. Ask whether to apply the previewed fixes. If the build holds vehicles that aren't tagged `BuildGuardIgnore`, say that fixes would also move their parts, and leave them out (tag them, or fix a smaller model) unless the user says otherwise. Only after they say yes, run:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   local result = BG.fixAll(<path>)
   return ("%d fix pass(es)\n%s\n\n%s"):format(#result.plans, BG.format(result.report), BG.formatChanges(result))
   ```
4. Report what was fixed and list everything still open (ledges, edges, slopes, duplicates, mesh overlaps, z-fights between two locked parts, roads under non-ground parts), each with a concrete suggestion. Mention that Ctrl+Z in Studio undoes each fix pass. If the model is built by a script, point out that the fix report's changes need to go into that script, or a rebuild brings the problems back.
