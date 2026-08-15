const builtin = @import("builtin");

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

// winapi
const BOOL = std.os.windows.BOOL;
const WORD = std.os.windows.WORD;
const DWORD = std.os.windows.DWORD;
const USHORT = std.os.windows.USHORT;
const ULONG = std.os.windows.ULONG;
const PVOID = std.os.windows.PVOID;
const HANDLE = std.os.windows.HANDLE;
const LPVOID = std.os.windows.LPVOID;
const LPCVOID = std.os.windows.LPCVOID;
const LPCSTR = std.os.windows.LPCSTR;
const ULONG_PTR = std.os.windows.ULONG_PTR;
const LARGE_INTEGER = std.os.windows.LARGE_INTEGER;
const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
const INVALID_SOCKET = INVALID_HANDLE_VALUE;
const GetLastError = std.os.windows.GetLastError;
const Win32Error = std.os.windows.Win32Error;
const SOCKET_ERROR: i32 = -1;
const NTSTATUS = std.os.windows.NTSTATUS;
const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
const GENERIC_WRITE = 0x40000000;
const GENERIC_READ = 0x80000000;
const FILE_ATTRIBUTE_NORMAL = 128;
const FILE_FLAG_OVERLAPPED = 0x40000000;

const roze = @import("../roze.zig");
const Io = roze.Io;

const winsock_version: DWORD = 0x0202;

pub const Userdata = struct {
    iocp: HANDLE,
    submitted_n: u32,
};

pub fn init(io: *Io) Io.InitError!void {
    var wsa_data: WSADATA = undefined;
    switch (ws2_32.WSAStartup(winsock_version, &wsa_data)) {
        0 => {},
        else => return error.Unexpected,
    }

    io.userdata.submitted_n = 0;
    io.userdata.iocp = kernel32.CreateIoCompletionPort(INVALID_HANDLE_VALUE, null, 0, 0) orelse
        unexpectedLastError(GetLastError());
}

pub fn deinit(io: *Io) void {
    kernel32.CloseHandle(io.userdata.iocp);
}

pub fn submitAndWait(io: *Io, timeout_ns: u63) Io.WaitError!void {
    drainSubmissions(io);

    if (io.completions.head != null or io.userdata.submitted_n == 0)
        // We should not block if we have completions in the list.
        return;

    var entries_buffer: [128]OVERLAPPED_ENTRY = undefined;
    var entries_count: ULONG = 0;

    if (kernel32.GetQueuedCompletionStatusEx(
        io.userdata.iocp,
        &entries_buffer,
        entries_buffer.len,
        &entries_count,
        @truncate(timeout_ns / std.time.ns_per_ms),
        .TRUE, // fAlertable
    ) == .FALSE) return switch (GetLastError()) {
        .WAIT_TIMEOUT => error.Timeout,
        else => |e| unexpectedLastError(e),
    };

    fillCompletions(io, entries_buffer[0..entries_count]);
}

fn drainSubmissions(io: *Io) void {
    while (io.submissions.popFirst()) |node| {
        const submission: *Io.Operation.Submission = @fieldParentPtr("node", node);
        const storage: *Io.Operation.Storage = @fieldParentPtr("submission", submission);

        submitOperation(io, storage);
    }
}

