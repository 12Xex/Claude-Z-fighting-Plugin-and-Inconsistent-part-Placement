---
name: check
description: Check a Roblox build with BuildGuard (z-fighting, buried or floating roads/rails, ledges, steep joins), preview the fixes, and apply them only after the user agrees.
argument-hint: "[instance path, e.g. workspace.Town]"
disable-model-invocation: true
---

Check the build at `$ARGUMENTS` (use `workspace` if nothing was given) with BuildGuard, through the Roblox Studio MCP tool that runs Luau (for example `run_code`).

1. Confirm the library exists:
   `print(game.ServerStorage:FindFirstChild("BuildGuard") and "ready" or "missing")`.
   If it's missing, tell the user to install the BuildGuard Studio plugin and press **Install library**, then stop.
2. Run `print(require(game.ServerStorage.BuildGuard).check(<path>))` and show the user the report and the fix preview, grouped by check.
3. Ask whether to apply the previewed fixes. Only after they say yes, run:
   ```lua
   local BG = require(game.ServerStorage.BuildGuard)
   local result = BG.fixAll(<path>)
   print(("%d fix pass(es)"):format(#result.plans))
   print(BG.format(result.report))
   ```
4. Report what was fixed and list everything still open (ledges, slopes, roads under non-ground parts), each with a concrete suggestion. Mention that Ctrl+Z in Studio undoes each fix pass.
