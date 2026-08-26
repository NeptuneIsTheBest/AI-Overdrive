local AIOverdrive = assert(
    _G.AIOverdrive and _G.AIOverdrive._core_loaded and _G.AIOverdrive,
    "AI Overdrive runtime loaded before its core"
)

if AIOverdrive._runtime_loaded then
    return AIOverdrive
end

local mrot_y = mrotation.y
local mvec3_add = mvector3.add
local mvec3_angle = mvector3.angle
local mvec3_copy = mvector3.copy
local mvec3_cross = mvector3.cross
local mvec3_dir = mvector3.direction
local mvec3_dis = mvector3.distance
local mvec3_dot = mvector3.dot
local mvec3_mul = mvector3.multiply
local mvec3_set = mvector3.set
local mvec3_set_length = mvector3.set_length
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract
local attention_tmp_vec1 = Vector3()

AIOverdrive._npc_weapon_trigger_patch_targets = AIOverdrive._npc_weapon_trigger_patch_targets
    or setmetatable({}, { __mode = "k" })
AIOverdrive._attention_cache_no_match = AIOverdrive._attention_cache_no_match or {}
AIOverdrive._attention_cache_nil_filter = AIOverdrive._attention_cache_nil_filter or {}
AIOverdrive._enemy_manager_pooled_task_objects =
    AIOverdrive._enemy_manager_pooled_task_objects
    or setmetatable({}, { __mode = "k" })