fn submitOperation(io: *Io, storage: *Io.Operation.Storage) void {
    switch (storage.submission.operation) {
        .tcp_accept => |tcp_accept| {
            const being_accepted_socket = ws2_32.WSASocketW(
                ws2_32.AF.INET,
                ws2_32.SOCK.STREAM,
                ws2_32.IPPROTO.TCP,
                null,
                0,
                .{ .OVERLAPPED = true },
            );

            if (being_accepted_socket == INVALID_SOCKET)
                switch (ws2_32.WSAGetLastError()) {
                    .WSAEMFILE => return putCompletion(
                        io,
                        storage,
                        .{ .tcp_accept = error.ProcessFdQuotaExceeded },
                    ),
                    else => |e| unexpectedWsaError(e),
                };

            errdefer _ = ws2_32.closesocket(being_accepted_socket);

            var bytes_received: DWORD = undefined;

            storage.* = .{ .pending = .{
                .overlapped = .zeroes,
                .operation = .{ .tcp_accept = .{
                    .accept_buffer = tcp_accept.buffer,
                    .listening_socket = tcp_accept.listening_socket_handle,
                    .being_accepted_socket = being_accepted_socket,
                } },
            } };

            if (ws2_32.AcceptEx(
                tcp_accept.listening_socket_handle,
                being_accepted_socket,
                tcp_accept.buffer,
                0,
                @sizeOf(ws2_32.sockaddr.in) + 16,
                @sizeOf(ws2_32.sockaddr.in) + 16,
                &bytes_received,
                &storage.pending.overlapped,
            ) != .FALSE) {
                io.userdata.submitted_n += 1;
            } else switch (ws2_32.WSAGetLastError()) {
                .WSA_IO_PENDING => io.userdata.submitted_n += 1,
                else => |e| unexpectedWsaError(e),
            }
        },
        .tcp_read => |tcp_read| {
            storage.* = .{ .pending = .{
                .overlapped = .zeroes,
                .operation = .{ .tcp_read = .{
                    .buffer = .{
                        .buf = tcp_read.buffer.ptr,
                        .len = @truncate(tcp_read.buffer.len),
                    },
                    .flags = 0,
                } },
            } };

            if (ws2_32.WSARecv(
                tcp_read.connected_socket_handle,
                (&storage.pending.operation.tcp_read.buffer)[0..1],
                1,
                null,
                &storage.pending.operation.tcp_read.flags,
                &storage.pending.overlapped,
                null,
            ) != SOCKET_ERROR) {
                io.userdata.submitted_n += 1;
            } else switch (ws2_32.WSAGetLastError()) {
                .WSA_IO_PENDING => io.userdata.submitted_n += 1,
                .WSAECONNRESET, .WSAENETRESET => putCompletion(
                    io,
                    storage,
                    .{ .tcp_read = error.ConnectionResetByPeer },
                ),
                else => |e| unexpectedWsaError(e),
            }
        },
        .tcp_write => |tcp_write| {
            storage.* = .{ .pending = .{
                .overlapped = .zeroes,
                .operation = .{ .tcp_write = .{
                    .buffer = .{
                        .buf = tcp_write.buffer.ptr,
                        .len = @truncate(tcp_write.buffer.len),
                    },
                } },
            } };

            if (ws2_32.WSASend(
                tcp_write.connected_socket_handle,
                (&storage.pending.operation.tcp_write.buffer)[0..1],
                1,
                null,
                0,
                &storage.pending.overlapped,
                null,
            ) != SOCKET_ERROR) {
                io.userdata.submitted_n += 1;
            } else switch (ws2_32.WSAGetLastError()) {
                .WSA_IO_PENDING => io.userdata.submitted_n += 1,
                .WSAECONNRESET, .WSAENETRESET => putCompletion(
                    io,
                    storage,
                    .{ .tcp_read = error.ConnectionResetByPeer },
                ),
                else => |e| unexpectedWsaError(e),
            }
        },
        .file_open => |file_open| {
            const handle_or_err = switch (file_open.mode) {
                .load => file.openBlocking(io, file_open.path),
                .create => file.createBlocking(io, file_open.path),
            };

            const result: Io.Operation.FileOpen.Result = if (handle_or_err) |handle|
                .{ .handle = handle }
            else |err|
                err;

            putCompletion(io, storage, .{ .file_open = result });
        },
        .file_read => |file_read| {
            if (file_read.buffers.len == 0)
                return putCompletion(io, storage, .{ .file_read = 0 });

            storage.* = .{ .pending = .{
                .overlapped = .withOffset(file_read.offset),
                .operation = .file_read,
            } };

            const buffer = file_read.buffers[0].slice();

            const err_maybe: ?Io.Operation.FileRead.Error = if (kernel32.ReadFile(
                file_read.file_handle,
                buffer.ptr,
                @truncate(buffer.len),
                null,
                &storage.pending.overlapped,
            ) != .FALSE) success: {
                io.userdata.submitted_n += 1;
                break :success null;
            } else switch (GetLastError()) {
                .IO_PENDING => pending: {
                    io.userdata.submitted_n += 1;
                    break :pending null;
                },
                .NETNAME_DELETED => error.ConnectionResetByPeer,
                else => |e| unexpectedLastError(e),
            };

            if (err_maybe) |err| putCompletion(io, storage, .{ .file_read = err });
        },
        .file_write => |file_write| {
            if (file_write.buffers.len == 0)
                return putCompletion(io, storage, .{ .file_write = 0 });

            storage.* = .{ .pending = .{
                .overlapped = .withOffset(file_write.offset),
                .operation = .file_write,
            } };

            const buffer = file_write.buffers[0].slice();

            const err_maybe: ?Io.Operation.FileWrite.Error = if (kernel32.WriteFile(
                file_write.file_handle,
                buffer.ptr,
                @truncate(buffer.len),
                null,
                &storage.pending.overlapped,
            ) != .FALSE) success: {
                io.userdata.submitted_n += 1;
                break :success null;
            } else switch (GetLastError()) {
                .IO_PENDING => pending: {
                    io.userdata.submitted_n += 1;
                    break :pending null;
                },
                .DISK_FULL => error.NoSpaceLeft,
                .ACCESS_DENIED => error.AccessDenied,
                .NOT_ENOUGH_QUOTA => error.DiskQuota,
                .NO_DATA => error.BrokenPipe,
                else => |e| unexpectedLastError(e),
            };

            if (err_maybe) |err| putCompletion(io, storage, .{ .file_write = err });
        },
        .file_synchronize => |file_synchronize| {
            const result: Io.Operation.FileSynchronize.Result = FlushFileBuffers: {
                if (kernel32.FlushFileBuffers(file_synchronize.file_handle) != .FALSE)
                    break :FlushFileBuffers;

                break :FlushFileBuffers switch (GetLastError()) {
                    .ACCESS_DENIED => error.AccessDenied,
                    .UNEXP_NET_ERR => error.InputOutput,
                    else => |e| unexpectedLastError(e),
                };
            };

            putCompletion(io, storage, .{ .file_synchronize = result });
        },
    }
}

