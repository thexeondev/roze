const std = @import("std");

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;
const assets = roze.assets;

pub fn CS_ENTER_BATTLE(scope: *Scope) Scope.Error!void {
    const request = try scope.command.take(protobuf.gen.CS_Enter_Battle.Decoded);

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
    const log = std.log.scoped(.@"roze::commands::leave_battle");

    var request = try scope.command.take(protobuf.gen.CS_Leave_Battle.Decoded);
    var state_save_needed: bool = false;

    const battle_result = request.battle_result orelse {
        log.debug("invalid battle result", .{});
        return try scope.sink.send(.SC_LEAVE_BATTLE, @as(
            protobuf.gen.SC_Leave_Battle,
            .{ .ret = -1 },
        ));
    };

    const hp_needs_refill = switch (battle_result) {
        .ENM_BATTLE_RESULT_TYPE_DEAD_FAIL => true,
        else => false,
    };

    const character = &scope.gameplay.character;
    while (try request.character_data.next()) |character_data| {
        const character_index = Gameplay.Character.Index.fromInstId(character_data.inst_id) orelse continue;

        const hp_new = if (hp_needs_refill) hp_max: {
            const bits = character.bits[@backingInt(character_index)];
            const dev_attributes = scope.asset_index.getDevelopAttributes(character_index);

            break :hp_max dev_attributes.maxhp *
                assets.getScaleForLevel(.scale_maxhp, bits.level, bits.break_level);
        } else character_data.current_hp;

        character.snapshots[character_index.toInt()] = .wrap(.{
            .hp = hp_new,
            .permanent_liquid = character_data.permanent_liquid,
        });
        state_save_needed = true;

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

    const extra_info: ?protobuf.gen.BattleExtraInfo = switch (battle_result) {
        .ENM_BATTLE_RESULT_TYPE_DEAD_FAIL => .{
            .reborn_map_id = scope.gameplay.map.id,
            .reborn_savepoint = assets.npc_lists.save_point_npc_ids[scope.gameplay.map.save_point_index],
        },
        else => null,
    };

    try scope.sink.send(.SC_LEAVE_BATTLE, @as(
        protobuf.gen.SC_Leave_Battle,
        .{
            .battle_uid = request.battle_uid,
            .battle_type = request.battle_type,
            .battle_field_id = request.battle_field_id,
            .battle_result = request.battle_result,
            .extra_info = extra_info,
        },
    ));

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    if (state_save_needed) scope.store.requestGameplayStateSave();
}
