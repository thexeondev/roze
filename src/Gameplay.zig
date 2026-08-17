const Gameplay = @This();
const std = @import("std");
const assert = std.debug.assert;
const IntegerBitSet = std.bit_set.IntegerBitSet;

const roze = @import("roze.zig");
const Io = roze.Io;
const assets = roze.assets;

const log = std.log.scoped(.@"roze::Gameplay");

map: Map,
character: Character,
character_team: Character.Team,

pub const init: Gameplay = .{
    .map = .init,
    .character = .init,
    .character_team = .init,
};

pub const Map = extern struct {
    id: u64,
    last_location: [3]i32,
    padding: i32 = 0,

    pub const init: Map = .{
        .id = 100001002004,
        .last_location = .{ 40462, 104829, 32967 },
    };
};

pub const Character = struct {
    pub const count = assets.tables.character.len;
    pub const Set = IntegerBitSet(Character.count);

    unlocked: Character.Set,
    bits: [Character.count]Bits,
    motives: [Character.count]MotiveUniqueId.Optional,
    snapshots: [Character.count]Snapshot.Optional,

    pub const init: Character = .{
        .unlocked = .full,
        .bits = @splat(.init),
        .motives = @splat(.none),
        .snapshots = @splat(.none),
    };

    /// Yields unlocked character indexes.
    pub fn iterator(character: *Character) Character.Iterator {
        return .{ .inner = character.unlocked.iterator(.{}) };
    }

    pub const Index = enum(u32) {
        _,

        pub const default = Character.Id.default.toIndex();

        /// Asserts bounds.
        pub fn fromInt(int: usize) Index {
            assert(int < Character.count);
            return @fromBackingInt(@intCast(int));
        }

        pub fn toInt(index: Character.Index) u32 {
            return @backingInt(index);
        }

        pub fn toId(index: Character.Index) Character.Id {
            return Id.list[@backingInt(index)];
        }

        /// We're using `index + 1` value as an "inst id"
        pub fn toInstId(index: Character.Index) u64 {
            return @backingInt(index) + 1;
        }

        pub fn fromInstId(inst_id: u64) ?Character.Index {
            if (inst_id == 0 or (inst_id - 1) > Character.count) return null;
            return @fromBackingInt(@intCast(inst_id - 1));
        }

        pub const Optional = enum(u32) {
            none = std.math.maxInt(u32),
            _,

            pub fn wrap(index: Character.Index) Character.Index.Optional {
                assert(@backingInt(index) != @backingInt(Optional.none));
                return @fromBackingInt(@backingInt(index));
            }

            pub fn unwrap(optional: Character.Index.Optional) ?Character.Index {
                return switch (optional) {
                    .none => null,
                    _ => @fromBackingInt(@backingInt(optional)),
                };
            }
        };
    };

    pub const Id = enum(u32) {
        _,

        pub const default = Character.Id.fromInt(1504).?;

        pub const list: []const Id = list: {
            @setEvalBranchQuota(assets.tables.character.len);
            var result: [assets.tables.character.len]Id = undefined;
            for (&result, assets.tables.character) |*id, config|
                id.* = @fromBackingInt(config.id);

            const final = result;
            break :list &final;
        };

        pub fn fromInt(int: usize) ?Character.Id {
            // See `std.enums.fromInt` implementation
            for (Id.list) |id| if (@backingInt(id) == int)
                return id;

            return null;
        }

        pub fn toIndex(id: Character.Id) Character.Index {
            return @fromBackingInt(@intCast(std.mem.findScalar(Id, list, id).?));
        }
    };

    pub const Iterator = struct {
        inner: IntegerBitSet(Character.count).Iterator(.{}),

        pub fn next(it: *Character.Iterator) ?Character.Index {
            return @fromBackingInt(@intCast(it.inner.next() orelse return null));
        }
    };

    pub const Bits = packed struct(u32) {
        level: Level,
        break_level: BreakLevel,
        exp: Exp,
        _: u6 = 0,

        pub const init: Bits = .{
            .level = .init,
            .break_level = .init,
            .exp = .zero,
        };
    };

    pub const Level = enum(u7) {
        init = 1,
        limit = 90,
        _,

        pub fn toInt(l: Level) u7 {
            return @backingInt(l);
        }
    };

    pub const BreakLevel = enum(u3) {
        init = 0,
        limit = 6,
        _,

        pub fn toInt(bl: BreakLevel) u3 {
            return @backingInt(bl);
        }
    };

    pub const Exp = enum(u16) {
        zero = 0,
        _,

        pub fn toInt(e: Exp) u16 {
            return @backingInt(e);
        }
    };

    pub const MotiveUniqueId = enum(u64) {
        _,

        pub const Optional = enum(u64) {
            none = 0,
            _,

            pub fn wrap(uid: MotiveUniqueId) MotiveUniqueId.Optional {
                assert(@backingInt(uid) != 0);
                return @fromBackingInt(@backingInt(uid));
            }

            pub fn unwrap(o: Optional) ?MotiveUniqueId {
                return switch (o) {
                    .none => null,
                    else => @fromBackingInt(@backingInt(o)),
                };
            }
        };
    };

    pub const Snapshot = packed struct(u64) {
        hp: i32,
        permanent_liquid: i32,

        pub const Optional = enum(u64) {
            none = 0,
            _,

            pub fn wrap(snapshot: Character.Snapshot) Character.Snapshot.Optional {
                return @fromBackingInt(@backingInt(snapshot));
            }

            pub fn unwrap(o: Character.Snapshot.Optional) ?Character.Snapshot {
                return switch (o) {
                    .none => null,
                    _ => @as(Character.Snapshot, @fromBackingInt(@backingInt(o))),
                };
            }
        };
    };

    pub const Team = struct {
        pub const count = 15;
        pub const members_per_team = 4;

        members: [Character.Team.count]Members,
        bits: Character.Team.Bits,

        pub const init: Character.Team = .{
            .members = @splat(
                .{ .wrap(.default), .none, .none, .none },
            ),
            .bits = .{
                .current_team = @fromBackingInt(0),
                .using_slot = @fromBackingInt(0),
            },
        };

        pub const Members = [Character.Team.members_per_team]Character.Index.Optional;

        pub const Bits = packed struct(u8) {
            current_team: Character.Team.Index,
            using_slot: Character.Team.Slot,
            _: u2 = 0,
        };

        pub const Slot = enum(u2) {
            _,

            pub fn fromSlotId(id: u32) ?Character.Team.Slot {
                if (id == 0) return null;
                if ((id - 1) >= Character.Team.members_per_team) return null;

                return @fromBackingInt(@intCast(id - 1));
            }

            pub fn toSlotId(slot: Character.Team.Slot) u8 {
                return @as(u8, @backingInt(slot)) + 1;
            }
        };

        pub const Index = enum(u4) {
            _,

            pub fn fromTeamId(id: u32) ?Character.Team.Index {
                if (id == 0) return null;
                if ((id - 1) >= Character.Team.count) return null;

                return @fromBackingInt(@intCast(id - 1));
            }

            pub fn toTeamId(index: Character.Team.Index) u8 {
                return @backingInt(index) + 1;
            }
        };
    };
};

