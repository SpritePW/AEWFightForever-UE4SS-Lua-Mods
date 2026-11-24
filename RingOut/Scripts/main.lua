local modname = "RingOut"

function log(message)
    print(string.format("[%s] %s\n", modname, message))
    return true
end

local mod_enabled = true
local debug_enabled = true

local near_rope_distance = 140.0
local grapple_patterns = {
    "_A_[MF]_Mov_Gp_F_",
    "_A_[MF]_Mov_Gp_B_",
    "_A_[MF]_Mov_Gp_R_",
    "_A_[MF]_Mov_Gp_Cou_",
    "_A_[MF]_Mov_Gp_Dsh_",
    "_A_[MF]_Mov_Dsh_Gp_",
    "_A_[MF]_Mov_Rope_Gp_",
}

local ignore_world_barrier = true
local disable_sync_barrier = true

local direction_commit_distance = 70.0
local direction_min_ahead = 25.0
local direction_min_speed = 250.0
local direction_window = 0.1
local direction_lifted_height = 40.0
local direction_landed_height = 10.0
local direction_tolerance = 60.0
local corner_margin = 45.0

local shoulder_min_height = 150.0
local shoulder_min_ahead = 25.0
local shoulder_min_speed = 180.0
local shoulder_max_reach = 200.0

local arc_clear = 170.0
local arc_time = 0.55
local arc_land_past = 210.0
local arc_hold_after = 0.6
local arc_lock_attacker = true
local arc_follow_body = true
local arc_follow_max = 250.0
local arc_body_past = 170.0
local arc_body_fix_max = 200.0

local floor_min_drop = 50.0
local floor_search_distance = 260.0
local floor_search_step = 15.0

local max_armed_seconds = 10.0
local min_armed_seconds = 0.35
local restore_delay = 0.7

local play_montage_path = "/Script/ABP_200508.ELCharacter_Native:PlayMontageCore_N"
local system_library_path = "/Script/Engine.Default__KismetSystemLibrary"
local tick_hook_paths = {
    "/Game/GameData/Assets/Character/ABP_Elite_Roster_Base.ABP_Elite_Roster_Base_C:BlueprintUpdateAnimation",
    "/Game/GameData/Assets/Character/ABP_Elite_Roster_Base_Career.ABP_Elite_Roster_Base_Career_C:BlueprintUpdateAnimation",
}
local rope_side_components = {
    "MeshThroughRopeBarrier_U", "MeshThroughRopeBarrier_D", "MeshThroughRopeBarrier_L", "MeshThroughRopeBarrier_R",
}
local body_bone_preferences = { "pelvis", "hips", "hip", "waist", "spine", "root" }

local script_dir = debug.getinfo(1, "S").source:match("^@(.*)[/\\]") or "."
local blocked_file = script_dir .. "/blocked_moves.txt"

local ring_actor = nil
local component_cache = {}
local ring_geometry = nil
local system_library = nil
local armed_moves = {}
local body_bone = nil
local body_bone_tried = false
local blocked_moves = {}
local last_move = nil
local last_frame = 0
local last_frame_seen = 0
local last_prewarm = 0
local tick_hooks_ready = {}
local hooks_done = false
local hook_attempts = 0

function debug_log(message)
    if debug_enabled then
        log(message)
    end
    return true
end

function is_valid(object)
    if object == nil then
        return false
    end
    local ok, result = pcall(function()
        return object:IsValid()
    end)
    return ok and result
end

function try_get(getter, ...)
    local ok, result = pcall(getter, ...)
    if ok then
        return result
    end
    debug_log("Error: " .. tostring(result))
    return nil
end

function short_name(full_name)
    return full_name:match("([^%.]+)$") or full_name
end

function vector(x, y, z)
    return { X = x, Y = y, Z = z }
end

function get_location(actor)
    local location = actor:K2_GetActorLocation()
    return vector(location.X, location.Y, location.Z)
end

function get_ring()
    if not is_valid(ring_actor) then
        ring_actor = FindFirstOf("BP_Ring_C")
        component_cache = {}
        if not is_valid(ring_actor) then
            ring_actor = nil
        end
    end
    return ring_actor
