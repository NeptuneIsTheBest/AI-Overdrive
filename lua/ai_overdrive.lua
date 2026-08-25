local existing = rawget(_G, "AIOverdrive")

if existing and existing._core_loaded then
    return existing
end

_G.AIOverdrive = existing or {}

local AIOverdrive = _G.AIOverdrive

AIOverdrive.VERSION = "0.2.1"
AIOverdrive.TASKS_PER_SECOND_PRESETS = {
    60,
    300,
    600,
    1200,
    3000
}
AIOverdrive.DEFAULT_TASKS_PER_SECOND = 600
AIOverdrive.DEFAULT_SHOOTING_UPDATE_RATE = "auto"
AIOverdrive.SHOOTING_UPDATE_RATES = {
    ["15"] = 15,
    ["60"] = 60
}
AIOverdrive.AUTO_SHOOTING_MIN_HZ = 30
AIOverdrive.AUTO_SHOOTING_MAX_HZ = 60
AIOverdrive.AUTO_SHOOTING_FPS_RATIO = 0.5
AIOverdrive.AUTO_SHOOTING_SMOOTHING_WINDOW = 0.5
AIOverdrive.SHOOTING_ACTION_PHASE_MODULUS = 997
AIOverdrive.MAX_NPC_WEAPON_CATCHUP_SHOTS = 8
AIOverdrive.NEW_NPC_WEAPON_DEFAULT_FIRE_RATE = 0.1
AIOverdrive.LEGACY_NPC_WEAPON_DEFAULT_FIRE_RATE = 1
AIOverdrive.DEFAULT_EVERY_FRAME_WALKING_ENABLED = true
AIOverdrive.DEFAULT_COARSE_PATH_BATCHING_ENABLED = true
AIOverdrive.DEFAULT_SEAMLESS_ACTION_TRANSITIONS_ENABLED = true
AIOverdrive.ACTION_TRANSITION_EPSILON = 0.000001
AIOverdrive.COARSE_SEARCH_BUDGET_RATIO = 0.05
AIOverdrive.MIN_COARSE_SEARCH_BUDGET = 0.00025
AIOverdrive.MAX_COARSE_SEARCH_BUDGET = 0.0015
AIOverdrive.MAX_COARSE_SEARCHES_PER_FRAME = 8
AIOverdrive.GFX_LOD_PRIORITY_BUDGET_RATIO = 0.05
AIOverdrive.MIN_GFX_LOD_PRIORITY_BUDGET = 0.00025
AIOverdrive.MAX_GFX_LOD_PRIORITY_BUDGET = 0.0015
AIOverdrive.MAX_GFX_LOD_PRIORITY_UPDATES_PER_FRAME = 8
AIOverdrive.DEFAULT_FRAME_DELTA_TIME = 1 / 60
AIOverdrive.mod_path = ModPath
AIOverdrive.save_path = SavePath .. "ai_overdrive.json"
AIOverdrive.settings = AIOverdrive.settings or {}
AIOverdrive._installed_required_scripts = AIOverdrive._installed_required_scripts or {}
AIOverdrive._shooting_settings_revision = AIOverdrive._shooting_settings_revision or 0

function AIOverdrive:log(message, level)
    log(string.format("[AI Overdrive][%s] %s", level or "INFO", tostring(message)))
end

function AIOverdrive:sanitize_tasks_per_second(value)
    local rate = tonumber(value)

    for preset_index = 1, #self.TASKS_PER_SECOND_PRESETS do
        local preset_rate = self.TASKS_PER_SECOND_PRESETS[preset_index]

        if rate == preset_rate then
            return preset_rate
        end
    end

    return self.DEFAULT_TASKS_PER_SECOND
end

function AIOverdrive:tasks_per_second()
    return self.settings.tasks_per_second
end

function AIOverdrive:accelerated_shooting_enabled()
    return self:shooting_update_rate() ~= "original"
end

function AIOverdrive:sanitize_shooting_update_rate(value)
    if value == "original"
        or value == "auto"
        or value == "full"
        or self.SHOOTING_UPDATE_RATES[value]
    then
        return value
    end

    return self.DEFAULT_SHOOTING_UPDATE_RATE
end

function AIOverdrive:shooting_update_rate()
    return self.settings.shooting_update_rate
end

function AIOverdrive:sanitize_every_frame_walking_enabled(value)
    if type(value) == "boolean" then
        return value
    end

    return self.DEFAULT_EVERY_FRAME_WALKING_ENABLED
end

function AIOverdrive:every_frame_walking_enabled()
    return self.settings.every_frame_walking_enabled
end

function AIOverdrive:sanitize_coarse_path_batching_enabled(value)
    if type(value) == "boolean" then
        return value
    end

    return self.DEFAULT_COARSE_PATH_BATCHING_ENABLED
end

function AIOverdrive:coarse_path_batching_enabled()
    return self.settings.coarse_path_batching_enabled
end

function AIOverdrive:sanitize_seamless_action_transitions_enabled(value)
    if type(value) == "boolean" then
        return value
    end

    return self.DEFAULT_SEAMLESS_ACTION_TRANSITIONS_ENABLED
end

function AIOverdrive:seamless_action_transitions_enabled()
    return self.settings.seamless_action_transitions_enabled
