local AIOverdrive = assert(
    _G.AIOverdrive
        and _G.AIOverdrive._core_loaded
        and _G.AIOverdrive._runtime_loaded
        and _G.AIOverdrive,
    "AI Overdrive Group AI runtime loaded before its gameplay runtime"
)

if AIOverdrive._group_ai_runtime_loaded then
    return AIOverdrive
end

AIOverdrive._group_ai_besiege_patch_targets =
    AIOverdrive._group_ai_besiege_patch_targets
    or setmetatable({}, { __mode = "k" })

local function find_spawn_points_near_area(
    self,
    target_area,
    nr_wanted,
    target_pos,
    max_dis,
    verify_clbk
)
    local all_areas = self._area_data
    local all_nav_segs = managers.navigation._nav_segments
    local mvec3_dis = mvector3.distance
    local t = self._t
    local distances = {}
    local spawn_points_found = {}

    target_pos = target_pos or target_area.pos

    local to_search_areas = {
        target_area
    }
    local found_areas = {
        [target_area.id] = true
    }
    local search_index = 1

    repeat
        local search_area = to_search_areas[search_index]

        search_index = search_index + 1

        local spawn_points = search_area.spawn_points

        if spawn_points then
            for _, spawn_data in ipairs(spawn_points) do
                if t >= spawn_data.delay_t
                    and (not verify_clbk or verify_clbk(spawn_data))
                then
                    local my_dis = mvec3_dis(target_pos, spawn_data.pos)

                    if not max_dis or my_dis < max_dis then
                        local insert_index = #distances

                        while insert_index > 0 do
                            if my_dis > distances[insert_index] then
                                break
                            end

                            insert_index = insert_index - 1
                        end

                        if insert_index < #distances then
                            if #distances == nr_wanted then
                                distances[nr_wanted] = my_dis
                                spawn_points_found[nr_wanted] = spawn_data
                            else
                                table.remove(distances)
                                table.remove(spawn_points_found)
                                table.insert(
                                    distances,
                                    insert_index + 1,
                                    my_dis
                                )
                                table.insert(
                                    spawn_points_found,
                                    insert_index + 1,
                                    spawn_data
                                )
                            end
                        elseif insert_index < nr_wanted then
                            table.insert(distances, my_dis)
                            table.insert(spawn_points_found, spawn_data)
                        end
                    end
                end
            end
        end

        if #spawn_points_found == nr_wanted then
            break
        end

        for other_area_id, other_area in pairs(all_areas) do
            if not found_areas[other_area_id]
                and other_area.neighbours[search_area.id]
            then
                table.insert(to_search_areas, other_area)
                found_areas[other_area_id] = true
            end
        end
    until search_index > #to_search_areas

    return #spawn_points_found > 0 and spawn_points_found
end

local function make_dis_id(from, to)
    local first = from < to and from or to
    local second = to < from and from or to

    return tostring(first) .. "-" .. tostring(second)
end

local function spawn_group_id(spawn_group)
    return spawn_group.mission_element:id()
end

