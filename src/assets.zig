const std = @import("std");
const fatal = std.process.fatal;
const assert = std.debug.assert;

const roze = @import("roze.zig");
const Gameplay = roze.Gameplay;

pub const tables = @import("assets/tables.zig");

/// Runtime asset indexer.
pub const Index = struct {
    character_develop_attributes: [tables.character.len]*const tables.P_DevelopAttribute,

    pub fn init(index: *Index) void {
        for (tables.character, &index.character_develop_attributes) |*character, *develop_attribute| {
            develop_attribute.* = lookup: for (tables.develop_attribute) |*config| {
                if (config.id == character.develop_attribute_id)
                    break :lookup config;
            } else fatal("no develop attribute for character {d}", .{character.id});
        }
    }

    pub fn getDevelopAttributes(
        index: *const Index,
        character: Gameplay.Character.Index,
    ) *const tables.P_DevelopAttribute {
        return index.character_develop_attributes[character.toInt()];
    }
};

pub fn getScaleForLevel(
    kind: enum {
        scale_maxhp,
        scale_atk,
        scale_def,
    },
    level: Gameplay.Character.Level,
    break_level: Gameplay.Character.BreakLevel,
) i32 {
    const index = @as(u8, @backingInt(level)) + @as(u8, @backingInt(break_level)) - 1;
    const template = &tables.level_up_template[index];
    assert(template.level == @backingInt(level));
    assert(template.break_level == @backingInt(break_level));

    return switch (kind) {
        inline else => |kind_comptime| @intCast(@field(template, @tagName(kind_comptime))),
    };
}