end

function AIOverdrive:tick_rate()
    return 1 / self:tasks_per_second()
end

function AIOverdrive:load_settings()
    local loaded_settings
    local file = io.open(self.save_path, "r")

    if file then
        local contents = file:read("*all")
        file:close()

        if contents and contents ~= "" then
            local decoded = json.decode(contents)

            if type(decoded) == "table" then
                loaded_settings = decoded
            else
                self:log("Could not decode settings; using defaults.", "WARN")
            end
        end
    end

    self.settings.tasks_per_second = self:sanitize_tasks_per_second(
        loaded_settings and loaded_settings.tasks_per_second
    )
    self.settings.shooting_update_rate = self:sanitize_shooting_update_rate(
        loaded_settings and loaded_settings.shooting_update_rate
    )
    self.settings.every_frame_walking_enabled = self:sanitize_every_frame_walking_enabled(
        loaded_settings and loaded_settings.every_frame_walking_enabled
    )
    self.settings.coarse_path_batching_enabled = self:sanitize_coarse_path_batching_enabled(
        loaded_settings and loaded_settings.coarse_path_batching_enabled
    )
    self.settings.seamless_action_transitions_enabled =
        self:sanitize_seamless_action_transitions_enabled(
            loaded_settings and loaded_settings.seamless_action_transitions_enabled
        )

    return self.settings
end

function AIOverdrive:save_settings()
    local data = {
        tasks_per_second = self:tasks_per_second(),
        shooting_update_rate = self:shooting_update_rate(),
        every_frame_walking_enabled = self:every_frame_walking_enabled(),
        coarse_path_batching_enabled = self:coarse_path_batching_enabled(),
        seamless_action_transitions_enabled = self:seamless_action_transitions_enabled()
    }
    local encoded = json.encode(data)

    local file, open_error = io.open(self.save_path, "w")

    if not file then
        self:log("Could not open settings file: " .. tostring(open_error), "ERROR")
        return false
    end

    local write_ok, write_error = file:write(encoded)
    file:close()

    if not write_ok then
        self:log("Could not write settings: " .. tostring(write_error), "ERROR")
        return false
    end

    return true
end

function AIOverdrive:apply_to_enemy_manager(enemy_manager, reset_queue_buffer)
    if not Network:is_server() then
        return enemy_manager and enemy_manager._tick_rate
            or tweak_data.group_ai.ai_tick_rate
    end

    local tasks_per_second = self:tasks_per_second()
    local tick_rate = 1 / tasks_per_second

    if enemy_manager then
        enemy_manager._tick_rate = tick_rate

        if reset_queue_buffer then
            enemy_manager._queue_buffer = 0
        end

        self:log(string.format(
            "Applied %d queued AI tasks/second (tick interval %.9f seconds).",
            tasks_per_second,
            tick_rate
        ))
    end

    return tick_rate
end

function AIOverdrive:reset_auto_shooting_frame_time()
    self._auto_shooting_last_sample_t = nil
    self._auto_shooting_smoothed_dt = nil
end

function AIOverdrive:set_tasks_per_second(value, apply_immediately)
    self.settings.tasks_per_second = self:sanitize_tasks_per_second(value)
    self:save_settings()

    if apply_immediately then
        local enemy_manager = managers.enemy
        self:apply_to_enemy_manager(enemy_manager, enemy_manager ~= nil)
    end

    return self.settings.tasks_per_second
end

function AIOverdrive:on_shooting_settings_changed()
    self._shooting_settings_revision = self._shooting_settings_revision + 1
    self:reset_auto_shooting_frame_time()
end

function AIOverdrive:set_shooting_update_rate(value)
    local update_rate = self:sanitize_shooting_update_rate(value)
    local changed = update_rate ~= self:shooting_update_rate()

    self.settings.shooting_update_rate = update_rate

    if changed then
        self:on_shooting_settings_changed()
    end

    self:save_settings()

    return self.settings.shooting_update_rate
end

function AIOverdrive:set_every_frame_walking_enabled(value)
    self.settings.every_frame_walking_enabled = self:sanitize_every_frame_walking_enabled(value)
    self:save_settings()

    return self.settings.every_frame_walking_enabled
end

function AIOverdrive:set_coarse_path_batching_enabled(value)
    self.settings.coarse_path_batching_enabled = self:sanitize_coarse_path_batching_enabled(value)
    self:save_settings()

    return self.settings.coarse_path_batching_enabled
end

function AIOverdrive:set_seamless_action_transitions_enabled(value)
    self.settings.seamless_action_transitions_enabled =
        self:sanitize_seamless_action_transitions_enabled(value)
    self:save_settings()

    return self.settings.seamless_action_transitions_enabled
end

function AIOverdrive:load_localization(localization_manager)
    localization_manager:load_localization_file(self.mod_path .. "loc/english.txt")

    if SystemInfo:language():key() == Idstring("schinese"):key() then
        localization_manager:load_localization_file(self.mod_path .. "loc/schinese.txt")
    end
end

if not AIOverdrive._settings_loaded then
    AIOverdrive:load_settings()
    AIOverdrive._settings_loaded = true
end

AIOverdrive._core_loaded = true

return AIOverdrive
