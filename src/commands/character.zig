const roze = @import("../roze.zig");
const assets = roze.assets;
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

pub fn CS_REQ_CHARACTER_LIST(scope: *Scope) Scope.Error!void {
    var characters_buf: [Gameplay.Character.count]protobuf.gen.CharacterData = undefined;
    var count: u32 = 0;

    var it = scope.gameplay.character.iterator();
    while (it.next()) |index| {
        const bits = scope.gameplay.character.bits[index.toInt()];

        characters_buf[count] = .{
            .level = bits.level.toInt(),
            .exp = bits.exp.toInt(),
            .break_level = bits.break_level.toInt(),
            .inst_id = index.toInstId(),
            .character_id = @backingInt(index.toId()),
            .motive_uniq_id = @backingInt(scope.gameplay.character.motives[index.toInt()]),
        };

        count += 1;
    }

    try scope.sink.send(.SC_RES_CHARACTER_LIST, @as(protobuf.gen.SC_Character_List_Rsp, .{
        .list = characters_buf[0..count],
    }));
}

pub fn CS_CHARACTER_HEAL_REQ(scope: *Scope) Scope.Error!void {
    const character = &scope.gameplay.character;
    const character_team = &scope.gameplay.character_team;
    const active_characters = character_team.members[@backingInt(character_team.bits.current_team)];

    for (active_characters) |character_index_maybe| {
        const character_index = character_index_maybe.unwrap() orelse continue;
        const bits = character.bits[@backingInt(character_index)];

        if (character.snapshots[@backingInt(character_index)].unwrap()) |snapshot_prev| {
            const dev_attributes = scope.asset_index.getDevelopAttributes(character_index);
            scope.gameplay.character.snapshots[@backingInt(character_index)] = .wrap(.{
                .hp = dev_attributes.maxhp *
                    assets.getScaleForLevel(.scale_maxhp, bits.level, bits.break_level),
                .permanent_liquid = snapshot_prev.permanent_liquid,
            });
        }

        var attr_buffer: protobuf.packers.Buffer(
            protobuf.packers.CharacterAttribDataBuffer,
            1,
        ) = undefined;
        var attr_list = attr_buffer.toList();

        protobuf.packers.packCharacterAttribData(
            scope.asset_index,
            &attr_list,
            character_index,
            bits,
            character.snapshots[@backingInt(character_index)],
        );

        try scope.sink.send(.SC_OUTSIDE_ATTRIB_NTF, @as(
            protobuf.gen.SC_Outside_Attrib_Ntf,
            .{ .data = attr_list.items(.data)[0] }, // why this is not a repeated field? lol.
        ));
    }

    try scope.sink.send(.SC_CHARACTER_HEAL_RES, @as(protobuf.gen.SC_Character_Heal_Res, .init));

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}
