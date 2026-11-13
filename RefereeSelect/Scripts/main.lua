local modname = "RefereeSelect"

function log(message)
    print(string.format("[%s] %s\n", modname, message))
    return true
end

local fixed_count = 2
local caw_id = 4
local aubrey_id = 51
local knox_id = 45
local restore_delay = 5000

local settings_path = "/Script/ABP_200508.Default__ELGameSystemDataUtilityFunction"
local character_data_path = "/Script/ABP_200508.Default__CharacterDataManager"
local system_library_path = "/Script/Engine.Default__KismetSystemLibrary"

local cursor_setup_path = "/Game/GameData/Assets/Widget/Menu/GameSettings/unit/WBP_GameSettingsCursor.WBP_GameSettingsCursor_C:Setup"
local save_settings_path = "/Game/GameData/Assets/Widget/Menu/GameSettings/WBP_GameSettings.WBP_GameSettings_C:SaveGameSettings"
local finish_spawning_path = "/Script/Engine.GameplayStatics:FinishSpawningActor"
local set_byte_path = "/Script/Engine.KismetSystemLibrary:SetBytePropertyByName"
local setup_wrestler_path = "/Game/GameData/Assets/Character/BP_Player.BP_Player_C:SetupWrestler"
local wrestler_id_path = "/Script/ELITE_Game.Default__WrestlerIDUtilityFunctions"
local debug_name_property = "DebugName_6_C48189C1413F50AB53511BBE7A56861A"

local script_dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
local state_file = script_dir .. "/referee_choice.txt"
local state = { value = nil, key = nil, swap = nil }
local menu_list = nil

local objects = {}
function get_object(path)
    local object = objects[path]
    if object and object:IsValid() then
        return object
    end
    object = StaticFindObject(path)
    if object and object:IsValid() then
        objects[path] = object
        return object
    end
    return nil
end

function try_call(object, function_name, ...)
    local args = { ... }
    local ok, result = pcall(function()
        return object[function_name](object, table.unpack(args))
    end)
    if ok then
        return result
    end
    return nil
end

function guid_key(guid)
    return string.format("%08X-%08X-%08X-%08X", guid.A & 0xFFFFFFFF, guid.B & 0xFFFFFFFF, guid.C & 0xFFFFFFFF, guid.D & 0xFFFFFFFF)
end

function to_guid(value)
    if value == nil then
        return nil
    end
    local ok, guid = pcall(function()
        return { A = value.A, B = value.B, C = value.C, D = value.D }
    end)
    if ok and guid.A ~= nil and (guid.A ~= 0 or guid.B ~= 0 or guid.C ~= 0 or guid.D ~= 0) then
        return guid
    end
    return nil
end

function get_referee_setting(context)
    local settings = get_object(settings_path)
    if settings == nil then
        return nil
    end
    local value = try_call(settings, "GetMatch_RefereeType", context)
    if type(value) == "number" then
        return value
    end
    return nil
end

function set_referee_setting(value)
    local settings = get_object(settings_path)
    local game_instance = FindFirstOf("GameInstance")
    if settings == nil or not game_instance:IsValid() then
        return false
    end
    return pcall(function() settings:SetMatch_RefereeType(value, game_instance) end)
end

function load_state()
    local file = io.open(state_file, "r")
    if file == nil then
        return
    end
    local line1 = file:read("*l")
    local line2 = file:read("*l")
    file:close()
    if line1 then
        local value, key = line1:match("^(%-?%d+)%s+(%S+)")
        if value then
            state.value = tonumber(value)
            state.key = key
        end
    end
    if line2 then
        local swap = line2:match("^swap%s+(%-?%d+)")
        if swap then
            state.swap = tonumber(swap)
        end
    end
end

function save_state()
    local file = io.open(state_file, "w")
    if file == nil then
        return
    end
    file:write(string.format("%d %s\n", state.value or 0, state.key or "-"))
    if state.swap then
        file:write(string.format("swap %d\n", state.swap))
    end
    file:close()
