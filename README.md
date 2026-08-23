# AI Unbound

AI Unbound raises PAYDAY 2's shared queued-task throughput for host-controlled AI. It keeps the original scheduler and lets the host choose a limit from 60 to 3000 tasks per second.

Author: [NeptuneIsTheBest](https://github.com/NeptuneIsTheBest)

PAYDAY 2 normally gives all NPCs a shared budget of roughly 60 queued AI tasks per second. Detection, target selection, travel, pathing, and combat decisions can wait in that queue when many NPCs are active, even if the frame rate remains stable.

AI Unbound changes the scheduler interval from the original `1 / 60` seconds to:

```text
tick interval = 1 / configured tasks per second
```

The mod does not replace the scheduler or any CopLogic implementation. Only tasks that are already due can run, so the selected value is a throughput ceiling rather than a guarantee that the game will execute that many tasks every second.

### Installation

1. Install [SuperBLT](https://superblt.znix.xyz/).
2. Download or clone this repository.
3. Put the `AI-Unbound` folder in your PAYDAY 2 `mods` directory.
4. Start the game and open **Options → Mod Options → AI Unbound**.

### Settings

- Range: 60–3000 tasks per second
- Step: 60
- Default: 600
- 60 restores the original scheduler throughput
- Changes apply immediately and persist across restarts

Changing the value during a heist keeps every queued task. AI Unbound only resets the scheduler's accumulated time credit so changing to a high value does not create an avoidable one-frame catch-up burst.

Enemy AI is host-authoritative. Only the host needs this mod for it to affect enemy behavior; clients do not need to install it. A client's local setting becomes relevant when that client hosts a game.

> [!WARNING]
> High values can substantially increase host CPU usage. A value of 3000 allows roughly 50 due tasks per frame at 60 FPS when the queue is busy. Increase the setting gradually.

### Compatibility

AI Unbound post-hooks `EnemyManager:_init_enemy_data` and does not overwrite `_update_queued_tasks`, CopLogic, detection delays, or pathfinding. If another mod also writes `EnemyManager._tick_rate`, the last write wins.