fn fillCompletions(io: *Io, entries: []OVERLAPPED_ENTRY) void {
    for (entries) |entry| {
        const status: NTSTATUS = @fromBackingInt(@intCast(entry.lpOverlapped.Internal));
        const pending: *PendingOperation = @fieldParentPtr("overlapped", entry.lpOverlapped);
        const storage: *Io.Operation.Storage = @fieldParentPtr("pending", pending);

        defer io.userdata.submitted_n -= 1;

        switch (pending.operation) {
            .tcp_accept => |tcp_accept| switch (status) {
                .SUCCESS => {
                    var local: *ws2_32.sockaddr = undefined;
                    var local_len: i32 = 0;

                    var remote: *ws2_32.sockaddr = undefined;
                    var remote_len: i32 = 0;

                    ws2_32.GetAcceptExSockaddrs(
                        tcp_accept.accept_buffer,
                        0,
                        @sizeOf(ws2_32.sockaddr.in) + 16,
                        @sizeOf(ws2_32.sockaddr.in) + 16,
                        &local,
                        &local_len,
                        &remote,
                        &remote_len,
                    );

                    _ = ws2_32.setsockopt(
                        tcp_accept.being_accepted_socket,
                        ws2_32.SOL.SOCKET,
                        ws2_32.SO.UPDATE_ACCEPT_CONTEXT,
                        @ptrCast(&tcp_accept.listening_socket),
                        @sizeOf(HANDLE),
                    );

                    _ = kernel32.CreateIoCompletionPort(
                        tcp_accept.being_accepted_socket,
                        io.userdata.iocp,
                        0,
                        0,
                    ) orelse unexpectedLastError(GetLastError());

                    const remote_in: *align(1) ws2_32.sockaddr.in = @ptrCast(remote);

                    putCompletion(io, storage, .{ .tcp_accept = .{ .raw = .{
                        .handle = tcp_accept.being_accepted_socket,
                        .address = .{ .impl = remote_in.* },
                    } } });
                },
                .CONNECTION_ABORTED => putCompletion(io, storage, .{ .tcp_accept = error.ConnectionAborted }),
                else => |e| unexpectedNtStatus(e),
            },
            .tcp_read => putCompletion(io, storage, .{ .tcp_read = switch (status) {
                .SUCCESS => entry.dwNumberOfBytesTransferred,
                .CONNECTION_RESET, .CONNECTION_DISCONNECTED => error.ConnectionResetByPeer,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                else => |e| unexpectedNtStatus(e),
            } }),
            .tcp_write => putCompletion(io, storage, .{ .tcp_write = switch (status) {
                .SUCCESS => entry.dwNumberOfBytesTransferred,
                .CONNECTION_RESET, .CONNECTION_DISCONNECTED => error.ConnectionResetByPeer,
                .INSUFFICIENT_RESOURCES => error.SystemResources,
                .PIPE_BROKEN, .PIPE_DISCONNECTED => error.BrokenPipe,
                else => |e| unexpectedNtStatus(e),
            } }),
            .file_open => unreachable, // Synchronous operation.
            .file_read => putCompletion(io, storage, .{ .file_read = switch (status) {
                .SUCCESS => entry.dwNumberOfBytesTransferred,
                .END_OF_FILE => 0,
                else => |e| unexpectedNtStatus(e),
            } }),
            .file_write => putCompletion(io, storage, .{ .file_write = switch (status) {
                .SUCCESS => entry.dwNumberOfBytesTransferred,
                .DISK_FULL => error.NoSpaceLeft,
                .ACCESS_DENIED => error.AccessDenied,
                .QUOTA_EXCEEDED, .WORKING_SET_QUOTA => error.DiskQuota,
                .PIPE_BROKEN, .PIPE_DISCONNECTED => error.BrokenPipe,
                else => |e| unexpectedNtStatus(e),
            } }),
            .file_synchronize => unreachable, // Synchronous operation.
        }
    }
}

