const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;
const Gameplay = roze.Gameplay;
const assets = roze.assets;

pub fn CS_GAMETIME_ALIGN_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_GAMETIME_ALIGN_RSP, @as(
        protobuf.gen.SC_GameTime_Align_Rsp,
        .{
            .cur_time = @backingInt(scope.gameplay.map.bits.time),
            .cur_weather = scope.gameplay.map.bits.weather.toWeatherTypeInt(),
        },
    ));
}

pub fn CS_GAMETIME_SETUP_REQ(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_GameTime_Setup_Req.Decoded);

    const weather: Gameplay.Map.Weather = Gameplay.Map.Weather.fromWeatherTypeInt(request.weather) orelse
        @fromBackingInt(@intCast(scope.time.toMilliseconds() % Gameplay.Map.Weather.count));

    const time: Gameplay.Map.Time = @fromBackingInt(@intCast(request.slip_to_time % Gameplay.Map.Time.base));

    try scope.sink.send(.SC_GAMETIME_SETUP_RES, @as(
        protobuf.gen.SC_GameTime_Setup_Res,
        .{
            .result = 0,
            .slip_to_time = @backingInt(time),
            .weather = weather.toWeatherTypeInt(),
        },
    ));

    scope.gameplay.map.bits.weather = weather;
    scope.gameplay.map.bits.time = time;

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

pub fn CS_SAVEPOINT_UNLOCK(scope: *Scope) Scope.Error!void {
    const log = std.log.scoped(.@"roze::commands::savepoint_unlock");

    const request = try scope.command.take(protobuf.gen.CS_SavePoint_Unlock.Decoded);

    const save_point_index = assets.npc_lists.getSavePointIndexByNpcId(request.savepoint_id) orelse {
        log.debug("savepoint with id {d} doesn't exist", .{request.savepoint_id});
        return try scope.sink.send(.SC_SAVEPOINT_UNLOCK, @as(protobuf.gen.SC_SavePoint_Unlock, .{
            .result = -1,
        }));
    };

    try scope.sink.send(.SC_SAVEPOINT_UNLOCK, @as(protobuf.gen.SC_SavePoint_Unlock, .{
        .result = 0,
        .savepoint_id = request.savepoint_id,
    }));

    if (scope.gameplay.save_point_unlock.isSet(save_point_index)) return;

    errdefer comptime unreachable; // Ensure that it's safe to request save.

    scope.gameplay.save_point_unlock.set(save_point_index);
    scope.store.requestGameplayStateSave();
}