local function find_spawn_group_near_area(
    self,
    target_area,
    allowed_groups,
    target_pos,
    max_dis,
    verify_clbk
)
    local all_areas = self._area_data
    local mvec3_dis = mvector3.distance_sq

    max_dis = max_dis and max_dis * max_dis

    local t = self._t
    local valid_spawn_groups = {}
    local valid_spawn_group_distances = {}
    local total_dis = 0

    target_pos = target_pos or target_area.pos

    local to_search_areas = {
        target_area
    }
    local found_areas = {
        [target_area.id] = true
    }
    local search_index = 1

    repeat
        local search_area = to_search_areas[search_index]

        search_index = search_index + 1

        local spawn_groups = search_area.spawn_groups

        if spawn_groups then
            for _, spawn_group in ipairs(spawn_groups) do
                if t >= spawn_group.delay_t
                    and (not verify_clbk or verify_clbk(spawn_group))
                then
                    local distance_id = make_dis_id(
                        spawn_group.nav_seg,
                        target_area.pos_nav_seg
                    )

                    if not self._graph_distance_cache[distance_id] then
                        local coarse_params = {
                            access_pos = "swat",
                            from_seg = spawn_group.nav_seg,
                            to_seg = target_area.pos_nav_seg,
                            id = distance_id
                        }
                        local path = managers.navigation:search_coarse(
                            coarse_params
                        )

                        if path and #path >= 2 then
                            local distance = 0
                            local current = spawn_group.pos

                            for path_index = 2, #path do
                                local next_pos = path[path_index][2]

                                if current and next_pos then
                                    distance = distance
                                        + mvector3.distance(current, next_pos)
                                end

                                current = next_pos
                            end

                            self._graph_distance_cache[distance_id] = distance
                        end
                    end

                    if self._graph_distance_cache[distance_id] then
                        local my_dis =
                            self._graph_distance_cache[distance_id]

                        if not max_dis or my_dis < max_dis then
                            total_dis = total_dis + my_dis
                            valid_spawn_groups[
                                spawn_group_id(spawn_group)
                            ] = spawn_group
                            valid_spawn_group_distances[
                                spawn_group_id(spawn_group)
                            ] = my_dis
                        end
                    end
                end
            end
        end

        for other_area_id, other_area in pairs(all_areas) do
            if not found_areas[other_area_id]
                and other_area.neighbours[search_area.id]
            then
                table.insert(to_search_areas, other_area)
                found_areas[other_area_id] = true
            end
        end
    until search_index > #to_search_areas

    if not next(valid_spawn_group_distances) then
        return
    end

    if self._spawn_group_timers then
        for id in pairs(valid_spawn_groups) do
            local cooldown = self._spawn_group_timers[id]

            if cooldown and cooldown > self._t then
                valid_spawn_groups[id] = nil
                valid_spawn_group_distances[id] = nil
            end
        end
    end

    if total_dis == 0 then
        total_dis = 1
    end

    local total_weight = 0
    local candidate_groups = {}

    self._debug_weights = {}

    local dis_limit = tweak_data.group_ai.ai_spawn_distance_limit

    for id, distance in pairs(valid_spawn_group_distances) do
        local weight = math.lerp(
            1,
            0.2,
            math.min(1, distance / dis_limit)
        ) * 5
        local spawn_group = valid_spawn_groups[id]
        local group_types = spawn_group.mission_element:spawn_groups()

        spawn_group.distance = distance
        total_weight = total_weight + self:_choose_best_groups(
            candidate_groups,
            spawn_group,
            group_types,
            allowed_groups,
            weight
        )
    end

    if total_weight == 0 then
        return
    end

    for _, group in ipairs(candidate_groups) do
        table.insert(self._debug_weights, clone(group))
    end

    return self:_choose_best_group(candidate_groups, total_weight)
end

local function find_flee_point(self, start_nav_seg, ignore_segs)
    local start_area = self:get_area_from_nav_seg_id(start_nav_seg)
    local to_search_areas = {
        start_area
    }
    local found_areas = {
        [start_area] = true
    }
    local search_index = 1

    repeat
        local search_area = to_search_areas[search_index]

        search_index = search_index + 1

        if search_area.flee_points and next(search_area.flee_points) then
            local _, flee_point = next(search_area.flee_points)

            if not ignore_segs
                or not table.contains(ignore_segs, flee_point.nav_seg)
            then
                return flee_point.pos
            end
        else
            for _, other_area in pairs(search_area.neighbours) do
                if not found_areas[other_area] then
                    table.insert(to_search_areas, other_area)
                    found_areas[other_area] = true
                end
            end
        end
    until search_index > #to_search_areas
end

local function find_safe_flee_point(self, start_nav_seg, ignore_segs)
    local start_area = self:get_area_from_nav_seg_id(start_nav_seg)

    if next(start_area.criminal.units) then
        return
    end

    local to_search_areas = {
        start_area
    }
    local found_areas = {
        [start_area] = true
    }
    local search_index = 1

    repeat
        local search_area = to_search_areas[search_index]

        search_index = search_index + 1

        if search_area.flee_points and next(search_area.flee_points) then
            local _, flee_point = next(search_area.flee_points)

            if not ignore_segs
                or not table.contains(ignore_segs, flee_point.nav_seg)
            then
                return flee_point
            end
        end

        for _, other_area in pairs(search_area.neighbours) do
            if not found_areas[other_area]
                and not next(other_area.criminal.units)
            then
                table.insert(to_search_areas, other_area)
                found_areas[other_area] = true
            end
        end
    until search_index > #to_search_areas