fn putCompletion(io: *Io, storage: *Io.Operation.Storage, result: Io.Operation.Result) void {
    storage.* = .{ .completion = .{
        .node = .init,
        .result = result,
    } };

    io.completions.append(&storage.completion.node);
}

pub const PendingOperation = struct {
    overlapped: OVERLAPPED,
    operation: union(Io.Operation.Tag) {
        tcp_accept: struct {
            accept_buffer: *socket.AcceptBuffer,
            listening_socket: HANDLE,
            being_accepted_socket: HANDLE,
        },
        tcp_read: struct {
            buffer: WSABUF(.@"var"),
            flags: u32,
        },
        tcp_write: struct {
            buffer: WSABUF(.@"const"),
        },
        file_open,
        file_read,
        file_write,
        file_synchronize,
    },
};

fn WSABUF(comptime mutability: Io.Mutability) type {
    return extern struct {
        len: ULONG,
        buf: switch (mutability) {
            .@"const" => [*]const u8,
            .@"var" => [*]u8,
        },
    };
}

const OVERLAPPED = extern struct {
    pub const zeroes: OVERLAPPED = mem.zeroes(OVERLAPPED);

    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,

    fn withOffset(offset: u64) OVERLAPPED {
        return .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{
                .DUMMYSTRUCTNAME = .{
                    .Offset = @truncate(offset),
                    .OffsetHigh = @truncate(offset >> 32),
                },
            },
            .hEvent = null,
        };
    }
};

const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: ULONG_PTR,
    lpOverlapped: *OVERLAPPED,
    Internal: ULONG_PTR,
    dwNumberOfBytesTransferred: DWORD,
};

const WSADATA = extern struct {
    wVersion: WORD,
    wHighVersion: WORD,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: *u8,
    szDescription: [256 + 1]u8,
    szSystemStatus: [128 + 1]u8,
};

pub const buffer_var = struct {
    pub const Impl = WSABUF(.@"var");

    pub const ptr_field = "buf";
    pub const len_field = "len";
};

pub const buffer_const = struct {
    pub const Impl = WSABUF(.@"const");

    pub const ptr_field = "buf";
    pub const len_field = "len";
};

pub const dir = struct {
    pub const Path = [*:0]const u8;

    pub fn createBlocking(path: Path) Io.CreateDirectoryError!void {
        if (kernel32.CreateDirectoryA(path, null) == .FALSE) return switch (GetLastError()) {
            .ALREADY_EXISTS => error.PathAlreadyExists,
            .PATH_NOT_FOUND => error.FileNotFound,
            else => |e| unexpectedLastError(e),
        };
    }
};