end

function restore_setting()
    if state.swap == nil then
        return
    end
    if set_referee_setting(state.swap) then
        state.swap = nil
        save_state()
    end
end

function get_body_height(data_object)
    local body_height = nil
    pcall(function()
        body_height = data_object:GetPropertyValue("MyWrestler").EditPerson.BodyHeightType
    end)
    if type(body_height) == "number" then
        return body_height
    end
    return 0
end

function describe(data_object)
    if data_object == nil or not data_object:IsValid() then
        return nil
    end
    local name = nil
    pcall(function()
        name = data_object:GetWrestlerNameParam().RingNameText:ToString()
    end)
    if name == nil or name == "" then
        return nil
    end
    return {
        name = name:gsub("[\r\n]+", " "),
        id = try_call(data_object, "GetWrestlerID"),
        guid = to_guid(try_call(data_object, "GetUID")),
        female = try_call(data_object, "GetGender") == 1,
        body_height = get_body_height(data_object),
    }
end

function get_wrestler_objects()
    local result = {}
    for _, data_object in ipairs(FindAllOf("MyWrestlerDataObject") or {}) do
        if data_object:IsValid() and not data_object:GetFullName():find("Default__", 1, true) then
            table.insert(result, data_object)
        end
    end

    local character_data = get_object(character_data_path)
    if character_data == nil then
        return result
    end
    local count = try_call(character_data, "GetCustomWrestlerNum")
    if type(count) ~= "number" then
        return result
    end
    for index = 0, count - 1 do
        local guid = nil
        pcall(function()
            local out = {}
            character_data:GetCustomWrestlerUID(out, index)
            guid = to_guid(out.UID)
        end)
        if guid then
            local data_object = try_call(character_data, "FindMyCharacterDataObject", guid)
            if data_object and data_object:IsValid() then
                table.insert(result, data_object)
            end
        end
    end
    return result
end

function sort_by_name(a, b)
    if a.name:lower() ~= b.name:lower() then
        return a.name:lower() < b.name:lower()
    end
    return a.key < b.key
end


function build_list()
    local list = {}
    local seen = {}

    for _, data_object in ipairs(get_wrestler_objects()) do
        local entry = describe(data_object)
        if entry and type(entry.id) == "number" then
            if entry.id == caw_id then
                if entry.guid then
                    entry.key = "C:" .. guid_key(entry.guid)
                    entry.created = true
                    if not seen[entry.key] then
                        seen[entry.key] = true
                        table.insert(list, entry)
                    end
                end
            elseif entry.id ~= aubrey_id and entry.id ~= knox_id then
                entry.key = "R:" .. entry.id
                entry.created = false
                if not seen[entry.key] then
                    seen[entry.key] = true
                    table.insert(list, entry)
                end
            end
        end
    end

    table.sort(list, sort_by_name)

    local roster_count = 0
    local created_count = 0

    for _, entry in ipairs(list) do
        if entry.created then
            created_count = created_count + 1
        else
            roster_count = roster_count + 1
        end
    end

    return list, roster_count, created_count
end


function get_entry(list, value)
    return list[value - fixed_count + 1]
end

function get_value(list, key)
    for index, entry in ipairs(list) do
        if entry.key == key then
            return fixed_count + index - 1
        end
    end
    return nil
end

