# Sh

Narrative zombie survival horror for Roblox, synced with [Rojo](https://rojo.space) (`rojo serve`).

## Scripts

| File | Runs as | Role |
| --- | --- | --- |
| `src/server/CoreGameController.server.lua` | Script | Round loop, generated floors, DataStore profiles, timers, hunger/thirst |
| `src/server/InteractionSystem.lua` | ModuleScript | Aim-ray interaction, inventory, doors, hiding, peeking, prompts |

`CoreGameController` is self-contained plain Lua 5.1: it requires no modules and builds each floor (a closed 40x10x40 room named `ActiveFloor`, with a `Spawns` folder) from Parts at `Y = 500`. To finish a floor, fire `ServerStorage.ServerSignals.FloorExitRequested` with a player who is in the run.

`InteractionSystem` is currently not loaded by anything: something must `require` it and call `Init(ReplicatedStorage.Remotes)` and `AddPlayer(player)` before the setup below applies.

## Studio setup

- `ServerStorage.ItemModels` (optional): a Model or Part named after each item id, used for dropped and looted items.
- A lobby with a `SpawnLocation` in Workspace.
- Enable Studio API access for DataStores.

Interactables are Models or Parts with the CollectionService tag `Interactable` and a `Kind` attribute. `DisplayName` overrides the prompt title on any of them. Sounds listed under Children are played if present.

| Kind | Attributes | Children |
| --- | --- | --- |
| `Door` | `Locked`, `KeyId`, `ConsumeKey`, `Deadbolt`, `OpenAngle`, `Health` | Sounds `Open` `Close` `Creak` `Lock` `Unlock` `Locked` `Hit` `Break` |
| `Container` | `Motion` (`Swing`/`Slide`), `OpenAngle`, `SlideDistance`, `LootTable` | `LootPoint` attachments, sounds `Open` `Close` |
| `Item` | `ItemId` | Sound `PickUp` |
| `HidingSpot` | `SpotType` (`Closet`/`Bed`) | `HidePoint`, `ExitPoint` attachments |
| `PeekSpot` | | `PeekPoint` attachment (camera) |
| `Note` | `Text` | |
| `Exit` | `RequiredItem`, `PromptLabel` | Sounds `Open` `Locked` |

Doors and swinging containers rotate around the pivot of the tagged instance, so place the pivot on the hinge, with the door's thickness along its Z axis. For a Model, anchor the `PrimaryPart` and weld the rest to it. A bare Part without a custom pivot hinges on its -X edge. Sliding drawers move along their look direction.
