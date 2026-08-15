const std = @import("std");
const ArrayList = std.ArrayList;

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const packers = roze.protobuf.packers;
const Gameplay = roze.Gameplay;
const Scope = roze.Scope;

pub fn CS_CHARACTER_TEAMS(scope: *Scope) Scope.Error!void {
    var team_data_buffer: packers.Buffer(
        packers.TeamDataBuffer,
        Gameplay.Character.Team.count,
    ) = undefined;
    var team_data_list = team_data_buffer.toList();

    for (scope.gameplay.character_team.members, 0..) |character_indexes, team_index_int| {
        const team_index: Gameplay.Character.Team.Index = @fromBackingInt(@intCast(team_index_int));
        packers.packTeamData(&team_data_list, team_index, character_indexes);
    }

    var team_character_attrib_buffer: packers.Buffer(
        packers.CharacterAttribDataBuffer,
        Gameplay.Character.Team.members_per_team,
    ) = undefined;
    var team_character_attrib_list = team_character_attrib_buffer.toList();
    packCharacterAttribListForCurrentTeam(&team_character_attrib_list, scope);

    const response: protobuf.gen.SC_Character_Teams = .{
        .teams = team_data_list.items(.data),
        .cur_team = .{
            .team_data = team_data_list.items(.data)[
                @backingInt(
                    scope.gameplay.character_team.bits.current_team,
                )
            ],
            .using_member_slot = scope.gameplay.character_team.bits.using_slot.toSlotId(),
            .attrib_data = team_character_attrib_list.items(.data),
            .team_src = .{ .src = 0, .src_ext = 0 },
            .temporary_liquid = .init,
        },
    };

    try scope.sink.send(.SC_CHARACTER_TEAMS, response);
}

