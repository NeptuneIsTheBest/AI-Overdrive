local AIOverdrive = assert(
    _G.AIOverdrive and _G.AIOverdrive._core_loaded and _G.AIOverdrive,
    "AI Overdrive runtime loaded before its core"
)

if AIOverdrive._runtime_loaded then
    return AIOverdrive
end

local mrot_y = mrotation.y
local mvec3_dir = mvector3.direction
local mvec3_dot = mvector3.dot

AIOverdrive._npc_weapon_trigger_patch_targets = AIOverdrive._npc_weapon_trigger_patch_targets
    or setmetatable({}, { __mode = "k" })
AIOverdrive._attention_cache_no_match = AIOverdrive._attention_cache_no_match or {}
AIOverdrive._attention_cache_nil_filter = AIOverdrive._attention_cache_nil_filter or {}

function AIOverdrive:patch_enemy_manager_delayed_callbacks(enemy_manager)
    Hooks:PreHook(
        enemy_manager,
        "_update_queued_tasks",
        "AIOverdrive_EnemyManager_UpdateQueuedTasks_CaptureDelayedCallbacks",
        function(manager, t)
            if not Network:is_server() then
                return
            end

            local snapshot_stack =
                manager._ai_overdrive_delayed_callback_snapshot_stack

            if not snapshot_stack then
                snapshot_stack = {}
                manager._ai_overdrive_delayed_callback_snapshot_stack = snapshot_stack
            end

            local eligible_callbacks = {}

            snapshot_stack[#snapshot_stack + 1] = eligible_callbacks

            local delayed_callbacks = manager._delayed_clbks
            local callback_index = #delayed_callbacks

            while callback_index > 0 do
                local callback_data = delayed_callbacks[callback_index]

                if not (t > callback_data[2]) then
                    break
                end

                eligible_callbacks[callback_data] = true
                callback_index = callback_index - 1
            end
        end
    )

    Hooks:PostHook(
        enemy_manager,
        "_update_queued_tasks",
        "AIOverdrive_EnemyManager_UpdateQueuedTasks_DrainDelayedCallbacks",
        function(manager, t)
            local snapshot_stack =
                manager._ai_overdrive_delayed_callback_snapshot_stack

            if not snapshot_stack then
                return
            end

            local eligible_callbacks = table.remove(snapshot_stack)

            if not eligible_callbacks then
                return
            end

            while true do
                local delayed_callbacks = manager._delayed_clbks
                local callback_index = #delayed_callbacks
                local callback_data

                while callback_index > 0 do
                    callback_data = delayed_callbacks[callback_index]

                    if eligible_callbacks[callback_data] then
                        break
                    end

                    callback_index = callback_index - 1
                end

                if callback_index == 0 or not (t > callback_data[2]) then
                    break
                end

                eligible_callbacks[callback_data] = nil

                local clbk = table.remove(delayed_callbacks, callback_index)[3]

                clbk()
            end
        end
    )
end

function AIOverdrive:_refresh_gfx_lod_priority_entry(manager, context, i)
    local states = context.states
    local units = context.units
    local unit = units[i]
    local unit_occluded = context.unit_occluded
    local world = context.world
    local world_in_view_with_options = context.world_in_view_with_options

    if not states[i] or not alive(unit) then
        return false
    end

    local occlusion_skipped = context.occ_skip_units[unit:key()]

    if not occlusion_skipped
        and (
            context.pl_tracker
                and not context.chk_vis_func(context.pl_tracker, context.trackers[i])
            or unit_occluded(unit)
        )
    then
        states[i] = false
        unit:base():set_visibility_state(false)
        manager:_remove_i_from_lod_prio(i, context.anim_lod)

        return true
    end

    if not world_in_view_with_options(
        world,
        context.com[i],
        0,
        120,
        18000
    ) then
        states[i] = false
        unit:base():set_visibility_state(false)
        manager:_remove_i_from_lod_prio(i, context.anim_lod)

        return true
    end

    local my_wgt = mvec3_dir(
        context.direction,
        context.cam_pos,
        context.com[i]
    )
    local dot = mvec3_dot(context.direction, context.pl_fwd)
    local imp_i_list = context.imp_i_list
    local imp_wgt_list = context.imp_wgt_list
    local previous_prio

    for prio, i_entry in ipairs(imp_i_list) do
        if i == i_entry then
            previous_prio = prio

            break
        end
    end

    my_wgt = my_wgt * my_wgt * (1 - dot)

    local i_wgt = #imp_wgt_list

    while i_wgt > 0 do
        if previous_prio ~= i_wgt and my_wgt >= imp_wgt_list[i_wgt] then
            break
        end

        i_wgt = i_wgt - 1
    end

    if not previous_prio or i_wgt <= previous_prio then
        i_wgt = i_wgt + 1
    end

    if i_wgt ~= previous_prio then
        local nr_lod_1 = context.nr_lod_1
        local nr_lod_total = context.nr_lod_total

        if previous_prio then
            table.remove(imp_i_list, previous_prio)
            table.remove(imp_wgt_list, previous_prio)

            if previous_prio <= nr_lod_1
                and nr_lod_1 < i_wgt
                and nr_lod_1 <= #imp_i_list
            then
                local promote_i = imp_i_list[nr_lod_1]

                states[promote_i] = 1
                units[promote_i]:base():set_visibility_state(1)
            elseif nr_lod_1 < previous_prio and i_wgt <= nr_lod_1 then
                local demote_i = imp_i_list[nr_lod_1]

                states[demote_i] = 2
                units[demote_i]:base():set_visibility_state(2)
            end
        elseif i_wgt <= nr_lod_total and #imp_i_list == nr_lod_total then
            local kick_i = imp_i_list[nr_lod_total]

            states[kick_i] = 3
            units[kick_i]:base():set_visibility_state(3)
            table.remove(imp_wgt_list)
            table.remove(imp_i_list)
        end

        local lod_stage

        if i_wgt <= nr_lod_total then
            table.insert(imp_wgt_list, i_wgt, my_wgt)
            table.insert(imp_i_list, i_wgt, i)

            lod_stage = i_wgt <= nr_lod_1 and 1 or 2
        else
            lod_stage = 3

            manager:_remove_i_from_lod_prio(i, context.anim_lod)
        end

        if states[i] ~= lod_stage then
            states[i] = lod_stage
            unit:base():set_visibility_state(lod_stage)
        end
    end

    return true
end

function AIOverdrive:continue_gfx_lod_priority_updates(manager, scratch)
    if not managers.navigation:is_data_ready() then
        return 0
    end

    local camera_rot = managers.viewport:get_current_camera_rotation()

    if not camera_rot then
        return 0
    end

    mrot_y(camera_rot, scratch.pl_fwd)

    local player = managers.player:player_unit()
    local pl_tracker
    local cam_pos

    if player then
        local movement = player:movement()

        pl_tracker = movement:nav_tracker()
        cam_pos = movement:m_head_pos()
    else
        pl_tracker = false
        cam_pos = managers.viewport:get_current_camera_position()
    end

    local gfx_lod_data = manager._gfx_lod_data
    local entries = gfx_lod_data.entries
    local units = entries.units
    local states = entries.states
    local trackers = entries.trackers
    local com = entries.com

    local nr_entries = #states

    if nr_entries <= 1 then
        return 0
    end

    local next_i = gfx_lod_data.next_chk_prio_i

    if nr_entries < next_i then
        next_i = 1
    end

    local anim_lod = managers.user:get_setting("video_animation_lod")
    local lod_counts = manager._nr_i_lod[anim_lod]
    local imp_i_list = gfx_lod_data.prio_i
    local imp_wgt_list = gfx_lod_data.prio_weights
    local chk_vis_func = pl_tracker and pl_tracker.check_visibility
    local context = scratch.context
    local world = World

    context.anim_lod = anim_lod
    context.cam_pos = cam_pos
    context.chk_vis_func = chk_vis_func
    context.com = com
    context.direction = scratch.direction
    context.imp_i_list = imp_i_list
    context.imp_wgt_list = imp_wgt_list
    context.nr_lod_1 = lod_counts[1]
    context.nr_lod_total = lod_counts[1] + lod_counts[2]
    context.occ_skip_units = managers.occlusion._skip_occlusion
    context.pl_fwd = scratch.pl_fwd
    context.pl_tracker = pl_tracker
    context.states = states
    context.trackers = trackers
    context.unit_occluded = Unit.occluded
    context.units = units
    context.world = world
    context.world_in_view_with_options = world.in_view_with_options

    local max_additional_updates = math.min(
        nr_entries - 1,
        self.MAX_GFX_LOD_PRIORITY_UPDATES_PER_FRAME - 1
    )
    local deadline = self:frame_budget_clock() + self:gfx_lod_priority_frame_budget()
    local processed = 0
    local scanned = 0

    while processed < max_additional_updates
        and scanned < nr_entries - 1
        and self:frame_budget_clock() < deadline
    do
        local i = next_i

        if self:_refresh_gfx_lod_priority_entry(manager, context, i) then
            processed = processed + 1
        end

        scanned = scanned + 1
        gfx_lod_data.next_chk_prio_i = i + 1
        next_i = i == nr_entries and 1 or i + 1
    end

    return processed
end

function AIOverdrive:patch_enemy_manager_gfx_lod(enemy_manager)
    local ai_overdrive = self
    local scratch = {
        context = {},
        direction = Vector3(),
        pl_fwd = Vector3()
    }

    Hooks:PostHook(
        enemy_manager,
        "_update_gfx_lod",
        "AIOverdrive_EnemyManager_UpdateGfxLod_ContinuePriorityRefresh",
        function(manager)
            ai_overdrive:continue_gfx_lod_priority_updates(manager, scratch)
        end
    )
end

function AIOverdrive:_begin_attention_cache_mutation(attention_object)
    attention_object._ai_overdrive_attention_cache = nil
    attention_object._ai_overdrive_attention_cache_mutation_depth =
        (attention_object._ai_overdrive_attention_cache_mutation_depth or 0) + 1
end

function AIOverdrive:_end_attention_cache_mutation(attention_object)
    local mutation_depth = attention_object._ai_overdrive_attention_cache_mutation_depth

    attention_object._ai_overdrive_attention_cache = nil

    if mutation_depth == 1 then
        attention_object._ai_overdrive_attention_cache_mutation_depth = nil
    else
        attention_object._ai_overdrive_attention_cache_mutation_depth = mutation_depth - 1
    end
end

function AIOverdrive:patch_ai_attention_object(ai_attention_object)
    if self._ai_attention_object_patch_target == ai_attention_object then
        return
    end

    local mutation_methods = {
        "add_attention",
        "remove_attention",
        "set_attention",
        "override_attention",
        "set_team"
    }

    local original_get_attention = Hooks:GetFunction(
        ai_attention_object,
        "get_attention"
    )
    local ai_overdrive = self

    for _, method_name in ipairs(mutation_methods) do
        local hook_id = "AIOverdrive_AIAttentionObject_" .. method_name

        Hooks:PreHook(
            ai_attention_object,
            method_name,
            hook_id .. "_BeginCacheMutation",
            function(attention_object)
                ai_overdrive:_begin_attention_cache_mutation(attention_object)
            end
        )
        Hooks:PostHook(
            ai_attention_object,
            method_name,
            hook_id .. "_EndCacheMutation",
            function(attention_object)
                ai_overdrive:_end_attention_cache_mutation(attention_object)
            end
        )
    end

    local no_match = self._attention_cache_no_match
    local nil_filter = self._attention_cache_nil_filter
    local default_min_reaction = ai_attention_object.REACT_MIN
    local default_max_reaction = ai_attention_object.REACT_MAX

    Hooks:OverrideFunction(
        ai_attention_object,
        "get_attention",
        function(attention_object, filter, min_reaction, max_reaction, team)
            if attention_object._ai_overdrive_attention_cache_mutation_depth
                or not attention_object._registered
                or not attention_object._attention_data
            then
                return original_get_attention(
                    attention_object,
                    filter,
                    min_reaction,
                    max_reaction,
                    team
                )
            end

            local attention_data = attention_object._attention_data
            local overrides = attention_object._overrides
            local cache = attention_object._ai_overdrive_attention_cache

            if not cache
                or cache.attention_data ~= attention_data
                or cache.overrides ~= overrides
            then
                cache = {
                    attention_data = attention_data,
                    overrides = overrides,
                    entries = {}
                }
                attention_object._ai_overdrive_attention_cache = cache
            end

            local relation_key = 0
            local attention_team = attention_object._team

            if team and attention_team then
                relation_key = team.foes[attention_team.id] and 2 or 1
            end

            local filter_key = filter == nil and nil_filter or filter
            local min_key = min_reaction or default_min_reaction
            local max_key = max_reaction or default_max_reaction
            local filter_cache = cache.entries[filter_key]

            if not filter_cache then
                filter_cache = {}
                cache.entries[filter_key] = filter_cache
            end

            local min_cache = filter_cache[min_key]

            if not min_cache then
                min_cache = {}
                filter_cache[min_key] = min_cache
            end

            local max_cache = min_cache[max_key]

            if not max_cache then
                max_cache = {}
                min_cache[max_key] = max_cache
            end

            local cached_settings = max_cache[relation_key]

            if cached_settings ~= nil then
                return cached_settings ~= no_match and cached_settings or nil
            end

            local settings = original_get_attention(
                attention_object,
                filter,
                min_reaction,
                max_reaction,
                team
            )

            max_cache[relation_key] = settings or no_match

            return settings
        end
    )

    self._ai_attention_object_patch_target = ai_attention_object
end

function AIOverdrive:patch_cop_logic_base_queue_task(cop_logic_base)
    if self._cop_logic_base_queue_task_patch_target == cop_logic_base then
        return
    end

    local ai_overdrive = self
    local original_queue_task = Hooks:GetFunction(cop_logic_base, "queue_task")

    Hooks:OverrideFunction(cop_logic_base, "queue_task", function(internal_data, id, func, data, exec_t, asap)
        local queued_tasks = internal_data.queued_tasks

        if queued_tasks and queued_tasks[id] then
            cop_logic_base.unqueue_task(internal_data, id)
        end

        if ai_overdrive:is_logic_decision_update(func, data) then
            internal_data._ai_overdrive_decision_update_id = id
        end

        return original_queue_task(internal_data, id, func, data, exec_t, asap)
    end)

    self._cop_logic_base_queue_task_patch_target = cop_logic_base
end

function AIOverdrive:is_logic_decision_update(func, data)
    if type(data) ~= "table" or type(data.logic) ~= "table" then
        return false
    end

    if type(data.logic.queued_update) == "function"
        and func == data.logic.queued_update
    then
        return true
    end

    return data.name == "sniper"
        and type(data.logic._upd_enemy_detection) == "function"
        and func == data.logic._upd_enemy_detection
end

function AIOverdrive:action_transition_due_t(t)
    return t - self.ACTION_TRANSITION_EPSILON
end

function AIOverdrive:is_natural_action_completion(action)
    return action
        and type(action.expired) == "function"
        and action:expired()
        and true
        or false
end

function AIOverdrive:remove_ordinary_action_wait(logic_data, action, t)
    local internal_data = logic_data and logic_data.internal_data

    if not internal_data or not action or type(action.type) ~= "function" then
        return false
    end

    local action_type = action:type()
    local logic_name = logic_data.name
    local changed = false
    local due_t = self:action_transition_due_t(t)

    if logic_name == "arrest" and (action_type == "walk" or action_type == "act") then
        if internal_data.next_action_delay_t ~= nil then
            internal_data.next_action_delay_t = due_t
            changed = true
        end
    elseif logic_name == "flee" and action_type == "walk" then
        if internal_data.next_action_t ~= nil then
            internal_data.next_action_t = due_t
            changed = true
        end

        if internal_data.cover_leave_t ~= nil then
            internal_data.cover_leave_t = nil
            changed = true
        end
    elseif logic_name == "travel"
        and action_type == "walk"
        and internal_data.cover_leave_t ~= nil
    then
        internal_data.cover_leave_t = nil
        changed = true
    end

    return changed
end

function AIOverdrive:remove_initial_arrest_wait(data, t)
    local internal_data = data and data.internal_data

    if data
        and data.name == "arrest"
        and internal_data
        and internal_data.next_action_delay_t ~= nil
    then
        internal_data.next_action_delay_t = self:action_transition_due_t(t)

        return true
    end

    return false
end

function AIOverdrive:on_ai_action_complete(brain, action)
    if not self:seamless_action_transitions_enabled() or not Network:is_server() then
        return false
    end

    local logic_data = brain and brain._logic_data

    if not logic_data
        or logic_data.logic ~= brain._current_logic
        or not logic_data.internal_data
        or logic_data.internal_data.exiting
    then
        return false
    end

    local t = TimerManager:game():time()

    self:remove_ordinary_action_wait(logic_data, action, t)

    if not self:is_natural_action_completion(action) then
        return false
    end

    local internal_data = logic_data.internal_data
    local task_id = internal_data._ai_overdrive_decision_update_id
    local queued_tasks = internal_data.queued_tasks

    if not task_id or not queued_tasks or not queued_tasks[task_id] then
        return false
    end

    local enemy_manager = managers and managers.enemy

    if not enemy_manager or type(enemy_manager.update_queue_task) ~= "function" then
        return false
    end

    enemy_manager:update_queue_task(
        task_id,
        nil,
        nil,
        self:action_transition_due_t(t),
        nil,
        true
    )

    return true
end

function AIOverdrive:on_cop_logic_arrest_enter(data)
    if not self:seamless_action_transitions_enabled() or not Network:is_server() then
        return false
    end

    return self:remove_initial_arrest_wait(data, TimerManager:game():time())
end

function AIOverdrive:patch_cop_brain_action_transitions(cop_brain, cop_logic_arrest)
    local ai_overdrive = self

    if self._cop_brain_action_transition_patch_target ~= cop_brain then
        Hooks:PostHook(
            cop_brain,
            "action_complete_clbk",
            "AIOverdrive_CopBrain_ActionComplete",
            function(brain, action)
                ai_overdrive:on_ai_action_complete(brain, action)
            end
        )

        self._cop_brain_action_transition_patch_target = cop_brain
    end

    if cop_logic_arrest
        and self._cop_logic_arrest_transition_patch_target ~= cop_logic_arrest
    then
        Hooks:PostHook(
            cop_logic_arrest,
            "enter",
            "AIOverdrive_CopLogicArrest_Enter",
            function(data)
                ai_overdrive:on_cop_logic_arrest_enter(data)
            end
        )

        self._cop_logic_arrest_transition_patch_target = cop_logic_arrest
    end
end

function AIOverdrive:calculate_auto_shooting_update_hz(frame_delta_time)
    local target_hz = self.AUTO_SHOOTING_FPS_RATIO / frame_delta_time

    return math.max(
        self.AUTO_SHOOTING_MIN_HZ,
        math.min(self.AUTO_SHOOTING_MAX_HZ, target_hz)
    )
end

function AIOverdrive:sample_auto_shooting_frame_time(frame_t, frame_delta_time)
    local last_sample_t = self._auto_shooting_last_sample_t

    if frame_t == last_sample_t then
        return self._auto_shooting_smoothed_dt or self.DEFAULT_FRAME_DELTA_TIME
    end

    local dt = frame_delta_time or TimerManager:wall():delta_time()

    if dt <= 0 then
        dt = self._auto_shooting_smoothed_dt or self.DEFAULT_FRAME_DELTA_TIME
    end

    local smoothed_dt = self._auto_shooting_smoothed_dt

    if smoothed_dt then
        local alpha = math.min(1, dt / self.AUTO_SHOOTING_SMOOTHING_WINDOW)

        smoothed_dt = smoothed_dt + (dt - smoothed_dt) * alpha
    else
        smoothed_dt = dt
    end

    self._auto_shooting_smoothed_dt = smoothed_dt
    self._auto_shooting_last_sample_t = frame_t

    return smoothed_dt
end

function AIOverdrive:resolve_shooting_update_for_frame(frame_t)
    local revision = self._shooting_settings_revision
    local resolution = self._shooting_frame_resolution

    if resolution
        and resolution.frame_t == frame_t
        and resolution.revision == revision
    then
        return resolution
    end

    local update_rate = self:shooting_update_rate()

    if not resolution then
        resolution = {}
        self._shooting_frame_resolution = resolution
    end

    resolution.frame_t = frame_t
    resolution.revision = revision
    resolution.update_rate = update_rate
    resolution.wall_t = nil
    resolution.target_hz = nil
    resolution.interval = nil

    if update_rate == "original" or update_rate == "full" then
        return resolution
    end

    local wall_timer = TimerManager:wall()
    local target_hz

    resolution.wall_t = wall_timer:time()

    if update_rate == "auto" then
        target_hz = self:calculate_auto_shooting_update_hz(
            self:sample_auto_shooting_frame_time(frame_t, wall_timer:delta_time())
        )
    else
        target_hz = self.SHOOTING_UPDATE_RATES[update_rate]
    end

    resolution.target_hz = target_hz
    resolution.interval = 1 / target_hz

    return resolution
end

function AIOverdrive:shooting_action_phase(action)
    local unit_id = action._unit:id()

    return math.abs(unit_id % self.SHOOTING_ACTION_PHASE_MODULUS)
        / self.SHOOTING_ACTION_PHASE_MODULUS
end

function AIOverdrive:advance_shooting_action_schedule(state, t, interval)
    local next_update_t = state.next_update_t
    local missed_intervals = math.floor(
        math.max(0, t - next_update_t) / interval
    ) + 1

    next_update_t = next_update_t + missed_intervals * interval

    if next_update_t <= t then
        next_update_t = t + interval
    end

    state.next_update_t = next_update_t
end

function AIOverdrive:prime_lod_action_update(action, vis_state, threshold_multiplier)
    action._skipped_frames = vis_state * threshold_multiplier

    return true
end

function AIOverdrive:prepare_shooting_action_update(action, t, vis_state, interval)
    local state = action._ai_overdrive_shooting_state
    local revision = self._shooting_settings_revision

    if not state
        or state.revision ~= revision
    then
        local phase = self:shooting_action_phase(action)

        state = {
            revision = revision,
            interval = interval,
            next_update_t = t + interval * phase
        }
        action._ai_overdrive_shooting_state = state
    else
        if interval < state.interval
            and state.next_update_t > t + interval
        then
            state.next_update_t = t + interval
        end

        state.interval = interval
    end

    if vis_state == 1 then
        state.next_update_t = t + interval

        return false
    end

    local skipped_frames = action._skipped_frames
    local original_threshold = vis_state * 3

    if skipped_frames >= original_threshold then
        if t + 0.000001 >= state.next_update_t then
            self:advance_shooting_action_schedule(state, t, interval)
        else
            state.next_update_t = t + interval
        end

        return false
    end

    if t + 0.000001 < state.next_update_t then
        return false
    end

    self:advance_shooting_action_schedule(state, t, interval)
    self:prime_lod_action_update(action, vis_state, 3)

    return true
end

function AIOverdrive:begin_npc_weapon_shoot_action(action)
    local weapon_base = action._weapon_base

    if not weapon_base then
        return
    end

    if type(action._autofiring) == "number"
        and type(action._autoshots_fired) == "number"
    then
        weapon_base._ai_overdrive_shoot_action = action
    elseif weapon_base._ai_overdrive_shoot_action == action then
        weapon_base._ai_overdrive_shoot_action = nil
    end
end

function AIOverdrive:end_npc_weapon_shoot_action(action)
    local weapon_base = action._weapon_base

    if weapon_base
        and weapon_base._ai_overdrive_shoot_action == action
    then
        weapon_base._ai_overdrive_shoot_action = nil
    end
end

function AIOverdrive:npc_weapon_fire_rate(weapon_base, default_fire_rate)
    local weapon_tweak = tweak_data.weapon[weapon_base._name_id]
    local fire_rate = tonumber(
        weapon_tweak
        and weapon_tweak.auto
        and weapon_tweak.auto.fire_rate
    )

    if not fire_rate or fire_rate <= 0 or fire_rate ~= fire_rate then
        return default_fire_rate
    end

    return fire_rate
end

function AIOverdrive:npc_weapon_catchup_limit(weapon_base)
    local shot_limit = self.MAX_NPC_WEAPON_CATCHUP_SHOTS
    local shoot_action = weapon_base._ai_overdrive_shoot_action

    if not shoot_action
        or shoot_action._weapon_base ~= weapon_base
        or type(shoot_action._autofiring) ~= "number"
        or type(shoot_action._autoshots_fired) ~= "number"
    then
        return shot_limit
    end

    local remaining_shots = math.max(
        1,
        math.floor(shoot_action._autofiring - shoot_action._autoshots_fired)
    )

    return math.min(shot_limit, remaining_shots), shoot_action
end

function AIOverdrive:catch_up_npc_weapon_trigger(weapon_base, default_fire_rate, ...)
    local current_t = Application:time()

    if weapon_base._next_fire_allowed > current_t then
        return
    end

    local fire_rate = self:npc_weapon_fire_rate(weapon_base, default_fire_rate)
    local shot_limit, shoot_action = self:npc_weapon_catchup_limit(weapon_base)
    local fired
    local death_result
    local shots_fired = 0

    while weapon_base._next_fire_allowed <= current_t
        and shots_fired < shot_limit
    do
        local shot_result = weapon_base:fire(...)

        if not shot_result then
            break
        end

        fired = shot_result
        shots_fired = shots_fired + 1
        weapon_base._next_fire_allowed = weapon_base._next_fire_allowed + fire_rate

        if not death_result
            and type(shot_result) == "table"
            and type(shot_result.hit_enemy) == "table"
            and shot_result.hit_enemy.type == "death"
        then
            death_result = shot_result
        end
    end

    if shoot_action
        and shots_fired > 1
        and weapon_base._ai_overdrive_shoot_action == shoot_action
        and type(shoot_action._autoshots_fired) == "number"
    then
        shoot_action._autoshots_fired = shoot_action._autoshots_fired + shots_fired - 1
    end

    if shots_fired == self.MAX_NPC_WEAPON_CATCHUP_SHOTS
        and weapon_base._next_fire_allowed <= current_t
    then
        local skipped_cycles = math.floor(
            (current_t - weapon_base._next_fire_allowed) / fire_rate
        ) + 1

        weapon_base._next_fire_allowed = weapon_base._next_fire_allowed
            + skipped_cycles * fire_rate

        if weapon_base._next_fire_allowed <= current_t then
            weapon_base._next_fire_allowed = current_t + fire_rate
        end
    end

    return death_result or fired
end

function AIOverdrive:patch_npc_weapon_trigger(weapon_class, default_fire_rate)
    if self._npc_weapon_trigger_patch_targets[weapon_class] then
        return
    end

    local ai_overdrive = self
    local original_trigger_held = Hooks:GetFunction(weapon_class, "trigger_held")

    Hooks:OverrideFunction(weapon_class, "trigger_held", function(weapon_base, ...)
        if not ai_overdrive:accelerated_shooting_enabled() then
            return original_trigger_held(weapon_base, ...)
        end

        return ai_overdrive:catch_up_npc_weapon_trigger(
            weapon_base,
            default_fire_rate,
            ...
        )
    end)

    self._npc_weapon_trigger_patch_targets[weapon_class] = true
end

function AIOverdrive:patch_new_npc_raycast_weapon_base(weapon_class)
    self:patch_npc_weapon_trigger(
        weapon_class,
        self.NEW_NPC_WEAPON_DEFAULT_FIRE_RATE
    )
end

function AIOverdrive:patch_npc_raycast_weapon_base(weapon_class)
    self:patch_npc_weapon_trigger(
        weapon_class,
        self.LEGACY_NPC_WEAPON_DEFAULT_FIRE_RATE
    )
end

function AIOverdrive:patch_cop_action_shoot(cop_action_shoot)
    local ai_overdrive = self

    Hooks:PreHook(
        cop_action_shoot,
        "update",
        "AIOverdrive_CopActionShoot_Update",
        function(action, t)
            local resolution = ai_overdrive:resolve_shooting_update_for_frame(t)

            if resolution.update_rate == "original" then
                return
            end

            ai_overdrive:begin_npc_weapon_shoot_action(action)

            local vis_state = action._ext_base:lod_stage() or 4

            if resolution.update_rate == "full" then
                ai_overdrive:prime_lod_action_update(action, vis_state, 3)

                return
            end

            ai_overdrive:prepare_shooting_action_update(
                action,
                resolution.wall_t,
                vis_state,
                resolution.interval
            )
        end
    )

    Hooks:PostHook(
        cop_action_shoot,
        "update",
        "AIOverdrive_CopActionShoot_Update_ClearNPCWeaponContext",
        function(action)
            ai_overdrive:end_npc_weapon_shoot_action(action)
        end
    )
end

function AIOverdrive:patch_cop_action_walk(cop_action_walk)
    local ai_overdrive = self

    Hooks:PreHook(
        cop_action_walk,
        "update",
        "AIOverdrive_CopActionWalk_Update",
        function(action)
            if not ai_overdrive:every_frame_walking_enabled() then
                return
            end

            local vis_state = action._ext_base:lod_stage() or 4

            ai_overdrive:prime_lod_action_update(action, vis_state, 1)
        end
    )
end

function AIOverdrive:current_frame_delta_time()
    local dt = TimerManager:wall():delta_time()

    if dt <= 0 then
        dt = self.DEFAULT_FRAME_DELTA_TIME
    end

    return dt
end

function AIOverdrive:adaptive_frame_budget(ratio, min_budget, max_budget)
    local dt = self:current_frame_delta_time()

    return math.max(
        min_budget,
        math.min(max_budget, dt * ratio)
    )
end

function AIOverdrive:frame_budget_clock()
    return TimerManager:wall():time()
end

function AIOverdrive:gfx_lod_priority_frame_budget()
    return self:adaptive_frame_budget(
        self.GFX_LOD_PRIORITY_BUDGET_RATIO,
        self.MIN_GFX_LOD_PRIORITY_BUDGET,
        self.MAX_GFX_LOD_PRIORITY_BUDGET
    )
end

function AIOverdrive:coarse_search_frame_budget()
    return self:adaptive_frame_budget(
        self.COARSE_SEARCH_BUDGET_RATIO,
        self.MIN_COARSE_SEARCH_BUDGET,
        self.MAX_COARSE_SEARCH_BUDGET
    )
end

function AIOverdrive:coarse_search_clock()
    return self:frame_budget_clock()
end

function AIOverdrive:patch_navigation_manager_coarse_searches(navigation_manager)
    local ai_overdrive = self

    Hooks:PreHook(
        navigation_manager,
        "_commence_coarce_searches",
        "AIOverdrive_NavigationManager_CommenceCoarseSearches_Start",
        function(manager)
            local frame_state = manager._ai_overdrive_coarse_search_frame_state

            if frame_state then
                frame_state.started_at = nil
                frame_state.queue_length = nil
            end

            if not Network:is_server()
                or not ai_overdrive:coarse_path_batching_enabled()
            then
                return
            end

            local queue_length = #manager._coarse_searches

            if queue_length <= 1 then
                return
            end

            if not frame_state then
                frame_state = {}
                manager._ai_overdrive_coarse_search_frame_state = frame_state
            end

            frame_state.started_at = ai_overdrive:coarse_search_clock()
            frame_state.queue_length = queue_length
        end
    )

    Hooks:PostHook(
        navigation_manager,
        "_commence_coarce_searches",
        "AIOverdrive_NavigationManager_CommenceCoarseSearches_Finish",
        function(manager)
            local frame_state = manager._ai_overdrive_coarse_search_frame_state

            if not frame_state or not frame_state.started_at then
                return
            end

            local started_at = frame_state.started_at
            local queue_length = frame_state.queue_length

            frame_state.started_at = nil
            frame_state.queue_length = nil

            if not ai_overdrive:coarse_path_batching_enabled() then
                return
            end

            local coarse_searches = manager._coarse_searches

            if not coarse_searches[1] then
                return
            end

            local max_searches = math.min(
                queue_length,
                ai_overdrive.MAX_COARSE_SEARCHES_PER_FRAME
            )
            local additional_searches = max_searches - 1
            local deadline = started_at + ai_overdrive:coarse_search_frame_budget()
            local processed = 0

            while processed < additional_searches
                and ai_overdrive:coarse_search_clock() < deadline
            do
                coarse_searches = manager._coarse_searches

                if not coarse_searches[1] then
                    break
                end

                local search_data = table.remove(coarse_searches, 1)
                local result = manager:_execute_coarce_search(search_data)

                search_data.results_callback(result)

                processed = processed + 1
            end
        end
    )
end

AIOverdrive._runtime_loaded = true

return AIOverdrive