pub const file = struct {
    pub const Impl = HANDLE;

    // TODO: helpers for constructing paths by formatting, etc.
    // Then we'll be able to use WTF-16 paths and *W functions with zero path conversion cost.
    // For now we'll be using *A functions.
    pub const Path = [*:0]const u8;

    pub const invalid_handle: Impl = INVALID_HANDLE_VALUE;

    pub fn close(impl: Impl) void {
        kernel32.CloseHandle(impl);
    }

    pub fn writeBlocking(impl: Impl, bufs: []const Io.Buffer(.@"const")) Io.File.WriteBlockingError!usize {
        if (bufs.len == 0) return 0;
        const buf = bufs[0].slice();

        var written: DWORD = undefined;
        if (kernel32.WriteFile(impl, buf.ptr, @truncate(buf.len), &written, null) != .FALSE) {
            return written;
        } else return switch (GetLastError()) {
            .INVALID_PARAMETER, .IO_PENDING => unreachable, // API misuse. The file doesn't support blocking writes.
            .DISK_FULL => error.NoSpaceLeft,
            .ACCESS_DENIED => error.AccessDenied,
            .NOT_ENOUGH_QUOTA => error.DiskQuota,
            .NO_DATA => error.BrokenPipe,
            else => |e| unexpectedLastError(e),
        };
    }

    pub fn createBlocking(io: *Io, path: Path) Io.File.OpenBlockingError!Impl {
        const handle = kernel32.CreateFileA(
            path,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            2, // CREATE_ALWAYS
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            null,
        );

        if (handle == INVALID_HANDLE_VALUE) return switch (GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
            else => |e| unexpectedLastError(e),
        };

        _ = kernel32.CreateIoCompletionPort(handle, io.userdata.iocp, 0, 0) orelse
            unexpectedLastError(GetLastError());

        return handle;
    }

    pub fn openBlocking(io: *Io, path: Path) Io.File.OpenBlockingError!Impl {
        const handle = kernel32.CreateFileA(
            path,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            3, // OPEN_EXISTING
            FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
            null,
        );

        if (handle == INVALID_HANDLE_VALUE) return switch (GetLastError()) {
            .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.FileNotFound,
            .ACCESS_DENIED, .SHARING_VIOLATION => error.AccessDenied,
            else => |e| unexpectedLastError(e),
        };

        _ = kernel32.CreateIoCompletionPort(handle, io.userdata.iocp, 0, 0) orelse
            unexpectedLastError(GetLastError());

        return handle;
    }

    pub fn readBlocking(impl: Impl, bufs: []const Io.Buffer(.@"var")) Io.File.ReadBlockingError!usize {
        if (bufs.len == 0) return 0;
        const buf = bufs[0].slice();

        var read: DWORD = undefined;

        if (kernel32.ReadFile(impl, buf.ptr, @truncate(buf.len), &read, null) != .FALSE) {
            return read;
        } else return switch (GetLastError()) {
            .INVALID_PARAMETER, .IO_PENDING => unreachable, // API misuse. The file doesn't support blocking reads.
            .NETNAME_DELETED => error.ConnectionResetByPeer,
            else => |e| unexpectedLastError(e),
        };
    }
};

