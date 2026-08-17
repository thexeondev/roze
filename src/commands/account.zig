const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const packers = roze.protobuf.packers;
const Scope = roze.Scope;
const assets = roze.assets;

const log = std.log.scoped(.@"roze::commands::account");

pub fn CS_SCHEMA_INFO_SYNC(scope: *Scope) Scope.Error!void {
    const response: protobuf.gen.SC_Schema_Info_Sync = .{
        .result = 0,
        .login_id = scope.store.role_id,
    };

    try scope.sink.send(.SC_SCHEMA_INFO_SYNC, response);
}

pub fn CS_ROLE_LOGIN(scope: *Scope) Scope.Error!void {
    const response: protobuf.gen.SC_Role_Login = .{
        .result = 0,
        .game_svr_url = "",
        .port = 0,
        .map_id = scope.gameplay.map.id,
        .today_first_login = true,
        .current_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        .is_inited_name = true,
        .time_zone_offset_seconds = 0,
    };

    try scope.sink.send(.SC_ROLE_LOGIN, response);
}

pub fn CS_ENTER_MAP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Enter_Map.Decoded);
    log.info("received enter map request: {any}", .{request});

    var unlocked_savepoints_buffer: packers.UnlockedSavepointsBuffer = undefined;
    const unlocked_savepoints = packers.packUnlockedSavepoints(
        &unlocked_savepoints_buffer,
        &scope.gameplay.save_point_unlock,
    );

    var unlocked_teleport_id_list_buffer: packers.UnlockedTeleportsBuffer = undefined;
    const unlocked_teleport_id_list = packers.packUnlockedTeleportIdList(
        &unlocked_teleport_id_list_buffer,
        &scope.gameplay.teleport_point_unlock,
    );

    const readiness: protobuf.gen.SC_Map_Ready_Ntf = .{
        .map_id = scope.gameplay.map.id,
        .last_logout_location = .init,
        .born_pos_type = .ENM_BORN_SAVE_POINT,
        .rotation = .{ .x = 0, .y = 0, .z = 0 },
        .current_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        .unlocked_savepoints = unlocked_savepoints,
        .unlocked_teleport_id_list = unlocked_teleport_id_list,
    };

    try scope.sink.send(.SC_MAP_READY_NTF, readiness);

    const response: protobuf.gen.SC_Enter_Map = .{
        .role_id = request.role_id,
        .map_id = request.map_id,
        .teleport_id = 0,
        .map_info = .{
            .current_gametime = @backingInt(scope.gameplay.map.bits.time),
            .current_weather = scope.gameplay.map.bits.weather.toWeatherTypeInt(),
        },
        .savepoint_id = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
    };

    try scope.sink.send(.SC_ENTER_MAP, response);
}

pub fn CS_FIN_ENTER_MAP(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Fin_Enter_Map.Decoded);
    log.info("received fin enter map request: {any}", .{request});

    var base_info: protobuf.gen.RoleBaseInfo = .{
        .role_id = scope.store.role_id,
        .role_name = "xeondev",
        .role_level = 1,
        .gender = .ENM_GENDER_FEMALE,
        .role_name_inited = true,
        .level_Data = .{
            .world_level_max = 1,
            .world_level_cur = 1,
            .team_level = 1,
            .team_exp = 0,
        },
        .second_role_name = "reversedrooms",
    };

    base_info.player_attr = &.{
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_COIN),
            .value = .{ .value_uint32 = 1337 },
        },
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_SATIETY),
            .value = .{ .value_uint32 = 100 },
        },
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_STAMINA_CUR),
            .value = .{ .value_uint32 = 100 },
        },
        .{
            .attr_type = @backingInt(protobuf.gen.PlayerAttrType.ENM_PLAYER_ATTR_STAMINA_FULLTIME),
            .value = .{ .value_uint32 = 100 },
        },
    };

    var unlocked_savepoints_buffer: packers.UnlockedSavepointsBuffer = undefined;
    const unlocked_savepoints = packers.packUnlockedSavepoints(
        &unlocked_savepoints_buffer,
        &scope.gameplay.save_point_unlock,
    );

    var unlocked_teleport_id_list_buffer: packers.UnlockedTeleportsBuffer = undefined;
    const unlocked_teleport_id_list = packers.packUnlockedTeleportIdList(
        &unlocked_teleport_id_list_buffer,
        &scope.gameplay.teleport_point_unlock,
    );

    const response: protobuf.gen.SC_Fin_Enter_Map = .{
        .role_id = request.role_id,
        .map_id = request.map_id,
        .role_info = .{
            .base_info = base_info,
            .map_info = .{
                .current_gametime = @backingInt(scope.gameplay.map.bits.time),
                .current_weather = scope.gameplay.map.bits.weather.toWeatherTypeInt(),
            },
            .global_conf = .{
                .satiety_limit = 100,
                .stamina_regen_max = 100,
                .stamina_regen_interval = 100,
                .max_silver_creature_cost = 100,
                .max_silver_creature_num = 1,
                .unlock_collection_range = 1,
                .launch_date = "2026-06-06T06:06:06",
                .launch_date_type = 0,
            },
        },
        .last_logout_location = .init,
        .current_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        .born_pos_type = .ENM_BORN_POSITION,
        .task_data = .init,
        .world_map_id = scope.gameplay.map.id,
        .unlocked_savepoints = unlocked_savepoints,
        .unlocked_teleport_id_list = unlocked_teleport_id_list,
    };

    try scope.sink.send(.SC_FIN_ENTER_MAP, response);
}