end

local function find_safe_enemy_loot_drop_point(self, start_nav_seg)
    local start_area = self:get_area_from_nav_seg_id(start_nav_seg)

    if next(start_area.criminal.units) then
        return
    end

    local to_search_areas = {
        start_area
    }
    local found_areas = {
        [start_area] = true
    }
    local search_index = 1

    repeat
        local search_area = to_search_areas[search_index]

        search_index = search_index + 1

        if search_area.enemy_loot_drop_points
            and next(search_area.enemy_loot_drop_points)
        then
            local nr_drop_points = table.size(
                search_area.enemy_loot_drop_points
            )
            local lucky_drop_point = math.random(nr_drop_points)

            for _, drop_point in pairs(
                search_area.enemy_loot_drop_points
            ) do
                lucky_drop_point = lucky_drop_point - 1

                if lucky_drop_point == 0 then
                    return drop_point
                end
            end
        else
            for _, other_area in pairs(search_area.neighbours) do
                if not found_areas[other_area] then
                    table.insert(to_search_areas, other_area)
                    found_areas[other_area] = true
                end
            end
        end
    until search_index > #to_search_areas
end

local function set_recon_objective_to_group(self, group)
    local current_objective = group.objective
    local target_area = current_objective.target_area
        or current_objective.area

    if not target_area.loot
        and not target_area.hostages
        or not current_objective.moving_out
            and current_objective.moved_in
            and group.in_place_t
            and self._t - group.in_place_t > 15
    then
        local recon_area
        local to_search_areas = {
            current_objective.area
        }
        local found_areas = {
            [current_objective.area] = "init"
        }
        local search_index = 1

        repeat
            local search_area = to_search_areas[search_index]

            search_index = search_index + 1

            if search_area.loot or search_area.hostages then
                local occupied

                for _, test_group in pairs(self._groups) do
                    if test_group ~= group
                        and (
                            test_group.objective.target_area == search_area
                            or test_group.objective.area == search_area
                        )
                    then
                        occupied = true

                        break
                    end
                end

                if not occupied
                    and group.visited_areas
                    and group.visited_areas[search_area]
                then
                    occupied = true
                end

                if not occupied then
                    local is_area_safe =
                        not next(search_area.criminal.units)

                    if is_area_safe then
                        recon_area = search_area

                        break
                    else
                        recon_area = recon_area or search_area
                    end
                end
            end

            if not next(search_area.criminal.units) then
                for _, other_area in pairs(search_area.neighbours) do
                    if not found_areas[other_area] then
                        table.insert(to_search_areas, other_area)
                        found_areas[other_area] = search_area
                    end
                end
            end
        until search_index > #to_search_areas

        if recon_area then
            local coarse_path = {
                {
                    recon_area.pos_nav_seg,
                    recon_area.pos
                }
            }
            local last_added_area = recon_area

            while found_areas[last_added_area] ~= "init" do
                last_added_area = found_areas[last_added_area]

                table.insert(coarse_path, 1, {
                    last_added_area.pos_nav_seg,
                    last_added_area.pos
                })
            end

            local group_objective = {
                attitude = "avoid",
                pose = "stand",
                scan = true,
                stance = "hos",
                type = "recon_area",
                area = current_objective.area,
                target_area = recon_area,
                coarse_path = coarse_path
            }

            self:_set_objective_to_enemy_group(group, group_objective)

            current_objective = group.objective
        end
    end

    if current_objective.target_area then
        if current_objective.moving_out
            and not current_objective.moving_in
            and current_objective.coarse_path
        then
            local forwardmost_index =
                self:_get_group_forwardmost_coarse_path_index(group)

            if forwardmost_index and forwardmost_index > 1 then
                for path_index = forwardmost_index + 1,
                    #current_objective.coarse_path
                do
                    local nav_point =
                        current_objective.coarse_path[path_index]

                    if not self:is_nav_seg_safe(nav_point[1]) then
                        for _ = 0,
                            #current_objective.coarse_path
                                - forwardmost_index
                        do
                            table.remove(current_objective.coarse_path)
                        end

                        local group_objective = {
                            attitude = "avoid",
                            pose = "stand",
                            scan = true,
                            stance = "hos",
                            type = "recon_area",
                            area = self:get_area_from_nav_seg_id(
                                current_objective.coarse_path[
                                    #current_objective.coarse_path
                                ][1]
                            ),
                            target_area = current_objective.target_area
                        }

                        self:_set_objective_to_enemy_group(
                            group,
                            group_objective
                        )

                        return
                    end
                end
            end
        end

        if not current_objective.moving_out
            and not current_objective.area.neighbours[
                current_objective.target_area.id
            ]
        then
            local search_params = {
                id = "GroupAI_recon",
                from_seg = current_objective.area.pos_nav_seg,
                to_seg = current_objective.target_area.pos_nav_seg,
                access_pos = self._get_group_acces_mask(group),
                verify_clbk = callback(
                    self,
                    self,
                    "is_nav_seg_safe"
                )
            }
            local coarse_path = managers.navigation:search_coarse(
                search_params
            )

            if coarse_path then
                self:_merge_coarse_path_by_area(coarse_path)
                table.remove(coarse_path)

                local group_objective = {
                    attitude = "avoid",
                    pose = "stand",
                    scan = true,
                    stance = "hos",
                    type = "recon_area",
                    area = self:get_area_from_nav_seg_id(
                        coarse_path[#coarse_path][1]
                    ),
                    target_area = current_objective.target_area,
                    coarse_path = coarse_path
                }

                self:_set_objective_to_enemy_group(group, group_objective)
            end
        end

        if not current_objective.moving_out
            and current_objective.area.neighbours[
                current_objective.target_area.id
            ]
        then
            local group_objective = {
                attitude = "avoid",
                pose = "crouch",
                scan = true,
                stance = "hos",
                type = "recon_area",
                area = current_objective.target_area
            }

            self:_set_objective_to_enemy_group(group, group_objective)

            group.objective.moving_in = true
            group.objective.moved_in = true

            if next(current_objective.target_area.criminal.units) then
                self:_chk_group_use_smoke_grenade(group, {
                    use_smoke = true,
                    target_areas = {
                        group_objective.area
                    }
                })
            end
        end
    end
end

local function set_assault_objective_to_group(self, group, phase)
    if not group.has_spawned then
        return
    end

    local phase_is_anticipation = phase == "anticipation"
    local current_objective = group.objective
    local approach
    local open_fire
    local push
    local pull_back
    local charge
    local obstructed_area = self:_chk_group_areas_tresspassed(group)
    local _, group_leader_data = self._determine_group_leader(group.units)
    local tactics_map

    if group_leader_data and group_leader_data.tactics then
        tactics_map = {}

        for _, tactic_name in ipairs(group_leader_data.tactics) do
            tactics_map[tactic_name] = true
        end

        if current_objective.tactic
            and not tactics_map[current_objective.tactic]
        then
            current_objective.tactic = nil
        end

        for _, tactic_name in ipairs(group_leader_data.tactics) do
            if tactic_name == "deathguard" and not phase_is_anticipation then
                if current_objective.tactic == tactic_name then
                    for _, criminal_data in pairs(self._char_criminals) do
                        if criminal_data.status
                            and criminal_data.status ~= "electrified"
                            and current_objective.follow_unit
                                == criminal_data.unit
                        then
                            local criminal_nav_seg =
                                criminal_data.tracker:nav_segment()

                            if current_objective.area.nav_segs[
                                criminal_nav_seg
                            ] then
                                return
                            end
                        end
                    end
                end

                local closest_criminal_data
                local closest_criminal_dis_sq

                for _, criminal_data in pairs(self._char_criminals) do
                    if criminal_data.status
                        and criminal_data.status ~= "electrified"
                    then
                        local _, _, closest_unit_dis_sq =
                            self._get_closest_group_unit_to_pos(
                                criminal_data.m_pos,
                                group.units
                            )

                        if closest_unit_dis_sq
                            and (
                                not closest_criminal_dis_sq
                                or closest_unit_dis_sq
                                    < closest_criminal_dis_sq
                            )
                        then
                            closest_criminal_data = criminal_data
                            closest_criminal_dis_sq = closest_unit_dis_sq
                        end
                    end
                end

                if closest_criminal_data then
                    local search_params = {
                        id = "GroupAI_deathguard",
                        from_tracker = group_leader_data.unit
                            :movement()
                            :nav_tracker(),
                        to_tracker = closest_criminal_data.tracker,
                        access_pos = self._get_group_acces_mask(group)
                    }
                    local coarse_path = managers.navigation:search_coarse(
                        search_params
                    )

                    if coarse_path then
                        local group_objective = {
                            attitude = "engage",
                            distance = 800,
                            moving_in = true,
                            tactic = "deathguard",
                            type = "assault_area",
                            follow_unit = closest_criminal_data.unit,
                            area = self:get_area_from_nav_seg_id(
                                coarse_path[#coarse_path][1]
                            ),
                            coarse_path = coarse_path
                        }

                        group.is_chasing = true

                        self:_set_objective_to_enemy_group(
                            group,
                            group_objective
                        )
                        self:_voice_deathguard_start(group)

                        return
                    end
                end
            elseif tactic_name == "charge"
                and not current_objective.moving_out
                and group.in_place_t
                and (
                    self._t - group.in_place_t > 15
                    or self._t - group.in_place_t > 4
                        and self._drama_data.amount <= tweak_data.drama.low
                )
                and next(current_objective.area.criminal.units)
                and group.is_chasing
                and not current_objective.charge
            then
                charge = true
            end
        end
    end

    local objective_area

    if obstructed_area then
        if current_objective.moving_out then
            if not current_objective.open_fire then
                open_fire = true
            end
        elseif not current_objective.pushed
            or charge and not current_objective.charge
        then
            push = true
        end
    else
        local obstructed_path_index =
            self:_chk_coarse_path_obstructed(group)

        if obstructed_path_index then
            print("obstructed_path_index", obstructed_path_index)

            objective_area = self:get_area_from_nav_seg_id(
                current_objective.coarse_path[
                    math.max(obstructed_path_index - 1, 1)
                ][1]
            )
            pull_back = true
        elseif not current_objective.moving_out then
            local has_criminals_close

            if not current_objective.moving_out then
                for _, neighbour_area in pairs(
                    current_objective.area.neighbours
                ) do
                    if next(neighbour_area.criminal.units) then
                        has_criminals_close = true

                        break
                    end
                end
            end

            if charge then
                push = true
            elseif not has_criminals_close or not group.in_place_t then
                approach = true
            elseif not phase_is_anticipation
                and not current_objective.open_fire
            then
                open_fire = true
            elseif not phase_is_anticipation
                and group.in_place_t
                and (
                    group.is_chasing
                    or not tactics_map
                    or not tactics_map.ranged_fire
                    or self._t - group.in_place_t > 15
                )
            then
                push = true
            elseif phase_is_anticipation and current_objective.open_fire then
                pull_back = true
            end
        end
    end

    objective_area = objective_area or current_objective.area

    if open_fire then
        local group_objective = {
            attitude = "engage",
            open_fire = true,
            pose = "stand",
            stance = "hos",
            type = "assault_area",
            tactic = current_objective.tactic,
            area = obstructed_area or current_objective.area,
            coarse_path = {
                {
                    objective_area.pos_nav_seg,
                    mvector3.copy(current_objective.area.pos)
                }
            }
        }

        self:_set_objective_to_enemy_group(group, group_objective)
        self:_voice_open_fire_start(group)
    elseif approach or push then
        local assault_area
        local alternate_assault_area
        local alternate_assault_area_from
        local assault_path
        local alternate_assault_path
        local to_search_areas = {
            objective_area
        }
        local found_areas = {
            [objective_area] = "init"
        }
        local search_index = 1

        repeat
            local search_area = to_search_areas[search_index]

            search_index = search_index + 1

            local criminal_character_in_area = false

            for criminal_key in pairs(search_area.criminal.units) do
                local status = self._criminals[criminal_key].status

                if (not status or status == "electrified")
                    and not self._criminals[criminal_key].is_deployable
                then
                    criminal_character_in_area = true

                    break
                end
            end

            if criminal_character_in_area then
                local assault_from_here = true

                if not push and tactics_map and tactics_map.flank then
                    local assault_from_area = found_areas[search_area]

                    if assault_from_area ~= "init" then
                        local cop_units = assault_from_area.police.units

                        for _, unit_data in pairs(cop_units) do
                            if unit_data.group
                                and unit_data.group ~= group
                                and unit_data.group.objective.type
                                    == "assault_area"
                            then
                                assault_from_here = false

                                if not alternate_assault_area
                                    or math.random() < 0.5
                                then
                                    local search_params = {
                                        id = "GroupAI_assault",
                                        from_seg = current_objective.area
                                            .pos_nav_seg,
                                        to_seg = search_area.pos_nav_seg,
                                        access_pos =
                                            self._get_group_acces_mask(group),
                                        verify_clbk = callback(
                                            self,
                                            self,
                                            "is_nav_seg_safe"
                                        )
                                    }

                                    alternate_assault_path =
                                        managers.navigation:search_coarse(
                                            search_params
                                        )

                                    if alternate_assault_path then
                                        self:_merge_coarse_path_by_area(
                                            alternate_assault_path
                                        )

                                        alternate_assault_area = search_area
                                        alternate_assault_area_from =
                                            assault_from_area
                                    end
                                end

                                found_areas[search_area] = nil

                                break
                            end
                        end
                    end
                end

                if assault_from_here then
                    local search_params = {
                        id = "GroupAI_assault",
                        from_seg = current_objective.area.pos_nav_seg,
                        to_seg = search_area.pos_nav_seg,
                        access_pos = self._get_group_acces_mask(group),
                        verify_clbk = callback(
                            self,
                            self,
                            "is_nav_seg_safe"
                        )
                    }

                    assault_path = managers.navigation:search_coarse(
                        search_params
                    )

                    if assault_path then
                        self:_merge_coarse_path_by_area(assault_path)

                        assault_area = search_area

                        break
                    end
                end
            else
                for _, other_area in pairs(search_area.neighbours) do
                    if not found_areas[other_area] then
                        table.insert(to_search_areas, other_area)
                        found_areas[other_area] = search_area
                    end
                end
            end
        until search_index > #to_search_areas

        if not assault_area and alternate_assault_area then
            assault_area = alternate_assault_area
            found_areas[assault_area] = alternate_assault_area_from
            assault_path = alternate_assault_path
        end

        if assault_area and assault_path then
            local assault_area = push
                and assault_area
                or found_areas[assault_area] == "init"
                    and objective_area
                or found_areas[assault_area]

            if #assault_path > 2
                and assault_area.nav_segs[
                    assault_path[#assault_path - 1][1]
                ]
            then
                table.remove(assault_path)
            end

            local used_grenade

            if push then
                local detonate_pos

                if charge then
                    for criminal_key, criminal_data in pairs(
                        assault_area.criminal.units
                    ) do
                        if not self._criminals[criminal_key].is_deployable
                        then
                            detonate_pos =
                                criminal_data.unit:movement():m_pos()

                            break
                        end
                    end
                end

                local first_check = math.random() < 0.5
                    and self._chk_group_use_flash_grenade
                    or self._chk_group_use_smoke_grenade
                local second_check = first_check
                        == self._chk_group_use_flash_grenade
                    and self._chk_group_use_smoke_grenade
                    or self._chk_group_use_flash_grenade

                used_grenade = first_check(
                    self,
                    group,
                    self._task_data.assault,
                    detonate_pos
                )
                used_grenade = used_grenade or second_check(
                    self,
                    group,
                    self._task_data.assault,
                    detonate_pos
                )

                self:_voice_move_in_start(group)
            end

            local group_objective = {
                stance = "hos",
                type = "assault_area",
                area = assault_area,
                coarse_path = assault_path,
                pose = push and "crouch" or "stand",
                attitude = push and "engage" or "avoid",
                moving_in = push and true or nil,
                open_fire = push or nil,
                pushed = push or nil,
                charge = charge,
                interrupt_dis = charge and 0 or nil
            }

            group.is_chasing = group.is_chasing or push

            self:_set_objective_to_enemy_group(group, group_objective)
        end
    elseif pull_back then
        local retreat_area
        local do_not_retreat

        for _, unit_data in pairs(group.units) do
            local nav_seg_id = unit_data.tracker:nav_segment()

            if current_objective.area.nav_segs[nav_seg_id] then
                retreat_area = current_objective.area

                break
            end

            if self:is_nav_seg_safe(nav_seg_id) then
                retreat_area = self:get_area_from_nav_seg_id(nav_seg_id)

                break
            end
        end

        if not retreat_area
            and not do_not_retreat
            and current_objective.coarse_path
        then
            local forwardmost_index =
                self:_get_group_forwardmost_coarse_path_index(group)

            if forwardmost_index then
                local nearest_safe_nav_seg_id =
                    current_objective.coarse_path[forwardmost_index][1]

                retreat_area = self:get_area_from_nav_seg_id(
                    nearest_safe_nav_seg_id
                )
            end
        end

        if retreat_area then
            local new_group_objective = {
                attitude = "avoid",
                pose = "crouch",
                stance = "hos",
                type = "assault_area",
                area = retreat_area,
                coarse_path = {
                    {
                        retreat_area.pos_nav_seg,
                        mvector3.copy(retreat_area.pos)
                    }
                }
            }

            group.is_chasing = nil

            self:_set_objective_to_enemy_group(
                group,
                new_group_objective
            )

            return
        end
    end
end

local function assign_group_to_retire(self, group)
    local retire_area
    local retire_pos
    local to_search_areas = {
        group.objective.area
    }
    local found_areas = {
        [group.objective.area] = true
    }
    local search_index = 1

    repeat
        local search_area = to_search_areas[search_index]

        search_index = search_index + 1

        if search_area.flee_points and next(search_area.flee_points) then
            retire_area = search_area

            local _, flee_point = next(search_area.flee_points)

            retire_pos = flee_point.pos

            break
        else
            for _, other_area in pairs(search_area.neighbours) do
                if not found_areas[other_area] then
                    table.insert(to_search_areas, other_area)
                    found_areas[other_area] = true
                end
            end
        end
    until search_index > #to_search_areas

    if not retire_area then
        Application:error(
            "[GroupAIStateBesiege:_assign_group_to_retire] flee point not found. from area:",
            inspect(group.objective.area),
            "group ID:",
            group.id
        )

        return
    end

    local group_objective = {
        type = "retire",
        area = retire_area or group.objective.area,
        coarse_path = {
            {
                retire_area.pos_nav_seg,
                retire_area.pos
            }
        },
        pos = retire_pos
    }

    self:_set_objective_to_enemy_group(group, group_objective)
end

function AIOverdrive:patch_group_ai_state_besiege(group_ai_state_besiege)
    if self._group_ai_besiege_patch_targets[group_ai_state_besiege] then
        return
    end

    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "_find_spawn_points_near_area",
        find_spawn_points_near_area
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "_find_spawn_group_near_area",
        find_spawn_group_near_area
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "flee_point",
        find_flee_point
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "safe_flee_point",
        find_safe_flee_point
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "get_safe_enemy_loot_drop_point",
        find_safe_enemy_loot_drop_point
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "_set_recon_objective_to_group",
        set_recon_objective_to_group
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "_set_assault_objective_to_group",
        set_assault_objective_to_group
    )
    Hooks:OverrideFunction(
        group_ai_state_besiege,
        "_assign_group_to_retire",
        assign_group_to_retire
    )

    self._group_ai_besiege_patch_targets[group_ai_state_besiege] = true
end

AIOverdrive._group_ai_runtime_loaded = true

return AIOverdrive
