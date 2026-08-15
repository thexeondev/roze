const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

const log = std.log.scoped(.@"roze::commands::battle");

pub fn CS_ENTER_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Enter_Battle.Decoded);
    log.debug("received enter battle request: {any}", .{request});

    try scope.sink.send(.SC_ENTER_BATTLE, @as(
        protobuf.gen.SC_Enter_Battle,
        .{
            .battle_uid = (@as(u64, request.battle_field_id) << 32) | request.battle_inst_id,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
            .random_seed = @truncate(scope.time.toMilliseconds()),
        },
    ));
}

pub fn CS_START_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Start_Battle.Decoded);

    log.debug("received start battle request: {any}", .{request});

    try scope.sink.send(.SC_START_BATTLE, @as(
        protobuf.gen.SC_Start_Battle,
        .{
            .battle_uid = request.battle_uid,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
        },
    ));
}

pub fn CS_LEAVE_BATTLE(scope: *Scope) Scope.Error!void {
    var request = try scope.command.take(protobuf.gen.CS_Leave_Battle.Decoded);

    log.debug("received leave battle request: {any}", .{request});

    if (request.battle_end_info) |*end_info| {
        log.debug("battle_end_info.vector3: {any}", .{end_info.vector3});
    }

    var should_save_state: bool = false;

    const character = &scope.gameplay.character;
    while (try request.character_data.next()) |character_data| {
        const character_index = Gameplay.Character.Index.fromInstId(character_data.inst_id) orelse continue;
        character.snapshots[character_index.toInt()] = .wrap(.{
            .hp = character_data.current_hp,
            .permanent_liquid = character_data.permanent_liquid,
        });
        should_save_state = true;

        {
            var attr_buffer: protobuf.packers.Buffer(
                protobuf.packers.CharacterAttribDataBuffer,
                1,
            ) = undefined;
            var attr_list = attr_buffer.toList();

            protobuf.packers.packCharacterAttribData(
                scope.asset_index,
                &attr_list,
                character_index,
                character.bits[@backingInt(character_index)],
                character.snapshots[@backingInt(character_index)],
            );

            try scope.sink.send(.SC_OUTSIDE_ATTRIB_NTF, @as(
                protobuf.gen.SC_Outside_Attrib_Ntf,
                .{ .data = attr_list.items(.data)[0] },
            ));
        }
    }

    try scope.sink.send(.SC_LEAVE_BATTLE, @as(
        protobuf.gen.SC_Leave_Battle,
        .{
            .battle_uid = request.battle_uid,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
            .battle_result = request.battle_result,
            .extra_info = null,
        },
    ));

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    if (should_save_state) scope.store.requestGameplayStateSave();
}