pub const socket_address_ip4 = struct {
    pub const Impl = ws2_32.sockaddr.in;

    pub fn init(impl: *Impl, addr: [4]u8, port: u16) void {
        impl.* = .{
            .family = ws2_32.AF.INET,
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
    pub const Impl = HANDLE;

    pub const AcceptBuffer = [(@sizeOf(ws2_32.sockaddr.in) + 16) * 2]u8;

    pub fn close(handle: Impl) void {
        assert(ws2_32.closesocket(handle) != SOCKET_ERROR);
    }

    pub fn listen(
        io: *Io,
        addr: *const socket_address_ip4.Impl,
        options: Io.ListenOptions,
    ) Io.ListenError!Impl {
        const handle = ws2_32.WSASocketW(
            ws2_32.AF.INET,
            ws2_32.SOCK.STREAM,
            ws2_32.IPPROTO.TCP,
            null,
            0,
            .{ .OVERLAPPED = true },
        );

        if (handle == INVALID_SOCKET) return switch (ws2_32.WSAGetLastError()) {
            .WSAEMFILE => error.ProcessFdQuotaExceeded,
            .WSAENOBUFS => error.SystemResources,
            else => |e| unexpectedWsaError(e),
        };

        errdefer _ = ws2_32.closesocket(handle);

        if (ws2_32.bind(handle, @ptrCast(addr), @sizeOf(ws2_32.sockaddr.in)) == SOCKET_ERROR)
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEACCES => error.AccessDenied,
                .WSAEADDRINUSE => error.AddressInUse,
                .WSAEADDRNOTAVAIL => error.AddressNotAvailable,
                else => |e| unexpectedWsaError(e),
            };

        if (ws2_32.listen(handle, options.backlog) == SOCKET_ERROR)
            return switch (ws2_32.WSAGetLastError()) {
                .WSAEADDRINUSE => error.AddressInUse,
                else => |e| unexpectedWsaError(e),
            };

        _ = kernel32.CreateIoCompletionPort(handle, io.userdata.iocp, 0, 0) orelse
            unexpectedLastError(GetLastError());

        return handle;
    }
};

pub fn randombytes(buf: []u8) Io.RandombytesError!void {
    var cursor = buf;

    while (cursor.len != 0) {
        const truncated: ULONG = @truncate(cursor.len);
        if (advapi32.RtlGenRandom(cursor.ptr, truncated) == .FALSE)
            return error.EntropyUnavailable;

        cursor = cursor[truncated..];
    }
}

pub const time = struct {
    pub const Spec = LARGE_INTEGER;

    const ns_per_unit = 100;

    pub fn now(spec: *Spec) void {
        spec.* = std.os.windows.ntdll.RtlGetSystemTimePrecise();
    }

    pub fn toSeconds(spec: *const Spec) u64 {
        const with_epoch: u64 = @intCast(spec.* + (std.time.epoch.windows * (std.time.ns_per_s / ns_per_unit)));
        return with_epoch / (std.time.ns_per_s / ns_per_unit);
    }

    pub fn toMilliseconds(spec: *const Spec) u64 {
        const with_epoch: u64 = @intCast(spec.* + (std.time.epoch.windows * (std.time.ns_per_s / ns_per_unit)));
        return with_epoch / (std.time.ns_per_ms / ns_per_unit);
    }
};

fn unexpectedLastError(err: Win32Error) noreturn {
    switch (builtin.optimize) {
        .debug, .safe => std.debug.panic("unexpected win32 error: {t}", .{err}),
        .small, .fast => std.process.exit(1),
    }
}

fn unexpectedWsaError(err: ws2_32.WinsockError) noreturn {
    switch (builtin.optimize) {
        .debug, .safe => std.debug.panic("unexpected winsock error: {t}", .{err}),
        .small, .fast => std.process.exit(1),
    }
}

fn unexpectedNtStatus(err: NTSTATUS) noreturn {
    switch (builtin.optimize) {
        .debug, .safe => std.debug.panic("unexpected NTSTATUS error: {t}", .{err}),
        .small, .fast => std.process.exit(1),
    }
}

const advapi32 = struct {
    pub extern "advapi32" fn SystemFunction036(output: [*]u8, length: ULONG) callconv(.winapi) BOOL;
    pub const RtlGenRandom = SystemFunction036;
};

const kernel32 = struct {
    extern "kernel32" fn WriteFile(
        hFile: HANDLE,
        lpBuffer: LPCVOID,
        nNumberOfBytesToWrite: DWORD,
        lpNumberOfBytesWritten: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn ReadFile(
        hFile: HANDLE,
        lpBuffer: LPVOID,
        nNumberOfBytesToRead: DWORD,
        lpNumberOfBytesRead: ?*DWORD,
        lpOverlapped: ?*OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateIoCompletionPort(
        FileHandle: HANDLE,
        ExistingCompletionPort: ?HANDLE,
        CompletionKey: ULONG_PTR,
        NumberOfConcurrentThreads: DWORD,
    ) callconv(.winapi) ?HANDLE;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) void;

    extern "kernel32" fn GetQueuedCompletionStatusEx(
        CompletionPort: HANDLE,
        lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
        ulCount: ULONG,
        ulNumEntriesRemoved: *ULONG,
        dwMilliseconds: DWORD,
        fAlertable: BOOL,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateDirectoryA(
        lpPathName: LPCSTR,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    ) callconv(.winapi) BOOL;

    extern "kernel32" fn CreateFileA(
        lpFileName: LPCSTR,
        dwDesiredAccess: DWORD,
        dwShareMode: DWORD,
        lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
        dwCreationDisposition: DWORD,
        dwFlagsAndAttributes: DWORD,
        hTemplateFile: ?HANDLE,
    ) callconv(.winapi) HANDLE;

    extern "kernel32" fn FlushFileBuffers(
        hFile: HANDLE,
    ) callconv(.winapi) BOOL;
};

const ws2_32 = struct {
    const AF = struct {
        const UNIX = 1;
        const INET = 2;
        const INET6 = 23;
    };

    const SOCK = struct {
        const STREAM = 1;
    };

    const IPPROTO = struct {
        const TCP = 6;
    };

    const WSA_FLAG = packed struct(u32) {
        OVERLAPPED: bool = false,
        _: u31 = 0,
    };

    const sockaddr = extern struct {
        family: u16,
        data: [14]u8,

        const in = extern struct {
            family: u16 = AF.INET,
            port: USHORT,
            addr: u32,
            zero: [8]u8 = [8]u8{ 0, 0, 0, 0, 0, 0, 0, 0 },
        };

        /// IPv6 socket address
        const in6 = extern struct {
            family: u16 = AF.INET6,
            port: USHORT,
            flowinfo: u32,
            addr: [16]u8,
            scope_id: u32,
        };

        /// UNIX domain socket address
        const un = extern struct {
            family: u16 = AF.UNIX,
            path: [108]u8,
        };
    };

    extern "ws2_32" fn WSAStartup(
        wVersionRequired: WORD,
        lpWSAData: *WSADATA,
    ) callconv(.winapi) i32;

    extern "ws2_32" fn WSASocketW(
        af: i32,
        @"type": i32,
        protocol: i32,
        lpProtocolInfo: ?*anyopaque,
        g: u32,
        dwFlags: WSA_FLAG,
    ) callconv(.winapi) HANDLE;

    extern "ws2_32" fn bind(
        socket: HANDLE,
        name: *const sockaddr,
        namelen: i32,
    ) callconv(.winapi) i32;

    extern "ws2_32" fn listen(
        socket: HANDLE,
        backlog: i32,
    ) callconv(.winapi) i32;

    extern "ws2_32" fn closesocket(socket: HANDLE) callconv(.winapi) i32;

    extern "mswsock" fn AcceptEx(
        sListenSocket: HANDLE,
        sAcceptSocket: HANDLE,
        lpOutputBuffer: *anyopaque,
        dwReceiveDataLength: u32,
        dwLocalAddressLength: u32,
        dwRemoteAddressLength: u32,
        lpdwBytesReceived: *u32,
        lpOverlapped: *OVERLAPPED,
    ) callconv(.winapi) BOOL;

    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WinsockError;

    extern "mswsock" fn GetAcceptExSockaddrs(
        lpOutputBuffer: *anyopaque,
        dwReceiveDataLength: u32,
        dwLocalAddressLength: u32,
        dwRemoteAddressLength: u32,
        LocalSockaddr: **sockaddr,
        LocalSockaddrLength: *i32,
        RemoteSockaddr: **sockaddr,
        RemoteSockaddrLength: *i32,
    ) callconv(.winapi) void;

    extern "ws2_32" fn setsockopt(
        s: HANDLE,
        level: i32,
        optname: i32,
        optval: ?[*]const u8,
        optlen: i32,
    ) callconv(.winapi) i32;

    extern "ws2_32" fn WSARecv(
        s: HANDLE,
        lpBuffers: [*]WSABUF(.@"var"),
        dwBufferCount: u32,
        lpNumberOfBytesRecv: ?*u32,
        lpFlags: *u32,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) i32;

    extern "ws2_32" fn WSASend(
        s: HANDLE,
        lpBuffers: [*]WSABUF(.@"const"),
        dwBufferCount: u32,
        lpNumberOfBytesSent: ?*u32,
        dwFlags: u32,
        lpOverlapped: ?*OVERLAPPED,
        lpCompletionRoutine: ?*anyopaque,
    ) callconv(.winapi) i32;

    const WinsockError = enum(u16) {
        WSA_INVALID_HANDLE = 6,
        WSA_NOT_ENOUGH_MEMORY = 8,
        WSA_INVALID_PARAMETER = 87,
        WSA_OPERATION_ABORTED = 995,
        WSA_IO_INCOMPLETE = 996,
        WSA_IO_PENDING = 997,
        WSAEINTR = 10004,
        WSAEBADF = 10009,
        WSAEACCES = 10013,
        WSAEFAULT = 10014,
        WSAEINVAL = 10022,
        WSAEMFILE = 10024,
        WSAEWOULDBLOCK = 10035,
        WSAEINPROGRESS = 10036,
        WSAEALREADY = 10037,
        WSAENOTSOCK = 10038,
        WSAEDESTADDRREQ = 10039,
        WSAEMSGSIZE = 10040,
        WSAEPROTOTYPE = 10041,
        WSAENOPROTOOPT = 10042,
        WSAEPROTONOSUPPORT = 10043,
        WSAESOCKTNOSUPPORT = 10044,
        WSAEOPNOTSUPP = 10045,
        WSAEPFNOSUPPORT = 10046,
        WSAEAFNOSUPPORT = 10047,
        WSAEADDRINUSE = 10048,
        WSAEADDRNOTAVAIL = 10049,
        WSAENETDOWN = 10050,
        WSAENETUNREACH = 10051,
        WSAENETRESET = 10052,
        WSAECONNABORTED = 10053,
        WSAECONNRESET = 10054,
        WSAENOBUFS = 10055,
        WSAEISCONN = 10056,
        WSAENOTCONN = 10057,
        WSAESHUTDOWN = 10058,
        WSAETOOMANYREFS = 10059,
        WSAETIMEDOUT = 10060,
        WSAECONNREFUSED = 10061,
        WSAELOOP = 10062,
        WSAENAMETOOLONG = 10063,
        WSAEHOSTDOWN = 10064,
        WSAEHOSTUNREACH = 10065,
        WSAENOTEMPTY = 10066,
        WSAEPROCLIM = 10067,
        WSAEUSERS = 10068,
        WSAEDQUOT = 10069,
        WSAESTALE = 10070,
        WSAEREMOTE = 10071,
        WSASYSNOTREADY = 10091,
        WSAVERNOTSUPPORTED = 10092,
        WSANOTINITIALISED = 10093,
        WSAEDISCON = 10101,
        WSAENOMORE = 10102,
        WSAECANCELLED = 10103,
        WSAEINVALIDPROCTABLE = 10104,
        WSAEINVALIDPROVIDER = 10105,
        WSAEPROVIDERFAILEDINIT = 10106,
        WSASYSCALLFAILURE = 10107,
        WSASERVICE_NOT_FOUND = 10108,
        WSATYPE_NOT_FOUND = 10109,
        WSA_E_NO_MORE = 10110,
        WSA_E_CANCELLED = 10111,
        WSAEREFUSED = 10112,
        WSAHOST_NOT_FOUND = 11001,
        WSATRY_AGAIN = 11002,
        WSANO_RECOVERY = 11003,
        WSANO_DATA = 11004,
        WSA_QOS_RECEIVERS = 11005,
        WSA_QOS_SENDERS = 11006,
        WSA_QOS_NO_SENDERS = 11007,
        WSA_QOS_NO_RECEIVERS = 11008,
        WSA_QOS_REQUEST_CONFIRMED = 11009,
        WSA_QOS_ADMISSION_FAILURE = 11010,
        WSA_QOS_POLICY_FAILURE = 11011,
        WSA_QOS_BAD_STYLE = 11012,
        WSA_QOS_BAD_OBJECT = 11013,
        WSA_QOS_TRAFFIC_CTRL_ERROR = 11014,
        WSA_QOS_GENERIC_ERROR = 11015,
        WSA_QOS_ESERVICETYPE = 11016,
        WSA_QOS_EFLOWSPEC = 11017,
        WSA_QOS_EPROVSPECBUF = 11018,
        WSA_QOS_EFILTERSTYLE = 11019,
        WSA_QOS_EFILTERTYPE = 11020,
        WSA_QOS_EFILTERCOUNT = 11021,
        WSA_QOS_EOBJLENGTH = 11022,
        WSA_QOS_EFLOWCOUNT = 11023,
        WSA_QOS_EUNKOWNPSOBJ = 11024,
        WSA_QOS_EPOLICYOBJ = 11025,
        WSA_QOS_EFLOWDESC = 11026,
        WSA_QOS_EPSFLOWSPEC = 11027,
        WSA_QOS_EPSFILTERSPEC = 11028,
        WSA_QOS_ESDMODEOBJ = 11029,
        WSA_QOS_ESHAPERATEOBJ = 11030,
        WSA_QOS_RESERVED_PETYPE = 11031,

        _,
    };

    const SOL = struct {
        const IRLMP = 255;
        const SOCKET = 65535;
    };

    const SO = struct {
        const DEBUG = 1;
        const ACCEPTCONN = 2;
        const REUSEADDR = 4;
        const KEEPALIVE = 8;
        const DONTROUTE = 16;
        const BROADCAST = 32;
        const USELOOPBACK = 64;
        const LINGER = 128;
        const OOBINLINE = 256;
        const SNDBUF = 4097;
        const RCVBUF = 4098;
        const SNDLOWAT = 4099;
        const RCVLOWAT = 4100;
        const SNDTIMEO = 4101;
        const RCVTIMEO = 4102;
        const ERROR = 4103;
        const TYPE = 4104;
        const BSP_STATE = 4105;
        const GROUP_ID = 8193;
        const GROUP_PRIORITY = 8194;
        const MAX_MSG_SIZE = 8195;
        const CONDITIONAL_ACCEPT = 12290;
        const PAUSE_ACCEPT = 12291;
        const COMPARTMENT_ID = 12292;
        const RANDOMIZE_PORT = 12293;
        const PORT_SCALABILITY = 12294;
        const REUSE_UNICASTPORT = 12295;
        const REUSE_MULTICASTPORT = 12296;
        const ORIGINAL_DST = 12303;
        const PROTOCOL_INFOA = 8196;
        const PROTOCOL_INFOW = 8197;
        const CONNDATA = 28672;
        const CONNOPT = 28673;
        const DISCDATA = 28674;
        const DISCOPT = 28675;
        const CONNDATALEN = 28676;
        const CONNOPTLEN = 28677;
        const DISCDATALEN = 28678;
        const DISCOPTLEN = 28679;
        const OPENTYPE = 28680;
        const SYNCHRONOUS_ALERT = 16;
        const SYNCHRONOUS_NONALERT = 32;
        const MAXDG = 28681;
        const MAXPATHDG = 28682;
        const UPDATE_ACCEPT_CONTEXT = 28683;
        const CONNECT_TIME = 28684;
        const UPDATE_CONNECT_CONTEXT = 28688;
    };
};