function fill_referee_row(cursor)
    if not cursor:IsValid() then
        return
    end
    local ok, row_name = pcall(function()
        return cursor:GetPropertyValue("ListParam")[debug_name_property]:ToString()
    end)
    if not ok or row_name ~= "REFEREE" then
        return
    end

    restore_setting()

    local content = cursor:GetPropertyValue("WBP_GameSettingsCursorContent")
    if not content:IsValid() then
        return
    end
    local values = content:GetPropertyValue("Values")
    if values:GetArrayNum() ~= fixed_count then
        return
    end

    local list, roster_count, created_count = build_list()
    menu_list = list
    for index, entry in ipairs(list) do
        values[fixed_count + index] = entry.name:upper()
    end
    local total = values:GetArrayNum()
    content:SetPropertyValue("MaxValue", total - 1)

    local saved = get_referee_setting(cursor)
    local selected = saved
    if saved and state.value == saved and state.key and state.key ~= "-" then
        selected = get_value(list, state.key) or saved
    end
    if selected and selected >= 0 and selected < total then
        content:SetPropertyValue("SelectValue", selected)
    end
    content:Update()

    log(string.format("Menu: %d roster + %d created wrestlers", roster_count, created_count))
end

function on_settings_saved(context)
    local value = get_referee_setting(context)
    if value == nil or value == state.value then
        return
    end
    local key = "-"
    if value >= fixed_count then
        menu_list = menu_list or build_list()
        local entry = get_entry(menu_list, value)
        if entry then
            key = entry.key
        end
    end
    state.value = value
    state.key = key
    save_state()
end

local cursor_hooked = false
local save_hooked = false
local hook_pending = false

LoopAsync(1000, function()
    if cursor_hooked and save_hooked then
        return true
    end
    if hook_pending then
        return false
    end
    hook_pending = true
    ExecuteInGameThread(function()
        if not cursor_hooked then
            cursor_hooked = pcall(RegisterHook, cursor_setup_path,
                function(Context)
                    local cursor = Context:get()
                    ExecuteInGameThread(function()
                        pcall(fill_referee_row, cursor)
                    end)
                end)
        end
        if not save_hooked then
            save_hooked = pcall(RegisterHook, save_settings_path,
                function(Context)
                    local settings_menu = Context:get()
                    ExecuteInGameThread(function()
                        pcall(on_settings_saved, settings_menu)
                    end)
                end)
        end
        hook_pending = false
    end)
    return false
end)

local setting_byte = false

function set_byte(actor, property_name, value)
    local system_library = get_object(system_library_path)
    if system_library then
        setting_byte = true
        pcall(function() system_library:SetBytePropertyByName(actor, FName(property_name), value) end)
        setting_byte = false
    end
end

function set_wrestler_uid(actor, guid)
    pcall(function()
        local uid = actor:GetPropertyValue("WrestlerUID")
        uid.A = guid.A
        uid.B = guid.B
        uid.C = guid.C
        uid.D = guid.D
    end)
end

function is_community(id)
    local utility = get_object(wrestler_id_path)
    if utility then
        local result = try_call(utility, "IsCommunityWrestlerID", id)
        if type(result) == "boolean" then
            return result
        end
    end
    return id >= 97 and id <= 106
end

local parts_referee = nil
local setup_hooked = false

function hook_setup_wrestler()
    if setup_hooked then
        return
    end
    setup_hooked = pcall(RegisterHook, setup_wrestler_path,
        function(Context)
            local actor = Context:get()
            local referee = parts_referee
            if referee == nil or not actor:IsValid() or actor:GetAddress() ~= referee.address then
                return
            end
            set_byte(actor, "WrestlerID_N", referee.id)
            ExecuteInGameThread(function()
                if actor:IsValid() then
                    set_byte(actor, "WrestlerID_N", referee.style_id)
                end
            end)
        end)
end

function resolve_entry(actor)
    local setting = get_referee_setting(actor)
    if setting == nil or setting < fixed_count then
        return nil, setting
    end
    local list = build_list()
    local entry = nil
    if state.value == setting and state.key and state.key ~= "-" then
        local value = get_value(list, state.key)
        if value then
            entry = get_entry(list, value)
        end
    end
    return entry or get_entry(list, setting), setting
end

local pending_referee = nil

