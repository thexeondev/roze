const builtin = @import("builtin");

const std = @import("std");
const os = std.os;
const mem = std.mem;
const linux = std.os.linux;

const roze = @import("../roze.zig");
const Io = roze.Io;

pub const Userdata = struct {
    ring: linux.IoUring,
    submitted_n: u32,
};

pub fn init(io: *Io) Io.InitError!void {
    io.userdata.submitted_n = 0;
    io.userdata.ring = linux.IoUring.init(
        256,
        linux.IORING_SETUP_SINGLE_ISSUER |
            linux.IORING_SETUP_DEFER_TASKRUN,
    ) catch |err| switch (err) {
        error.SystemOutdated, error.PermissionDenied => return error.ImplementationUnsupported,

        error.OutOfMemory,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.LockedMemoryLimitExceeded,
        => return error.SystemResources,

        else => return error.Unexpected,
    };
}

pub fn deinit(io: *Io) void {
    io.userdata.ring.deinit();
}

pub fn submitAndWait(io: *Io, timeout_ns: u63) Io.WaitError!void {
    try submitAll(io);
    try enterTimeout(io, timeout_ns);
    fillCompletions(io);
}

fn submitAll(io: *Io) Io.WaitError!void {
    while (io.submissions.popFirst()) |node| {
        const sqe = get_sqe: while (true) {
            break :get_sqe io.userdata.ring.get_sqe() catch |err| switch (err) {
                error.SubmissionQueueFull => {
                    try flushSq(io);
                    continue;
                },
            };
        };

        const submission: *Io.Operation.Submission = @fieldParentPtr("node", node);
        const storage: *Io.Operation.Storage = @fieldParentPtr("submission", submission);
        makeSqe(storage, sqe);

        io.userdata.submitted_n += 1;
    }
}

/// `Io.Operation.Storage.submission` is active.
fn makeSqe(storage: *Io.Operation.Storage, sqe: *linux.io_uring_sqe) void {
    defer sqe.user_data = @intFromPtr(storage);

    switch (storage.submission.operation) {
        .tcp_accept => |tcp_accept| {
            storage.* = .{ .pending = .{ .tcp_accept = .{
                .accept_buffer = tcp_accept.buffer,
            } } };

            tcp_accept.buffer.addrlen = @sizeOf(linux.sockaddr.in);
            sqe.prep_accept(
                tcp_accept.listening_socket_handle,
                @ptrCast(&tcp_accept.buffer.addr),
                &tcp_accept.buffer.addrlen,
                0,
            );
        },
        .tcp_read => |tcp_read| {
            storage.* = .{ .pending = .tcp_read };
            sqe.prep_recv(
                tcp_read.connected_socket_handle,
                tcp_read.buffer,
                0,
            );
        },
        .tcp_write => |tcp_write| {
            storage.* = .{ .pending = .tcp_write };
            sqe.prep_send(
                tcp_write.connected_socket_handle,
                tcp_write.buffer,
                linux.MSG.NOSIGNAL,
            );
        },
        .file_open => |file_open| {
            storage.* = .{ .pending = .file_open };
            const o: linux.O = switch (file_open.mode) {
                .load => .{ .ACCMODE = .RDWR },
                .create => .{
                    .ACCMODE = .RDWR,
                    .TRUNC = true,
                    .CREAT = true,
                },
            };

            sqe.prep_openat(linux.AT.FDCWD, file_open.path, o, 0o666);
        },
        .file_read => |file_read| {
            storage.* = .{ .pending = .file_read };
            sqe.prep_readv(
                file_read.file_handle,
                @ptrCast(file_read.buffers),
                file_read.offset,
            );
        },
        .file_write => |file_write| {
            storage.* = .{ .pending = .file_write };
            sqe.prep_writev(
                file_write.file_handle,
                @ptrCast(file_write.buffers),
                file_write.offset,
            );
        },
        .file_synchronize => |file_synchronize| {
            storage.* = .{ .pending = .file_synchronize };
            sqe.prep_fsync(file_synchronize.file_handle, 0);
        },
    }
}

