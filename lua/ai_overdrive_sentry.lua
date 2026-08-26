local AIOverdrive = assert(
    _G.AIOverdrive
        and _G.AIOverdrive._core_loaded
        and _G.AIOverdrive._runtime_loaded
        and _G.AIOverdrive,
    "AI Overdrive sentry runtime loaded before its gameplay runtime"
)

if AIOverdrive._sentry_runtime_loaded then
    return AIOverdrive
end

local mvec3_add = mvector3.add
local mvec3_cross = mvector3.cross
local mvec3_dir = mvector3.direction
local mvec3_dist_sq = mvector3.distance_sq
local mvec3_dot = mvector3.dot
local mvec3_mul = mvector3.multiply
local mvec3_norm = mvector3.normalize
local mvec3_set = mvector3.set
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract
local mvec3_z = mvector3.z
local math_max = math.max

AIOverdrive._sentry_gun_brain_patch_targets =
    AIOverdrive._sentry_gun_brain_patch_targets
    or setmetatable({}, { __mode = "k" })

local function sentry_scratch(brain)
    local scratch = brain._ai_overdrive_sentry_scratch

    if not scratch then
        scratch = {
            current_fwd = Vector3(),
            direction = Vector3(),
            shield_ignore_units = {
                brain._unit
            },
            shield_target_pos = Vector3(),
            sight_direction = Vector3(),
            sight_ignore_units = {
                brain._unit
            },
            sight_offset = Vector3(),
            sight_target_pos = Vector3(),
            sight_target_same_height = Vector3()
        }
        brain._ai_overdrive_sentry_scratch = scratch
    else
        scratch.shield_ignore_units[1] = brain._unit
        scratch.shield_ignore_units[2] = nil
        scratch.sight_ignore_units[1] = brain._unit
        scratch.sight_ignore_units[2] = nil
    end

    return scratch
end

local function shield_blocks_attention(
    brain,
    scratch,
    ignore_units,
    my_pos,
    attention
)
    if brain._ap_bullets then
        return false
    end

    if attention and attention.unit then
        local shield_target_pos = scratch.shield_target_pos

        mvec3_set(shield_target_pos, attention.unit:position())
        mvec3_set_z(shield_target_pos, mvec3_z(shield_target_pos) + 50)

        return World:raycast(
            "ray",
            my_pos,
            shield_target_pos,
            "ignore_unit",
            ignore_units,
            "slot_mask",
            brain._shield_check
        ) and true or false
    end

    return false
end

local function attention_base_weight(
    scratch,
    attention_info,
    t,
    current_pos,
    current_fwd,
    max_dis
)
    local total_weight = 1

    if attention_info.health_ratio
        and attention_info.unit:character_damage():health_ratio() <= 0
    then
        return 0
    elseif attention_info.verified_t and t - attention_info.verified_t < 3
    then
        local elapsed_t = t - attention_info.verified_t

        total_weight = total_weight
            * math.lerp(1, 0.6, elapsed_t / 3)
    else
        return 0
    end

    if attention_info.settings.weight_mul then
        total_weight = total_weight * attention_info.settings.weight_mul
    end

    local dis = mvec3_dir(
        scratch.direction,
        current_pos,
        attention_info.m_head_pos
    )
    local dis_weight = math_max(0, (max_dis - dis) / max_dis)

    total_weight = total_weight * dis_weight

    local dot_weight = 1 + mvec3_dot(scratch.direction, current_fwd)

    dot_weight = dot_weight * dot_weight * dot_weight

    return total_weight * dot_weight
end

