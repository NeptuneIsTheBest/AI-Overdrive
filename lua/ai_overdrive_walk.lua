local AIOverdrive = assert(
    _G.AIOverdrive
        and _G.AIOverdrive._core_loaded
        and _G.AIOverdrive._runtime_loaded
        and _G.AIOverdrive,
    "AI Overdrive walk runtime loaded before its gameplay runtime"
)

if AIOverdrive._walk_runtime_loaded then
    return AIOverdrive
end

local mvec3_set = mvector3.set
local mvec3_z = mvector3.z
local mvec3_set_z = mvector3.set_z
local mvec3_sub = mvector3.subtract
local mvec3_norm = mvector3.normalize
local mvec3_lerp = mvector3.lerp
local mvec3_dot = mvector3.dot
local mvec3_cross = mvector3.cross
local mvec3_dis = mvector3.distance
local mvec3_dis_sq = mvector3.distance_sq
local mvec3_len = mvector3.length
local mvec3_rot = mvector3.rotate_with
local mrot_lookat = mrotation.set_look_at
local mrot_slerp = mrotation.slerp
local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local tmp_vec1 = Vector3()
local tmp_vec2 = Vector3()
local tmp_vec3 = Vector3()
local tmp_vec4 = Vector3()
local spline_tmp_vec1 = Vector3()
local spline_tmp_vec2 = Vector3()
local temp_rot1 = Rotation()
local idstr_base = Idstring("base")

AIOverdrive._cop_action_walk_patch_targets =
    AIOverdrive._cop_action_walk_patch_targets
    or setmetatable({}, { __mode = "k" })

local function stable_spline_output(output, returned_pos)
    if not rawequal(output, returned_pos) then
        mvec3_set(output, returned_pos)
    end

    return output
end

function AIOverdrive._walk_spline_into(output, path, pos, index, walk_dis)
    while true do
        mvec3_set(spline_tmp_vec1, path[index + 1])
        mvec3_sub(spline_tmp_vec1, path[index])
        mvec3_set_z(spline_tmp_vec1, 0)

        local dis = mvec3_norm(spline_tmp_vec1)

        mvec3_set(spline_tmp_vec2, pos)
        mvec3_sub(spline_tmp_vec2, path[index])
        mvec3_set_z(spline_tmp_vec2, 0)

        local my_dis = mvec3_dot(spline_tmp_vec2, spline_tmp_vec1)

        if dis == 0 or dis <= my_dis + walk_dis and walk_dis >= 0 then
            if index == #path - 1 then
                mvec3_set(output, path[index + 1])

                return output, index, true
            end

            index = index + 1
        elseif my_dis + walk_dis < 0 and walk_dis < 0 then
            if index == 1 then
                mvec3_set(output, path[index])

                return output, index
            end

            index = index - 1
        else
            mvec3_lerp(
                output,
                path[index],
                path[index + 1],
                (walk_dis + my_dis) / dis
            )

            return output, index
        end
    end
end

