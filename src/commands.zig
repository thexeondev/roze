const std = @import("std");
const assert = std.debug.assert;

const roze = @import("roze.zig");
const EClientServerCmds = roze.protobuf.gen.EClientServerCmds;

const log = std.log.scoped(.@"roze::commands");

pub const Buffer = struct {
    id: u32,
    data: []const u8,

    pub const Error = roze.protobuf.DecodeError;

    pub fn take(buffer: *const Buffer, comptime Command: type) Buffer.Error!Command {
        comptime assert(!@hasDecl(Command, "Decoded"));
        return try roze.protobuf.decode(Command, buffer.data);
    }
};

const HandlerFn = *const fn (*roze.Scope) roze.Scope.Error!void;

const handlers: []const ?HandlerFn = handlers: {
    var array: [@backingInt(EClientServerCmds.CS_CMD_MAX)]?HandlerFn = @splat(null);

    for (namespaces) |namespace| for (@typeInfo(namespace).@"struct".decl_names) |decl_name| {
        const handler = &@field(namespace, decl_name);
        assert(@TypeOf(handler) == HandlerFn);

        const cmd = @field(EClientServerCmds, decl_name);

        if (array[@backingInt(cmd)] != null)
            @compileError("handler for '" ++ @tagName(cmd) ++ "' defined twice");

        array[@backingInt(cmd)] = handler;
    };

    // This adds a bunch of zeroes to end executable,
    // but we're getting free cmd-to-handler dispatching.
    const final = array;
    break :handlers &final;
};

/// Executes `scope.command`
pub fn execute(scope: *roze.Scope) roze.Scope.Error!void {
    const id = scope.command.id;

    if (id < 0 or id > handlers.len)
        log.warn("command id out of range: {d}", .{id});

    return if (handlers[id]) |handler| {
        try handler(scope);
        log.debug(
            "player with id {d} executed command {t}",
            .{ scope.store.role_id, @as(EClientServerCmds, @fromBackingInt(@intCast(id))) },
        );
    } else if (std.enums.fromInt(EClientServerCmds, id)) |tag|
        log.warn("unhandled command: {t}", .{tag})
    else
        log.warn("illegal command id: {d}", .{id});
}

const namespaces: []const type = &.{
    @import("commands/account.zig"),
    @import("commands/setting.zig"),
    @import("commands/unlock.zig"),
    @import("commands/red_point.zig"),
    @import("commands/limit_group.zig"),
    @import("commands/attrib.zig"),
    @import("commands/character.zig"),
    @import("commands/item_bag.zig"),
    @import("commands/talent.zig"),
    @import("commands/equipment.zig"),
    @import("commands/constellation.zig"),
    @import("commands/character_team.zig"),
    @import("commands/character_tmp.zig"),
    @import("commands/map_panel.zig"),
    @import("commands/map.zig"),
    @import("commands/compose.zig"),
    @import("commands/patrol_monster.zig"),
    @import("commands/rookie_guide.zig"),
    @import("commands/guide.zig"),
    @import("commands/dungeons.zig"),
    @import("commands/daily_mission.zig"),
    @import("commands/buff.zig"),
    @import("commands/case.zig"),
    @import("commands/month_card.zig"),
    @import("commands/player_region_progress.zig"),
    @import("commands/battle_pass.zig"),
    @import("commands/mini_feature.zig"),
    @import("commands/horse_racing.zig"),
    @import("commands/compendium.zig"),
    @import("commands/letter.zig"),
    @import("commands/hunt.zig"),
    @import("commands/intel_center.zig"),
    @import("commands/task.zig"),
    @import("commands/house.zig"),
    @import("commands/mail.zig"),
    @import("commands/wanted.zig"),
    @import("commands/activity.zig"),
    @import("commands/affinity.zig"),
    @import("commands/shop.zig"),
    @import("commands/urban_memory.zig"),
    @import("commands/battle_verify.zig"),
    @import("commands/battle.zig"),
};