pub const Attr = enum(i32) {
    pub const count = @typeInfo(Attr).@"enum".field_names.len;

    maxhp = 101,
    atk = 102,
    def = 103,
    atk_critical_chance = 104,
    atk_critical_damage = 105,
    def_critical_damage_res = 106,
    blood_absorption_efficiency = 107,
    atk_heal_add_rate = 108,
    def_heal_add_rate = 109,
    atk_ignore_target_defence = 110,
    atk_body_part_break_add_rate = 113,
    atk_slash_spec = 121,
    atk_strike_spec = 122,
    atk_pierce_spec = 123,
    atk_fire_spec = 131,
    atk_ice_spec = 132,
    atk_thunder_spec = 133,
    atk_gravity_spec = 134,
    atk_radiation_spec = 135,
    atk_silver_spec = 136,
    atk_blackiron_spec = 137,
    atk_normal_spec = 138,
    atk_burst_spec = 141,
    atk_pursue_break_def = 1164,
    atk_pursue_catalyst = 1165,
    atk_abn_elem_master = 1171,
    atk_fire_damage_add_rate = 311,
    atk_ice_damage_add_rate = 313,
    atk_thunder_damage_add_rate = 315,
    atk_gravity_damage_add_rate = 317,
    atk_radiation_damage_add_rate = 319,
    atk_silver_damage_add_rate = 327,
    atk_black_iron_damage_add_rate = 329,
    liquid_absorb_rate = 1149,
    atk_abn_elem_accum_efficiency = 1185,
    atk_non_break_damage = 1207,
    atk_abn_critical_chance = 1204,
    atk_abn_critical_damage = 1205,
    horse_stamina_cost_modifier = 1220,

    hp = 1001,
    permanent_liquid = 1150,
};

pub const Header = extern struct {
    const version: u32 = 1;

    state_version: u32,
};

pub fn StateVector(comptime mut: Io.Mutability) type {
    // Increase this number when adding a new field.
    return [8]Io.Buffer(mut);
}

pub fn writableVector(gameplay: *Gameplay, header_buffer: *Header, bufs: *StateVector(.@"var")) void {
    // Increase this number when adding a new field.
    // Don't be tempted to make it a constant elsewhere,
    // as this has to be in-sync with the code below.
    comptime assert(bufs.len == 8);

    bufs[0].init(@ptrCast(header_buffer));
    bufs[1].init(@ptrCast(&gameplay.map));
    bufs[2].init(@ptrCast(&gameplay.character.unlocked));
    bufs[3].init(@ptrCast(&gameplay.character.bits));
    bufs[4].init(@ptrCast(&gameplay.character.motives));
    bufs[5].init(@ptrCast(&gameplay.character.snapshots));
    bufs[6].init(@ptrCast(&gameplay.character_team.members));
    bufs[7].init(@ptrCast(&gameplay.character_team.bits));
}

pub fn readableVector(gameplay: *Gameplay, header_buffer: *Header, bufs: *StateVector(.@"const")) void {
    // Increase this number when adding a new field.
    // Don't be tempted to make it a constant elsewhere,
    // as this has to be in-sync with the code below.
    comptime assert(bufs.len == 8);

    header_buffer.* = .{ .state_version = Header.version };
    bufs[0].init(@ptrCast(header_buffer));
    bufs[1].init(@ptrCast(&gameplay.map));
    bufs[2].init(@ptrCast(&gameplay.character.unlocked));
    bufs[3].init(@ptrCast(&gameplay.character.bits));
    bufs[4].init(@ptrCast(&gameplay.character.motives));
    bufs[5].init(@ptrCast(&gameplay.character.snapshots));
    bufs[6].init(@ptrCast(&gameplay.character_team.members));
    bufs[7].init(@ptrCast(&gameplay.character_team.bits));
}
