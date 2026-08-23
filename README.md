# AI Unbound

A lightweight, host-side [SuperBLT](https://superblt.znix.xyz/) mod that increases the queued-task throughput of AI in **PAYDAY 2**.

PAYDAY 2 normally processes queued AI work through a shared scheduler at roughly 60 tasks per second. In busy fights, detection, targeting, movement, pathfinding, and combat updates can spend extra time waiting in that queue—even when the game is otherwise running smoothly.

AI Unbound makes that limit configurable from **60 to 3000 tasks per second**. It does not replace the game's AI logic or make enemies smarter; it simply allows AI tasks that are already due to be processed sooner.

## Features

- Configurable limit from 60 to 3000 AI tasks per second
- Changes take effect immediately, including during a heist
- Settings persist between game sessions
- Host-side behavior; clients do not need the mod
- Preserves queued tasks when the setting changes
- English and Simplified Chinese localization

## Requirements

- PAYDAY 2
- [SuperBLT](https://superblt.znix.xyz/)

## Installation

1. Install SuperBLT if you have not already.
2. Download or clone this repository.
3. Place the mod folder in your PAYDAY 2 `mods` directory.
4. Make sure `mod.txt` is directly inside that folder:

   ```text
   PAYDAY 2/
   └── mods/
       └── AI Unbound/
           ├── mod.txt
           ├── main.lua
           └── lua/
   ```

5. Launch the game. SuperBLT will load AI Unbound automatically.

## Usage

Open **Options → Mod Options → AI Unbound**, then adjust **AI tasks per second**.

| Setting | Value |
| --- | ---: |
| Minimum | 60 |
| Default | 600 |
| Maximum | 3000 |
| Step size | 60 |

Setting the value to **60** restores the original scheduler throughput. Higher values can reduce queue delays when many AI tasks are waiting, but they also increase the amount of work the host may perform each frame.

> [!WARNING]
> High values can substantially increase host CPU usage. Raise the limit gradually and lower it if performance becomes less stable.

## Multiplayer

Enemy AI is controlled by the host, so only the host needs AI Unbound for it to affect enemy behavior. A client's local setting is used only when that client hosts a game.

## How it works

AI Unbound changes the enemy manager's scheduler interval from the original `1 / 60` seconds to:

```text
tick interval = 1 / configured tasks per second
```

The configured value is a throughput ceiling, not a target. The mod only processes tasks that the game has already queued and marked as due.

When the value changes during a heist, the existing queue is kept intact. Only the scheduler's accumulated time credit is cleared to avoid an unnecessary one-frame catch-up burst.

## Compatibility

AI Unbound post-hooks `EnemyManager:_init_enemy_data`. It does not overwrite `_update_queued_tasks`, CopLogic, detection delays, or pathfinding behavior.

Mods that also change `EnemyManager._tick_rate` may conflict with AI Unbound; whichever mod writes the value last takes effect.

## Author

[NeptuneIsTheBest](https://github.com/NeptuneIsTheBest)
