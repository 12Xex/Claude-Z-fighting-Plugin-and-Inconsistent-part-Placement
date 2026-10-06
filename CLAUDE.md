# BuildGuard repo

- Library: `src/BuildGuard` (pure Luau; Studio-only code is confined to `StudioWorld.lua` and `withUndo`). Studio plugin UI: `src/Plugin`.
- Claude Code plugin: `claude-plugin/roblox-buildguard` (listed by `.claude-plugin/marketplace.json`). Its `roblox-building` skill holds the rules Claude follows when building in Studio. When you change the library API, update `skills/roblox-building/SKILL.md` and `reference.md` to match, and bump `version` in its `plugin.json`.
- Run `lune run tests/run` before committing. It must print `0 failed`. Run `claude plugin validate .` after touching the plugin or marketplace.
- Any new check needs a planted problem in `TestScene.lua` (with the expected outcome) and a control that must not be flagged.
