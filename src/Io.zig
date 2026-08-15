const Io = @This();
const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const roze = @import("roze.zig");
const SinglyLinkedListWithTail = roze.SinglyLinkedListWithTail;

pub const std_log = @import("Io/std_log.zig");

const system = switch (builtin.os.tag) {
    .linux => @import("Io/linux.zig"),
    .windows => @import("Io/windows.zig"),
    else => |tag| @compileError("roze.Io doesn't support OS: " ++ @tagName(tag)),
};

submissions: SinglyLinkedListWithTail,
completions: SinglyLinkedListWithTail,
userdata: system.Userdata,

pub const InitError = error{
    SystemResources,
    ImplementationUnsupported,
    Unexpected,
};

pub fn init(io: *Io) InitError!void {
    io.submissions = .init;
    io.completions = .init;

    try system.init(io);
}

pub fn deinit(io: *Io) void {
    system.deinit(io);
}

pub const Mutability = enum {
    @"var",
    @"const",
};

pub fn Buffer(comptime mut: Mutability) type {
    return switch (mut) {
        .@"var" => extern struct {
            impl: system.buffer_var.Impl,

            pub fn slice(b: @This()) []u8 {
                const data = @field(b.impl, system.buffer_var.ptr_field);
                const len = @field(b.impl, system.buffer_var.len_field);
                return data[0..len];
            }

            pub fn init(b: *@This(), data: []u8) void {
                @field(b.impl, system.buffer_var.ptr_field) = data.ptr;
                @field(b.impl, system.buffer_var.len_field) = @intCast(data.len);
            }

            pub fn advance(b: *@This(), n: usize) void {
                @field(b.impl, system.buffer_var.ptr_field) += @intCast(n);
                @field(b.impl, system.buffer_var.len_field) -= @intCast(n);
            }
        },
        .@"const" => extern struct {
            impl: system.buffer_const.Impl,

            pub fn slice(b: @This()) []const u8 {
                const data = @field(b.impl, system.buffer_const.ptr_field);
                const len = @field(b.impl, system.buffer_const.len_field);
                return data[0..len];
            }

            pub fn init(b: *@This(), data: []const u8) void {
                @field(b.impl, system.buffer_const.ptr_field) = data.ptr;
                @field(b.impl, system.buffer_const.len_field) = @intCast(data.len);
            }

            pub fn advance(b: *@This(), n: usize) void {
                @field(b.impl, system.buffer_const.ptr_field) += @intCast(n);
                @field(b.impl, system.buffer_const.len_field) -= @intCast(n);
            }
        },
    };
}

