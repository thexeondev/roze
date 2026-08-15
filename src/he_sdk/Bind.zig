const Bind = @This();
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const roze = @import("../roze.zig");
const Io = roze.Io;

const save_file_name = "sdk_bind.bin";

const Map = std.array_hash_map.Auto(u64, void);

file: Io.File,
map: Map,
lock: bool,

const base_role_id: u64 = 1337;

pub const RoleId = enum(u64) {
    _,

    fn fromIndex(index: usize) RoleId {
        return @fromBackingInt(@intCast(@as(u64, @intCast(index)) + base_role_id));
    }
};

pub const SizeError = error{TooManyAccounts};

pub const InitError = Allocator.Error ||
    Io.File.OpenBlockingError ||
    Io.File.WriteBlockingError ||
    LoadError ||
    error{PathTooLong};

pub fn init(io: *Io, arena: Allocator, store_dir: []const u8, store_size: u32) InitError!Bind {
    var map: Map = .empty;
    try map.ensureTotalCapacity(arena, store_size);

    var path_buf: [4096]u8 = undefined;
    const path = std.mem.printSentinel(&path_buf, "{s}/{s}", .{ store_dir, save_file_name }, 0) catch
        return error.PathTooLong;

    if (Io.File.openBlocking(io, path)) |file| {
        errdefer file.closeBlocking(io);
        try loadFromFile(arena, io, file, &map);

        return .{ .file = file, .map = map, .lock = false };
    } else |err| switch (err) {
        error.FileNotFound => {
            const file = try Io.File.createBlocking(io, path.ptr);
            errdefer file.closeBlocking(io);

            var empty_header: u64 = 0;
            try file.writeAllBlocking(io, @ptrCast(&empty_header), 0);

            return .{ .file = file, .map = map, .lock = false };
        },
        else => |e| return e,
    }
}

pub const LockError = error{StoreLocked};

pub const GetOrCreateError = SizeError || LockError;

pub const GetOrCreate = struct {
    needs_save: bool,
    role_id: RoleId,
};

pub fn getOrCreate(bind: *Bind, sdk_uid: u64) GetOrCreateError!GetOrCreate {
    if (bind.lock) return error.StoreLocked;

    if (bind.map.getIndex(sdk_uid)) |index|
        return .{ .needs_save = false, .role_id = .fromIndex(index) };

    if (bind.map.entries.len == bind.map.entries.capacity)
        return error.TooManyAccounts;

    const index = bind.map.entries.len;
    bind.map.putAssumeCapacity(sdk_uid, {});

    return .{ .needs_save = true, .role_id = .fromIndex(index) };
}

fn get(bind: *Bind, sdk_uid: u64) ?RoleId {
    const index = bind.map.getIndex(sdk_uid) orelse return null;
    return .fromIndex(index);
}

pub const LoadError = Allocator.Error || Io.File.ReadBlockingError || SizeError || error{
    MalformedFile,
};

/// `arena` is required for `reIndex`.
fn loadFromFile(arena: Allocator, io: *Io, file: Io.File, map: *Map) LoadError!void {
    var count: u64 = undefined;
    file.readAllBlocking(io, @ptrCast(&count), 0) catch |err| switch (err) {
        error.EndOfStream => return error.MalformedFile,
        else => |e| return e,
    };

    if (count > map.entries.capacity)
        return error.TooManyAccounts;

    map.entries.len = count;
    file.readAllBlocking(io, @ptrCast(map.keys()), @sizeOf(u64)) catch |err| switch (err) {
        error.EndOfStream => return error.MalformedFile,
        else => |e| return e,
    };

    try map.reIndex(arena);
    try map.ensureTotalCapacity(arena, map.entries.capacity);
}

pub const SaveHeaderBuffer = [8]u8;
pub const SaveVector = [2]Io.Buffer(.@"const");

pub fn getSaveVector(bind: *Bind, header_buffer: *SaveHeaderBuffer) SaveVector {
    comptime assert(@sizeOf(u64) == @sizeOf(SaveHeaderBuffer));

    const length: u64 = @intCast(bind.map.entries.len);
    header_buffer.* = @bitCast(length);

    var bufs: [2]Io.Buffer(.@"const") = undefined;
    bufs[0].init(header_buffer);
    bufs[1].init(@ptrCast(bind.map.keys()));
    return bufs;
}
