const Account = @This();
const std = @import("std");
const mem = std.mem;
const Random = std.Random;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const bcrypt = std.crypto.pwhash.bcrypt;

const roze = @import("../roze.zig");
const Io = roze.Io;

email: Email,
password_hash: PasswordHash,
token: Token,

pub const Identified = struct {
    uid: Uid,
    account: Account,
};

pub const Storage = struct {
    file: Io.File,
    accounts: std.MultiArrayList(Account),
    email_map: std.array_hash_map.Auto(void, void),
    token_map: std.array_hash_map.Auto(void, void),
    /// Indicates whether the storage access is locked.
    /// Currently it happens during asynchronous saves.
    lock: bool,

    const save_file_name = "sdk_accounts.bin";

    pub const SizeError = error{TooManyAccounts};

    const ByEmailAdapter = struct {
        slice: std.MultiArrayList(Account).Slice,

        pub fn hash(ctx: ByEmailAdapter, email: Email) u32 {
            _ = ctx;
            return std.array_hash_map.hashString(email.view());
        }

        pub fn eql(ctx: ByEmailAdapter, a: Email, b: void, b_index: usize) bool {
            _ = b;
            return mem.eql(u8, ctx.slice.items(.email)[b_index].view(), a.view());
        }
    };

    const ByTokenAdapter = struct {
        slice: std.MultiArrayList(Account).Slice,

        pub fn hash(ctx: ByTokenAdapter, token: Token) u32 {
            _ = ctx;
            return std.array_hash_map.hashString(&token.string);
        }

        pub fn eql(ctx: ByTokenAdapter, a: Token, b: void, b_index: usize) bool {
            _ = b;
            return mem.eql(u8, &ctx.slice.items(.token)[b_index].string, &a.string);
        }
    };

    pub const InitError = Allocator.Error || Io.File.OpenBlockingError || Io.File.WriteBlockingError || error{
        PathTooLong,
    } || ReadFromFileError;

    pub fn init(
        storage: *Storage,
        io: *Io,
        arena: Allocator,
        size: u32,
        store_dir: []const u8,
    ) InitError!void {
        storage.lock = false;
        storage.accounts = try .initCapacity(arena, size);

        storage.email_map = .empty;
        try storage.email_map.ensureTotalCapacity(arena, size);

        storage.token_map = .empty;
        try storage.token_map.ensureTotalCapacity(arena, size);

        var path_buf: [4096]u8 = undefined;
        const path = mem.printSentinel(&path_buf, "{s}/{s}", .{ store_dir, save_file_name }, 0) catch
            return error.PathTooLong;

        if (Io.File.openBlocking(io, path.ptr)) |file| {
            errdefer file.closeBlocking(io);
            try storage.readFromFileBlocking(io, file);

            storage.file = file;
        } else |err| switch (err) {
            error.FileNotFound => {
                const file = try Io.File.createBlocking(io, path.ptr);
                errdefer file.closeBlocking(io);

                var empty_header: u64 = 0;
                try file.writeAllBlocking(io, @ptrCast(&empty_header), 0);

                storage.file = file;
            },
            else => |e| return e,
        }
    }

    pub fn deinit(storage: *Storage, io: *Io) void {
        storage.file.closeBlocking(io);
    }

    fn vector(
        comptime mutability: Io.Mutability,
        s: switch (mutability) {
            .@"var" => *Storage,
            .@"const" => *const Storage,
        },
    ) [@typeInfo(Account).@"struct".field_names.len]Io.Buffer(mutability) {
        var vec: [@typeInfo(Account).@"struct".field_names.len]Io.Buffer(mutability) = undefined;
        const slice = s.accounts.slice();

        inline for (std.enums.values(std.MultiArrayList(Account).Field), 0..) |field, i|
            vec[i].init(@ptrCast(slice.items(field)));

        return vec;
    }

    pub const LockError = error{StorageLocked};

    pub const GetOrCreateError = PasswordHash.HashError || SizeError || LockError;

    pub const GetOrCreate = struct {
        needs_save: bool,
        identified: Identified,
    };

    pub fn getOrCreateByEmail(
        s: *Storage,
        random: Random,
        email: Email,
        password: []const u8,
    ) GetOrCreateError!?GetOrCreate {
        if (s.lock) return error.StorageLocked;

        if (s.getByEmail(email, password)) |identified|
            return .{ .needs_save = false, .identified = identified }
        else |err| switch (err) {
            error.NotFound => {},
            error.PasswordMismatch => return null,
            else => |e| return e,
        }

        const password_hash: PasswordHash = try .hash(random, password);

        const index = s.accounts.len;
        s.accounts.appendBounded(.{
            .email = email,
            .password_hash = password_hash,
            .token = .random(.fromIndex(index), random),
        }) catch return error.TooManyAccounts;

        const slice = s.accounts.slice();
        const by_email_adapter: ByEmailAdapter = .{ .slice = slice };
        _ = s.email_map.getOrPutAssumeCapacityAdapted(email, by_email_adapter);
        const by_token_adapter: ByTokenAdapter = .{ .slice = slice };
        _ = s.token_map.getOrPutAssumeCapacityAdapted(slice.items(.token)[index], by_token_adapter);

        return .{ .needs_save = true, .identified = .{
            .uid = .fromIndex(@intCast(index)),
            .account = slice.get(index),
        } };
    }

    pub fn getByToken(s: *Storage, token: Token) LockError!?Identified {
        if (s.lock) return error.StorageLocked;

        const slice = s.accounts.slice();
        const adapter: ByTokenAdapter = .{ .slice = slice };
        const index = s.token_map.getIndexAdapted(token, adapter) orelse return null;

        return .{
            .uid = .fromIndex(index),
            .account = slice.get(index),
        };
    }

    fn getByEmail(s: *Storage, email: Email, password: []const u8) !Identified {
        const slice = s.accounts.slice();
        const adapter: ByEmailAdapter = .{ .slice = slice };
        const index = s.email_map.getIndexAdapted(email, adapter) orelse
            return error.NotFound;

        if (!slice.items(.password_hash)[index].eql(password))
            return error.PasswordMismatch;

        return .{
            .uid = .fromIndex(index),
            .account = slice.get(index),
        };
    }

    pub const ReadFromFileError = Io.File.ReadBlockingError || SizeError || error{
        /// The store file is malformed.
        MalformedFile,
    };

    fn readFromFileBlocking(s: *Storage, io: *Io, file: Io.File) ReadFromFileError!void {
        var count: u64 = undefined;
        const header: []u8 = @ptrCast(&count);
        file.readAllBlocking(io, header, 0) catch |err| switch (err) {
            error.EndOfStream => return error.MalformedFile,
            else => |e| return e,
        };

        if (count > s.accounts.capacity) return error.TooManyAccounts;

        s.accounts.len = count;
        if (count == 0) return;

        var data = vector(.@"var", s);
        file.readVecAllBlocking(io, &data, header.len) catch |err| switch (err) {
            error.EndOfStream => return error.MalformedFile,
            else => |e| return e,
        };

        s.reIndex();
    }

    fn reIndex(s: *Storage) void {
        const slice = s.accounts.slice();
        const by_email_adapter: ByEmailAdapter = .{ .slice = slice };
        const by_token_adapter: ByTokenAdapter = .{ .slice = slice };

        for (slice.items(.email), slice.items(.token)) |email, token| {
            _ = s.email_map.getOrPutAssumeCapacityAdapted(email, by_email_adapter);
            _ = s.token_map.getOrPutAssumeCapacityAdapted(token, by_token_adapter);
        }
    }

    pub const SaveVector = [@typeInfo(Account).@"struct".field_names.len + 1]Io.Buffer(.@"const");
    pub const SaveHeaderBuffer = [8]u8;

    pub fn getSaveVector(
        s: *const Storage,
        header_buffer: *SaveHeaderBuffer,
    ) SaveVector {
        var vec: [@typeInfo(Account).@"struct".field_names.len + 1]Io.Buffer(.@"const") = undefined;
        header_buffer.* = @bitCast(s.accounts.len);
        vec[0].init(header_buffer);

        const slice = s.accounts.slice();

        inline for (std.enums.values(std.MultiArrayList(Account).Field), vec[1..]) |field, *buf|
            buf.init(@ptrCast(slice.items(field)));

        return vec;
    }
};