pub const Ip4Address = struct {
    impl: system.socket_address_ip4.Impl,

    pub const ParseLiteralError = error{
        InvalidIp,
        InvalidPort,
    };

    pub fn parseLiteral(literal: []const u8) ParseLiteralError!Ip4Address {
        const ip, const port_digits = mem.cutScalar(u8, literal, ':') orelse return error.InvalidPort;

        var it = mem.splitScalar(u8, ip, '.');
        var bytes: [4]u8 = undefined;
        for (&bytes) |*byte| {
            const digits = it.next() orelse return error.InvalidIp;
            byte.* = std.fmt.parseInt(u8, digits, 10) catch return error.InvalidIp;
        }

        if (it.next() != null) return error.InvalidIp;
        const port_int = std.fmt.parseInt(u16, port_digits, 10) catch return error.InvalidPort;

        var result: Ip4Address = undefined;
        system.socket_address_ip4.init(&result.impl, bytes, port_int);
        return result;
    }

    pub fn format(ip4a: *const Ip4Address, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const bytes = system.socket_address_ip4.getBytes(&ip4a.impl);
        const port = system.socket_address_ip4.getPort(&ip4a.impl);
        try writer.print("{d}.{d}.{d}.{d}:{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3], port });
    }

    pub fn getBytes(ip4a: *const Ip4Address) [4]u8 {
        return system.socket_address_ip4.getBytes(&ip4a.impl);
    }

    pub fn getPort(ip4a: *const Ip4Address) u16 {
        return system.socket_address_ip4.getPort(&ip4a.impl);
    }
};

pub const Socket = struct {
    pub const Handle = system.socket.Impl;

    handle: Handle,
    address: Ip4Address,

    pub const Listening = struct {
        raw: Socket,
    };

    pub const Connected = struct {
        raw: Socket,
    };
};

pub const ListenOptions = packed struct {
    reuse_address: bool,
    backlog: u31,
};

pub const ListenError = error{
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    AddressInUse,
    AddressNotAvailable,
    AccessDenied,
};

pub fn listen(io: *Io, ip4a: *const Ip4Address, options: ListenOptions) ListenError!Socket.Listening {
    const handle = try system.socket.listen(io, &ip4a.impl, options);
    return .{ .raw = .{ .handle = handle, .address = ip4a.* } };
}

pub fn closeSocket(io: *Io, socket: *const Socket) void {
    _ = io;
    system.socket.close(socket.handle);
}

pub const RandombytesError = error{
    /// The system's entropy source reported an error.
    EntropyUnavailable,
};

/// Collects random bytes from system's entropy source.
///
/// This function is intended to be used to obtain entropy for
/// a [CS]PRNG. See `std.Random`.
///
/// This function doesn't in any way participate in the event loop,
/// however, it takes an `Io` parameter to avoid getting called from "pure"
/// contexts.
pub fn randombytes(io: *Io, buf: []u8) RandombytesError!void {
    _ = io;
    try system.randombytes(buf);
}

pub const Timespec = struct {
    impl: system.time.Spec,

    /// Collects current timestamp from system's realtime clock source.
    ///
    /// This function doesn't in any way participate in the event loop,
    /// however, it takes an `Io` parameter to avoid getting called from "pure"
    /// contexts.
    pub fn collect(io: *Io) Timespec {
        _ = io;
        var ts: Timespec = undefined;
        system.time.now(&ts.impl);

        return ts;
    }

    pub fn toSeconds(ts: *const Timespec) u64 {
        return system.time.toSeconds(&ts.impl);
    }

    pub fn toMilliseconds(ts: *const Timespec) u64 {
        return system.time.toMilliseconds(&ts.impl);
    }
};

pub const CreateDirectoryError = error{
    PathAlreadyExists,
    AccessDenied,
    FileNotFound,
    NoSpaceLeft,
    SystemResources,
};

pub fn createDirectoryBlocking(path: system.dir.Path) CreateDirectoryError!void {
    try system.dir.createBlocking(path);
}

pub const File = struct {
    pub const Handle = system.file.Impl;
    pub const Path = system.file.Path;

    const IntRepr = @Int(.unsigned, @bitSizeOf(Handle));

    handle: Handle,

    /// Uses system's invalid handle value to represent
    /// the `none` state. Therefore, more efficient than using `?Io.File`.
    /// Whenever you have to *store* an optional file anywhere, consider this type.
    pub const Optional = enum(IntRepr) {
        none = switch (@typeInfo(Handle)) {
            .pointer => @bitCast(@intFromPtr(system.file.invalid_handle)),
            .int => @bitCast(system.file.invalid_handle),
            else => unreachable,
        },
        _,

        pub fn unwrap(o: File.Optional) ?File {
            return switch (o) {
                .none => null,
                _ => .{ .handle = switch (@typeInfo(Handle)) {
                    .pointer => @ptrFromInt(@backingInt(o)),
                    .int => @bitCast(@backingInt(o)),
                    else => comptime unreachable,
                } },
            };
        }

        /// Asserts `file` is backed by a valid handle.
        pub fn wrap(file: File) File.Optional {
            assert(file.handle != system.file.invalid_handle);

            return @fromBackingInt(switch (@typeInfo(Handle)) {
                .pointer => @bitCast(@intFromPtr(file.handle)),
                .int => @bitCast(file.handle),
                else => comptime unreachable,
            });
        }
    };

    /// System-preopened file handles, also known as "stdio".
    ///
    /// Preopens allow only a subset of strictly blocking operations
    /// to be performed. Because of their nature, operating on them
    /// does not require an `Io` instance. This allows to avoid a
    /// common pitfall of making `Io` instance global, for example for
    /// debug functionality.
    pub const Preopen = enum {
        stdin,
        stdout,
        stderr,

        /// Returns a system file handle for the `Preopen`.
        /// These handles must not be used with `Io.File` instances.
        pub fn fileHandle(preopen: Preopen) File.Handle {
            return switch (preopen) {
                .stdin => std.Io.File.stdin().handle,
                .stdout => std.Io.File.stdout().handle,
                .stderr => std.Io.File.stderr().handle,
            };
        }

        /// Perform a vectored write to a preopened file.
        /// This function does not take an `Io` parameter because
        /// preopens do not participate in event loop.
        pub fn writeVecBlocking(
            preopen: File.Preopen,
            bufs: []const Buffer(.@"const"),
        ) File.WriteBlockingError!usize {
            return try system.file.writeBlocking(preopen.fileHandle(), bufs);
        }

        /// Perform a write to a preopened file.
        /// This function does not take an `Io` parameter because
        /// preopens do not participate in event loop.
        pub fn writeBlocking(preopen: File.Preopen, data: []const u8) File.WriteBlockingError!usize {
            var buf: Io.Buffer(.@"const") = undefined;
            buf.init(data);
            return try preopen.writeVecBlocking((&buf)[0..1]);
        }

        /// Write all bytes from `data` to a preopened file.
        /// This function does not take an `Io` parameter because
        /// preopens do not participate in event loop.
        pub fn writeAllBlocking(preopen: File.Preopen, data: []const u8) File.WriteBlockingError!void {
            var cursor = data;
            while (cursor.len > 0) {
                const wrote = try preopen.writeBlocking(cursor);
                cursor = cursor[wrote..];
            }
        }
    };

    /// Creates a file at specified `path`, synchronously.
    pub fn createBlocking(io: *Io, path: Path) OpenBlockingError!File {
        const handle = try system.file.createBlocking(io, path);
        return .{ .handle = handle };
    }

    /// Opens a file at specified `path`, synchronously.
    pub fn openBlocking(io: *Io, path: Path) OpenBlockingError!File {
        const handle = try system.file.openBlocking(io, path);
        return .{ .handle = handle };
    }

    /// Closes `file`, synchronously.
    pub fn closeBlocking(file: File, io: *Io) void {
        _ = io;
        system.file.close(file.handle);
    }

    /// Performs a positional read operation on `file`
    /// using vectored I/O, if possible.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn readVecBlocking(
        file: File,
        io: *Io,
        bufs: []const Io.Buffer(.@"var"),
        offset: u64,
    ) ReadBlockingError!usize {
        return io.operate(.{ .file_read = .{
            .file_handle = file.handle,
            .buffers = bufs,
            .offset = offset,
        } }).file_read;
    }

    /// Performs a positional read operation on `file`.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn readBlocking(file: File, io: *Io, data: []u8, offset: u64) ReadBlockingError!usize {
        var buf: Io.Buffer(.@"var") = undefined;
        buf.init(data);
        return try file.readVecBlocking(io, (&buf)[0..1], offset);
    }

    /// Performs as many read operations as required to fill `data`.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn readAllBlocking(file: File, io: *Io, data: []u8, offset: u64) ReadBlockingEndingError!void {
        var cursor = data;
        var position = offset;

        while (cursor.len > 0) {
            const read = try file.readBlocking(io, cursor, position);
            if (read == 0) return error.EndOfStream;
            cursor = cursor[read..];
            position += read;
        }
    }

    /// Performs as many read operations as required to fill `bufs`
    /// using vectored I/O, if possible.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn readVecAllBlocking(
        file: File,
        io: *Io,
        bufs: []Io.Buffer(.@"var"),
        offset: u64,
    ) ReadBlockingEndingError!void {
        var index: usize = 0;
        var truncate: usize = 0;
        var position: u64 = offset;

        while (index < bufs.len) {
            {
                const untruncated = bufs[index];
                var truncated = untruncated;
                truncated.advance(truncate);
                bufs[index] = truncated;
                defer bufs[index] = untruncated;
                const read = try file.readVecBlocking(io, bufs[index..], position);
                if (read == 0) return error.EndOfStream;
                truncate += read;
                position += read;
            }

            while (index < bufs.len and truncate >= bufs[index].slice().len) {
                truncate -= bufs[index].slice().len;
                index += 1;
            }
        }
    }

    /// Performs a positional write operation on `file`
    /// using vectored I/O, if possible.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn writeVecBlocking(
        file: File,
        io: *Io,
        bufs: []const Io.Buffer(.@"const"),
        offset: u64,
    ) WriteBlockingError!usize {
        return io.operate(.{ .file_write = .{
            .file_handle = file.handle,
            .buffers = bufs,
            .offset = offset,
        } }).file_write;
    }

    /// Performs a positional write operation on `file`.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn writeBlocking(file: File, io: *Io, data: []const u8, offset: u64) WriteBlockingError!usize {
        var buf: Io.Buffer(.@"const") = undefined;
        buf.init(data);
        return try file.writeVecBlocking(io, (&buf)[0..1], offset);
    }

    /// Performs as many write operations as required to drain `data`.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn writeAllBlocking(file: File, io: *Io, data: []const u8, offset: u64) WriteBlockingError!void {
        var cursor = data;
        var position = offset;

        while (cursor.len > 0) {
            const wrote = try file.writeBlocking(io, cursor, position);
            cursor = cursor[wrote..];
            position += wrote;
        }
    }

    /// Performs as many write operations as required to drain `bufs`
    /// using vectored I/O, if possible.
    ///
    /// See `operate` for more info on "blocking" behavior of this function.
    pub fn writeVecAllBlocking(
        file: File,
        io: *Io,
        bufs: []Io.Buffer(.@"const"),
        offset: u64,
    ) WriteBlockingError!void {
        var index: usize = 0;
        var truncate: usize = 0;
        var position: u64 = offset;

        while (index < bufs.len) {
            {
                const untruncated = bufs[index];
                var truncated = untruncated;
                truncated.advance(truncate);
                bufs[index] = truncated;
                defer bufs[index] = untruncated;
                const read = try file.writeVecBlocking(io, bufs[index..], position);
                truncate += read;
                position += read;
            }

            while (index < bufs.len and truncate >= bufs[index].slice().len) {
                truncate -= bufs[index].slice().len;
                index += 1;
            }
        }
    }

    pub const OpenBlockingError = error{
        FileNotFound,
        BadPathName,
        AccessDenied,
        FileTooBig,
        SystemResources,
        NoSpaceLeft,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
    };

    pub const WriteError = error{
        NotConnected,
        DiskQuota,
        FileTooBig,
        InputOutput,
        NoSpaceLeft,
        Unseekable,
        AccessDenied,
        BrokenPipe,
    };

    pub const WriteBlockingError = WriteError || error{WouldBlock};

    pub const ReadBlockingError = error{
        WouldBlock,
        ConnectionResetByPeer,
        InputOutput,
        SystemResources,
        Unseekable,
    };

    pub const ReadBlockingEndingError = ReadBlockingError || error{EndOfStream};
};