fn fillCompletions(io: *Io) void {
    var cqes_buffer: [128]linux.io_uring_cqe = undefined;

    while (true) {
        const count = io.userdata.ring.copy_cqes(&cqes_buffer, 0) catch unreachable;
        if (count == 0) break;

        const cqes = cqes_buffer[0..count];

        for (cqes) |cqe| {
            const storage: *Io.Operation.Storage = @ptrFromInt(cqe.user_data);
            const result: Io.Operation.Result = switch (storage.pending) {
                .tcp_accept => |tcp_accept| .{ .tcp_accept = switch (cqe.err()) {
                    .SUCCESS => .{ .raw = .{
                        .handle = @intCast(cqe.res),
                        .address = .{ .impl = tcp_accept.accept_buffer.addr },
                    } },
                    .NOMEM, .NOBUFS => error.SystemResources,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    .CONNABORTED => error.ConnectionAborted,
                    .PERM => error.BlockedByFirewall,
                    .PROTO => error.ProtocolError,
                    else => |e| unexpectedErrno(e),
                } },
                .tcp_read => .{ .tcp_read = switch (cqe.err()) {
                    .SUCCESS => @intCast(cqe.res),
                    .NOMEM => error.SystemResources,
                    .TIMEDOUT => error.PeerUnresponsive,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .CONNREFUSED => error.ConnectionRefused,
                    else => |e| unexpectedErrno(e),
                } },
                .tcp_write => .{ .tcp_write = switch (cqe.err()) {
                    .SUCCESS => @intCast(cqe.res),
                    .NOMEM, .NOBUFS => error.SystemResources,
                    .TIMEDOUT => error.PeerUnresponsive,
                    .CONNRESET => error.ConnectionResetByPeer,
                    .ALREADY => error.FastOpenAlreadyInProgress,
                    else => |e| unexpectedErrno(e),
                } },
                .file_open => .{ .file_open = switch (cqe.err()) {
                    .SUCCESS => .{ .handle = @intCast(cqe.res) },
                    .NOENT, .SRCH => error.FileNotFound,
                    .INVAL, .ILSEQ => error.BadPathName,
                    .ACCES, .PERM => error.AccessDenied,
                    .NOMEM => error.SystemResources,
                    .FBIG => error.FileTooBig,
                    .NOSPC => error.NoSpaceLeft,
                    .MFILE => error.ProcessFdQuotaExceeded,
                    .NFILE => error.SystemFdQuotaExceeded,
                    else => |e| unexpectedErrno(e),
                } },
                .file_read => .{ .file_read = switch (cqe.err()) {
                    .SUCCESS => @intCast(cqe.res),
                    .CONNRESET => error.ConnectionResetByPeer,
                    .NOBUFS, .NOMEM => error.SystemResources,
                    .IO => error.InputOutput,
                    .NXIO, .OVERFLOW, .SPIPE => error.Unseekable,
                    else => |e| unexpectedErrno(e),
                } },
                .file_write => .{ .file_write = switch (cqe.err()) {
                    .SUCCESS => @intCast(cqe.res),
                    .DESTADDRREQ => error.NotConnected,
                    .DQUOT => error.DiskQuota,
                    .FBIG => error.FileTooBig,
                    .IO => error.InputOutput,
                    .NOSPC => error.NoSpaceLeft,
                    .SPIPE, .NXIO, .OVERFLOW => error.Unseekable,
                    .PERM => error.AccessDenied,
                    .PIPE => error.BrokenPipe,
                    else => |e| unexpectedErrno(e),
                } },
                .file_synchronize => .{ .file_synchronize = switch (cqe.err()) {
                    .SUCCESS => {},
                    .IO => error.InputOutput,
                    else => |e| unexpectedErrno(e),
                } },
            };

            storage.* = .{ .completion = .{
                .node = .init,
                .result = result,
            } };

            io.completions.append(&storage.completion.node);
            io.userdata.submitted_n -= 1;
        }
    }
}

fn flushSq(io: *Io) Io.WaitError!void {
    try enterTimeout(io, 0);
}

