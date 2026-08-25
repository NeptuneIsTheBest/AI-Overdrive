dofile(ModPath .. "lua/ai_overdrive.lua")

local AIOverdrive = _G.AIOverdrive
local required_script = RequiredScript:lower()

if required_script == "lib/managers/menumanager" then
    Hooks:Add("MenuManagerInitialize", "AIOverdrive_MenuManagerInitialize", function()
        MenuCallbackHandler.ai_overdrive_set_tasks_per_second = function(_, item)
            AIOverdrive:set_tasks_per_second(item:value(), true)
        end

        MenuCallbackHandler.ai_overdrive_set_shooting_update_rate = function(_, item)
            AIOverdrive:set_shooting_update_rate(item:value())
        end

        MenuCallbackHandler.ai_overdrive_set_every_frame_walking_enabled = function(_, item)
            AIOverdrive:set_every_frame_walking_enabled(item:value() == "on")
        end

        MenuCallbackHandler.ai_overdrive_set_coarse_path_batching_enabled = function(_, item)
            AIOverdrive:set_coarse_path_batching_enabled(item:value() == "on")
        end

        MenuCallbackHandler.ai_overdrive_set_seamless_action_transitions_enabled = function(_, item)
            AIOverdrive:set_seamless_action_transitions_enabled(item:value() == "on")
        end

        MenuHelper:LoadFromJsonFile(
            AIOverdrive.mod_path .. "menu/options.json",
            AIOverdrive,
            AIOverdrive.settings
        )
    end)
elseif required_script == "lib/managers/enemymanager" then
    AIOverdrive:patch_enemy_manager_delayed_callbacks(EnemyManager)
    AIOverdrive:patch_enemy_manager_gfx_lod(EnemyManager)

    Hooks:PostHook(
        EnemyManager,
        "_init_enemy_data",
        "AIOverdrive_EnemyManager_InitEnemyData",
        function(enemy_manager)
            AIOverdrive:apply_to_enemy_manager(enemy_manager, false)
        end
    )
elseif required_script == "lib/managers/navigationmanager" then
    AIOverdrive:patch_navigation_manager_coarse_searches(NavigationManager)
elseif required_script == "lib/units/props/aiattentionobject" then
    AIOverdrive:patch_ai_attention_object(AIAttentionObject)
elseif required_script == "lib/units/enemies/cop/logics/coplogicbase" then
    AIOverdrive:patch_cop_logic_base_queue_task(CopLogicBase)
elseif required_script == "lib/units/enemies/cop/copbrain" then
    AIOverdrive:patch_cop_brain_action_transitions(CopBrain, CopLogicArrest)
elseif required_script == "lib/units/enemies/cop/actions/upper_body/copactionshoot" then
    AIOverdrive:patch_cop_action_shoot(CopActionShoot)
elseif required_script == "lib/units/enemies/cop/actions/lower_body/copactionwalk" then
    AIOverdrive:patch_cop_action_walk(CopActionWalk)
elseif required_script == "lib/units/weapons/newnpcraycastweaponbase" then
    AIOverdrive:patch_new_npc_raycast_weapon_base(NewNPCRaycastWeaponBase)
elseif required_script == "lib/units/weapons/npcraycastweaponbase" then
    AIOverdrive:patch_npc_raycast_weapon_base(NPCRaycastWeaponBase)
elseif required_script == "lib/managers/localizationmanager" then
    Hooks:Add(
        "LocalizationManagerPostInit",
        "AIOverdrive_LocalizationManagerPostInit",
        function(localization_manager)
            AIOverdrive:load_localization(localization_manager)
        end
    )
end