pub const Operation = union(enum) {
    pub const Tag = @typeInfo(Operation).@"union".tag_type.?;

    tcp_accept: TcpAccept,
    tcp_read: TcpRead,
    tcp_write: TcpWrite,
    file_open: FileOpen,
    file_read: FileRead,
    file_write: FileWrite,
    file_synchronize: FileSynchronize,

    pub const TcpAccept = struct {
        pub const Buffer = system.socket.AcceptBuffer;

        listening_socket_handle: Socket.Handle,
        buffer: *TcpAccept.Buffer,

        pub const Error = error{
            SystemResources,
            ProcessFdQuotaExceeded,
            SystemFdQuotaExceeded,
            ConnectionAborted,
            BlockedByFirewall,
            ProtocolError,
        };

        pub const Result = TcpAccept.Error!Socket.Connected;
    };

    /// Performs one underlying TCP read call on `connected_socket_handle`.
    pub const TcpRead = struct {
        connected_socket_handle: Socket.Handle,
        buffer: []u8,

        pub const Error = error{
            SystemResources,
            PeerUnresponsive,
            ConnectionResetByPeer,
            ConnectionRefused,
        };

        pub const Result = TcpRead.Error!usize;
    };

    /// Performs one underlying TCP write call on `connected_socket_handle`.
    pub const TcpWrite = struct {
        connected_socket_handle: Socket.Handle,
        buffer: []const u8,

        pub const Error = error{
            FastOpenAlreadyInProgress,
            BrokenPipe,
            ConnectionResetByPeer,
            SystemResources,
            PeerUnresponsive,
        };

        pub const Result = TcpWrite.Error!usize;
    };

    /// Opens or creates a file at `path`.
    pub const FileOpen = struct {
        pub const Mode = enum {
            load,
            create,
        };

        path: File.Path,
        mode: Mode,

        pub const Error = error{
            FileNotFound,
            BadPathName,
            AccessDenied,
            FileTooBig,
            SystemResources,
            NoSpaceLeft,
            ProcessFdQuotaExceeded,
            SystemFdQuotaExceeded,
        };

        pub const Result = FileOpen.Error!File;
    };

    /// Performs one positional read on `file_handle` at `offset`.
    pub const FileRead = struct {
        file_handle: Io.File.Handle,
        buffers: []const Buffer(.@"var"),
        offset: u64,

        pub const Error = error{
            ConnectionResetByPeer,
            InputOutput,
            SystemResources,
            Unseekable,
        };

        pub const Result = FileRead.Error!usize;
    };

    /// Performs one positional write on `file_handle` at `offset`.
    pub const FileWrite = struct {
        file_handle: Io.File.Handle,
        buffers: []const Buffer(.@"const"),
        offset: u64,

        pub const Error = File.WriteError;

        pub const Result = FileWrite.Error!usize;
    };

    /// Transfer all modified in-core data of the `file_handle`
    /// to the permanent storage device.
    pub const FileSynchronize = struct {
        file_handle: Io.File.Handle,

        pub const Error = error{
            AccessDenied,
            InputOutput,
        };

        pub const Result = Error!void;
    };

    pub const Result = Result: {
        const union_info = @typeInfo(Operation).@"union";
        var field_types: [union_info.field_names.len]type = undefined;
        for (&field_types, union_info.field_types) |*ResultType, OperationType|
            ResultType.* = OperationType.Result;

        break :Result @Union(.auto, Operation.Tag, union_info.field_names, &field_types, &@splat(.{}));
    };

    /// Once `submit` is called, the storage must not be modified
    /// or freed until it's returned by `nextCompletion`.
    pub const Storage = union {
        submission: Submission,
        pending: system.PendingOperation,
        completion: Completion,

        /// Initializes a submission storage.
        pub fn init(operation: Operation) Operation.Storage {
            return .{ .submission = .{ .node = .init, .operation = operation } };
        }
    };

    /// Submission list entry.
    /// This struct is not intended to be accessed except from within `system`.
    pub const Submission = struct {
        node: SinglyLinkedListWithTail.Node,
        operation: Operation,
    };

    /// Completion list entry.
    /// This struct is not intended to be instantiated except from within `system`.
    pub const Completion = struct {
        node: SinglyLinkedListWithTail.Node,
        result: Operation.Result,
    };
};

