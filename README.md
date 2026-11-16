# Contract Vehicles To Field

A Farming Simulator 25 mod. When you accept a field contract and lease the equipment, the vehicles are delivered to the contract field instead of the shop.

## What it does

- Parks the leased vehicles side by side just inside the field edge closest to a road, facing into the field.
- Shows an in-game message saying which field the vehicles were delivered to.
- Lets you start a field contract with leased equipment even when the shop spawn area is full.
- Leaves contracts that are not tied to a field (transport and so on) on the normal shop delivery.
- Works in single player and multiplayer. It runs on the server.

If no road is within 150 m, the vehicles go to the field edge closest to the middle of the field. If the row does not fit there, they go to the field's map entry point.

## Install

1. Zip the contents of this repository (`modDesc.xml` at the top level of the zip) as `FS25_ContractVehiclesToField.zip`.
2. Put the zip in `Documents/My Games/FarmingSimulator2025/mods/`. Do not unzip it.
3. Enable the mod in your savegame.

The zip name must not contain spaces or brackets, such as `(1)`. The game skips those files.

## Settings

Edit the values at the top of `scripts/ContractVehiclesToField.lua`:

| Setting | Default | Meaning |
| --- | --- | --- |
| `USE_FIELD_EDGE` | `true` | Park along the field edge. `false` uses the field's map entry point. |
| `EDGE_INSET` | `2.0` | Distance in metres from the field edge to the rear of the vehicles. |
| `SPACING` | `2.5` | Gap in metres between vehicles. |
| `MAX_ROAD_DISTANCE` | `150` | Roads further from the field than this are ignored. |

## Troubleshooting

`log.txt` shows where the vehicles were placed, in lines starting with `[FS25_ContractVehiclesToField]`.