local function select_focus_attention(brain, t)
    local scratch = sentry_scratch(brain)
    local current_focus = brain._attention_obj
    local current_pos = brain._ext_movement:m_head_pos()
    local current_fwd

    if current_focus then
        current_fwd = scratch.current_fwd

        mvec3_dir(
            current_fwd,
            brain._ext_movement:m_head_pos(),
            current_focus.m_head_pos
        )
    else
        current_fwd = brain._ext_movement:m_head_fwd()
    end

    local detected_attention_objects = brain._detected_attention_objects
    local best_focus_reaction = 0

    for _, attention_info in pairs(detected_attention_objects) do
        if attention_info.identified
            and best_focus_reaction < attention_info.reaction
        then
            best_focus_reaction = attention_info.reaction
        end
    end

    local max_dis = brain._tweak_data.DETECTION_RANGE
    local best_focus_attention
    local best_focus_weight
    local best_focus_shielded

    for _, attention_info in pairs(detected_attention_objects) do
        if attention_info.identified
            and attention_info.reaction == best_focus_reaction
        then
            local base_weight = attention_base_weight(
                scratch,
                attention_info,
                t,
                current_pos,
                current_fwd,
                max_dis
            )

            if not best_focus_weight
                or best_focus_weight < base_weight
                or base_weight < 0
            then
                local shielded = shield_blocks_attention(
                    brain,
                    scratch,
                    scratch.shield_ignore_units,
                    current_pos,
                    attention_info
                )
                local weight = shielded and base_weight * 0.01
                    or base_weight

                if not best_focus_weight or best_focus_weight < weight then
                    best_focus_weight = weight
                    best_focus_attention = attention_info
                    best_focus_shielded = shielded
                end
            end
        end
    end

    brain._ai_overdrive_focus_shield_t = t
    brain._ai_overdrive_focus_shield_u_key = best_focus_attention
        and best_focus_attention.u_key
    brain._ai_overdrive_focus_shielded = best_focus_shielded and true or false
    brain._ai_overdrive_focus_shield_ap = brain._ap_bullets and true or false

    if current_focus ~= best_focus_attention then
        if best_focus_attention then
            brain._ext_movement:set_attention({
                unit = best_focus_attention.unit,
                u_key = best_focus_attention.u_key,
                handler = best_focus_attention.handler,
                reaction = best_focus_attention.reaction
            })
        else
            brain._ext_movement:set_attention()
        end

        brain._attention_obj = best_focus_attention
    end
end

local function focus_is_shielded(brain, scratch, t)
    local focus = brain._attention_obj

    if brain._ai_overdrive_focus_shield_t == t
        and brain._ai_overdrive_focus_shield_u_key
            == (focus and focus.u_key)
        and brain._ai_overdrive_focus_shield_ap
            == (brain._ap_bullets and true or false)
    then
        return brain._ai_overdrive_focus_shielded
    end

    return shield_blocks_attention(
        brain,
        scratch,
        scratch.shield_ignore_units,
        brain._ext_movement:m_head_pos(),
        brain._attention_obj
    )
end

local function update_fire(brain, t)
    if brain._ext_movement:is_activating()
        or brain._ext_movement:is_inactivating()
        or brain._idle
    then
        if brain._firing then
            brain:stop_autofire()
        end

        return
    end

    local attention = brain._ext_movement:attention()

    if brain._unit:weapon():out_of_ammo() then
        if brain._unit:weapon():can_auto_reload() then
            if brain._firing then
                brain:stop_autofire()
            end

            if not brain._ext_movement:rearming() then
                brain._ext_movement:rearm()
            end
        elseif not brain._unit:base():waiting_for_refill() then
            brain:switch_off()
        end
    elseif brain._ext_movement:rearming() then
        brain._ext_movement:complete_rearming()
    elseif attention
        and attention.reaction
        and attention.reaction >= AIAttentionObject.REACT_SHOOT
        and not brain._ext_movement:warming_up(t)
        and not focus_is_shielded(brain, sentry_scratch(brain), t)
    then
        local expend_ammo = Network:is_server()
        local damage_player = attention.unit:base()
            and attention.unit:base().is_local_player
        local my_pos = brain._ext_movement:m_head_pos()
        local target_pos = brain:get_target_base_pos(attention)

        if not target_pos then
            brain:stop_autofire()

            return
        end

        if not brain:is_target_on_sight(my_pos, target_pos) then
            brain:stop_autofire()

            return
        end

        if brain._firing then
            brain._unit:weapon():trigger_held(
                false,
                expend_ammo,
                damage_player,
                attention.unit
            )
        else
            local direction = sentry_scratch(brain).direction

            mvec3_dir(direction, my_pos, target_pos)

            local max_dot = brain._tweak_data.KEEP_FIRE_ANGLE

            max_dot = math.min(
                0.99,
                1 - (1 - max_dot) * (brain._shaprness_mul or 1)
            )

            if max_dot
                < mvec3_dot(direction, brain._ext_movement:m_head_fwd())
            then
                brain._unit:weapon():start_autofire()
                brain._unit:weapon():trigger_held(
                    false,
                    expend_ammo,
                    damage_player,
                    attention.unit
                )

                brain._firing = true
            end
        end
    elseif brain._firing then
        brain:stop_autofire()
    end