end

function get_ring_component(name)
    local component = component_cache[name]
    if is_valid(component) then
        return component
    end
    for _, box in ipairs(FindAllOf("BoxComponent") or {}) do
        local ok, full_name = pcall(function()
            return box:GetFullName()
        end)
        if ok and full_name and full_name:find("BP_Ring", 1, true) and full_name:find("." .. name, 1, true) then
            component_cache[name] = box
            return box
        end
    end
    return nil
end

function build_ring_geometry()
    if not get_ring() then
        return nil
    end
    local points = {}
    for _, name in ipairs(rope_side_components) do
        local component = get_ring_component(name)
        if not component then
            debug_log("Geometry: missing " .. name)
            return nil
        end
        local location = component:K2_GetComponentLocation()
        points[#points + 1] = vector(location.X, location.Y, location.Z)
    end
    local center_x, center_y = 0, 0
    for _, point in ipairs(points) do
        center_x = center_x + point.X
        center_y = center_y + point.Y
    end
    center_x = center_x / #points
    center_y = center_y / #points
    local sides = {}
    for index, point in ipairs(points) do
        local dx, dy = point.X - center_x, point.Y - center_y
        local length = math.sqrt(dx * dx + dy * dy)
        if length < 1 then
            return nil
        end
        sides[index] = { normal_x = dx / length, normal_y = dy / length, half_size = length, name = rope_side_components[index] }
    end
    ring_geometry = { center_x = center_x, center_y = center_y, sides = sides }
    return ring_geometry
end

function get_ring_geometry()
    if ring_geometry and is_valid(ring_actor) then
        return ring_geometry
    end
    return build_ring_geometry()
end

function distance_past_ropes(location)
    local geometry = get_ring_geometry()
    if not geometry then
        return nil
    end
    local best, best_side = -math.huge, nil
    for _, side in ipairs(geometry.sides) do
        local value = (location.X - geometry.center_x) * side.normal_x + (location.Y - geometry.center_y) * side.normal_y - side.half_size
        if value > best then
            best, best_side = value, side
        end
    end
    return best, best_side
end

function get_rope_hit(location, dir_x, dir_y)
    local geometry = get_ring_geometry()
    if not geometry then
        return nil
    end
    local best = nil
    for _, side in ipairs(geometry.sides) do
        local cosine = dir_x * side.normal_x + dir_y * side.normal_y
        if cosine > 0.05 then
            local distance = (side.half_size - ((location.X - geometry.center_x) * side.normal_x + (location.Y - geometry.center_y) * side.normal_y)) / cosine
            if distance >= 0 and (not best or distance < best.distance) then
                best = { side = side, distance = distance, cosine = cosine }
            end
        end
    end
    if not best then
        return nil
    end
    best.x = location.X + dir_x * best.distance
    best.y = location.Y + dir_y * best.distance
    local tangent_x, tangent_y = -best.side.normal_y, best.side.normal_x
    local half = 0
    for _, side in ipairs(geometry.sides) do
        if math.abs(side.normal_x * tangent_x + side.normal_y * tangent_y) > 0.9 then
            half = math.max(half, side.half_size)
        end
    end
    local along = math.abs((best.x - geometry.center_x) * tangent_x + (best.y - geometry.center_y) * tangent_y)
    best.corner_gap = half - along
    return best
end

function save_barriers(character)
    return {
        ignore_world = try_get(function()
            return character.bBarrierCollisionIgnoreWorld_N
        end),
        sync_barrier = try_get(function()
            return character:IsEnableSyncBarrierCollision()
        end),
    }
end

function override_barriers(character)
    if ignore_world_barrier then
        pcall(function()
            character.bBarrierCollisionIgnoreWorld_N = true
        end)
    end
    if disable_sync_barrier then
        pcall(function()
            character:SetEnableSyncBarrierCollision(false)
        end)
    end
end

function restore_barriers(character, saved)
    if not is_valid(character) or not saved then
        return
    end
    if ignore_world_barrier and saved.ignore_world ~= nil then
        pcall(function()
            character.bBarrierCollisionIgnoreWorld_N = saved.ignore_world
        end)
    end
    if disable_sync_barrier and saved.sync_barrier ~= nil then
        pcall(function()
            character:SetEnableSyncBarrierCollision(saved.sync_barrier)
        end)
    end
end

function get_system_library()
    if not is_valid(system_library) then
        system_library = StaticFindObject(system_library_path)
    end
    return system_library
end

function trace_down(context, x, y, z_from, ignore)
    local library = get_system_library()
    if not library then
        return nil
    end
    local hit = {}
    local color = { R = 0, G = 0, B = 0, A = 0 }
    local ok, was_hit = pcall(function()
        return library:LineTraceSingle(context, vector(x, y, z_from + 200), vector(x, y, z_from - 2000),
            0, false, ignore, 0, hit, true, color, color, 0.0)
    end)
    if not ok or not was_hit then
        return nil
    end
    return try_get(function()
        return hit.ImpactPoint.Z
    end) or try_get(function()
        return hit.Location.Z
    end)
end

function get_sync_motion(state)
    for _, character in ipairs({ state.attacker, state.receiver }) do
        local sync_motion = try_get(function()
            return character.SyncMotion
        end)
        if is_valid(sync_motion) then
            return sync_motion
        end
    end
    return nil
end

function get_receiver_index(sync_motion, receiver)
    local receiver_name = receiver:GetFullName()
    local found = nil
    pcall(function()
        local out = {}
        sync_motion:GetSyncActor(out)
        local list = out.SyncActors or out[1] or out
        if list and list.ForEach then
            list:ForEach(function(index, element)
                local actor = element:get()
                if is_valid(actor) and actor:GetFullName() == receiver_name then
                    found = index - 1
                end
            end)
        elseif type(list) == "table" then
            for index, actor in ipairs(list) do
                if is_valid(actor) and actor:GetFullName() == receiver_name then
                    found = index - 1
                end
            end
        end
    end)
    return found or 1
end

function release_sync(state, arc)
    local sync_motion = get_sync_motion(state)
    if not sync_motion then
        debug_log("Sync: no SyncMotion object")
        return
    end
    local index = get_receiver_index(sync_motion, state.receiver)
    local ok, err = pcall(function()
        sync_motion:SetEnableUpdateTransform(index, false)
    end)
    if ok then
        arc.sync_motion = sync_motion
        arc.sync_index = index
    else
        log("Sync: SetEnableUpdateTransform failed: " .. tostring(err))
    end
end

function build_arc(state, receiver_location, dir_x, dir_y, hit)
    local ignore = { state.receiver, state.attacker }
    local to_rope = math.max(hit.distance, 1)
    local mat_z = trace_down(state.receiver, receiver_location.X, receiver_location.Y, receiver_location.Z, ignore)
    if not mat_z then
        log("Arc: mat trace failed")
        return nil
    end
    local step = floor_search_step / hit.cosine
    local land_along = arc_land_past / hit.cosine
    local max_along = land_along + floor_search_distance / hit.cosine
    local floor_z, land_x, land_y
    while land_along <= max_along do
        land_x = receiver_location.X + dir_x * (to_rope + land_along)
        land_y = receiver_location.Y + dir_y * (to_rope + land_along)
        local z = trace_down(state.receiver, land_x, land_y, receiver_location.Z, ignore)
        if z and z < mat_z - floor_min_drop then
            floor_z = z
            break
        end
        land_along = land_along + step
    end
    if not floor_z then
        log("Arc: no floor found past the apron")
        return nil
    end
    local total = to_rope + land_along
    local land_z = floor_z + (state.base_z - mat_z)
    local rope_fraction = to_rope / total
    local straight_z = (1 - rope_fraction) * receiver_location.Z + rope_fraction * land_z
    local bump = math.max(0, (state.base_z + arc_clear - straight_z) / (4 * rope_fraction * (1 - rope_fraction)))
    local arc = {
        start = receiver_location, landing = vector(land_x, land_y, land_z), bump = bump,
        start_time = os.clock(), duration = arc_time, attacker_lock = get_location(state.attacker),
        dir_x = dir_x, dir_y = dir_y, body_fix = 0,
    }
    release_sync(state, arc)
    return arc
end

function hold_at(actor, location, tolerance)
    local current = get_location(actor)
    local dx, dy, dz = current.X - location.X, current.Y - location.Y, current.Z - location.Z
    if dx * dx + dy * dy + dz * dz > tolerance * tolerance then
        pcall(function()
            actor:K2_SetActorLocation(location, false, {}, true)
        end)
    end
end

function find_body_bone(mesh)
    body_bone_tried = true
    local bone_count = try_get(function()
        return mesh:GetNumBones()
    end)
    if type(bone_count) ~= "number" or bone_count <= 0 then
        return
    end
    local names = {}
    for index = 0, math.min(bone_count, 300) - 1 do
        local name = try_get(function()
            return mesh:GetBoneName(index):ToString()
        end)
        if name then
            names[#names + 1] = name
        end
    end
    for _, wanted in ipairs(body_bone_preferences) do
        for _, name in ipairs(names) do
            local lower = name:lower()
            if lower:find(wanted, 1, true) and not lower:find("ik") and not lower:find("twist")
                and not lower:find("thigh") and not (wanted ~= "root" and lower == "root") then
                body_bone = FName(name)
                return
            end
        end
    end
end

function get_body_location(character)
    local mesh = try_get(function()
        return character.Mesh
    end)
    if not is_valid(mesh) then
        return nil
    end
    if not body_bone then
        if body_bone_tried then
            return nil
        end
        find_body_bone(mesh)
        if not body_bone then
            return nil
        end
    end
    local ok, location = pcall(function()
        return mesh:GetSocketLocation(body_bone)
    end)
    if not ok or not location then
        return nil
    end
    return vector(location.X, location.Y, location.Z)
end

function hold_landed(state)
    local arc = state.arc
    if arc_body_past > 0 and arc.body_fix < arc_body_fix_max then
        local body = get_body_location(state.receiver)
        if body then
            local capsule = get_location(state.receiver)
            local offset = (body.X - capsule.X) * arc.dir_x + (body.Y - capsule.Y) * arc.dir_y
            local needed = arc_body_past - ((distance_past_ropes(arc.landing) or 0) + offset)
            if needed > 3 then
                local step = math.min(needed, arc_body_fix_max - arc.body_fix, 25)
                arc.landing = vector(arc.landing.X + arc.dir_x * step, arc.landing.Y + arc.dir_y * step, arc.landing.Z)
                arc.body_fix = arc.body_fix + step
            end
        end
    end
    hold_at(state.receiver, arc.landing, 3)
end

function step_arc(state, now)
    local arc = state.arc
    local progress = math.min((now - arc.start_time) / arc.duration, 1.0)
    local x = arc.start.X + (arc.landing.X - arc.start.X) * progress
    local y = arc.start.Y + (arc.landing.Y - arc.start.Y) * progress
    local z = (1 - progress) * arc.start.Z + progress * arc.landing.Z + 4 * arc.bump * progress * (1 - progress)
    if arc_follow_body then
        local body = get_body_location(state.receiver)
        if body then
            local capsule = get_location(state.receiver)
            local lag = -((body.X - capsule.X) * arc.dir_x + (body.Y - capsule.Y) * arc.dir_y)
            lag = math.max(0, math.min(lag, arc_follow_max))
            arc.lag = (arc.lag or lag) * 0.7 + lag * 0.3
            x = x + arc.dir_x * arc.lag
            y = y + arc.dir_y * arc.lag
        end
    end
    pcall(function()
        state.receiver:K2_SetActorLocation(vector(x, y, z), false, {}, true)
    end)
    if arc_lock_attacker and is_valid(state.attacker) then
        local attacker_location = get_location(state.attacker)
        hold_at(state.attacker, vector(arc.attacker_lock.X, arc.attacker_lock.Y, attacker_location.Z), 5)
    end
    if progress >= 1.0 and not arc.landed then
        arc.landed = true
        if arc.lag and arc.lag > 0 then
            arc.landing = vector(arc.landing.X + arc.dir_x * arc.lag, arc.landing.Y + arc.dir_y * arc.lag, arc.landing.Z)
        end
    end
end

function finish_move(key, state, reason)
    if state.finished then
        return
    end
    state.finished = true
    restore_barriers(state.attacker, state.attacker_barriers)
    restore_barriers(state.receiver, state.receiver_barriers)
    if state.arc and state.arc.sync_motion and is_valid(state.arc.sync_motion) then
        pcall(function()
            state.arc.sync_motion:SetEnableUpdateTransform(state.arc.sync_index, true)
        end)
    end
    armed_moves[key] = nil
    debug_log("Done (" .. reason .. ")")
end

function on_move_ended(key, state)
    if state.arc then
        if not state.arc.landed then
            state.arc.duration = 0.0001
            step_arc(state, os.clock())
        end
        state.restore_at = os.clock() + restore_delay
        return
    end
    finish_move(key, state, "stayed inside")
end

function check_direction(state, elapsed, receiver_location)
    local now = os.clock()
    local attacker_location = get_location(state.attacker)
    local height = receiver_location.Z - state.base_z
    if height >= direction_lifted_height then
        state.was_lifted = true
    elseif state.was_lifted and height <= direction_landed_height then
        state.arc_failed = true
        debug_log(string.format("Direction at %.2fs: landed without being thrown - stays in", elapsed))
        return
    end
    state.separation_history = state.separation_history or {}
    local history = state.separation_history
    history[#history + 1] = {
        time = now, x = receiver_location.X - attacker_location.X, y = receiver_location.Y - attacker_location.Y,
        ahead = (distance_past_ropes(receiver_location) or 0) - (distance_past_ropes(attacker_location) or 0),
    }
    while #history > 2 and now - history[2].time >= direction_window do
        table.remove(history, 1)
    end
    if not check_thrown_away(state, elapsed, receiver_location, height, history) then
        check_over_shoulder(state, elapsed, receiver_location, attacker_location, height, history)
    end
end

function send_out(state, elapsed, receiver_location, dir_x, dir_y, hit, message)
    debug_log(string.format("Direction at %.2fs: %s toward the %s rope (%.0f deg off square), z %.0f - sending out",
        elapsed, message, hit.side.name:match("_(%a)$") or hit.side.name, math.deg(math.acos(math.min(1, hit.cosine))),
        receiver_location.Z - state.base_z))
    state.arc = build_arc(state, receiver_location, dir_x, dir_y, hit)
    if not state.arc then
        state.arc_failed = true
    end
end

function check_thrown_away(state, elapsed, receiver_location, height, history)
    local dx = receiver_location.X - state.receiver_start.X
    local dy = receiver_location.Y - state.receiver_start.Y
    local moved = math.sqrt(dx * dx + dy * dy)
    if moved < direction_commit_distance then
        return false
    end
    local dir_x, dir_y = dx / moved, dy / moved
    local last, first = history[#history], history[1]
    local ahead = last.x * dir_x + last.y * dir_y
    if ahead < direction_min_ahead then
        return false
    end
    local span = last.time - first.time
    if span < direction_window * 0.6 then
        return false
    end
    local speed = (ahead - (first.x * dir_x + first.y * dir_y)) / span
    if speed < direction_min_speed then
        return false
    end

    local min_cos = math.cos(math.rad(direction_tolerance))
    local hit = nil
    local outside, side = distance_past_ropes(receiver_location)
    if outside and outside > 0 and side and dir_x * side.normal_x + dir_y * side.normal_y >= min_cos then
        hit = { side = side, distance = 0, cosine = dir_x * side.normal_x + dir_y * side.normal_y, corner_gap = math.huge }
    else
        hit = get_rope_hit(receiver_location, dir_x, dir_y)
    end
    local reason = nil
    if not hit then
        reason = "no rope that way"
    elseif hit.cosine < min_cos then
        reason = string.format("%.0f deg off the rope", math.deg(math.acos(math.min(1, hit.cosine))))
    elseif hit.corner_gap < corner_margin then
        reason = "heading into a corner post"
    else
        local geometry = get_ring_geometry()
        local attacker_gap = hit.side.half_size - ((state.attacker_start.X - geometry.center_x) * hit.side.normal_x
            + (state.attacker_start.Y - geometry.center_y) * hit.side.normal_y)
        if attacker_gap > near_rope_distance then
            reason = string.format("not the rope you're at (%.0f away from it)", attacker_gap)
        end
    end
    if reason then
        state.arc_failed = true
        debug_log(string.format("Direction at %.2fs: %s - stays in", elapsed, reason))
        return true
    end
    send_out(state, elapsed, receiver_location, dir_x, dir_y, hit,
        string.format("thrown %.0f, %.0f past you at %.0f/s", moved, ahead, speed))
    return true
end

function check_over_shoulder(state, elapsed, receiver_location, attacker_location, height, history)
    if height <= shoulder_min_height then
        return
    end
    local last, first = history[#history], history[1]
    local span = last.time - first.time
    if span < direction_window * 0.6 or last.ahead < shoulder_min_ahead then
        return
    end
    local speed = (last.ahead - first.ahead) / span
    if speed < shoulder_min_speed then
        return
    end
    if (distance_past_ropes(attacker_location) or -math.huge) <= -near_rope_distance then
        return
    end
    local dir_x, dir_y = last.x - first.x, last.y - first.y
    local length = math.sqrt(dir_x * dir_x + dir_y * dir_y)
    if length < 10 then
        dir_x, dir_y = last.x, last.y
        length = math.sqrt(dir_x * dir_x + dir_y * dir_y)
    end
    if length <= 1 then
        return
    end
    dir_x, dir_y = dir_x / length, dir_y / length
    local hit = get_rope_hit(receiver_location, dir_x, dir_y)
    if not hit or hit.cosine < math.cos(math.rad(direction_tolerance)) or hit.corner_gap < corner_margin
        or hit.distance > shoulder_max_reach then
        return
    end
    send_out(state, elapsed, receiver_location, dir_x, dir_y, hit,
        string.format("over your shoulder, %.0f past you at %.0f/s", last.ahead, speed))
end

function update_move(key, state)
    if state.finished or state.restore_at then
        return
    end
    if not is_valid(state.attacker) or not is_valid(state.receiver) then
        return finish_move(key, state, "actor gone")
    end

    local elapsed = os.clock() - state.start_time
    override_barriers(state.attacker)
    override_barriers(state.receiver)

    if not state.sync_checked then
        local partner = try_get(function()
            return state.attacker:GetSyncChar_N()
        end)
        if is_valid(partner) and partner:GetFullName() ~= state.attacker:GetFullName() then
            if partner:GetFullName() ~= state.receiver:GetFullName() then
                restore_barriers(state.receiver, state.receiver_barriers)
                state.receiver = partner
                state.receiver_barriers = save_barriers(partner)
                state.receiver_start = get_location(partner)
                override_barriers(partner)
            end
            state.sync_checked = true
        end
    end

    local now = os.clock()
    if not state.arc and not state.arc_failed then
        check_direction(state, elapsed, get_location(state.receiver))
    end
    if state.arc then
        if state.arc.landed then
            hold_landed(state)
        else
            step_arc(state, now)
        end
    end

    local partner = try_get(function()
        return state.attacker:GetSyncChar_N()
    end)
    local synced = is_valid(partner) and partner:GetFullName() ~= state.attacker:GetFullName()
    if synced then
        state.saw_sync = true
    end

    local ended = false
    if state.arc then
        if state.arc.landed then
            state.arc.landed_at = state.arc.landed_at or now
            ended = now - state.arc.landed_at >= arc_hold_after
        end
    elseif state.saw_sync then
        ended = (not synced) and elapsed > min_armed_seconds
    else
        ended = elapsed > math.max(state.play_length or 0, 1.5)
    end
    if ended or elapsed > max_armed_seconds then
        state.ended = true
        on_move_ended(key, state)
    end
end

function arm_move(attacker, receiver, montage_name, play_length, move_key)
    local key = attacker:GetFullName()
    if armed_moves[key] then
        return
    end
    if not get_ring_geometry() then
        debug_log("No ring geometry, not arming")
        return
    end
    local attacker_outside = distance_past_ropes(get_location(attacker))
    local receiver_outside = distance_past_ropes(get_location(receiver))
    if not attacker_outside or not receiver_outside then
        return
    end
    if math.max(attacker_outside, receiver_outside) <= -near_rope_distance then
        return
    end
    if attacker_outside > 0 or receiver_outside > 0 then
        return
    end

    local state = {
        attacker = attacker, receiver = receiver, start_time = os.clock(), play_length = play_length, move_key = move_key,
        attacker_start = get_location(attacker), receiver_start = get_location(receiver), base_z = get_location(receiver).Z,
        attacker_barriers = save_barriers(attacker), receiver_barriers = save_barriers(receiver),
    }
    armed_moves[key] = state
    override_barriers(attacker)
    override_barriers(receiver)
    debug_log(string.format("Armed: %s (attacker %.0f, receiver %.0f from the ropes)", short_name(montage_name), -attacker_outside, -receiver_outside))
    if last_frame_seen == 0 then
        log("WARNING: frame tick has not run yet - move will not be tracked")
    end
end

function get_move_key(name)
    local key = name:match("_Mov_(.+)$") or name
    key = key:gsub("_PinCombo_.*$", "")
    return key
end

function load_blocked_moves()
    blocked_moves = {}
    local file = io.open(blocked_file, "r")
    if not file then
        return
    end
    for line in file:lines() do
        line = line:gsub("%s+$", "")
        if line ~= "" and not line:match("^#") then
            blocked_moves[line] = true
        end
    end
    file:close()
end

function save_blocked_moves()
    local file = io.open(blocked_file, "w")
    if not file then
        log("Could not write " .. blocked_file)
        return
    end
    file:write("# RingOut: moves that never send the opponent outside (one per line)\n")
    local keys = {}
    for key in pairs(blocked_moves) do
        keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
        file:write(key .. "\n")
    end
    file:close()
end

function is_grapple(name)
    for _, pattern in ipairs(grapple_patterns) do
        if name:find(pattern) then
            return true
        end
    end
    return false
end

function frame_tick()
    local now = os.clock()
    if now - last_frame < 0.008 then
        return
    end
    last_frame = now
    last_frame_seen = now
    if (not ring_geometry or not is_valid(ring_actor)) and now - last_prewarm > 5 then
        ring_geometry = nil
        last_prewarm = now
        pcall(build_ring_geometry)
    end
    for key, state in pairs(armed_moves) do
        if state.restore_at then
            if is_valid(state.receiver) then
                pcall(hold_landed, state)
            end
            if now >= state.restore_at then
                finish_move(key, state, "sent outside")
            end
        elseif not state.finished and not state.ended then
            local ok, err = pcall(update_move, key, state)
            if not ok then
                log("Tick error: " .. tostring(err))
                finish_move(key, state, "error")
            end
        end
    end
end

function register_hooks()
    if hooks_done then
        return
    end
    hook_attempts = hook_attempts + 1
    if hook_attempts > 40 then
        hooks_done = true
        log("WARNING: no frame tick hook, mod cannot run")
        return
    end
    for _, path in ipairs(tick_hook_paths) do
        if not tick_hooks_ready[path] then
            local registered = pcall(RegisterHook, path,
                function(Context)
                    local ok, err = pcall(frame_tick)
                    if not ok and debug_enabled then
                        log("Frame tick error: " .. tostring(err))
                    end
                end)
            if registered then
                tick_hooks_ready[path] = true
                hooks_done = true
            end
        end
    end
end

RegisterHook(play_montage_path,
    function(Context, Montage)
        register_hooks()
        if not mod_enabled then
            return
        end
        local ok, err = pcall(function()
            local character = Context:get()
            if not is_valid(character) then
                return
            end
            local montage = Montage:get()
            if not is_valid(montage) then
                return
            end
            local name = short_name(montage:GetFullName())
            if not is_grapple(name) or armed_moves[character:GetFullName()] then
                return
            end
            local key = get_move_key(name)
            last_move = key
            if blocked_moves[key] then
                debug_log("Blocked move, ignoring: " .. key)
                return
            end

            local receiver = try_get(function()
                return character:GetSyncChar_N()
            end)
            if not is_valid(receiver) or receiver:GetFullName() == character:GetFullName() then
                receiver = try_get(function()
                    return character.TargetActor
                end)
            end
            if not is_valid(receiver) then
                return
            end
            local play_length = try_get(function()
                return montage:GetPlayLength()
            end)
            arm_move(character, receiver, name, type(play_length) == "number" and play_length or nil, key)
        end)
        if not ok then
            log("Hook error: " .. tostring(err))
        end
    end)

RegisterConsoleCommandHandler("ringout", function(FullCommand, Parameters)
    mod_enabled = not mod_enabled
    return log("Enabled: " .. tostring(mod_enabled))
end)

RegisterConsoleCommandHandler("ringout_lift", function(FullCommand, Parameters)
    local value = Parameters and tonumber(Parameters[1])
    if value then
        arc_clear = value
    end
    return log(string.format("Rope clearance: %.0f (usage: ringout_lift <units above start height>)", arc_clear))
end)

RegisterConsoleCommandHandler("ringout_arc", function(FullCommand, Parameters)
    local duration = Parameters and tonumber(Parameters[1])
    local distance = Parameters and tonumber(Parameters[2])
    if duration then
        arc_time = duration
    end
    if distance then
        arc_land_past = distance
    end
    return log(string.format("Arc time: %.2fs, land %.0f past ropes (usage: ringout_arc <seconds> <distance>)", arc_time, arc_land_past))
end)

RegisterConsoleCommandHandler("ringout_commit", function(FullCommand, Parameters)
    local value = Parameters and tonumber(Parameters[1])
    if value then
        direction_commit_distance = value
    end
    return log(string.format("Decide the direction after the opponent has moved %.0f (usage: ringout_commit <units>)", direction_commit_distance))
end)

RegisterConsoleCommandHandler("ringout_block", function(FullCommand, Parameters)
    local key = (Parameters and Parameters[1]) or last_move
    if not key then
        return log("No move yet - do a grapple first, or: ringout_block <move>")
    end
    blocked_moves[key] = true
    save_blocked_moves()
    return log("Blocked: " .. key .. " (ringout_unblock to undo)")
end)

RegisterConsoleCommandHandler("ringout_unblock", function(FullCommand, Parameters)
    local key = (Parameters and Parameters[1]) or last_move
    if key and blocked_moves[key] then
        blocked_moves[key] = nil
        save_blocked_moves()
        return log("Unblocked: " .. key)
    end
    return log("Not blocked: " .. tostring(key))
end)

RegisterConsoleCommandHandler("ringout_list", function(FullCommand, Parameters)
    local count = 0
    for key in pairs(blocked_moves) do
        log("  Blocked: " .. key)
        count = count + 1
    end
    return log(count .. " blocked move(s). Last grapple: " .. tostring(last_move))
end)

RegisterConsoleCommandHandler("ringout_debug", function(FullCommand, Parameters)
    debug_enabled = not debug_enabled
    return log("Debug: " .. tostring(debug_enabled))
end)

RegisterConsoleCommandHandler("ringout_info", function(FullCommand, Parameters)
    ExecuteInGameThread(function()
        ring_geometry = nil
        local geometry = build_ring_geometry()
        if not geometry then
            log("No ring geometry (no BP_Ring_C or boxes missing)")
            return
        end
        log(string.format("Ring centre (%.1f, %.1f)", geometry.center_x, geometry.center_y))
        for _, side in ipairs(geometry.sides) do
            log(string.format("  %s  normal (%.2f, %.2f)  half-size %.1f", side.name, side.normal_x, side.normal_y, side.half_size))
        end
        for _, character in ipairs(FindAllOf("BP_Player_C") or {}) do
            if is_valid(character) then
                local location = get_location(character)
                local outside, side = distance_past_ropes(location)
                log(string.format("  %s  pos (%.0f, %.0f, %.0f)  %s ropes by %.1f (%s)",
                    short_name(character:GetFullName()), location.X, location.Y, location.Z,
                    (outside or 0) > 0 and "OUTSIDE" or "inside", math.abs(outside or 0), side and side.name or "?"))
            end
        end
    end)
    return true
end)

load_blocked_moves()
pcall(register_hooks)
