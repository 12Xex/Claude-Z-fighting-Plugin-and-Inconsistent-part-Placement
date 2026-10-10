# BuildGuard workflows

Step-by-step order for each kind of build. Every code block runs in Studio through the MCP tool that runs Luau (`execute_luau` on Studio's built-in server, `run_code` on the older one). End a block with `return <text>` to get its result back (print output may not come back). Start each block with:

```lua
local BG = require(game.ServerStorage.BuildGuard)
```

## Every session

1. Run the check from SKILL.md step 0 (installed, and version `"0.6.0"`).
2. Find where things go. Print the top level of `workspace` and the model you'll work in, so you build into the user's existing structure:
   ```lua
   local out = {}
   for _, c in workspace:GetChildren() do table.insert(out, c.ClassName .. " " .. c:GetFullName()) end
   return table.concat(out, "\n")
   ```
3. Put each new thing in its own named `Model` (`HaulRoad_North`, `Town_Shop1`, `MineTunnel_A`). Checks, settings and the user's Ctrl+Z all work per model.
4. Build in a few `run_code` calls per model, not one call per part. Print what each call made.
5. Check the place-wide numbers once: `return BG.explainConfig(workspace)`. If `roadHeadroom` is 0 and the game has trucks, measure the truck (Vehicles below) and propose `BG.setProjectConfig({ roadHeadroom = ... }, reason)` to the user.

## Fixing: your build vs. the user's

- **Your own new model:** you may run `BG.fixAll(model)` after reading `BG.check(model)`.
- **Anything the user already built:** run `BG.check` only. Show them the report and fix preview, and apply fixes only after they say yes. Every apply is one Ctrl+Z step in Studio.
- **A model a script builds:** after `fixAll`, return `BG.formatChanges(result)` and put every change in the builder script (each line gives the `part.CFrame *= CFrame.new(...)` or `part.Size += Vector3.new(...)` to add to that part). Then rebuild and check again: a rebuild without them brings the problems back.
- **A big area (a whole map):** `BG.check` can take longer than one call may wait. Use `return BG.startCheck(workspace.Map)` to get a job id, then `return (BG.jobStatus("<id>", { page = 1 }))` in later calls until it gives the report (one page of 120 lines per call; ask for the next page until it stops saying "page n of m").

## Landscape and terrain

1. Shape terrain first (hills, pits, river channels, cave volumes) with `workspace.Terrain:FillBlock`, `FillBall` and so on. Terrain is stored in 4-stud voxels, so keep carve sizes and positions on multiples of 4.
2. Then lay out roads and rails on it (below). Snapping follows whatever terrain is there, so terrain changes after snapping mean snapping again.

## Roads

1. Lay each piece flat with its top face up. Size it as length × 0.8 × width, with the width (at least 22) on the other horizontal axis. The 0.8 thickness keeps the step from the ground onto the road (thickness + 0.1 lift) under the 1-stud limit. Name it so its first word is `Road` (`Road_01`, `Road_North_3`), and put it on the grid with `BG.snapToGrid`:
   ```lua
   local roads = Instance.new("Model")
   roads.Name = "HaulRoad_North"
   local function road(name, length, cf)
   	local p = Instance.new("Part")
   	p.Name = name
   	p.Size = Vector3.new(length, 0.8, 22)
   	p.CFrame = BG.snapToGrid(cf)
   	p.Anchored = true
   	p.Material = Enum.Material.Asphalt
   	p.Parent = roads
   	return p
   end
   road("Road_01", 40, CFrame.new(0, 10, 0))
   road("Road_02", 40, CFrame.new(40, 10, 0))
   roads.Parent = workspace.Map
   ```
2. Snap the whole model, and read what was skipped:
   ```lua
   local plan, skipped = BG.planSnap(workspace.Map.HaulRoad_North)
   BG.apply(plan)
   local out = { BG.Plan.describe(plan) }
   for _, s in skipped do table.insert(out, "skipped " .. s.part.Name .. ": " .. s.reason) end
   return table.concat(out, "\n")
   ```
3. **Hills:** pieces tilted more than 5° are ramps and aren't snapped, so place each one by its joints. Start from the top edge of the piece it joins, so there's no ledge:
   ```lua
   -- edge: the top-surface point at the end of the previous piece
   -- heading: compass direction of travel in degrees (0 = +X, 90 = -Z)
   -- angle: climb in degrees (negative goes downhill; at most 20 either way)
   ramp.CFrame = CFrame.new(edge)
   	* CFrame.Angles(0, math.rad(heading), 0)
   	* CFrame.Angles(0, 0, math.rad(angle))
   	* CFrame.new(ramp.Size.X / 2, -ramp.Size.Y / 2, 0)
   ```
   Change direction gradually: no more than 20° between neighbours, and no piece steeper than 20° overall. Use switchbacks for anything steeper.
4. Markings go on with `BG.Layers.place` (see Details).
5. Run `return BG.check(roads)`. Ledge, edge, slope, route slope and width warnings mean the layout needs changing; they have no automatic fix. An `edge` warning means the ground beside the road is too far below (or above) its top: make the road thinner, or shape the terrain up to the road's edge.

## Rails and minecart tracks

1. Track bed first (first word `Track`: `TrackBed_01`), then snap it.
2. Rails (first word `Rail`: `Rail_L_01`) and sleepers on top of the bed, then snap the rails. Rails land 0.2 above the bed, because the bed counts as their ground.
3. Rail pieces have the same 20° slope and 1-stud join limits as roads, but no width check.

## Tunnels and caves

1. Carve the tunnel in terrain (`FillBlock` with `Enum.Material.Air`), or build it from parts. Make sure it has a floor.
2. Put the tunnel's roads and rails in one model. Road headroom normally comes from the place-wide setting (Every session, step 5). Set the minecart's rail headroom, or a different truck's, on the tunnel's model:
   ```lua
   BG.setConfig(workspace.Map.MineTunnel_A, { railHeadroom = 7 }, "6-stud minecart")
   ```
   Get the numbers from `BG.checkVehicle` (Vehicles below), or ask the user. Don't guess.
3. Snap the roads and rails. They land on the tunnel floor. A part buried more than 20 studs deep is skipped with a message; carve its space instead.
4. Check the model. `headroom` warnings mean the roof is too low for that vehicle.
5. The approved cave entrance width (6 studs) isn't checked automatically yet. Build entrances to it by hand, and say so in your report.

## Rivers and water

1. Carve the river channel, then fill it with `Enum.Material.Water`.
2. **Snapping ignores water.** A road over a river with nothing under it but water would snap down onto the riverbed. Build the bridge's supports (abutments or pillars) first. Snapping rests a road on the highest ground under it, so it sits on them. Then snap the bridge road and check it.

## Town buildings

1. Lay buildings out on the 4-stud grid (`BG.snapToGrid`) and keep them off roads and rails. Anything on a road is flagged as burying it.
   A big floor slab or platform isn't ground unless it's tagged `BuildGuardGround`; tag only real ground (a slab roads and buildings stand on), never a roof.
2. BuildGuard doesn't check buildings on uneven ground yet. Do it by hand: raycast the ground under each corner, and make the foundation reach below the lowest point, so no corner hovers:
   ```lua
   local function groundY(x, z)
   	local r = workspace:Raycast(Vector3.new(x, 1000, z), Vector3.new(0, -2000, 0))
   	return r and r.Position.Y
   end
   ```
   Run this before the building exists, or the ray hits the building.
3. Walls: one wall runs the full length and the other stops where it meets it. Overlapping corners with level tops z-fight.
4. Windows and doors: either sink the frame fully into the wall and put the glass on a layer, or make the frame thicker than the wall. Never make it exactly as thick.
5. `return BG.check(building)` and fix every error.

## Signs, markings, trim and other details

1. Everything that sits on a surface goes through `BG.Layers.place`, never hand-placed flush:
   ```lua
   BG.Layers.place(sign, wall, { face = "Front", layer = 1, v = 3 })
   BG.Layers.place(stripe, road, { layer = 1, u = -10 })
   BG.Layers.place(arrow, road, { layer = 2 })   -- overlaps the stripe
   ```
2. The item's `Size.Y` is its thickness. Items that overlap on the same face need different layers and the same thickness.
3. To lift details you've already placed by eye, keep where they are: `{ layer = 1, keepPosition = true }`.
4. Details on map-sized models seen from far away (quarry walls, billboards across the pit): 0.02 gaps can flicker on phones beyond about 130 studs. When the user has checked the far-view rig (the plugin's **Far-view test**) and picked a distance, set it on the model: `BG.setConfig(model, { zFightViewDistance = 300 }, "seen across the pit")`. Checks then want bigger gaps there, and layers lift more.

## Meshes (Blender imports)

1. Import each mesh once. A second copy at the same position and size is a `duplicate` error; delete one.
2. BuildGuard reads the triangles of meshes owned by the user or the game owner, and checks them for z-fighting like flat faces. Meshes it can't load (other creators' meshes) and unions are checked by their box only. The report's `Meshes:` line counts both; tell the user how many were box-only.
3. `meshoverlap` warnings mean two meshes' boxes nearly coincide: usually a double import with a different mesh id, or an overlay mesh that will z-fight. Look at them and fix or explain.
4. Detail meshes on a surface still go through `BG.Layers.place`.

## Vehicles (imported from Blender)

Trucks and minecarts are modelled in Blender and imported. Don't build or rework them in Studio.

1. To place one, move the whole model with `PivotTo`. Don't change its parts.
2. If a check reports something inside a vehicle model (a z-fight, a duplicate mesh), don't apply the fix there: the next import brings it back. Tell the user which parts, so they fix it in Blender. If they'd rather BuildGuard skipped vehicles, tag the vehicle models `BuildGuardIgnore`.
3. To set road numbers from a truck, measure it and show the user every `FAIL` and `check` line:
   ```lua
   return (BG.checkVehicle(workspace.Vehicles.HaulTruck))
   ```
   Don't change the project's road limits yourself. Propose the change and let the user decide.

## NPCs

1. Tag each character model `BuildGuardIgnore` (`model:AddTag("BuildGuardIgnore")`, or the attribute). Accessories overlap on purpose, and BuildGuard doesn't check NPCs. Tag label and helper folders the same way.
2. Stand them on the ground by raycast. For R15 rigs, put the `HumanoidRootPart` centre at ground + `Humanoid.HipHeight` + half the root part's height, and move the model with `PivotTo`.
3. Keep them off roads and rails unless the user asks.

## Reporting back to the user

After each model, tell the user:
1. **What you built**, and where (full instance path).
2. **The final check:** errors (must be 0) and warnings.
3. **What was fixed automatically:** how many changes, and that Ctrl+Z undoes them. For script-built models, that you put the fix report's changes in the script.
4. **Every line under "Config overrides in effect":** what you changed and why.
5. **Every warning and note left**, with the part paths and what you suggest.
6. **What was only partly checked:** meshes checked by box only (the `Meshes:` line).
7. **What isn't checked yet** that this build relied on: buildings on uneven ground, NPC footing, cave entrance width.

## When something goes wrong

| Message | What to do |
|---|---|
| `BuildGuard missing` / wrong version | Ask the user to press **Install library** in the BuildGuard panel |
| `plan is stale, ... changed since it was made` | Something moved after the scan. Run `BG.check` again and re-plan. |
| `config ... attribute ... ignored` | A `BuildGuard_` attribute is wrong. Fix it with `BG.setConfig`, or remove it with `BG.clearConfig`. |
| Snap skipped: `no ground below` | Nothing under the part. Build the ground or supports first. |
| Snap skipped: `buried deeper than 20 studs` | Carve the space for it, or move it up yourself. |
| Snap skipped: `tilted …, treated as a ramp` | Expected for ramps. Place them by their joints (Roads step 3). |
| `buried … move the cover … by hand` | Something sits on the road/rail. Move it; don't move the road onto it. |
| The check is slow or times out | Use `BG.startCheck(root)` and poll `BG.jobStatus(id)`, or check one model at a time. The report's `Time:` line shows which check is slow. |
| `Meshes: ... by their box only (no permission ...)` | Those meshes belong to another creator, so their triangles can't be read. Check them by eye, or re-upload them under the user's account. |
| `duplicate` | A mesh or part imported twice at the same place. Delete one. |
| `edge` | The road's top is more than 1 stud above (or below) the ground beside it. Use 0.8-thick roads, or raise the terrain to the road. |
| `zgap` | In a far-view model, same-facing faces are closer than the gap that holds at its view distance. Apply the fix. |
| `no wheels found` (checkVehicle) | The wheels don't spin on hinges and aren't named `Wheel_FL`/`Tire_RearLeft` and so on. Tag them `BuildGuardWheel`. |