end

local function target_is_on_sight(brain, my_pos, target_base_pos)
    if not target_base_pos then
        return false
    end

    local fire_range = brain._tweak_data.FIRE_RANGE

    if fire_range * fire_range < mvec3_dist_sq(my_pos, target_base_pos) then
        return false
    end

    local scratch = sentry_scratch(brain)
    local target_pos = scratch.sight_target_pos
    local ignore_units = scratch.sight_ignore_units

    mvec3_set(target_pos, target_base_pos)

    local vis_ray = World:raycast(
        "ray",
        my_pos,
        target_pos,
        "ignore_unit",
        ignore_units,
        "slot_mask",
        brain._visibility_slotmask,
        "ray_type",
        "ai_vision"
    )

    if not vis_ray then
        return true
    end

    local target_same_height = scratch.sight_target_same_height
    local direction = scratch.sight_direction
    local offset = scratch.sight_offset

    mvec3_set(target_same_height, target_base_pos)
    mvec3_set_z(target_same_height, mvec3_z(my_pos))
    mvec3_set(direction, my_pos)
    mvec3_sub(direction, target_same_height)
    mvec3_norm(direction)
    mvec3_cross(offset, direction, math.UP)
    mvec3_mul(offset, brain.attention_target_offset_hor)

    mvec3_set(target_pos, target_base_pos)
    mvec3_add(target_pos, offset)
    mvec3_set_z(
        target_pos,
        mvec3_z(target_pos) + brain.attention_target_offset_ver
    )

    vis_ray = World:raycast(
        "ray",
        my_pos,
        target_pos,
        "ignore_unit",
        ignore_units,
        "slot_mask",
        brain._visibility_slotmask,
        "ray_type",
        "ai_vision"
    )

    if not vis_ray then
        return true
    end

    mvec3_mul(offset, -1)
    mvec3_set(target_pos, target_base_pos)
    mvec3_add(target_pos, offset)
    mvec3_set_z(
        target_pos,
        mvec3_z(target_pos) + brain.attention_target_offset_ver
    )

    return not World:raycast(
        "ray",
        my_pos,
        target_pos,
        "ignore_unit",
        ignore_units,
        "slot_mask",
        brain._visibility_slotmask,
        "ray_type",
        "ai_vision"
    )
end

function AIOverdrive:patch_sentry_gun_brain(sentry_gun_brain)
    if self._sentry_gun_brain_patch_targets[sentry_gun_brain] then
        return
    end

    Hooks:OverrideFunction(
        sentry_gun_brain,
        "_select_focus_attention",
        select_focus_attention
    )
    Hooks:OverrideFunction(
        sentry_gun_brain,
        "_upd_fire",
        update_fire
    )
    Hooks:OverrideFunction(
        sentry_gun_brain,
        "is_target_on_sight",
        target_is_on_sight
    )
    Hooks:OverrideFunction(
        sentry_gun_brain,
        "_ignore_shield",
        function(brain, ignore_units, my_pos, attention)
            local scratch = sentry_scratch(brain)

            return shield_blocks_attention(
                brain,
                scratch,
                ignore_units or scratch.shield_ignore_units,
                my_pos,
                attention
            )
        end
    )

    self._sentry_gun_brain_patch_targets[sentry_gun_brain] = true
end

AIOverdrive._sentry_runtime_loaded = true

return AIOverdrive
