const std = @import("std");
const fatal = std.process.fatal;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const roze = @import("roze.zig");
const Gameplay = roze.Gameplay;

pub const tables = @import("assets/tables.zig");

pub const NpcLists = struct {
    save_point_npc_ids: []const u64,
    /// Guaranteed to have same length as `save_point_ids`
    save_point_map_ids: []const u64,
};

pub const npc_lists: NpcLists = npc_lists: {
    var save_point_npc_ids: [tables.functional_npc.len]u64 = undefined;
    var save_point_map_ids: [tables.functional_npc.len]u64 = undefined;
    var save_point_count: usize = 0;

    @setEvalBranchQuota(tables.functional_npc.len);
    for (tables.functional_npc) |functional_npc| {
        const npc_type: tables.FunctionalNpcType = @fromBackingInt(functional_npc.type);

        switch (npc_type) {
            .save_point => {
                defer save_point_count += 1;

                save_point_npc_ids[save_point_count] = functional_npc.id;
                save_point_map_ids[save_point_count] = functional_npc.map_id;
            },
            else => {},
        }
    }

    const final_save_point_npc_ids = save_point_npc_ids[0..save_point_count].*;
    const final_save_point_map_ids = save_point_map_ids[0..save_point_count].*;

    break :npc_lists .{
        .save_point_npc_ids = &final_save_point_npc_ids,
        .save_point_map_ids = &final_save_point_map_ids,
    };
};

/// Runtime asset indexer.
pub const Index = struct {
    character_develop_attributes: [tables.character.len]*const tables.P_DevelopAttribute,
    sub_region_progress: std.array_hash_map.Auto(u64, *const tables.P_RegionProgress),
    sub_region_sequence: std.array_hash_map.Auto(u64, *const tables.P_RegionSequence),

    pub fn init(index: *Index, arena: Allocator) Allocator.Error!void {
        for (tables.character, &index.character_develop_attributes) |*character, *develop_attribute| {
            develop_attribute.* = lookup: for (tables.develop_attribute) |*config| {
                if (config.id == character.develop_attribute_id)
                    break :lookup config;
            } else fatal("no develop attribute for character {d}", .{character.id});
        }

        index.sub_region_progress = .empty;
        try index.sub_region_progress.ensureTotalCapacity(arena, tables.sub_region_config_read_target.len);

        var sequence_count: usize = 0;

        inline for (@typeInfo(tables.region_progress_sheets).@"struct".decl_names) |sheet_name| {
            const progress_sheet = @field(tables.region_progress_sheets, sheet_name);
            for (progress_sheet) |*config| {
                index.sub_region_progress.putAssumeCapacity(config.id, config);
                sequence_count += config.sequence_id.len;
            }
        }

        index.sub_region_sequence = .empty;
        try index.sub_region_sequence.ensureTotalCapacity(arena, sequence_count);

        inline for (@typeInfo(tables.region_sequence_sheets).@"struct".decl_names) |sheet_name| {
            const sequence_sheet = @field(tables.region_sequence_sheets, sheet_name);
            for (sequence_sheet) |*config|
                index.sub_region_sequence.putAssumeCapacity(config.id, config);
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
