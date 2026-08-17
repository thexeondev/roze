const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;

const roze = @import("../roze.zig");
const assets = roze.assets;
const protobuf = roze.protobuf;
const Gameplay = roze.Gameplay;

pub fn Buffer(comptime Struct: type, comptime n: usize) type {
    return struct {
        const struct_info = @typeInfo(Struct).@"struct";

        pub const Data = Data: {
            var array_types: [struct_info.field_types.len]type = undefined;
            for (&array_types, struct_info.field_types) |*ArrayType, FieldType|
                ArrayType.* = [n]FieldType;

            break :Data @Struct(.auto, null, struct_info.field_names, &array_types, &@splat(.{}));
        };

        data: Data,

        pub fn toList(b: *@This()) List(Struct) {
            var list: List(Struct) = .{
                .ptrs = undefined,
                .capacity = n,
                .count = 0,
            };

            inline for (&list.ptrs, struct_info.field_names) |*ptr, field_name| {
                ptr.* = @ptrCast(&@field(b.data, field_name));
            }

            return list;
        }
    };
}

pub fn List(comptime Struct: type) type {
    const struct_info = @typeInfo(Struct).@"struct";

    return struct {
        ptrs: [struct_info.field_names.len][*]u8,
        capacity: u32,
        count: u32,

        pub fn items(
            list: *@This(),
            comptime field: std.meta.FieldEnum(Struct),
        ) []struct_info.field_types[@backingInt(field)] {
            const T = struct_info.field_types[@backingInt(field)];

            return @as([*]T, @ptrCast(@alignCast(list.ptrs[@backingInt(field)])))[0..list.count];
        }

        pub fn addOneAssumeCapacity(list: *@This()) Handle {
            const i = list.count;
            list.count += 1;

            var handle: Handle = undefined;

            inline for (struct_info.field_names, 0..) |field_name, field_index| {
                @field(handle, field_name) = &list.items(@fromBackingInt(field_index))[i];
            }

            return handle;
        }

        pub const Handle = Handle: {
            var pointer_types: [struct_info.field_types.len]type = undefined;
            for (&pointer_types, struct_info.field_types) |*PointerType, FieldType|
                PointerType.* = *FieldType;

            break :Handle @Struct(.auto, null, struct_info.field_names, &pointer_types, &@splat(.{}));
        };
    };
}

pub fn packVector3Int(values: *const [3]i32) protobuf.gen.Vector3Int {
    return .{ .x = values[0], .y = values[1], .z = values[2] };
}

pub const CharacterAttribDataBuffer = struct {
    data: protobuf.gen.PBCharacterAttribData,
    list: [Gameplay.Attr.count]protobuf.gen.PBAttribDataElem,
};

pub fn packCharacterAttribData(
    asset_index: *const assets.Index,
    list: *List(CharacterAttribDataBuffer),
    index: Gameplay.Character.Index,
    bits: Gameplay.Character.Bits,
    optional_snapshot: Gameplay.Character.Snapshot.Optional,
) void {
    const handle = list.addOneAssumeCapacity();
    var attrib_data: std.ArrayList(protobuf.gen.PBAttribDataElem) = .initBuffer(handle.list);

    const dev_attributes = asset_index.getDevelopAttributes(index);

    inline for (@typeInfo(assets.tables.P_DevelopAttribute).@"struct".field_names[1..]) |attr_name| {
        const attrib_type = @field(Gameplay.Attr, attr_name);
        var base_value = @field(dev_attributes, attr_name);

        switch (attrib_type) {
            .maxhp => base_value *= assets.getScaleForLevel(.scale_maxhp, bits.level, bits.break_level),
            .atk => base_value *= assets.getScaleForLevel(.scale_atk, bits.level, bits.break_level),
            .def => base_value *= assets.getScaleForLevel(.scale_def, bits.level, bits.break_level),
            else => {},
        }

        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(attrib_type),
            .total_base = base_value,
            .total_multi = 0,
            .total_add = 0,
        });
    }

    if (optional_snapshot.unwrap()) |snapshot| {
        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.hp),
            .total_base = snapshot.hp,
        });

        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.permanent_liquid),
            .total_base = snapshot.permanent_liquid,
        });
    } else {
        attrib_data.appendAssumeCapacity(.{
            .attrib_type = @backingInt(Gameplay.Attr.hp),
            .total_base = dev_attributes.maxhp *
                assets.getScaleForLevel(.scale_maxhp, bits.level, bits.break_level),
        });
    }

    handle.data.* = .{
        .inst_id = index.toInstId(),
        .attrib_data = attrib_data.items,
    };
}

pub const TeamDataBuffer = struct {
    data: protobuf.gen.TeamData,
    members: [Gameplay.Character.Team.members_per_team]protobuf.gen.TeamMemberData,
};

pub fn packTeamData(
    list: *List(TeamDataBuffer),
    team_index: Gameplay.Character.Team.Index,
    character_indexes: Gameplay.Character.Team.Members,
) void {
    const handle = list.addOneAssumeCapacity();
    var member_slots: ArrayList(protobuf.gen.TeamMemberData) = .initBuffer(handle.members);

    for (character_indexes, 0..) |character_index_maybe, slot_int| {
        const character_index = character_index_maybe.unwrap() orelse continue;
        const slot: Gameplay.Character.Team.Slot = @fromBackingInt(@intCast(slot_int));

        member_slots.appendAssumeCapacity(.{
            .member_slot_id = slot.toSlotId(),
            .inst_id = character_index.toInstId(),
            .character_id = @backingInt(character_index.toId()),
        });
    }

    handle.data.* = .{
        .team_id = team_index.toTeamId(),
        .member_data = member_slots.items,
        .name = "reversedrooms",
    };
}