pub fn CS_CHARACTER_UPDATE_TEAM(scope: *Scope) Scope.Error!void {
    const log = std.log.scoped(.@"roze::commands::character_update_team");

    const request = try scope.command.take(protobuf.gen.CS_Character_Update_Team.Decoded);
    var team_data_in = request.team_data orelse {
        log.debug("team_data is null", .{});
        return try scope.sink.send(
            .SC_CHARACTER_UPDATE_TEAM,
            @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
        );
    };

    const team_index = Gameplay.Character.Team.Index.fromTeamId(team_data_in.team_id) orelse {
        log.debug("invalid team id: {d}", .{team_data_in.team_id});
        return try scope.sink.send(
            .SC_CHARACTER_UPDATE_TEAM,
            @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
        );
    };

    var new_members: Gameplay.Character.Team.Members = @splat(.none);
    var first_used_slot_maybe: ?Gameplay.Character.Team.Slot = null;
    var count_in_member_data: u32 = 0;

    while (try team_data_in.member_data.next()) |member_in| {
        count_in_member_data += 1;
        if (count_in_member_data > Gameplay.Character.Team.members_per_team) {
            log.debug("too many team members", .{});

            return try scope.sink.send(
                .SC_CHARACTER_UPDATE_TEAM,
                @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
            );
        }

        const slot = Gameplay.Character.Team.Slot.fromSlotId(member_in.member_slot_id) orelse {
            log.debug("invalid member slot id: {d}", .{member_in.member_slot_id});
            return try scope.sink.send(
                .SC_CHARACTER_UPDATE_TEAM,
                @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
            );
        };

        if (new_members[@backingInt(slot)] != .none) {
            log.debug("duplicated member at slot with id {d}", .{member_in.member_slot_id});
            return try scope.sink.send(
                .SC_CHARACTER_UPDATE_TEAM,
                @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
            );
        }

        const character_index = Gameplay.Character.Index.fromInstId(member_in.inst_id) orelse {
            log.debug("invalid character inst id: {d}", .{member_in.inst_id});
            return try scope.sink.send(
                .SC_CHARACTER_UPDATE_TEAM,
                @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
            );
        };

        if (!scope.gameplay.character.unlocked.isSet(@backingInt(character_index))) {
            log.debug("character with inst id {d} is not unlocked", .{member_in.inst_id});
            return try scope.sink.send(
                .SC_CHARACTER_UPDATE_TEAM,
                @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
            );
        }

        new_members[@backingInt(slot)] = .wrap(character_index);

        if (first_used_slot_maybe == null)
            first_used_slot_maybe = slot;
    }

    const first_used_slot = first_used_slot_maybe orelse {
        log.debug("not a single team member is set", .{});
        return try scope.sink.send(
            .SC_CHARACTER_UPDATE_TEAM,
            @as(protobuf.gen.SC_Character_Update_Team, .{ .result = -1 }),
        );
    };

    scope.gameplay.character_team.members[@backingInt(team_index)] = new_members;

    var team_character_attrib_buffer: packers.Buffer(
        packers.CharacterAttribDataBuffer,
        Gameplay.Character.Team.members_per_team,
    ) = undefined;
    var team_character_attrib_list = team_character_attrib_buffer.toList();

    if (scope.gameplay.character_team.bits.current_team == team_index) {
        if (new_members[@backingInt(scope.gameplay.character_team.bits.using_slot)] == .none)
            scope.gameplay.character_team.bits.using_slot = first_used_slot;

        packCharacterAttribListForCurrentTeam(&team_character_attrib_list, scope);
    }

    var team_data_buffer: packers.Buffer(
        packers.TeamDataBuffer,
        1,
    ) = undefined;
    var team_data_list = team_data_buffer.toList();
    packers.packTeamData(&team_data_list, team_index, new_members);

    const response: protobuf.gen.SC_Character_Update_Team = .{
        .team_data = team_data_list.items(.data)[0],
        .using_member_slot = scope.gameplay.character_team.bits.using_slot.toSlotId(),
        .attrib_data = team_character_attrib_list.items(.data),
    };

    try scope.sink.send(.SC_CHARACTER_UPDATE_TEAM, response);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

pub fn CS_CHARACTER_SWITCH_TEAM(scope: *Scope) Scope.Error!void {
    const log = std.log.scoped(.@"roze::commands::character_switch_team");

    const request = try scope.command.take(protobuf.gen.CS_Character_Switch_Team.Decoded);
    const team_index = Gameplay.Character.Team.Index.fromTeamId(request.team_id) orelse {
        log.debug("invalid team id: {d}", .{request.team_id});
        return try scope.sink.send(
            .SC_CHARACTER_SWITCH_TEAM,
            @as(protobuf.gen.SC_Character_Switch_Team, .{ .result = -1 }),
        );
    };

    if (team_index == scope.gameplay.character_team.bits.current_team) {
        log.debug("team with specified id is already active", .{});
        return try scope.sink.send(
            .SC_CHARACTER_SWITCH_TEAM,
            @as(protobuf.gen.SC_Character_Switch_Team, .{ .result = -1 }),
        );
    }

    const prev_using_slot = scope.gameplay.character_team.bits.using_slot;
    const switch_to_team_members = scope.gameplay.character_team.members[@backingInt(team_index)];

    const new_using_slot: Gameplay.Character.Team.Slot =
        if (switch_to_team_members[@backingInt(prev_using_slot)] != .none)
            prev_using_slot
        else find_new: for (switch_to_team_members, 0..) |character_index_maybe, slot_index| {
            if (character_index_maybe != .none)
                break :find_new @fromBackingInt(@intCast(slot_index));
        } else {
            log.debug(
                "tried to switch to team with id {d} while it doesn't have any members",
                .{request.team_id},
            );

            return try scope.sink.send(
                .SC_CHARACTER_SWITCH_TEAM,
                @as(protobuf.gen.SC_Character_Switch_Team, .{ .result = -1 }),
            );
        };

    scope.gameplay.character_team.bits.current_team = team_index;
    scope.gameplay.character_team.bits.using_slot = new_using_slot;

    var team_character_attrib_buffer: packers.Buffer(
        packers.CharacterAttribDataBuffer,
        Gameplay.Character.Team.members_per_team,
    ) = undefined;
    var team_character_attrib_list = team_character_attrib_buffer.toList();
    packCharacterAttribListForCurrentTeam(&team_character_attrib_list, scope);

    const response: protobuf.gen.SC_Character_Switch_Team = .{
        .team_id = team_index.toTeamId(),
        .using_member_slot = new_using_slot.toSlotId(),
        .attrib_data = team_character_attrib_list.items(.data),
    };

    try scope.sink.send(.SC_CHARACTER_SWITCH_TEAM, response);

    errdefer comptime unreachable; // Ensure that it's safe to request save.
    scope.store.requestGameplayStateSave();
}

fn packCharacterAttribListForCurrentTeam(
    list: *packers.List(packers.CharacterAttribDataBuffer),
    scope: *Scope,
) void {
    for (
        &scope.gameplay.character_team.members[
            @backingInt(scope.gameplay.character_team.bits.current_team)
        ],
    ) |character_index_maybe| {
        const character_index = character_index_maybe.unwrap() orelse continue;

        protobuf.packers.packCharacterAttribData(
            scope.asset_index,
            list,
            character_index,
            scope.gameplay.character.bits[character_index.toInt()],
            scope.gameplay.character.snapshots[character_index.toInt()],
        );
    }
}