local function _recycle_enemy_manager_task(manager, task)
    if not AIOverdrive._enemy_manager_pooled_task_objects[task] then
        return
    end

    for key in pairs(task) do
        task[key] = nil
    end

    local task_pool = manager._ai_overdrive_queued_task_pool

    if not task_pool then
        task_pool = {}
        manager._ai_overdrive_queued_task_pool = task_pool
    end

    task_pool[#task_pool + 1] = task
end

local function _enemy_manager_queue_task(
    manager,
    id,
    task_clbk,
    data,
    execute_t,
    verification_clbk,
    asap
)
    local task_pool = manager._ai_overdrive_queued_task_pool
    local task

    if task_pool then
        local pool_size = #task_pool

        if pool_size > 0 then
            task = task_pool[pool_size]
            task_pool[pool_size] = nil
        end
    end

    if not task then
        task = {}
        AIOverdrive._enemy_manager_pooled_task_objects[task] = true
    end

    task.clbk = task_clbk
    task.id = id
    task.data = data
    task.t = execute_t or 0
    task.v_cb = verification_clbk
    task.asap = asap

    local queued_tasks = manager._queued_tasks

    queued_tasks[#queued_tasks + 1] = task
end

local function _enemy_manager_update_queue_task(
    manager,
    id,
    task_clbk,
    data,
    execute_t,
    verification_clbk,
    asap
)
    local queued_tasks = manager._queued_tasks
    local task_index = 1

    while task_index <= #queued_tasks do
        local task = queued_tasks[task_index]

        if task.id == id then
            task.clbk = task_clbk or task.clbk
            task.data = data or task.data
            task.t = execute_t or task.t
            task.v_cb = verification_clbk or task.v_cb
            task.asap = asap or task.asap

            return
        end

        task_index = task_index + 1
    end
end

local function _adjust_enemy_manager_queue_scan_cursors(manager, removed_index)
    local scan_depth = manager._ai_overdrive_queue_scan_depth

    if not scan_depth or scan_depth == 0 then
        return
    end

    local scan_cursors = manager._ai_overdrive_queue_scan_cursors

    for depth = 1, scan_depth do
        local cursor = scan_cursors[depth]

        if cursor and removed_index < cursor then
            scan_cursors[depth] = cursor - 1
        end
    end
end

local function _enemy_manager_unqueue_task(manager, id)
    local tasks = manager._queued_tasks
    local task_index = #tasks

    while task_index > 0 do
        if tasks[task_index].id == id then
            local task = table.remove(tasks, task_index)

            _adjust_enemy_manager_queue_scan_cursors(manager, task_index)
            _recycle_enemy_manager_task(manager, task)

            return
        end

        task_index = task_index - 1
    end
end

local function _enemy_manager_execute_queued_task(manager, task_index)
    local task = table.remove(manager._queued_tasks, task_index)
    local verification_clbk = task.v_cb
    local id = task.id
    local task_clbk = task.clbk
    local data = task.data

    _adjust_enemy_manager_queue_scan_cursors(manager, task_index)

    manager._queued_task_executed = true

    if verification_clbk then
        verification_clbk(id)
    end

    task_clbk(data)
    _recycle_enemy_manager_task(manager, task)
end

local function _begin_enemy_manager_queue_scan(manager)
    local scan_cursors = manager._ai_overdrive_queue_scan_cursors

    if not scan_cursors then
        scan_cursors = {}
        manager._ai_overdrive_queue_scan_cursors = scan_cursors
    end

    local scan_depth = (manager._ai_overdrive_queue_scan_depth or 0) + 1

    manager._ai_overdrive_queue_scan_depth = scan_depth
    scan_cursors[scan_depth] = 1

    return scan_cursors, scan_depth
end

local function _end_enemy_manager_queue_scan(manager, scan_cursors, scan_depth)
    scan_cursors[scan_depth] = nil
    manager._ai_overdrive_queue_scan_depth = scan_depth - 1
end

local function _capture_enemy_manager_delayed_callbacks(manager, t)
    if not Network:is_server() then
        return
    end

    local delayed_callbacks = manager._delayed_clbks
    local callback_index = #delayed_callbacks
    local callback_data = delayed_callbacks[callback_index]

    if not callback_data or not (t > callback_data[2]) then
        return
    end

    local snapshot_pool =
        manager._ai_overdrive_delayed_callback_snapshot_pool
    local eligible_callbacks

    if snapshot_pool and #snapshot_pool > 0 then
        eligible_callbacks = snapshot_pool[#snapshot_pool]
        snapshot_pool[#snapshot_pool] = nil
    else
        eligible_callbacks = {}
    end

    while callback_index > 0 do
        callback_data = delayed_callbacks[callback_index]

        if not (t > callback_data[2]) then
            break
        end

        eligible_callbacks[callback_data] = true
        callback_index = callback_index - 1
    end

    return eligible_callbacks
end

local function _release_enemy_manager_delayed_callback_snapshot(
    manager,
    eligible_callbacks
)
    for callback_data in pairs(eligible_callbacks) do
        eligible_callbacks[callback_data] = nil
    end

    local snapshot_pool =
        manager._ai_overdrive_delayed_callback_snapshot_pool

    if not snapshot_pool then
        snapshot_pool = {}
        manager._ai_overdrive_delayed_callback_snapshot_pool = snapshot_pool
    end

    snapshot_pool[#snapshot_pool + 1] = eligible_callbacks
end

local function _update_enemy_manager_delayed_callbacks(
    manager,
    t,
    eligible_callbacks
)
    local delayed_callbacks = manager._delayed_clbks
    local next_callback = delayed_callbacks[#delayed_callbacks]

    if next_callback and t > next_callback[2] then
        local clbk = table.remove(delayed_callbacks)[3]

        clbk()
    end

    if not eligible_callbacks then
        return
    end

    while true do
        delayed_callbacks = manager._delayed_clbks

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

    _release_enemy_manager_delayed_callback_snapshot(
        manager,
        eligible_callbacks
    )
end

local function _enemy_manager_update_queued_tasks(manager, t, dt)
    local eligible_callbacks =
        _capture_enemy_manager_delayed_callbacks(manager, t)

    manager._queue_buffer = manager._queue_buffer + dt

    local i_asap_task
    local tick_rate = manager._tick_rate
    local queued_tasks = manager._queued_tasks

    if tick_rate <= manager._queue_buffer then
        local scan_cursors, scan_depth = _begin_enemy_manager_queue_scan(manager)

        while true do
            local task_index = scan_cursors[scan_depth]
            local task_data = queued_tasks[task_index]

            if not task_data then
                break
            end

            scan_cursors[scan_depth] = task_index + 1

            if t > task_data.t then
                manager._queue_buffer = manager._queue_buffer - tick_rate

                local stop = manager._queue_buffer <= 0

                manager:_execute_queued_task(task_index)

                if stop then
                    break
                end
            elseif not i_asap_task and task_data.asap then
                i_asap_task = task_index
            end
        end

        _end_enemy_manager_queue_scan(manager, scan_cursors, scan_depth)
    end

    if i_asap_task and not manager._queued_task_executed then
        manager._queue_buffer = manager._queue_buffer - tick_rate

        manager:_execute_queued_task(i_asap_task)
    end

    manager._queue_buffer = #queued_tasks == 0
        and 0
        or math.min(manager._queue_buffer, tick_rate * #queued_tasks)

    _update_enemy_manager_delayed_callbacks(manager, t, eligible_callbacks)
end

function AIOverdrive:patch_enemy_manager_task_scheduler(enemy_manager)
    if self._enemy_manager_task_scheduler_patch_target == enemy_manager then
        return
    end

    Hooks:OverrideFunction(
        enemy_manager,
        "queue_task",
        _enemy_manager_queue_task
    )
    Hooks:OverrideFunction(
        enemy_manager,
        "update_queue_task",
        _enemy_manager_update_queue_task
    )
    Hooks:OverrideFunction(
        enemy_manager,
        "unqueue_task",
        _enemy_manager_unqueue_task
    )
    Hooks:OverrideFunction(
        enemy_manager,
        "_execute_queued_task",
        _enemy_manager_execute_queued_task
    )
    Hooks:OverrideFunction(
        enemy_manager,
        "_update_queued_tasks",
        _enemy_manager_update_queued_tasks
    )

    self._enemy_manager_task_scheduler_patch_target = enemy_manager
end

function AIOverdrive:_prepare_gfx_lod_context(manager, scratch)
    if not managers.navigation:is_data_ready() then
        return
    end

    local camera_rot = managers.viewport:get_current_camera_rotation()

    if not camera_rot then
        return
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
    local states = entries.states
    local nr_entries = #states
    local context = scratch.context
    local world = World

    context.cam_pos = cam_pos
    context.chk_vis_func = pl_tracker and pl_tracker.check_visibility
    context.com = entries.com
    context.direction = scratch.direction
    context.gfx_lod_data = gfx_lod_data
    context.nr_entries = nr_entries
    context.occ_skip_units = managers.occlusion._skip_occlusion
    context.pl_fwd = scratch.pl_fwd
    context.pl_tracker = pl_tracker
    context.states = states
    context.trackers = entries.trackers
    context.unit_occluded = Unit.occluded
    context.units = entries.units
    context.world = world
    context.world_in_view_with_options = world.in_view_with_options

    return context
end

function AIOverdrive:_prepare_gfx_lod_priority_context(manager, context)
    local gfx_lod_data = context.gfx_lod_data
    local anim_lod = managers.user:get_setting("video_animation_lod")
    local lod_counts = manager._nr_i_lod[anim_lod]

    context.anim_lod = anim_lod
    context.imp_i_list = gfx_lod_data.prio_i
    context.imp_wgt_list = gfx_lod_data.prio_weights
    context.nr_lod_1 = lod_counts[1]
    context.nr_lod_total = lod_counts[1] + lod_counts[2]
end

function AIOverdrive:_activate_gfx_lod_entries_in_view(context)
    local states = context.states
    local units = context.units
    local world = context.world
    local world_in_view_with_options = context.world_in_view_with_options
    local pl_tracker = context.pl_tracker
    local chk_vis_func = context.chk_vis_func
    local unit_occluded = context.unit_occluded
    local occ_skip_units = context.occ_skip_units

    for i, state in ipairs(states) do
        local unit = units[i]

        if not state
            and alive(unit)
            and world_in_view_with_options(
                world,
                context.com[i],
                0,
                110,
                18000
            )
        then
            local occlusion_skipped = occ_skip_units[unit:key()]

            if occlusion_skipped
                or (
                    (not pl_tracker or chk_vis_func(pl_tracker, context.trackers[i]))
                    and not unit_occluded(unit)
                )
            then
                states[i] = 1
                unit:base():set_visibility_state(1)
            end
        end
    end
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

function AIOverdrive:_refresh_next_gfx_lod_priority_entry(manager, context)
    local nr_entries = context.nr_entries

    if nr_entries == 0 then
        return false
    end

    local gfx_lod_data = context.gfx_lod_data
    local i = gfx_lod_data.next_chk_prio_i

    if nr_entries < i then
        i = 1
    end

    local start_i = i

    repeat
        if self:_refresh_gfx_lod_priority_entry(manager, context, i) then
            gfx_lod_data.next_chk_prio_i = i + 1

            return true
        end

        i = i == nr_entries and 1 or i + 1
    until i == start_i

    return false
end

function AIOverdrive:update_gfx_lod(manager, scratch)
    local context = self:_prepare_gfx_lod_context(manager, scratch)

    if not context then
        return
    end

    self:_activate_gfx_lod_entries_in_view(context)
    context.nr_entries = #context.states

    if context.nr_entries == 0 then
        return
    end

    self:_prepare_gfx_lod_priority_context(manager, context)
    self:_refresh_next_gfx_lod_priority_entry(manager, context)
end

function AIOverdrive:continue_gfx_lod_priority_updates(manager, scratch)
    local context = self:_prepare_gfx_lod_context(manager, scratch)

    if not context then
        return 0
    end

    local nr_entries = context.nr_entries

    if nr_entries <= 1 then
        return 0
    end

    self:_prepare_gfx_lod_priority_context(manager, context)

    local gfx_lod_data = context.gfx_lod_data
    local next_i = gfx_lod_data.next_chk_prio_i

    if nr_entries < next_i then
        next_i = 1
    end

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

    Hooks:OverrideFunction(
        enemy_manager,
        "_update_gfx_lod",
        function(manager)
            ai_overdrive:update_gfx_lod(manager, scratch)
        end
    )

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

local function _attention_angle_check(
    movement,
    my_head_fwd,
    my_pos,
    detection,
    attention_pos,
    dis,
    strictness
)
    mvec3_dir(attention_tmp_vec1, my_pos, attention_pos)

    if not my_head_fwd then
        my_head_fwd = movement:m_head_rot():z()
    end

    local angle = mvec3_angle(my_head_fwd, attention_tmp_vec1)
    local angle_max = math.lerp(
        180,
        detection.angle_max,
        math.clamp((dis - 150) / 700, 0, 1)
    )

    if angle_max > angle * strictness then
        return true, my_head_fwd
    end

    return nil, my_head_fwd
end

local function _attention_angle_and_distance_check(
    movement,
    my_head_fwd,
    my_pos,
    detection,
    handler,
    settings,
    attention_pos
)
    attention_pos = attention_pos or handler:get_detection_m_pos()

    local dis = mvec3_dir(attention_tmp_vec1, my_pos, attention_pos)
    local max_dis = math.min(
        detection.dis_max,
        settings.max_range or detection.dis_max
    )
    local settings_detection = settings.detection

    if settings_detection and settings_detection.range_mul then
        max_dis = max_dis * settings_detection.range_mul
    end

    local dis_multiplier = dis / max_dis

    if settings.uncover_range
        and detection.use_uncover_range
        and dis < settings.uncover_range
    then
        return -1, 0, my_head_fwd
    end

    if dis_multiplier < 1 then
        if settings.notice_requires_FOV then
            if not my_head_fwd then
                my_head_fwd = movement:m_head_rot():z()
            end

            local angle = mvec3_angle(my_head_fwd, attention_tmp_vec1)

            if angle < 55
                and not detection.use_uncover_range
                and settings.uncover_range
                and dis < settings.uncover_range
            then
                return -1, 0, my_head_fwd
            end

            local angle_max = math.lerp(
                180,
                detection.angle_max,
                math.clamp((dis - 150) / 700, 0, 1)
            )
            local angle_multiplier = angle / angle_max

            if angle_multiplier < 1 then
                return angle, dis_multiplier, my_head_fwd
            end
        else
            return 0, dis_multiplier, my_head_fwd
        end
    end

    return nil, nil, my_head_fwd
end

local function _attention_nearly_visible_check(
    attention_info,
    detect_pos,
    my_pos,
    visibility_slotmask,
    world
)
    local near_pos = attention_tmp_vec1
    local max_distance = 2000

    if max_distance > attention_info.verified_dis
        and math.abs(detect_pos.z - my_pos.z) < 300
    then
        mvec3_set(near_pos, detect_pos)

        local height_over_target = math.lerp(
            100,
            10,
            math.max(attention_info.verified_dis / max_distance)
        )

        mvec3_set_z(near_pos, near_pos.z + height_over_target)

        local near_vis_ray = world:raycast(
            "ray",
            my_pos,
            near_pos,
            "slot_mask",
            visibility_slotmask,
            "ray_type",
            "ai_vision",
            "report"
        )

        if near_vis_ray then
            local side_vec = attention_tmp_vec1

            mvec3_set(side_vec, detect_pos)
            mvec3_sub(side_vec, my_pos)
            mvec3_cross(side_vec, side_vec, math.UP)
            mvec3_set_length(side_vec, 150)
            mvec3_set(near_pos, detect_pos)
            mvec3_add(near_pos, side_vec)

            local near_vis_ray = world:raycast(
                "ray",
                my_pos,
                near_pos,
                "slot_mask",
                visibility_slotmask,
                "ray_type",
                "ai_vision",
                "report"
            )

            if near_vis_ray then
                mvec3_mul(side_vec, -2)
                mvec3_add(near_pos, side_vec)

                near_vis_ray = world:raycast(
                    "ray",
                    my_pos,
                    near_pos,
                    "slot_mask",
                    visibility_slotmask,
                    "ray_type",
                    "ai_vision",
                    "report"
                )
            end
        end

        if not near_vis_ray then
            attention_info.nearly_visible = true
            attention_info.last_verified_pos = mvec3_copy(near_pos)
        end
    end
end

local function _record_acquired_attention_importance_weight(
    player_importance_wgt,
    attention_info,
    attention_unit,
    attention_movement,
    my_pos
)
    if not player_importance_wgt or not attention_info.is_human_player then
        return
    end

    attention_movement = attention_movement or attention_unit:movement()

    local weight = mvec3_dir(
        attention_tmp_vec1,
        attention_info.m_head_pos,
        my_pos
    )
    local e_fwd = attention_movement:detect_look_dir()
    local dot = mvec3_dot(e_fwd, attention_tmp_vec1)

    weight = weight * weight * (1 - dot)

    local report_index = #player_importance_wgt

    player_importance_wgt[report_index + 1] = attention_info.u_key
    player_importance_wgt[report_index + 2] = weight
end

local function _record_attention_object_importance_weight(
    player_importance_wgt,
    u_key,
    attention_info,
    my_pos
)
    if not player_importance_wgt then
        return
    end

    local attention_unit = attention_info.unit
    local attention_base = attention_unit:base()
    local is_local_player
    local is_husk_player

    if attention_base then
        is_local_player = attention_base.is_local_player
        is_husk_player = not is_local_player and attention_base.is_husk_player
    end

    if not (is_local_player or is_husk_player) then
        return
    end

    local weight = mvec3_dir(
        attention_tmp_vec1,
        attention_info.handler:get_detection_m_pos(),
        my_pos
    )
    local attention_movement = attention_unit:movement()
    local e_fwd = attention_movement:detect_look_dir()
    local dot = mvec3_dot(e_fwd, attention_tmp_vec1)

    weight = weight * weight * (1 - dot)

    local report_index = #player_importance_wgt

    player_importance_wgt[report_index + 1] = u_key
    player_importance_wgt[report_index + 2] = weight
end

local function _upd_attention_obj_detection(data, min_reaction, max_reaction)
    local t = data.t
    local detected_obj = data.detected_attention_objects
    local my_data = data.internal_data
    local my_key = data.key
    local my_unit = data.unit
    local movement = my_unit:movement()
    local my_pos = movement:m_head_pos()
    local my_access = data.SO_access
    local team = data.team
    local group_state = managers.groupai:state()
    local all_attention_objects = group_state:get_AI_attention_objects_by_filter(
        data.SO_access_str,
        team
    )
    local my_head_fwd
    local my_tracker = movement:nav_tracker()
    local chk_vis_func = my_tracker.check_visibility
    local is_detection_persistent = group_state:is_detection_persistent()
    local delay = 2
    local player_importance_wgt =
        my_unit:in_slot(managers.slot:get_mask("enemies")) and {}
    local detection = my_data.detection
    local visibility_slotmask = data.visibility_slotmask
    local world = World
    local cop_logic_base = CopLogicBase

    for u_key, attention_info in pairs(all_attention_objects) do
        if u_key ~= my_key
            and not detected_obj[u_key]
            and (
                not attention_info.nav_tracker
                or chk_vis_func(my_tracker, attention_info.nav_tracker)
            )
        then
            local settings = attention_info.handler:get_attention(
                my_access,
                min_reaction,
                max_reaction,
                team
            )

            if settings then
                local acquired
                local attention_pos =
                    attention_info.handler:get_detection_m_pos()
                local angle
                local dis_multiplier

                angle, dis_multiplier, my_head_fwd =
                    _attention_angle_and_distance_check(
                        movement,
                        my_head_fwd,
                        my_pos,
                        detection,
                        attention_info.handler,
                        settings,
                        attention_pos
                    )

                if angle then
                    local vis_ray = world:raycast(
                        "ray",
                        my_pos,
                        attention_pos,
                        "slot_mask",
                        visibility_slotmask,
                        "ray_type",
                        "ai_vision"
                    )

                    if not vis_ray or vis_ray.unit:key() == u_key then
                        acquired = true
                        detected_obj[u_key] =
                            cop_logic_base._create_detected_attention_object_data(
                                t,
                                my_unit,
                                u_key,
                                attention_info,
                                settings
                            )
                    end
                end

                if not acquired then
                    _record_attention_object_importance_weight(
                        player_importance_wgt,
                        u_key,
                        attention_info,
                        my_pos
                    )
                end
            end
        end
    end

    for u_key, attention_info in pairs(detected_obj) do
        local attention_unit = attention_info.unit
        local attention_movement

        if t < attention_info.next_verify_t then
            if attention_info.reaction >= AIAttentionObject.REACT_SUSPICIOUS then
                delay = math.min(attention_info.next_verify_t - t, delay)
            end
        else
            attention_info.next_verify_t = t
                + (
                    attention_info.identified
                    and attention_info.verified
                    and attention_info.settings.verification_interval
                    or attention_info.settings.notice_interval
                    or attention_info.settings.verification_interval
                )
            delay = math.min(
                delay,
                attention_info.settings.verification_interval
            )

            if not attention_info.identified then
                local noticable
                local angle
                local dis_multiplier

                angle, dis_multiplier, my_head_fwd =
                    _attention_angle_and_distance_check(
                        movement,
                        my_head_fwd,
                        my_pos,
                        detection,
                        attention_info.handler,
                        attention_info.settings
                    )

                if angle then
                    local attention_pos =
                        attention_info.handler:get_detection_m_pos()
                    local vis_ray = world:raycast(
                        "ray",
                        my_pos,
                        attention_pos,
                        "slot_mask",
                        visibility_slotmask,
                        "ray_type",
                        "ai_vision"
                    )

                    if not vis_ray or vis_ray.unit:key() == u_key then
                        noticable = true
                    end
                end

                local delta_prog
                local dt = t - attention_info.prev_notice_chk_t

                if noticable then
                    if angle == -1 then
                        if attention_info.is_husk_player then
                            local peer = managers.network:session():peer_by_unit(
                                attention_unit
                            )
                            local latency =
                                peer and Network:qos(peer:rpc()).ping or nil

                            if latency then
                                delta_prog = dt / (latency / 1000) + 0.02
                            else
                                delta_prog = 0
                            end
                        else
                            delta_prog = 1
                        end
                    else
                        local min_delay = detection.delay[1]
                        local max_delay = detection.delay[2]
                        local angle_mul_mod = 0.25
                            * math.min(angle / detection.angle_max, 1)
                        local dis_mul_mod = 0.75 * dis_multiplier
                        local notice_delay_mul =
                            attention_info.settings.notice_delay_mul or 1
                        local settings_detection =
                            attention_info.settings.detection

                        if settings_detection
                            and settings_detection.delay_mul
                        then
                            notice_delay_mul = notice_delay_mul
                                * settings_detection.delay_mul
                        end

                        local notice_delay_modified = math.lerp(
                            min_delay * notice_delay_mul,
                            max_delay,
                            dis_mul_mod + angle_mul_mod
                        )

                        if attention_info.is_husk_player then
                            local peer = managers.network:session():peer_by_unit(
                                attention_unit
                            )
                            local latency =
                                peer and Network:qos(peer:rpc()).ping or nil

                            if latency then
                                notice_delay_modified =
                                    notice_delay_modified
                                    + latency / 1000
                                    + 0.02
                            else
                                delta_prog = 0
                            end
                        end

                        delta_prog = delta_prog
                            or notice_delay_modified > 0
                                and dt / notice_delay_modified
                            or 1
                    end
                else
                    delta_prog = dt * -0.125
                end

                attention_info.notice_progress =
                    attention_info.notice_progress + delta_prog

                if attention_info.notice_progress > 1 then
                    attention_info.notice_progress = nil
                    attention_info.prev_notice_chk_t = nil
                    attention_info.identified = true
                    attention_info.release_t =
                        t + attention_info.settings.release_delay
                    attention_info.identified_t = t
                    noticable = true

                    data.logic.on_attention_obj_identified(
                        data,
                        u_key,
                        attention_info
                    )
                elseif attention_info.notice_progress < 0 then
                    cop_logic_base._destroy_detected_attention_object_data(
                        data,
                        attention_info
                    )

                    noticable = false
                else
                    noticable = attention_info.notice_progress
                    attention_info.prev_notice_chk_t = t

                    if data.cool
                        and attention_info.settings.reaction
                            >= AIAttentionObject.REACT_SCARED
                    then
                        group_state:on_criminal_suspicion_progress(
                            attention_unit,
                            my_unit,
                            noticable
                        )
                    end
                end

                if noticable ~= false
                    and attention_info.settings.notice_clbk
                then
                    attention_info.settings.notice_clbk(my_unit, noticable)
                end
            end

            if attention_info.identified then
                delay = math.min(
                    delay,
                    attention_info.settings.verification_interval
                )
                attention_info.nearly_visible = nil

                local verified
                local vis_ray
                local attention_pos =
                    attention_info.handler:get_detection_m_pos()
                local dis = mvec3_dis(data.m_pos, attention_info.m_pos)

                if dis < detection.dis_max * 1.2
                    and (
                        not attention_info.settings.max_range
                        or dis
                            < attention_info.settings.max_range
                                * (
                                    attention_info.settings.detection
                                    and attention_info.settings.detection.range_mul
                                    or 1
                                )
                                * 1.2
                    )
                then
                    local detect_pos

                    if attention_info.is_husk_player
                        and attention_unit:anim_data().crouch
                    then
                        detect_pos = attention_tmp_vec1

                        mvec3_set(detect_pos, attention_info.m_pos)
                        mvec3_add(
                            detect_pos,
                            tweak_data.player.stances.default.crouched.head.translation
                        )
                    else
                        detect_pos = attention_pos
                    end

                    local in_FOV =
                        not attention_info.settings.notice_requires_FOV

                    if not in_FOV
                        and data.enemy_slotmask
                        and attention_unit:in_slot(data.enemy_slotmask)
                    then
                        in_FOV = true
                    end

                    if not in_FOV then
                        in_FOV, my_head_fwd = _attention_angle_check(
                            movement,
                            my_head_fwd,
                            my_pos,
                            detection,
                            attention_pos,
                            dis,
                            0.8
                        )
                    end

                    if in_FOV then
                        vis_ray = world:raycast(
                            "ray",
                            my_pos,
                            detect_pos,
                            "slot_mask",
                            visibility_slotmask,
                            "ray_type",
                            "ai_vision"
                        )

                        if not vis_ray or vis_ray.unit:key() == u_key then
                            verified = true
                        end
                    end

                    attention_info.verified = verified
                end

                attention_info.dis = dis
                attention_info.vis_ray = vis_ray and vis_ray.dis or nil

                local is_ignored = false

                attention_movement = attention_unit:movement()

                if attention_movement and attention_movement.is_cuffed then
                    is_ignored = attention_movement:is_cuffed()
                end

                if is_ignored then
                    cop_logic_base._destroy_detected_attention_object_data(
                        data,
                        attention_info
                    )
                elseif verified then
                    attention_info.release_t = nil
                    attention_info.verified_t = t

                    mvec3_set(attention_info.verified_pos, attention_pos)

                    attention_info.last_verified_pos =
                        mvec3_copy(attention_pos)
                    attention_info.verified_dis = dis
                elseif data.enemy_slotmask
                    and attention_unit:in_slot(data.enemy_slotmask)
                then
                    if attention_info.criminal_record
                        and attention_info.settings.reaction
                            >= AIAttentionObject.REACT_COMBAT
                    then
                        if not is_detection_persistent
                            and mvec3_dis(
                                attention_pos,
                                attention_info.criminal_record.pos
                            ) > 700
                        then
                            cop_logic_base._destroy_detected_attention_object_data(
                                data,
                                attention_info
                            )
                        else
                            delay = math.min(0.2, delay)
                            attention_info.verified_pos =
                                mvec3_copy(
                                    attention_info.criminal_record.pos
                                )
                            attention_info.verified_dis = dis

                            if vis_ray
                                and data.logic._chk_nearly_visible_chk_needed(
                                    data,
                                    attention_info,
                                    u_key
                                )
                            then
                                _attention_nearly_visible_check(
                                    attention_info,
                                    attention_pos,
                                    my_pos,
                                    visibility_slotmask,
                                    world
                                )
                            end
                        end
                    elseif attention_info.release_t
                        and t > attention_info.release_t
                    then
                        cop_logic_base._destroy_detected_attention_object_data(
                            data,
                            attention_info
                        )
                    else
                        attention_info.release_t =
                            attention_info.release_t
                            or t + attention_info.settings.release_delay
                    end
                elseif attention_info.release_t
                    and t > attention_info.release_t
                then
                    cop_logic_base._destroy_detected_attention_object_data(
                        data,
                        attention_info
                    )
                else
                    attention_info.release_t =
                        attention_info.release_t
                        or t + attention_info.settings.release_delay
                end
            end
        end

        _record_acquired_attention_importance_weight(
            player_importance_wgt,
            attention_info,
            attention_unit,
            attention_movement,
            my_pos
        )
    end

    if player_importance_wgt then
        group_state:set_importance_weight(my_key, player_importance_wgt)
    end

    return delay
end

function AIOverdrive:patch_cop_logic_base_attention_detection(cop_logic_base)
    if self._cop_logic_base_attention_detection_patch_target == cop_logic_base then
        return
    end

    Hooks:OverrideFunction(
        cop_logic_base,
        "_upd_attention_obj_detection",
        _upd_attention_obj_detection
    )

    self._cop_logic_base_attention_detection_patch_target = cop_logic_base
end

function AIOverdrive:patch_cop_logic_base_queue_task(cop_logic_base)
    if self._cop_logic_base_queue_task_patch_target == cop_logic_base then
        return
    end

    local ai_overdrive = self

    Hooks:OverrideFunction(cop_logic_base, "queue_task", function(internal_data, id, func, data, exec_t, asap)
        if internal_data.unit
            and internal_data
                ~= internal_data.unit:brain()._logic_data.internal_data
        then
            debug_pause(
                "[CopLogicBase.queue_task] Task queued from the wrong logic",
                internal_data.unit,
                id,
                func,
                data,
                exec_t,
                asap
            )
        end

        local queued_tasks = internal_data.queued_tasks

        if queued_tasks then
            internal_data._ai_overdrive_queued_tasks_cache = queued_tasks

            if queued_tasks[id] then
                cop_logic_base.unqueue_task(internal_data, id)
            end
        end

        queued_tasks = internal_data.queued_tasks

        if not queued_tasks then
            queued_tasks = internal_data._ai_overdrive_queued_tasks_cache

            if not queued_tasks or next(queued_tasks) then
                queued_tasks = {}
                internal_data._ai_overdrive_queued_tasks_cache = queued_tasks
            end

            internal_data.queued_tasks = queued_tasks
        end

        queued_tasks[id] = true

        if ai_overdrive:is_logic_decision_update(func, data) then
            internal_data._ai_overdrive_decision_update_id = id
        end

        local verification_clbk =
            internal_data._ai_overdrive_queue_verification_clbk

        if not verification_clbk then
            verification_clbk = callback(
                cop_logic_base,
                cop_logic_base,
                "on_queued_task",
                internal_data
            )
            internal_data._ai_overdrive_queue_verification_clbk =
                verification_clbk
        end

        return managers.enemy:queue_task(
            id,
            func,
            data,
            exec_t,
            verification_clbk,
            asap
        )
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