function prepare_referee(actor, value_param)
    parts_referee = nil
    pending_referee = nil
    local entry, setting = resolve_entry(actor)
    if entry == nil then
        if setting and setting >= fixed_count then
            log(string.format("Referee setting %d has no wrestler, using default", setting))
        end
        return
    end
    local style_id = entry.female and aubrey_id or knox_id
    local spawn_id = style_id
    if entry.created or is_community(entry.id) then
        spawn_id = entry.id
        parts_referee = { address = actor:GetAddress(), id = entry.id, style_id = style_id }
        hook_setup_wrestler()
    end
    restore_referee_components(actor)
    pcall(function() value_param:set(spawn_id) end)
    set_byte(actor, "WrestlerID_N", spawn_id)
    set_wrestler_uid(actor, entry.guid)
    set_byte(actor, "BodyHeightType", entry.body_height)
    pending_referee = { address = actor:GetAddress(), entry = entry, setting = setting }
end

local referee_default_path = "/Game/GameData/Assets/Character/Referee/BP_Referee.Default__BP_Referee_C"
local referee_components = { "CustomCostume", "BuildBody" }

function component_valid(object, property_name)
    local ok, valid = pcall(function() return object:GetPropertyValue(property_name):IsValid() end)
    return ok and valid
end

function restore_referee_defaults()
    local referee_default = StaticFindObject(referee_default_path)
    if referee_default == nil or not referee_default:IsValid() then
        return false
    end
    for _, property_name in ipairs(referee_components) do
        if not component_valid(referee_default, property_name) then
            local component = StaticFindObject(referee_default_path .. ":" .. property_name)
            if component and component:IsValid() then
                pcall(function() referee_default:SetPropertyValue(property_name, component) end)
                log(string.format("Referee default %s restored: %s", property_name,
                    tostring(component_valid(referee_default, property_name))))
            end
        end
    end
    return true
end

function restore_referee_components(actor)
    for _, property_name in ipairs(referee_components) do
        if not component_valid(actor, property_name) then
            local actor_path = actor:GetFullName():match("^%S+%s+(.+)$")
            local component = StaticFindObject(actor_path .. "." .. property_name)
            if component == nil or not component:IsValid() then
                component = StaticFindObject(actor_path .. ":" .. property_name)
            end
            if component and component:IsValid() then
                pcall(function() actor:SetPropertyValue(property_name, component) end)
            end
            log(string.format("Referee %s restored: %s", property_name, tostring(component_valid(actor, property_name))))
        end
    end
end

function finish_referee(actor)
    local pending = pending_referee
    pending_referee = nil
    if pending == nil or pending.address ~= actor:GetAddress() then
        return
    end
    local entry = pending.entry
    pcall(function() actor:UpdateMeshScale(false, 0) end)

    if set_referee_setting(entry.female and 0 or 1) then
        state.swap = pending.setting
        save_state()
        ExecuteWithDelay(restore_delay, function()
            ExecuteInGameThread(function()
                restore_setting()
            end)
        end)
    end

    log(string.format("Referee: %s (%s style)", entry.name, entry.female and "Aubrey" or "Knox"))
end

function is_referee(actor)
    return actor:IsValid() and actor:GetClass():GetFName():ToString() == "BP_Referee_C"
end

RegisterHook(set_byte_path,
    function(Context, ObjectParam, NameParam, ValueParam)
        if setting_byte then
            return
        end
        local actor = ObjectParam:get()
        if not is_referee(actor) or NameParam:get():ToString() ~= "WrestlerID_N" then
            return
        end
        prepare_referee(actor, ValueParam)
    end)

RegisterHook(finish_spawning_path,
    function(Context, ActorParam)
        local actor = ActorParam:get()
        if is_referee(actor) then
            finish_referee(actor)
        end
    end)

LoopAsync(2000, function()
    ExecuteInGameThread(function()
        pcall(restore_referee_defaults)
    end)
    return false
end)

load_state()

if state.swap then
    LoopAsync(2000, function()
        if state.swap == nil then
            return true
        end
        ExecuteInGameThread(function()
            pcall(restore_setting)
        end)
        return false
    end)
end

log("Loaded")