fn enterTimeout(io: *Io, timeout_ns: u63) Io.WaitError!void {
    if (io.userdata.submitted_n == 0) return;

    var ts: linux.kernel_timespec = .{
        .sec = timeout_ns / std.time.ns_per_s,
        .nsec = timeout_ns % std.time.ns_per_s,
    };

    var arg: linux.io_uring_getevents_arg = .{
        .sigmask = 0,
        .sigmask_sz = linux.NSIG / 8,
        .pad = 0,
        .ts = @intFromPtr(&ts),
    };

    const flags: u32 = linux.IORING_ENTER_GETEVENTS | linux.IORING_ENTER_EXT_ARG;

    const enter_rc = linux.syscall6(
        .io_uring_enter,
        @as(usize, @bitCast(@as(isize, io.userdata.ring.fd))),
        io.userdata.ring.flush_sq(),
        if (timeout_ns > 0) 1 else 0,
        flags,
        @intFromPtr(&arg),
        @sizeOf(linux.io_uring_getevents_arg),
    );

    switch (linux.errno(enter_rc)) {
        .SUCCESS => {},
        .AGAIN, .BUSY => return error.SystemResources,
        .INTR => return error.Interrupted,
        .TIME => return error.Timeout,
        else => |e| unexpectedErrno(e),
    }
}

pub const PendingOperation = union(Io.Operation.Tag) {
    tcp_accept: struct {
        accept_buffer: *socket.AcceptBuffer,
    },
    tcp_read,
    tcp_write,
    file_open,
    file_read,
    file_write,
    file_synchronize,
};

pub const buffer_var = struct {
    pub const Impl = std.posix.iovec;

    pub const ptr_field = "base";
    pub const len_field = "len";
};

pub const buffer_const = struct {
    pub const Impl = std.posix.iovec_const;

    pub const ptr_field = "base";
    pub const len_field = "len";
};

pub const socket_address_ip4 = struct {
    pub const Impl = linux.sockaddr.in;

    pub fn init(impl: *Impl, addr: [4]u8, port: u16) void {
        impl.* = .{
            .family = linux.AF.INET,
            .port = mem.nativeToBig(u16, port),
            .addr = @bitCast(addr),
            .zero = mem.zeroes(@FieldType(Impl, "zero")),
        };
    }

    pub fn getBytes(impl: *const Impl) [4]u8 {
        return @bitCast(impl.addr);
    }

    pub fn getPort(impl: *const Impl) u16 {
        return mem.bigToNative(u16, impl.port);
    }
};

pub const socket = struct {
    pub const Impl = linux.fd_t;

    pub const AcceptBuffer = struct {
        addr: linux.sockaddr.in,
        addrlen: linux.socklen_t,
    };

    pub fn listen(
        io: *Io,
        addr: *const socket_address_ip4.Impl,
        options: Io.ListenOptions,
    ) Io.ListenError!Impl {
        _ = io;

        const socket_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM, linux.IPPROTO.TCP);
        const fd: Impl = switch (linux.errno(socket_rc)) {
            .SUCCESS => @intCast(socket_rc),
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .ACCES => return error.AccessDenied,
            .NOMEM, .NOBUFS => return error.SystemResources,
            else => |e| unexpectedErrno(e),
        };

        errdefer _ = linux.close(fd);

        if (options.reuse_address) {
            var opt: u32 = 1;
            const rc = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&opt), @sizeOf(u32));
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                else => |e| unexpectedErrno(e),
            }
        }

        const bind_rc = linux.bind(fd, @ptrCast(addr), @sizeOf(linux.sockaddr.in));
        switch (linux.errno(bind_rc)) {
            .SUCCESS => {},
            .ACCES => return error.AccessDenied,
            .ADDRINUSE => return error.AddressInUse,
            .ADDRNOTAVAIL => return error.AddressNotAvailable,
            else => |e| unexpectedErrno(e),
        }

        const listen_rc = linux.listen(fd, options.backlog);
        switch (linux.errno(listen_rc)) {
            .SUCCESS => {},
            .ADDRINUSE => return error.AddressInUse,
            else => |e| unexpectedErrno(e),
        }

        return fd;
    }

    pub fn close(impl: Impl) void {
        _ = linux.close(impl);
    }
};

pub const dir = struct {
    pub const Path = [*:0]const u8;

    pub fn createBlocking(path: Path) Io.CreateDirectoryError!void {
        const rc = linux.mkdirat(linux.AT.FDCWD, path, 0o755);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .ACCES, .PERM => return error.AccessDenied,
            .EXIST => return error.PathAlreadyExists,
            .NOENT => return error.FileNotFound,
            .NOMEM => return error.SystemResources,
            .NOSPC => return error.NoSpaceLeft,
            else => |e| unexpectedErrno(e),
        }
    }
};

