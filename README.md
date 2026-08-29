# AI Overdrive

A lightweight enhancement mod for **PAYDAY 2** AI.

## What It Improves

- Helps enemies and teammates keep up when a lot is happening at once
- Lets AI move into its next decision as soon as an action ends
- Reduces pauses while AI waits to find a route
- Makes distant AI shooting feel more responsive
- Keeps movement looking smoother across enemies, civilians, escorts, and AI teammates
- Reduces deployed-sentry targeting work and large-map Group AI spikes

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
               ├── ai_overdrive.lua
               ├── ai_overdrive_group_ai.lua
               ├── ai_overdrive_runtime.lua
               ├── ai_overdrive_sentry.lua
               └── ai_overdrive_walk.lua
   ```

5. Launch the game. SuperBLT will load AI Overdrive automatically.

## Configuration

Open **Options → Mod Options → AI Overdrive**.

Settings apply immediately and persist between game sessions.

| Setting | Default | Behavior |
| --- | ---: | --- |
| AI response speed | Balanced (Recommended) | Helps AI process actions sooner during busy fights |
| Seamless action transitions | On | Removes decision gaps and pauses between ordinary movement segments |
| Faster route finding | On | Reduces the time AI spends waiting for a route |
| Shooting response | Adaptive (Recommended) | Makes distant AI aim and fire more promptly |
| Smoother movement | On | Keeps enemies, civilians, and AI teammates moving smoothly |

Choosing **Original**, or turning an option off, restores the base-game behavior for that setting.

> [!WARNING]
> Start with the recommended defaults. If the game begins to stutter, lower **AI response speed** or **Shooting response**, or turn off one of the optional improvements.

## Multiplayer

Most AI decisions are controlled by the host, so the host's AI response, action-transition, and route-finding settings benefit everyone. Shooting and movement actions are also simulated locally by each peer, so those improvements use each installed player's own settings.

| Improvement | Where it applies |
| --- | --- |
| AI response speed, seamless action transitions, and faster route finding | Host |
| Shooting response and smoother movement | Each installed player, locally |
| Automatic responsiveness improvements | Each installed player where relevant |

Players without the mod keep the original local shooting and movement behavior without interfering with the host's AI settings.

## How It Works

### Loading lifecycle

SuperBLT can invoke a script hook every time the matching game module is requested, including repeated requests for a module Lua has already cached. AI Overdrive loads its lightweight settings, menu, and localization core once during menu setup, then defers gameplay code until the first hooked gameplay class is available. The gameplay runtime is also loaded once, the specialized walking, sentry, and Group AI runtimes are deferred until their classes are available, and every target class is patched at most once while retaining its original per-class hook timing.

### Queued work

PAYDAY 2 normally advances queued AI tasks through a shared scheduler at roughly 60 tasks per second. AI Overdrive changes the scheduler interval to:

```text
tick interval = 1 / configured tasks per second
```

The **AI response speed** presets map to 60 tasks per second for Original, 300 for Light Boost, 600 for Balanced, 1200 for Fast, and 3000 for Maximum. The configured value is a ceiling, not a target. Only tasks that the game has already queued are eligible. Due tasks are processed first; when the scheduler has enough time credit and no queued task has yet run that frame, the base game may instead execute a queued `asap` task before its scheduled time. Changing the value preserves the existing queue and clears only its accumulated time credit to avoid a one-frame catch-up burst.

The task queue remains an insertion-ordered array. AI Overdrive replaces the base game's repeated restart-from-the-front scans with a reusable forward cursor, and repairs active cursors when a callback removes a task. Each task is therefore checked at most once per scheduler call without allocating a temporary `checked` table. Tasks appended by a running callback remain behind existing work and can still run in the same call when time credit remains; tasks already checked are not reconsidered until the next call. Cancelled AI Overdrive task records return immediately to a per-manager pool, while executed records return after their callbacks finish and directly inserted third-party records are left unpooled. Each `CopLogicBase` state also retains its task-membership table and verification callback instead of recreating them on every requeue. Queue-task updates use the original first-match behavior without allocating a predicate closure.

`EnemyManager:_update_queued_tasks` normally executes at most one delayed callback per frame. AI Overdrive snapshots callbacks that are already overdue, runs the scheduler update, and then drains captured callbacks that are still registered and still overdue. Chronological and equal-time FIFO ordering follows the live queue, including when a callback reschedules another captured callback during the drain. Cancelled callbacks and callbacks rescheduled into the future are skipped; a captured callback rescheduled to a time that is still overdue remains eligible. Callbacks created during the drain wait until the next update. Capture and draining run directly inside the scheduler override, avoiding the temporary return tables that SuperBLT pre- and post-hooks would otherwise allocate every frame.

When `CopLogicBase` submits a task ID that its current logic has already queued, AI Overdrive removes the old entry before submitting the replacement instead of appending a duplicate. New task IDs still use the original queue implementation.

### Attention and visibility

Equivalent `AIAttentionObject:get_attention` queries share cached matches and misses. Cache keys include the exact access filter, reaction range, and resolved friend-or-foe relationship. Standard attention mutations clear the cache, and uncached queries still use the original selector unchanged.

`CopLogicBase` attention scans reuse file-level detection helpers and cache stable unit extensions and Group AI state references for each scan. Player-importance reports append directly by array index instead of calling `table.insert`. Candidate and detected-object traversal, notice and verification timing, and all original visibility rays remain unchanged, including the three fallback rays used by the near-visible check.

The original visibility scan checks every hidden unit each frame before refreshing one valid LOD-priority entry. AI Overdrive keeps that cadence but tests the activation frustum first, so hidden units outside the view do not also query navigation visibility or `Unit.occluded`. It then continues from the original round-robin position for up to eight total priority entries while a separate time budget remains. The budget is 5% of the current real frame duration, clamped between 0.25 and 1.5 milliseconds. Original frustum thresholds, ranking, slot limits, occlusion handling, and visibility transitions remain intact.

### Sentry targeting

A sentry first determines the highest identified reaction tier that can win focus selection, then evaluates weights only within that tier. Once a candidate has a winner it also skips shield rays whose unreduced weight cannot win. The winning shield result is reused by the firing update at the same game time. Target visibility tests now cast the center ray before constructing side offsets, and all recurring shield and sight vectors and ignore tables are retained per sentry. Reaction ordering, the original weight formula and shield penalty, center/right/left ray order, fire range, aiming threshold, and AP-ammo behavior remain unchanged.

### Paths and actions

With **Seamless action transitions** enabled, AI Overdrive remembers only the current logic's main decision task: its `queued_update`, or the sniper logic's combined detection/decision update. When an action expires naturally, that existing task is marked due and `asap`; the normal AI scheduler runs it at its next opportunity instead of waiting for the original polling interval, which ranges from fractions of a second to several seconds. The completion callback never executes AI logic directly, so movement state is not re-entered while it is still finishing the old action. The update then requeues itself with its original interval.

The same option removes the base game's ordinary movement pauses: the 2–2.5 second arrest-action gate, the 2–8 second pause between civilian flee legs, and cover dwell between travel or flee path segments. It does not change animation duration, reload or hurt recovery, mission action timeouts, path-failure backoff, combat cover timing, or dodge, tase, and spooc-attack cooldowns. Interrupted actions do not trigger an extra decision update, although any ordinary movement delay written by the interrupted action is cleared.

With **Faster route finding** enabled, the original coarse path update starts the first search, then AI Overdrive processes more queued searches in FIFO order. Work is limited to searches present at the start of the frame, a maximum of eight searches, and a budget equal to 5% of the current real frame duration clamped between 0.25 and 1.5 milliseconds. Turning the option off restores the original one-search-per-frame limit.

The eight remaining area-graph breadth-first searches in `GroupAIStateBesiege` use a forward head index instead of repeatedly shifting `table.remove(queue, 1)`. Neighbours are still appended and visited in the same FIFO order. The current game's `_begin_new_tasks` search already uses a head index and is left untouched; ordinary recon, hostage, and spawning queues are not treated as graph searches.

Shooting actions normally update every frame at visibility LOD 1, then every 6, 9, or 12 frames at lower visibility levels. **Original** leaves both that cadence and the original one-shot weapon trigger unchanged. **Light** sets a 15 Hz minimum, **Adaptive** uses half the smoothed real-time frame rate clamped to 30–60 Hz, **Smooth** sets a 60 Hz minimum, and **Maximum** removes the original frame skipping. The effective rate never exceeds the rendered frame rate, and action updates are phase-staggered rather than replayed after a hitch.

With any accelerated **Shooting response** setting, ordinary `CopActionShoot` bursts from both current and legacy NPC raycast weapons fire overdue automatic-weapon cycles the next time their shooting action runs. The original weapon trigger handles every shot and AI Overdrive limits catch-up to eight shots per call; older debt beyond that cap is discarded while the next firing time stays aligned to the weapon's cadence. Empty magazines and failed shots stop the loop immediately, and short bursts still stop after their originally selected number of rounds. Other callers, including hurt and ragdoll firing, retain the original one-shot-per-call behavior.

Walking actions normally update every 1, 2, 3, or 4 frames depending on visibility. **Smoother movement** keeps the same real LOD, elapsed-time, path, rotation, animation, stop, and navigation-link behavior while running the ordinary walking update every frame. Its optimized path updates each action's persistent last-position and lazily initialized footstep-position vectors in place and uses mutable module scratch vectors, avoiding the five short-lived vector results that the base implementation can produce during a steady movement update. Turning the option off delegates both walking and path advancement to the captured base-game functions. The option applies to enemies, civilians, escorts, and AI teammates on every installed peer.

## Compatibility

AI Overdrive uses SuperBLT hooks around the enemy manager, navigation manager, Group AI state, attention objects, sentry brains, `CopLogicBase`, `CopBrain`, arrest logic, shooting actions, walking actions, and NPC weapons. It minimally replaces `EnemyManager.queue_task`, `EnemyManager.update_queue_task`, `EnemyManager._update_queued_tasks`, `EnemyManager._execute_queued_task`, `EnemyManager.unqueue_task`, `EnemyManager._update_gfx_lod`, `AIAttentionObject.get_attention`, `CopLogicBase._upd_attention_obj_detection`, `CopLogicBase.queue_task`, the eight `GroupAIStateBesiege` area-BFS functions, the sentry focus/fire/shield/sight functions, and the ordinary `CopActionWalk` update/path interpolation functions; both NPC weapon `trigger_held` implementations, action completion, and arrest entry use post-hooks, while the shooting scheduler and coarse path-search algorithm remain intact.

Conflicts may occur with mods that:

- Change `EnemyManager._tick_rate`
- Replace `EnemyManager.queue_task`, `update_queue_task`, `_update_queued_tasks`, `_execute_queued_task`, `unqueue_task`, `_update_gfx_lod`, `AIAttentionObject.get_attention`, `CopLogicBase._upd_attention_obj_detection`, `CopLogicBase.queue_task`, `CopBrain.action_complete_clbk`, `CopLogicArrest.enter`, `CopActionShoot.update`, `CopActionWalk.update`, `CopActionWalk._nav_chk_walk`, or `CopActionWalk._walk_spline`
- Directly replace either NPC weapon `trigger_held` implementation without preserving SuperBLT hooks, or change its return value or `_next_fire_allowed` contract
- Replace `SentryGunBrain._select_focus_attention`, `_upd_fire`, `_ignore_shield`, or `is_target_on_sight`
- Replace `GroupAIStateBesiege._find_spawn_points_near_area`, `_find_spawn_group_near_area`, `flee_point`, `safe_flee_point`, `get_safe_enemy_loot_drop_point`, `_set_recon_objective_to_group`, `_set_assault_objective_to_group`, or `_assign_group_to_retire`
- Directly insert into or remove entries from `EnemyManager._queued_tasks` instead of using the manager methods, or retain references to removed task records
- Change delayed-callback ordering, visibility-LOD priority arrays, coarse-search queue consumption, or action `_skipped_frames`
- Mutate attention settings without using the standard attention-data methods

Load order determines which behavior takes effect when another mod replaces the same implementation.

## Author

[NeptuneIsTheBest](https://github.com/NeptuneIsTheBest)