/// Submits one `Operation`.
/// `Operation.Storage.submission` must be the active field.
///
/// See `Operation.Storage.init` for a convenience API
/// to initialize `Operation.Storage`
pub fn submit(io: *Io, operation: *Operation.Storage) void {
    io.submissions.append(&operation.submission.node);
}

/// Returns next completion if any.
/// `Operation.Storage.completion` is the active field.
pub fn nextCompletion(io: *Io) ?*Operation.Storage {
    const node = io.completions.popFirst() orelse
        return null;

    const completion: *Operation.Completion = @alignCast(@fieldParentPtr("node", node));
    return @alignCast(@fieldParentPtr("completion", completion));
}

pub const WaitError = error{
    /// The blocking wait syscall was interrupted by a signal.
    Interrupted,
    /// The underlying API reported resource exhaustion.
    SystemResources,
    /// The given `timeout_ns` exceeded.
    Timeout,
};

/// Waits for one or more previously `submit`ted `Operation`s to complete,
/// or timeout to expire.
pub fn wait(io: *Io, timeout_ns: u63) WaitError!void {
    try system.submitAndWait(io, timeout_ns);
}

/// Submits an `Operation` and waits for it to complete.
/// During this time, other pending `Operation`s may progress as well,
/// but the caller won't be notified about their completion.
///
/// Ideally, this should be used only when there's no other `Operation`s in-flight,
/// for example: on application initial startup.
pub fn operate(io: *Io, operation: Io.Operation) Io.Operation.Result {
    var storage: Io.Operation.Storage = .init(operation);
    io.submit(&storage);

    while (true) {
        io.wait(std.math.maxInt(u63)) catch |err| switch (err) {
            error.Timeout => unreachable,
            error.SystemResources, error.Interrupted => continue,
        };

        var new_completions: SinglyLinkedListWithTail = .init;
        defer io.completions = new_completions;

        var seen_completion = false;

        while (io.nextCompletion()) |completed_storage| {
            if (completed_storage == &storage) {
                assert(!seen_completion);
                seen_completion = true;
            } else {
                new_completions.append(&completed_storage.completion.node);
            }
        }

        if (seen_completion) return storage.completion.result;
    }
}