function AIOverdrive._update_walk_action(self, t)
    local dt
    local vis_state = self._ext_base:lod_stage()

    vis_state = vis_state or 4
    self._skipped_frames = vis_state

    if vis_state == 1 then
        dt = t - self._last_upd_t
        self._last_upd_t = t
    elseif vis_state > self._skipped_frames then
        self._skipped_frames = self._skipped_frames + 1

        return
    else
        self._skipped_frames = 1
        dt = t - self._last_upd_t
        self._last_upd_t = t
    end

    if self._ik_update then
        self._ik_update(t)
    end

    if self._end_of_path and (not self._ext_anim.act or not self._ext_anim.walk) then
        if self._next_is_nav_link then
            self:_set_updator("_upd_nav_link_first_frame")
            self:update(t)

            return
        elseif self._persistent then
            self:_set_updator("_upd_wait")
        else
            self._expired = true

            if self._end_rot then
                self._ext_movement:set_rotation(self._end_rot)
            end
        end
    else
        self:_nav_chk_walk(t, dt, vis_state)
    end

    local move_dir = tmp_vec3

    mvec3_set(move_dir, self._last_pos)
    mvec3_sub(move_dir, self._common_data.pos)
    mvec3_set_z(move_dir, 0)

    if self._cur_vel < 0.1 or self._ext_anim.act and self._ext_anim.walk then
        move_dir = nil
    end

    local anim_data = self._ext_anim

    if move_dir and not self._expired then
        local face_fwd = tmp_vec1
        local wanted_walk_dir
        local move_dir_norm = move_dir

        mvec3_norm(move_dir_norm)

        if self._no_strafe or self._walk_turn then
            wanted_walk_dir = "fwd"
        else
            if self._curve_path_end_rot
                and mvector3.distance_sq(
                    self._last_pos,
                    self._footstep_pos
                ) < 19600
            then
                mvec3_set(face_fwd, self._common_data.fwd)
            elseif self._attention_pos then
                mvec3_set(face_fwd, self._attention_pos)
                mvec3_sub(face_fwd, self._common_data.pos)
            elseif self._footstep_pos then
                mvec3_set(face_fwd, self._footstep_pos)
                mvec3_sub(face_fwd, self._common_data.pos)
            else
                mvec3_set(face_fwd, self._common_data.fwd)
            end

            mvec3_set_z(face_fwd, 0)
            mvec3_norm(face_fwd)

            local face_right = tmp_vec2

            mvec3_cross(face_right, face_fwd, math.UP)
            mvec3_norm(face_right)

            local right_dot = mvec3_dot(move_dir_norm, face_right)
            local fwd_dot = mvec3_dot(move_dir_norm, face_fwd)

            if math_abs(fwd_dot) > math_abs(right_dot) then
                if (anim_data.move_l and right_dot < 0
                    or anim_data.move_r and right_dot > 0)
                    and math_abs(fwd_dot) < 0.73
                then
                    wanted_walk_dir = anim_data.move_side
                else
                    wanted_walk_dir = fwd_dot > 0 and "fwd" or "bwd"
                end
            elseif (anim_data.move_fwd and fwd_dot > 0
                or anim_data.move_bwd and fwd_dot < 0)
                and math_abs(right_dot) < 0.73
            then
                wanted_walk_dir = anim_data.move_side
            else
                wanted_walk_dir = right_dot > 0 and "r" or "l"
            end
        end

        local rot_new

        if self._curve_path_end_rot then
            local dis_lerp = 1 - math.min(
                1,
                mvec3_dis(self._last_pos, self._footstep_pos) / 140
            )

            rot_new = temp_rot1

            mrot_slerp(
                rot_new,
                self._curve_path_end_rot,
                self._nav_link_rot or self._end_rot,
                dis_lerp
            )
        else
            local wanted_u_fwd = tmp_vec1

            mvec3_set(wanted_u_fwd, move_dir_norm)
            mvec3_rot(wanted_u_fwd, self._walk_side_rot[wanted_walk_dir])
            mrot_lookat(temp_rot1, wanted_u_fwd, math.UP)

            rot_new = temp_rot1

            mrot_slerp(
                rot_new,
                self._common_data.rot,
                rot_new,
                math.min(1, dt * 5)
            )
        end

        self._ext_movement:set_rotation(rot_new)

        if self._chk_stop_dis
            and not self._was_interrupted
            and not self._common_data.char_tweak.no_run_stop
        then
            local end_dis = mvec3_dis(
                self._nav_point_pos(
                    self._simplified_path[#self._simplified_path]
                ),
                self._last_pos
            )

            if end_dis < self._chk_stop_dis then
                local stop_anim_fwd = not self._nav_link_rot
                    and self._end_rot
                    and self._end_rot:y()
                    or move_dir_norm:rotate_with(
                        self._walk_side_rot[wanted_walk_dir]
                    )
                local move_dir_r_norm = tmp_vec4

                mvec3_cross(move_dir_r_norm, move_dir_norm, math.UP)

                local fwd_dot = mvec3_dot(stop_anim_fwd, move_dir_norm)
                local r_dot = mvec3_dot(stop_anim_fwd, move_dir_r_norm)
                local stop_anim_side = math.abs(fwd_dot) > math.abs(r_dot)
                    and (fwd_dot > 0 and "fwd" or "bwd")
                    or r_dot > 0 and "l" or "r"
                local stop_pose

                if self._action_desc.end_pose then
                    stop_pose = self._action_desc.end_pose
                else
                    stop_pose = self._ext_anim.pose or self._fallback_pose
                end

                if stop_pose ~= self._ext_anim.pose then
                    local pose_redir_res =
                        self._ext_movement:play_redirect(stop_pose)

                    if not pose_redir_res then
                        debug_pause_unit(
                            self._unit,
                            "STOP POSE FAIL!!!",
                            self._unit,
                            stop_pose
                        )
                    end
                end

                local stop_dis = self._anim_movement[stop_pose]
                    ["run_stop_" .. stop_anim_side]

                if stop_dis and end_dis < stop_dis then
                    self._stop_anim_side = stop_anim_side
                    self._stop_anim_fwd = stop_anim_fwd
                    self._stop_dis = stop_dis

                    self:_set_updator("_upd_stop_anim_first_frame")
                end
            end
        elseif self._walk_turn and not self._chk_stop_dis then
            local end_dis = mvec3_dis(
                self._curve_path[self._curve_path_index + 1],
                self._last_pos
            )

            if end_dis < 45 then
                self:_set_updator("_upd_walk_turn_first_frame")
            end
        end

        local pose = self._stance.values[4] > 0
            and "wounded"
            or self._ext_anim.pose
            or self._fallback_pose
        local real_velocity = self._cur_vel
        local variant = self._haste

        if variant == "run" and not self._no_walk then
            if self._ext_anim.sprint then
                if real_velocity > 480 and self._ext_anim.pose == "stand" then
                    variant = "sprint"
                elseif real_velocity > 250 then
                    variant = "run"
                else
                    variant = "walk"
                end
            elseif self._ext_anim.run then
                if not self._walk_anim_velocities[pose] then
                    debug_pause_unit(
                        self._unit,
                        "No walk anim velocities for pose:",
                        pose,
                        inspect(self._walk_anim_velocities),
                        self._unit
                    )
                elseif not self._walk_anim_velocities[pose][self._stance.name]
                then
                    debug_pause_unit(
                        self._unit,
                        "No walk anim velocities for (pose, stance name):",
                        pose,
                        self._stance.name,
                        inspect(self._walk_anim_velocities),
                        inspect(self._walk_anim_velocities[pose]),
                        self._unit
                    )
                elseif real_velocity > 530
                    and self._walk_anim_velocities[pose]
                    and self._walk_anim_velocities[pose][self._stance.name]
                    and self._walk_anim_velocities[pose][self._stance.name].sprint
                    and self._ext_anim.pose == "stand"
                then
                    variant = "sprint"
                elseif real_velocity > 250 then
                    variant = "run"
                else
                    variant = "walk"
                end
            else
                variant = real_velocity > 530
                    and self._walk_anim_velocities[pose][self._stance.name].sprint
                    and self._ext_anim.pose == "stand"
                    and "sprint"
                    or real_velocity > 300 and "run"
                    or "walk"
            end
        end

        if not safe_get_value(
            self._walk_anim_velocities,
            pose,
            self._stance.name,
            variant,
            wanted_walk_dir
        ) then
            debug_pause(
                "Boom...",
                self._common_data.unit,
                "pose",
                pose,
                "stance",
                self._stance.name,
                "variant",
                variant,
                "wanted_walk_dir",
                wanted_walk_dir,
                self._machine:segment_state(idstr_base)
            )

            if not safe_get_value(
                self._walk_anim_velocities,
                pose,
                self._stance.name
            ) and self._stance.name == "ntl" then
                self._stance.name = "cbt"
            end

            while not safe_get_value(
                self._walk_anim_velocities,
                pose,
                self._stance.name,
                variant
            ) do
                if variant == "sprint" then
                    variant = "run"
                end

                if variant == "run" then
                    variant = "walk"
                end
            end

            if not safe_get_value(
                self._walk_anim_velocities,
                pose,
                self._stance.name,
                variant,
                wanted_walk_dir
            ) then
                return
            end
        end

        self:_adjust_move_anim(wanted_walk_dir, variant)

        local anim_walk_speed = self._walk_anim_velocities[pose]
            [self._stance.name][variant][wanted_walk_dir]
        local wanted_walk_anim_speed = real_velocity / anim_walk_speed

        self:_adjust_walk_anim_speed(dt, wanted_walk_anim_speed)
    end

    self:_set_new_pos(dt)
end

function AIOverdrive._nav_chk_walk_optimized(self, t, dt, vis_state)
    local s_path = self._simplified_path
    local c_path = self._curve_path
    local c_index = self._curve_path_index
    local vel

    if self._ext_anim.act and self._ext_anim.walk then
        local new_anim_pos = self._unit:get_animation_delta_position()
        local anim_displacement = mvector3.length(new_anim_pos)

        vel = anim_displacement / dt

        if vel == 0 then
            return
        end
    else
        vel = self:_get_current_max_walk_speed(
            self._ext_anim.move_side or "fwd"
        )
    end

    local walk_dis = vel * dt
    local footstep_length = 200
    local nav_advanced
    local cur_pos = self._common_data.pos
    local new_pos, new_c_index, complete, upd_footstep, reservation_failed

    while not self._end_of_curved_path do
        local footstep_pos = self._footstep_pos

        if not footstep_pos then
            footstep_pos = Vector3()
            self._footstep_pos = footstep_pos
        end

        new_pos, new_c_index, complete = self._walk_spline(
            c_path,
            self._last_pos,
            c_index,
            walk_dis + footstep_length,
            footstep_pos
        )
        new_pos = stable_spline_output(footstep_pos, new_pos)
        upd_footstep = true

        if complete then
            if #s_path == 2 then
                self._end_of_curved_path = true

                if self._end_rot and not self._persistent then
                    self._curve_path_end_rot = Rotation(
                        mrotation.yaw(self._common_data.rot),
                        0,
                        0
                    )
                end

                nav_advanced = true

                break
            elseif self._next_is_nav_link then
                self._end_of_curved_path = true
                self._nav_link_rot = Rotation(
                    self._next_is_nav_link.element:value("rotation"),
                    0,
                    0
                )
                self._curve_path_end_rot = Rotation(
                    mrotation.yaw(self._common_data.rot),
                    0,
                    0
                )

                break
            else
                self:_advance_simplified_path()

                local next_pos = self._nav_point_pos(s_path[2])

                if self._sync
                    and not self._action_desc.path_simplified
                    and not self._next_is_nav_link
                    and s_path[3]
                    and not self:_reserve_nav_pos(
                        next_pos,
                        self._nav_point_pos(s_path[3]),
                        self._nav_point_pos(c_path[#c_path]),
                        vel
                    )
                then
                end

                if not s_path[1].x then
                    debug_pause_unit(
                        self._unit,
                        "[CopActionWalk:_nav_chk_walk] missed nav_link",
                        self._unit,
                        inspect(s_path)
                    )

                    s_path[1] = self._nav_point_pos(s_path[1])
                end

                local dis_sq = mvec3_dis_sq(s_path[1], next_pos)
                local new_c_path

                if dis_sq > 490000
                    and not self._action_desc.path_simplified
                    and self._ext_base:lod_stage() == 1
                then
                    new_c_path = self:_calculate_curved_path(s_path, 1, 1)
                else
                    new_c_path = {
                        s_path[1],
                        next_pos
                    }
                end

                local i = #c_path - 1

                while c_index <= i do
                    table.insert(new_c_path, 1, c_path[i])

                    i = i - 1
                end

                self._curve_path = new_c_path
                self._curve_path_index = 1
                c_path = self._curve_path
                c_index = 1

                if self._sync then
                    self:_send_nav_point(next_pos)
                end

                nav_advanced = true
            end
        else
            break
        end
    end

    if upd_footstep then
        mvec3_set_z(self._footstep_pos, mvec3_z(cur_pos))
    end

    if not reservation_failed then
        local wanted_vel

        if self._turn_vel and vis_state == 1 then
            mvec3_set(tmp_vec1, c_path[c_index + 1])
            mvec3_set_z(tmp_vec1, mvec3_z(cur_pos))

            local dis = mvec3_dis_sq(tmp_vec1, cur_pos)

            if dis < 4900 then
                wanted_vel = math.lerp(self._turn_vel, vel, dis / 4900)
            end
        end

        wanted_vel = wanted_vel or vel

        if self._start_run then
            local delta_pos =
                self._common_data.unit:get_animation_delta_position()

            walk_dis = mvec3_len(delta_pos)
            self._cur_vel = walk_dis / dt
            self._cur_vel = math_min(
                self:_get_current_max_walk_speed(
                    self._ext_anim.move_side or "fwd"
                ),
                math_max(walk_dis / dt, self._start_max_vel)
            )

            if self._cur_vel < self._start_max_vel then
                self._cur_vel = self._start_max_vel
                walk_dis = self._cur_vel * dt
            else
                self._start_max_vel = self._cur_vel
            end
        else
            local c_vel = self._cur_vel

            if c_vel ~= wanted_vel then
                local adj = vel * (c_vel < wanted_vel and 1.5 or 4) * dt

                c_vel = math.step(c_vel, wanted_vel, adj)
                self._cur_vel = c_vel
            end

            walk_dis = c_vel * dt
        end

        local last_pos = self._last_pos

        new_pos, new_c_index, complete = self._walk_spline(
            c_path,
            last_pos,
            c_index,
            walk_dis,
            last_pos
        )
        new_pos = stable_spline_output(last_pos, new_pos)

        if complete then
            if self._next_is_nav_link then
                self._end_of_path = true

                if self._sync then
                    if alive(self._next_is_nav_link.c_class) then
                        local delay =
                            self._next_is_nav_link.element:nav_link_delay()

                        if delay > 0 then
                            self._next_is_nav_link.c_class:set_delay_time(
                                t + delay
                            )
                        end
                    else
                        debug_pause_unit(
                            self._unit,
                            "dead nav_link",
                            self._unit
                        )
                    end
                end
            elseif #s_path == 2 then
                self._end_of_path = true
            end
        elseif new_c_index ~= self._curve_path_index or nav_advanced then
            local future_pos = c_path[new_c_index + 2]
            local next_pos = c_path[new_c_index + 1]
            local back_pos = c_path[new_c_index]
            local cur_vec = tmp_vec2

            mvec3_set(cur_vec, next_pos)
            mvec3_sub(cur_vec, back_pos)
            mvec3_set_z(cur_vec, 0)

            if future_pos then
                mvec3_norm(cur_vec)

                local next_vec = tmp_vec1

                mvec3_set(next_vec, future_pos)
                mvec3_sub(next_vec, next_pos)
                mvec3_set_z(next_vec, 0)

                local future_dis_flat = mvec3_norm(next_vec)
                local turn_dot = mvec3_dot(cur_vec, next_vec)

                if self._haste ~= "run"
                    and turn_dot > -0.7
                    and turn_dot < 0.7
                    and not self._attention_pos
                    and future_dis_flat > 80
                    and self._common_data.stance.name == "ntl"
                    and mvec3_dot(self._common_data.fwd, cur_vec) > 0.97
                then
                    self._walk_turn = true
                else
                    turn_dot = turn_dot * turn_dot

                    local dot_lerp = math_max(0, turn_dot)
                    local turn_vel = math.lerp(
                        math.min(vel, 100),
                        self:_get_current_max_walk_speed(
                            self._ext_anim.move_side or "fwd"
                        ),
                        dot_lerp
                    )

                    self._turn_vel = turn_vel
                    self._walk_turn = nil
                end
            else
                if vis_state < 3
                    and self._end_of_curved_path
                    and self._ext_anim.run
                    and not self._was_interrupted
                    and not self._NO_RUN_STOP
                    and not self._no_walk
                    and not (
                        mvec3_dis(
                            c_path[new_c_index + 1],
                            new_pos
                        ) < 210
                    )
                then
                    self._chk_stop_dis = 210
                elseif self._chk_stop_dis then
                    self._chk_stop_dis = nil
                end

                self._walk_turn = nil
            end
        end

        self._curve_path_index = new_c_index
    end
end

function AIOverdrive:patch_cop_action_walk(cop_action_walk)
    if self._cop_action_walk_patch_targets[cop_action_walk] then
        return
    end

    local ai_overdrive = self
    local original_update = Hooks:GetFunction(cop_action_walk, "update")
    local original_nav_chk_walk =
        Hooks:GetFunction(cop_action_walk, "_nav_chk_walk")
    local original_walk_spline =
        Hooks:GetFunction(cop_action_walk, "_walk_spline")

    Hooks:OverrideFunction(
        cop_action_walk,
        "_walk_spline",
        function(path, pos, index, walk_dis, output)
            if output then
                return ai_overdrive._walk_spline_into(
                    output,
                    path,
                    pos,
                    index,
                    walk_dis
                )
            end

            return original_walk_spline(path, pos, index, walk_dis)
        end
    )

    Hooks:OverrideFunction(
        cop_action_walk,
        "_nav_chk_walk",
        function(action, t, dt, vis_state)
            if not ai_overdrive:every_frame_walking_enabled() then
                return original_nav_chk_walk(action, t, dt, vis_state)
            end

            return ai_overdrive._nav_chk_walk_optimized(
                action,
                t,
                dt,
                vis_state
            )
        end
    )

    Hooks:OverrideFunction(
        cop_action_walk,
        "update",
        function(action, t)
            if not ai_overdrive:every_frame_walking_enabled() then
                return original_update(action, t)
            end

            return ai_overdrive._update_walk_action(action, t)
        end
    )

    self._cop_action_walk_patch_targets[cop_action_walk] = true
end

AIOverdrive._walk_runtime_loaded = true

return AIOverdrive
