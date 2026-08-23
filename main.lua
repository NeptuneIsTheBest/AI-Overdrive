dofile(ModPath .. "lua/ai_unbound.lua")

local AIUnbound = _G.AIUnbound
local required_script = RequiredScript and RequiredScript:lower()

if required_script == "lib/managers/menumanager" then
    Hooks:Add("MenuManagerInitialize", "AIUnbound_MenuManagerInitialize", function()
        MenuCallbackHandler.ai_unbound_set_tasks_per_second = function(_, item)
            AIUnbound:set_tasks_per_second(item and item:value(), true)
        end

        MenuHelper:LoadFromJsonFile(
            AIUnbound.mod_path .. "menu/options.json",
            AIUnbound,
            AIUnbound.settings
        )
    end)
elseif required_script == "lib/managers/enemymanager" then
    Hooks:PostHook(
        EnemyManager,
        "_init_enemy_data",
        "AIUnbound_EnemyManager_InitEnemyData",
        function(enemy_manager)
            AIUnbound:apply_to_enemy_manager(enemy_manager, false)
        end
    )
elseif required_script == "lib/managers/localizationmanager" then
    Hooks:Add("LocalizationManagerPostInit", "AIUnbound_LocalizationManagerPostInit", function(localization_manager)
        AIUnbound:load_localization(localization_manager)
    end)
end
