_G.AIUnbound = _G.AIUnbound or {}

local AIUnbound = _G.AIUnbound

AIUnbound.VERSION = "1.0.0"
AIUnbound.MIN_TASKS_PER_SECOND = 60
AIUnbound.MAX_TASKS_PER_SECOND = 3000
AIUnbound.TASKS_PER_SECOND_STEP = 60
AIUnbound.DEFAULT_TASKS_PER_SECOND = 600
AIUnbound.mod_path = ModPath or AIUnbound.mod_path or ""
AIUnbound.save_path = (SavePath or "") .. "ai_unbound.json"
AIUnbound.settings = AIUnbound.settings or {}

function AIUnbound:log(message, level)
    local logger = rawget(_G, "log")

    if type(logger) == "function" then
        logger(string.format("[AI Unbound][%s] %s", level or "INFO", tostring(message)))
    end
end

function AIUnbound:sanitize_tasks_per_second(value)
    local value_type = type(value)

    if value_type ~= "number" and value_type ~= "string" then
        return self.DEFAULT_TASKS_PER_SECOND
    end

    local rate = tonumber(value)

    if not rate or rate ~= rate or rate == math.huge or rate == -math.huge then
        return self.DEFAULT_TASKS_PER_SECOND
    end

    rate = math.floor(rate / self.TASKS_PER_SECOND_STEP + 0.5) * self.TASKS_PER_SECOND_STEP
    rate = math.max(self.MIN_TASKS_PER_SECOND, math.min(self.MAX_TASKS_PER_SECOND, rate))

    return rate
end

function AIUnbound:tasks_per_second()
    return self:sanitize_tasks_per_second(self.settings.tasks_per_second)
end

function AIUnbound:tick_rate()
    return 1 / self:tasks_per_second()
end

function AIUnbound:load_settings()
    local loaded_settings
    local file = io.open(self.save_path, "r")

    if file then
        local contents = file:read("*all")
        file:close()

        if contents and contents ~= "" then
            local ok, decoded = pcall(function()
                return json.decode(contents)
            end)

            if ok and type(decoded) == "table" then
                loaded_settings = decoded
            else
                self:log("Could not decode settings; using defaults.", "WARN")
            end
        end
    end

    self.settings.tasks_per_second = self:sanitize_tasks_per_second(
        loaded_settings and loaded_settings.tasks_per_second
    )

    return self.settings
end

function AIUnbound:save_settings()
    local data = {
        tasks_per_second = self:tasks_per_second()
    }
    local ok, encoded = pcall(function()
        return json.encode(data)
    end)

    if not ok or type(encoded) ~= "string" then
        self:log("Could not encode settings.", "ERROR")
        return false
    end

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

function AIUnbound:apply_to_enemy_manager(enemy_manager, reset_queue_buffer)
    local tasks_per_second = self:tasks_per_second()
    local tick_rate = 1 / tasks_per_second

    if tweak_data and tweak_data.group_ai then
        tweak_data.group_ai.ai_tick_rate = tick_rate
    end

    if enemy_manager then
        enemy_manager._tick_rate = tick_rate

        if reset_queue_buffer then
            enemy_manager._queue_buffer = 0
        end
    end

    self:log(string.format(
        "Applied %d queued AI tasks/second (tick interval %.9f seconds).",
        tasks_per_second,
        tick_rate
    ))

    return tick_rate
end

function AIUnbound:set_tasks_per_second(value, apply_immediately)
    self.settings.tasks_per_second = self:sanitize_tasks_per_second(value)
    self:save_settings()

    if apply_immediately then
        local enemy_manager = managers and managers.enemy
        self:apply_to_enemy_manager(enemy_manager, enemy_manager ~= nil)
    end

    return self.settings.tasks_per_second
end

function AIUnbound:load_localization(localization_manager)
    if not localization_manager then
        self:log("Localization manager is unavailable.", "WARN")
        return false
    end

    localization_manager:load_localization_file(self.mod_path .. "loc/english.txt")

    if SystemInfo and Idstring and SystemInfo:language():key() == Idstring("schinese"):key() then
        localization_manager:load_localization_file(self.mod_path .. "loc/schinese.txt")
    end

    return true
end

if not AIUnbound._settings_loaded then
    AIUnbound:load_settings()
    AIUnbound._settings_loaded = true
else
    AIUnbound.settings.tasks_per_second = AIUnbound:sanitize_tasks_per_second(
        AIUnbound.settings.tasks_per_second
    )
end

return AIUnbound
