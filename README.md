# AI Overdrive

A lightweight enhancement mod for **PAYDAY 2** AI.

## What It Improves

- Helps enemies and teammates keep up when a lot is happening at once
- Reduces pauses while AI waits to find a route
- Makes distant AI shooting feel more responsive
- Keeps movement looking smoother across enemies, civilians, escorts, and AI teammates

## Requirements

- PAYDAY 2
- [SuperBLT](https://superblt.znix.xyz/)

## Installation

1. Install SuperBLT if you have not already.
2. Download or clone this repository.
3. Place the mod folder in your PAYDAY 2 `mods` directory.
4. Keep the runtime files in this directory structure:

   ```text
   PAYDAY 2/
   └── mods/
       └── AI Overdrive/
           ├── mod.txt
           ├── main.lua
           ├── menu/
           │   └── options.json
           ├── loc/
           │   ├── english.txt
           │   └── schinese.txt
           └── lua/
               └── ai_overdrive.lua
   ```

5. Launch the game. SuperBLT will load AI Overdrive automatically.

## Configuration

Open **Options → Mod Options → AI Overdrive**.

Settings apply immediately and persist between game sessions.

| Setting | Default | Behavior |
| --- | ---: | --- |
| AI response speed | Balanced (Recommended) | Helps AI process actions sooner during busy fights |
| Faster route finding | On | Reduces the time AI spends waiting for a route |
| Shooting response | Adaptive (Recommended) | Makes distant AI aim and fire more promptly |
| Smoother movement | On | Keeps enemies, civilians, and AI teammates moving smoothly |

Choosing **Original** restores the base-game behavior for that setting.

> [!WARNING]
> Start with the recommended defaults. If the game begins to stutter, lower **AI response speed** or **Shooting response**, or turn off one of the optional improvements.

## Multiplayer

Most AI decisions are controlled by the host, so the host's AI response and route-finding settings benefit everyone. Shooting and movement actions are also simulated locally by each peer, so those improvements use each installed player's own settings.

| Improvement | Where it applies |
| --- | --- |
| AI response speed and faster route finding | Host |
| Shooting response and smoother movement | Each installed player, locally |
| Automatic responsiveness improvements | Each installed player where relevant |

Players without the mod keep the original local shooting and movement behavior without interfering with the host's AI settings.

## How It Works

### Queued work

PAYDAY 2 normally advances queued AI tasks through a shared scheduler at roughly 60 tasks per second. AI Overdrive changes the scheduler interval to:

```text
tick interval = 1 / configured tasks per second
```

The **AI response speed** presets map to 60 tasks per second for Original, 300 for Light Boost, 600 for Balanced, 1200 for Fast, and 3000 for Maximum. The configured value is a ceiling, not a target. Only tasks that the game has already queued are eligible. Due tasks are processed first; when the scheduler has enough time credit and no queued task has yet run that frame, the base game may instead execute a queued `asap` task before its scheduled time. Changing the value preserves the existing queue and clears only its accumulated time credit to avoid a one-frame catch-up burst.

`EnemyManager:_update_queued_tasks` normally executes at most one delayed callback per frame. AI Overdrive snapshots callbacks that are already overdue, lets the original update run, and then drains captured callbacks that are still registered and still overdue. Chronological and equal-time FIFO ordering follows the live queue, including when a callback reschedules another captured callback during the drain. Cancelled callbacks and callbacks rescheduled into the future are skipped; a captured callback rescheduled to a time that is still overdue remains eligible. Callbacks created during the drain wait until the next update.

When `CopLogicBase` submits a task ID that its current logic has already queued, the existing entry is refreshed through `EnemyManager:update_queue_task` instead of appending a duplicate. New task IDs still use the original queue implementation.

### Attention and visibility

Equivalent `AIAttentionObject:get_attention` queries share cached matches and misses. Cache keys include the exact access filter, reaction range, and resolved friend-or-foe relationship. Standard attention mutations clear the cache, and uncached queries still use the original selector unchanged.

The original visibility scan refreshes one valid LOD-priority entry per frame. AI Overdrive continues from the original round-robin position for up to eight total entries while a separate time budget remains. The budget is 5% of the current real frame duration, clamped between 0.25 and 1.5 milliseconds. Original ranking, slot limits, occlusion handling, and visibility transitions remain intact.

### Paths and actions

With **Faster route finding** enabled, the original coarse path update starts the first search, then AI Overdrive processes more queued searches in FIFO order. Work is limited to searches present at the start of the frame, a maximum of eight searches, and a budget equal to 5% of the current real frame duration clamped between 0.25 and 1.5 milliseconds. Turning the option off restores the original one-search-per-frame limit.

Shooting actions normally update every frame at visibility LOD 1, then every 6, 9, or 12 frames at lower visibility levels. **Original** leaves both that cadence and the original one-shot weapon trigger unchanged. **Light** sets a 15 Hz minimum, **Adaptive** uses half the smoothed real-time frame rate clamped to 30–60 Hz, **Smooth** sets a 60 Hz minimum, and **Maximum** removes the original frame skipping. The effective rate never exceeds the rendered frame rate, and action updates are phase-staggered rather than replayed after a hitch.

With any accelerated **Shooting response** setting, both current and legacy NPC raycast weapons fire overdue automatic-weapon cycles the next time their shooting action runs. Catch-up is limited to eight shots per call; older debt beyond that cap is discarded while the next firing time stays aligned to the weapon's cadence. Empty magazines and failed shots stop the loop immediately, and short bursts still stop after their originally selected number of rounds.

Walking actions normally update every 1, 2, 3, or 4 frames depending on visibility. **Smoother movement** advances only the original skip counter before calling the original function, leaving the real LOD, path, elapsed-time, and animation logic intact. The option applies to enemies, civilians, escorts, and AI teammates on every installed peer.

## Compatibility

AI Overdrive uses SuperBLT hooks around the enemy manager, navigation manager, attention objects, `CopLogicBase`, shooting actions, walking actions, and NPC weapons. It minimally replaces `AIAttentionObject.get_attention`, `CopLogicBase.queue_task`, `NewNPCRaycastWeaponBase.trigger_held`, and `NPCRaycastWeaponBase.trigger_held`; the scheduler update, visibility scan, path-search algorithm, and action update functions remain intact.

Conflicts may occur with mods that:

- Change `EnemyManager._tick_rate`
- Replace `_update_queued_tasks`, `_update_gfx_lod`, `AIAttentionObject.get_attention`, `CopLogicBase.queue_task`, `CopActionShoot.update`, `CopActionWalk.update`, or either NPC weapon `trigger_held` implementation
- Change delayed-callback ordering, visibility-LOD priority arrays, coarse-search queue consumption, or action `_skipped_frames`
- Mutate attention settings without using the standard attention-data methods

Load order determines which behavior takes effect when another mod replaces the same implementation.

## Author

[NeptuneIsTheBest](https://github.com/NeptuneIsTheBest)
