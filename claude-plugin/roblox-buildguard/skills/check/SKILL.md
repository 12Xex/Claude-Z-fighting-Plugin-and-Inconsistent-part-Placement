---
name: check
description: Check a Roblox build with BuildGuard (z-fighting on parts, round parts and meshes, duplicates, buried or floating roads/rails, ledges, road edges, steep joins, vehicle collisions and wheel clearance), preview the fixes, and apply them only after the user agrees.
argument-hint: "[instance path, e.g. workspace.Town]"
disable-model-invocation: true
---

Check the build at `$ARGUMENTS` (use `workspace` if nothing was given) with BuildGuard, through the Roblox Studio MCP tool that runs Luau (for example `run_code`).

1. Confirm the library exists and is current:
   `local m = game.ServerStorage:FindFirstChild("BuildGuard") print(if m then require(m).VERSION else "missing")`.
   If it's missing or not `0.6.0`, tell the user to install the BuildGuard Studio plugin and press **Install library**, then stop.
2. Run the check. For one model, `print(require(game.ServerStorage.BuildGuard).check(<path>))`. For `workspace` or a whole map, start it in the background so the call doesn't time out, then poll until it returns the report:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   print(BG.startCheck(<path>))      -- prints the job id
   -- next calls:
   print(BG.jobStatus("<id>"))
   ```
   Show the user the report and the fix preview, grouped by check, with each part's path and position. Mention the `Meshes:` line if any meshes were checked by box only, and every `[NOTE]`.
3. Ask whether to apply the previewed fixes. Only after they say yes, run:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   local result = BG.fixAll(<path>)
   print(("%d fix pass(es)"):format(#result.plans))
   print(BG.format(result.report))
   print(BG.formatChanges(result))
   ```
4. Report what was fixed and list everything still open (ledges, edges, slopes, duplicates, vehicle collisions, wheel sweeps, roads under non-ground parts), each with a concrete suggestion. Mention that Ctrl+Z in Studio undoes each fix pass. If the model is built by a script, point out that the fix report's changes need to go into that script, or a rebuild brings the problems back.