pub const file = struct {
    pub const Impl = linux.fd_t;

    pub const Path = [*:0]const u8;

    pub const invalid_handle: Impl = -1;

    pub fn writeBlocking(impl: Impl, data: []const Io.Buffer(.@"const")) Io.File.WriteBlockingError!usize {
        const rc = linux.writev(impl, @ptrCast(data.ptr), data.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => error.WouldBlock,
            .DESTADDRREQ => error.NotConnected,
            .DQUOT => error.DiskQuota,
            .FBIG => error.FileTooBig,
            .IO => error.InputOutput,
            .NOSPC => error.NoSpaceLeft,
            .SPIPE, .NXIO, .OVERFLOW => error.Unseekable,
            .PERM => error.AccessDenied,
            .PIPE => error.BrokenPipe,
            else => |e| unexpectedErrno(e),
        };
    }

    pub fn readBlocking(impl: Impl, data: []const Io.Buffer(.@"var")) Io.File.ReadBlockingError!usize {
        const rc = linux.readv(impl, @ptrCast(data.ptr), data.len);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .AGAIN => error.WouldBlock,
            .CONNRESET => error.ConnectionResetByPeer,
            .NOBUFS, .NOMEM => error.SystemResources,
            .IO => error.InputOutput,
            .NXIO, .OVERFLOW, .SPIPE => error.Unseekable,
            else => |e| unexpectedErrno(e),
        };
    }

    pub fn openBlocking(io: *Io, path: Path) Io.File.OpenBlockingError!Impl {
        _ = io;
        const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDWR }, 0o666);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOENT, .SRCH => error.FileNotFound,
            .INVAL, .ILSEQ => error.BadPathName,
            .ACCES, .PERM => error.AccessDenied,
            .NOMEM => error.SystemResources,
            .FBIG => error.FileTooBig,
            .NOSPC => error.NoSpaceLeft,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            else => |e| unexpectedErrno(e),
        };
    }

    pub fn createBlocking(io: *Io, path: Path) Io.File.OpenBlockingError!Impl {
        _ = io;
        const rc = linux.openat(linux.AT.FDCWD, path, .{
            .ACCMODE = .RDWR,
            .TRUNC = true,
            .CREAT = true,
        }, 0o666);
        return switch (linux.errno(rc)) {
            .SUCCESS => @intCast(rc),
            .NOENT, .SRCH => error.FileNotFound,
            .INVAL, .ILSEQ => error.BadPathName,
            .ACCES, .PERM => error.AccessDenied,
            .NOMEM => error.SystemResources,
            .FBIG => error.FileTooBig,
            .NOSPC => error.NoSpaceLeft,
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            else => |e| unexpectedErrno(e),
        };
    }

    pub fn close(impl: Impl) void {
        _ = linux.close(impl);
    }
};

fn unexpectedErrno(e: linux.E) noreturn {
    switch (builtin.optimize) {
        .debug, .safe => std.debug.panic("unexpected errno: {t}", .{e}),
        .small, .fast => std.process.exit(1),
    }
}

pub fn randombytes(buf: []u8) Io.RandombytesError!void {
    const open_rc = linux.open("/dev/urandom", .{}, 0);
    const fd: linux.fd_t = switch (linux.errno(open_rc)) {
        .SUCCESS => @intCast(open_rc),
        else => return error.EntropyUnavailable,
    };

    defer _ = linux.close(fd);

    var unfilled = buf;
    while (unfilled.len != 0) {
        const read_rc = linux.read(fd, unfilled.ptr, @intCast(unfilled.len));
        switch (linux.errno(read_rc)) {
            .SUCCESS => unfilled = unfilled[read_rc..],
            else => return error.EntropyUnavailable,
        }
    }
}

pub const time = struct {
    pub const Spec = linux.timespec;

    pub fn now(spec: *Spec) void {
        const rc = linux.clock_gettime(.REALTIME, spec);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |e| unexpectedErrno(e),
        }
    }

    pub fn toSeconds(spec: *const Spec) u64 {
        return @intCast(spec.sec);
    }

    pub fn toMilliseconds(spec: *const Spec) u64 {
        const seconds: u64 = @intCast(spec.sec);
        const nanoseconds: u64 = @intCast(spec.nsec);

        return seconds * std.time.ms_per_s + (nanoseconds / std.time.ns_per_ms);
    }
};