pub const Uid = enum(u64) {
    _,

    pub const string_length = 20;

    pub fn print(uid: Uid, buffer: *[string_length]u8) []u8 {
        return mem.print(buffer, "{d}", .{@backingInt(uid)}) catch unreachable;
    }

    pub fn fromIndex(index: u64) Uid {
        return @fromBackingInt(index + 1);
    }

    pub fn toIndex(uid: Uid) u64 {
        return @backingInt(uid) - 1;
    }
};

pub const Email = extern struct {
    const max_length = 63;
    buffer: [max_length]u8,

    pub fn fromSlice(slice: []const u8) ?Email {
        if (slice.len > max_length)
            return null;

        for (slice) |c| if (!std.ascii.isAlphanumeric(c) and c != '@' and c != '.')
            return null;

        var email: Email = undefined;
        @memcpy(email.buffer[0..slice.len], slice);
        @memset(email.buffer[slice.len..], 0);
        return email;
    }

    pub fn view(email: *const Email) []const u8 {
        return mem.span(@as([*:0]const u8, @ptrCast(&email.buffer)));
    }
};

const PasswordHash = extern struct {
    string: [67]u8,

    pub const HashError = error{HashFailed};

    fn hash(random: Random, password: []const u8) HashError!PasswordHash {
        var ph: PasswordHash = undefined;
        var salt: [bcrypt.salt_length]u8 = undefined;
        random.bytes(&salt);

        _ = bcrypt.strHashWithSalt(password, .{
            .encoding = .phc,
            .params = .owasp,
        }, &ph.string, salt) catch return error.HashFailed;

        return ph;
    }

    fn eql(ph: *const PasswordHash, plain: []const u8) bool {
        bcrypt.strVerify(&ph.string, plain, .{
            .silently_truncate_password = false,
        }) catch return false;

        return true;
    }
};

pub const Token = extern struct {
    string: [length]u8,

    const length = 128;

    pub fn fromSlice(userdata: []const u8) ?Token {
        if (userdata.len != length) return null;

        return .{ .string = userdata[0..length].* };
    }

    fn random(uid: Uid, rng: Random) Token {
        var token: Token = undefined;

        const prefix = mem.print(&token.string, "{d}-", .{@backingInt(uid)}) catch unreachable;
        for (token.string[prefix.len..]) |*char|
            char.* = rng.intRangeAtMost(u8, 'A', 'Z');

        return token;
    }

    fn eql(token: *const Token, userdata: []const u8) bool {
        return mem.eql(u8, &token.string, userdata);
    }
};
