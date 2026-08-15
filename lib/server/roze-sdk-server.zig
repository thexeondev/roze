const builtin = @import("builtin");

const std = @import("std");
const mem = std.mem;
const Random = std.Random;
const process = std.process;
const assert = std.debug.assert;
const DefaultCsprng = std.Random.DefaultCsprng;

const roze = @import("roze");
const Io = roze.Io;
const Maybe = roze.Maybe;
const Ip4Address = roze.Io.Ip4Address;
const SinglyLinkedListWithTail = roze.SinglyLinkedListWithTail;

pub const std_options: std.Options = .{
    .logFn = Io.std_log.logFn,
};

const default_listen_address = "127.0.0.1:30001";
const default_listen_backlog: u31 = 64;
const default_concurrency: u32 = 1024;
const default_store_size: u32 = 1024;
const default_store_dir = "store";

const ret_buffer_size = 1024;
const ret_base64_buffer_size = std.base64.standard.Encoder.calcSize(ret_buffer_size);

const log = std.log.scoped(.@"roze-sdk-server");

const Option = enum {
    @"--help",
    @"--listen-address",
    @"--listen-backlog",
    @"--concurrency",
    @"--store-size",
    @"--store-dir",
};

fn usage() noreturn {
    Io.File.Preopen.stdout.writeAllBlocking(std.fmt.comptimePrint(
        \\Usage: roze-sdk-server [options]
        \\
        \\Options:
        \\  --help            Print this help and exit
        \\  --listen-address  The address to listen on via TCP; default is {q}
        \\  --listen-backlog  The kernel backlog size for the listening socket; default is {d}
        \\  --concurrency     The amount of connections allowed to be processed concurrently; default is {d}
        \\  --store-size      The capacity of account storage; default is {d}
        \\  --store-dir       The directory to store persistent data files in; default is {q}
        \\
    ,
        .{ default_listen_address, default_listen_backlog, default_concurrency, default_store_size, default_store_dir },
    )) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}

pub fn main(init: process.Init.Minimal) !void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var io_instance: Io = undefined;
    try io_instance.init();
    defer io_instance.deinit();
    const io = &io_instance;

    var argv = try init.args.iterateAllocator(arena);
    defer argv.deinit();
    assert(argv.skip());

    var listen_address = comptime Ip4Address.parseLiteral(default_listen_address) catch unreachable;
    var listen_options: Io.ListenOptions = .{
        .reuse_address = true,
        .backlog = default_listen_backlog,
    };
    var concurrency: u32 = default_concurrency;
    var store_size: u32 = default_store_size;
    var store_dir: [:0]const u8 = default_store_dir;

    while (argv.next()) |arg| {
        const option = std.meta.stringToEnum(Option, arg) orelse {
            log.err("unrecognized argument: {q}", .{arg});
            usage();
        };

        switch (option) {
            .@"--help" => usage(),
            .@"--listen-address" => {
                listen_address = Ip4Address.parseLiteral(argv.next() orelse usage()) catch |err|
                    fatal("bad --listen-address: {t}", .{err});
            },
            .@"--listen-backlog" => {
                listen_options.backlog = std.fmt.parseInt(u31, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --listen-backlog: {t}", .{err});
            },
            .@"--concurrency" => {
                concurrency = std.fmt.parseInt(u32, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --concurrency: {t}", .{err});
            },
            .@"--store-size" => {
                store_size = std.fmt.parseInt(u32, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --store-size: {t}", .{err});
            },
            .@"--store-dir" => {
                store_dir = try arena.dupeSentinel(u8, argv.next() orelse usage(), 0);
            },
        }
    }

    Io.createDirectoryBlocking(store_dir.ptr) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| return e,
    };

    var csprng_seed: [DefaultCsprng.secret_seed_length]u8 = undefined;
    try io.randombytes(&csprng_seed);

    var csprng_instance: DefaultCsprng = .init(csprng_seed);
    const csprng = csprng_instance.random();

    var account_storage: roze.he_sdk.Account.Storage = undefined;
    account_storage.init(io, arena, store_size, store_dir) catch |err| switch (err) {
        error.OutOfMemory => fatal(
            \\failed to allocate store of size {d}
            \\likely cause: --store-size is higher than the system can allocate
        , .{store_size}),
        error.MalformedFile => fatal(
            \\failed to read store file
            \\likely cause: the file is corrupted or its format is incompatible (e.g. due to breaking change)
        , .{}),
        error.TooManyAccounts => fatal(
            \\too many accounts in the store file
            \\likely cause: the server was previously running with a higher --store-size value
        , .{}),
        else => |e| return e,
    };
    defer account_storage.deinit(io);

    const connections = try arena.alloc(Connection, concurrency);

    var listening = io.listen(&listen_address, listen_options) catch |err| switch (err) {
        error.AddressInUse => fatal(
            \\the address {f} is already in use
            \\likely cause: another instance of this server is already running
        , .{listen_address}),
        else => |e| return e,
    };
    defer io.closeSocket(&listening.raw);

    for (connections) |*connection| {
        connection.submitAccept(io, &listening);
    }

    var storage_access_queue: SinglyLinkedListWithTail = .init;

    log.info("waiting for requests at http://{f}", .{listen_address});

    while (true) {
        try io.wait(std.math.maxInt(u63));

        while (io.nextCompletion()) |storage| {
            const connection: *Connection = @alignCast(@fieldParentPtr("operation", storage));
            switch (storage.completion.result) {
                .tcp_accept => |tcp_accept| {
                    const connected = tcp_accept catch |err| {
                        log.warn("accept failed: {t}", .{err});
                        connection.submitAccept(io, &listening);
                        continue;
                    };

                    connection.socket = connected;
                    connection.state = .start;

                    var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = &storage.completion.result };
                    connection.state = tick(io, csprng, &account_storage, connection, &maybe) catch |err| {
                        assert(err != error.StorageLocked);

                        if (err != error.EndOfStream and err != error.ConnectionResetByPeer)
                            log.err("connection tick failed: {t}", .{err});

                        connection.closeAndSubmitAccept(io, &listening);
                        continue;
                    };
                },
                else => {
                    var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = &storage.completion.result };
                    connection.state = tick(io, csprng, &account_storage, connection, &maybe) catch |err| switch (err) {
                        error.StorageLocked => {
                            storage_access_queue.append(&connection.storage_access_queue_node);
                            continue;
                        },
                        else => |e| {
                            if (e != error.EndOfStream and e != error.ConnectionResetByPeer)
                                log.err("connection tick failed: {t}", .{e});

                            connection.closeAndSubmitAccept(io, &listening);
                            continue;
                        },
                    };
                },
            }
        }

        while (!account_storage.lock) {
            const node = storage_access_queue.popFirst() orelse break;
            const connection: *Connection = @alignCast(@fieldParentPtr("storage_access_queue_node", node));

            var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = null };
            connection.state = tick(io, csprng, &account_storage, connection, &maybe) catch |err| {
                assert(err != error.StorageLocked); // See loop condition.

                if (err != error.EndOfStream and err != error.ConnectionResetByPeer)
                    log.err("connection tick failed: {t}", .{err});

                connection.closeAndSubmitAccept(io, &listening);
                continue;
            };
        }
    }
}

fn tick(
    io: *Io,
    csprng: Random,
    account_storage: *roze.he_sdk.Account.Storage,
    connection: *Connection,
    io_result_maybe: *Maybe(Io.Operation.Result),
) !Connection.State {
    state: switch (connection.state) {
        .start => {
            _ = io_result_maybe.take();

            connection.read_buffer_end = 0;
            connection.read_buffer_seek = 0;
            connection.write_buffer_end = 0;
            connection.write_buffer_seek = 0;

            continue :state .reading_head;
        },
        .reading_head => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_read);

                const read_n = try io_result.tcp_read;
                if (read_n == 0) return error.EndOfStream;

                assert(connection.read_buffer_end + read_n <= connection.read_buffer.len);
                connection.read_buffer_end += read_n;
            }

            const buffered = connection.read_buffer[0..connection.read_buffer_end];
            var cursor = buffered;

            var request_line: roze.http.request.Line = undefined;
            request_line.parse(&cursor) catch |err| switch (err) {
                error.ReadMore => {
                    connection.submitRead(io);
                    return .reading_head;
                },
                else => |e| return e,
            };

            var headers: roze.http.request.Headers = .init;
            headers.parse(&cursor) catch |err| switch (err) {
                error.ReadMore => {
                    connection.submitRead(io);
                    return .reading_head;
                },
                else => |e| return e,
            };

            connection.read_buffer_seek = cursor.ptr - buffered.ptr;

            if (!mem.eql(u8, request_line.method, "POST")) {
                continue :state .{ .serve = .{
                    .request_line = request_line,
                    .body = &.{},
                } };
            } else {
                const content_length = headers.content_length orelse
                    return error.PostMissingContentLength;

                if (content_length == 0)
                    return error.ContentLengthZero;

                if (content_length > connection.read_buffer.len)
                    return error.StreamTooLong;

                continue :state .{ .reading_body = .{
                    .request_line = request_line,
                    .content_length = content_length,
                } };
            }
        },
        .reading_body => |reading_body| {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_read);

                const read_n = try io_result.tcp_read;
                if (read_n == 0) return error.EndOfStream;

                assert(connection.read_buffer_end + read_n <= connection.read_buffer.len);
                connection.read_buffer_end += read_n;
            }

            if (connection.read_buffer_end - connection.read_buffer_seek < reading_body.content_length) {
                connection.submitRead(io);
                return .{ .reading_body = reading_body };
            }

            const body = connection.read_buffer[connection.read_buffer_seek..][0..reading_body.content_length];
            connection.read_buffer_seek += reading_body.content_length;

            continue :state .{ .serve = .{
                .request_line = reading_body.request_line,
                .body = body,
            } };
        },
        .serve => |serve| {
            assert(io_result_maybe.take() == null);

            const path, _ = mem.cutScalar(u8, serve.request_line.target, '?') orelse
                .{ serve.request_line.target, "" };

            const status = serveRequest(account_storage, csprng, connection, &.{
                .path = path,
                .body = serve.body,
            }) catch |err| switch (err) {
                error.StorageLocked => comptime unreachable, // Storage locks must be reported as `status`.
                else => |e| return e,
            };

            switch (status) {
                .wait_on_storage_lock => {
                    connection.state = .{ .serve = serve }; // Preserve current state.
                    return error.StorageLocked;
                },
                .respond => continue :state .writing_response,
                .save_then_respond => {
                    account_storage.lock = true;
                    connection.save_write_offset = 0;
                    connection.save_vector = account_storage.getSaveVector(&connection.save_header_buffer);

                    continue :state .{ .writing_save_file = .{ .buffers = &connection.save_vector } };
                },
            }
        },
        .writing_response => {
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .tcp_write);
                const write_n = try io_result.tcp_write;
                connection.write_buffer_seek += write_n;
            }

            if (connection.writeMore(io)) return .writing_response;

            connection.rebaseReadBuffer();
            continue :state .reading_head;
        },
        .writing_save_file => |writing_save_file| {
            assert(account_storage.lock);

            var buffers = writing_save_file.buffers;
            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .file_write);
                var write_n = try io_result.file_write;
                connection.save_write_offset += write_n;

                while (write_n >= buffers[0].slice().len) {
                    write_n -= buffers[0].slice().len;
                    buffers = buffers[1..];

                    if (buffers.len == 0) {
                        connection.operation = .init(.{ .file_synchronize = .{
                            .file_handle = account_storage.file.handle,
                        } });
                        io.submit(&connection.operation);

                        return .syncing_save_file;
                    }
                }

                buffers[0].advance(write_n);
            }

            connection.operation = .init(.{ .file_write = .{
                .file_handle = account_storage.file.handle,
                .buffers = buffers,
                .offset = connection.save_write_offset,
            } });
            io.submit(&connection.operation);

            return .{ .writing_save_file = .{ .buffers = buffers } };
        },
        .syncing_save_file => {
            assert(account_storage.lock);

            if (io_result_maybe.take()) |io_result| {
                assert(io_result == .file_synchronize);
                try io_result.file_synchronize;

                account_storage.lock = false;
                continue :state .writing_response;
            }

            return .syncing_save_file;
        },
    }
}

const Connection = struct {
    const read_buffer_size = 4 * 1024;
    const write_buffer_size = 4 * 1024;

    operation: Io.Operation.Storage,
    accept_buffer: Io.Operation.TcpAccept.Buffer,
    socket: Io.Socket.Connected,
    read_buffer: [read_buffer_size]u8,
    read_buffer_end: usize,
    read_buffer_seek: usize,
    write_buffer: [write_buffer_size]u8,
    write_buffer_seek: usize,
    write_buffer_end: usize,
    ret_buffer: [ret_buffer_size]u8,
    ret_base64_buffer: [ret_base64_buffer_size]u8,
    save_vector: roze.he_sdk.Account.Storage.SaveVector,
    save_header_buffer: roze.he_sdk.Account.Storage.SaveHeaderBuffer,
    save_write_offset: u64,
    storage_access_queue_node: SinglyLinkedListWithTail.Node,
    state: State,

    const State = union(enum) {
        start,
        reading_head,
        reading_body: struct {
            request_line: roze.http.request.Line,
            content_length: u64,
        },
        serve: struct {
            request_line: roze.http.request.Line,
            body: []u8,
        },
        writing_response,
        writing_save_file: struct {
            buffers: []Io.Buffer(.@"const"),
        },
        syncing_save_file,
    };

    fn submitAccept(connection: *Connection, io: *Io, listening: *const Io.Socket.Listening) void {
        connection.operation = .init(.{ .tcp_accept = .{
            .listening_socket_handle = listening.raw.handle,
            .buffer = &connection.accept_buffer,
        } });

        io.submit(&connection.operation);
    }

    fn closeAndSubmitAccept(connection: *Connection, io: *Io, listening: *const Io.Socket.Listening) void {
        io.closeSocket(&connection.socket.raw);
        connection.submitAccept(io, listening);
    }

    fn submitRead(connection: *Connection, io: *Io) void {
        connection.operation = .init(.{ .tcp_read = .{
            .connected_socket_handle = connection.socket.raw.handle,
            .buffer = connection.read_buffer[connection.read_buffer_end..],
        } });

        io.submit(&connection.operation);
    }

    fn submitWrite(connection: *Connection, io: *Io) void {
        connection.operation = .init(.{ .tcp_write = .{
            .connected_socket_handle = connection.socket.raw.handle,
            .buffer = connection.write_buffer[connection.write_buffer_seek..connection.write_buffer_end],
        } });

        io.submit(&connection.operation);
    }

    /// Returns `true` if another write operation was submitted.
    fn writeMore(connection: *Connection, io: *Io) bool {
        if (connection.write_buffer_seek < connection.write_buffer_end) {
            connection.submitWrite(io);
            return true;
        } else {
            // The buffer is fully drained.
            connection.write_buffer_seek = 0;
            connection.write_buffer_end = 0;
            return false;
        }
    }

    fn rebaseReadBuffer(connection: *Connection) void {
        if (connection.read_buffer_end == connection.read_buffer_seek) {
            connection.read_buffer_end = 0;
            connection.read_buffer_seek = 0;
        } else if (connection.read_buffer_seek != 0) {
            const new_end = connection.read_buffer_end - connection.read_buffer_seek;
            @memmove(
                connection.read_buffer[0..new_end],
                connection.read_buffer[connection.read_buffer_seek..connection.read_buffer_end],
            );

            connection.read_buffer_seek = 0;
            connection.read_buffer_end = new_end;
        }
    }

    fn respondString(
        connection: *Connection,
        status: u16,
        phrase: []const u8,
        data: []const u8,
    ) !void {
        connection.write_buffer_end = try roze.http.response.putCustomString(
            &connection.write_buffer,
            status,
            phrase,
            data,
        );

        connection.write_buffer_seek = 0;
    }

    fn respondJson(connection: *Connection, comptime Json: type, json: *const Json) !void {
        connection.write_buffer_end = try roze.http.response.putJson(&connection.write_buffer, Json, json);
        connection.write_buffer_seek = 0;
    }

    fn respondRetNull(
        connection: *Connection,
        code: i32,
        message: []const u8,
    ) !void {
        try connection.respondJson(roze.he_sdk.AnyResponse, &.{
            .code = code,
            .message = message,
            .ret = null,
        });
    }

    fn respondRetEncrypted(
        connection: *Connection,
        comptime Ret: type,
        ret: *const Ret,
    ) !void {
        const ret_json = mem.print(&connection.ret_buffer, "{f}", .{std.json.fmt(ret, .{})}) catch
            return error.OutOfMemory;

        const ret_encrypted = try roze.he_sdk.crypto.encrypt(&connection.ret_buffer, ret_json.len);
        const ret_encoded_length = std.base64.standard.Encoder.calcSize(ret_encrypted.len);
        if (ret_encoded_length > connection.ret_base64_buffer.len)
            return error.OutOfMemory;

        const ret_encoded = std.base64.standard.Encoder.encode(
            connection.ret_base64_buffer[0..ret_encoded_length],
            ret_encrypted,
        );

        try connection.respondJson(roze.he_sdk.AnyResponse, &.{
            .code = 0,
            .message = "",
            .ret = ret_encoded,
        });
    }
};

const Request = struct {
    const Path = enum {
        @"/api/safeLogin",
        @"/api/historicalSafeLogin",
        @"/api/risk/checkAccount",
        @"/api/passport/relations",
        @"/api/fetchCurrentToken",
    };

    path: []const u8,
    body: []u8,
};

const ServeRequestStatus = enum {
    wait_on_storage_lock,
    respond,
    save_then_respond,
};

fn serveRequest(
    account_storage: *roze.he_sdk.Account.Storage,
    csprng: Random,
    connection: *Connection,
    request: *const Request,
) !ServeRequestStatus {
    const path = std.meta.stringToEnum(Request.Path, request.path) orelse {
        log.warn("unhandled path: {s}", .{request.path});
        try connection.respondString(404, "Not Found", "Not Found");
        return .respond;
    };

    const body = decryptAndDecode(request.body) catch |err| {
        log.err("bad request {q}: {t}", .{ request.path, err });
        try connection.respondString(400, "Bad Request", "Bad Request");
        return .respond;
    };

    switch (path) {
        .@"/api/safeLogin", .@"/api/historicalSafeLogin" => {
            const param = roze.json.parse(roze.he_sdk.SafeLoginParam, body) catch {
                try connection.respondString(400, "Bad Request", "Bad Request");
                return .respond;
            };

            const extra = roze.json.parse(roze.he_sdk.SafeLoginParam.Extra, param.extraParams) catch {
                try connection.respondString(400, "Bad Request", "Bad Request");
                return .respond;
            };

            const email = roze.he_sdk.Account.Email.fromSlice(extra.account) orelse {
                log.debug("invalid email: {s}", .{extra.account});
                try connection.respondRetNull(1, "invalid email specified");
                return .respond;
            };

            const got_or_created_maybe = account_storage.getOrCreateByEmail(
                csprng,
                email,
                extra.password,
            ) catch |err| switch (err) {
                error.StorageLocked => return .wait_on_storage_lock,
                error.TooManyAccounts => {
                    log.warn("too many accounts in storage, rejected creation attempt", .{});
                    try connection.respondString(503, "Service Unavailable", "Service Unavailable");
                    return .respond;
                },
                else => |e| {
                    log.err("getOrCreateByEmail failed: {t}", .{e});
                    try connection.respondString(500, "Internal Server Error", "Internal Server Error");
                    return .respond;
                },
            };

            const got_or_created = got_or_created_maybe orelse {
                try connection.respondRetNull(1, "email or password don't match");
                return .respond;
            };

            const identified = &got_or_created.identified;

            var uid_fmt: [roze.he_sdk.Account.Uid.string_length]u8 = undefined;
            const uid = identified.uid.print(&uid_fmt);

            try connection.respondRetEncrypted(roze.he_sdk.SafeLoginRet, &.{
                .channelUid = uid,
                .sdkUid = uid,
                .passportId = @backingInt(identified.uid),
                .channelToken = &identified.account.token.string,
                .heiToken = &identified.account.token.string,
                .unionid = extra.account,
                .expireTime = std.math.maxInt(u63),
                .privacyAgreementStatus = 1,
                .subChannelName = "onekey",
            });

            return if (got_or_created.needs_save)
                .save_then_respond
            else
                .respond;
        },
        .@"/api/risk/checkAccount" => {
            try connection.respondRetEncrypted(roze.he_sdk.CheckAccountRet, &.{
                .accountStatus = 1,
                .area = "EU",
                .firstBinding = false,
                .matching = true,
            });
            return .respond;
        },
        .@"/api/passport/relations" => {
            try connection.respondRetNull(0, "");
            return .respond;
        },
        .@"/api/fetchCurrentToken" => {
            const param = roze.json.parse(roze.he_sdk.FetchCurrentTokenParam, body) catch {
                try connection.respondString(400, "Bad Request", "Bad Request");
                return .respond;
            };

            const token = roze.he_sdk.Account.Token.fromSlice(param.channelToken) orelse {
                try connection.respondRetNull(1, "please log-in again");
                return .respond;
            };

            const identified_maybe = account_storage.getByToken(token) catch |err| switch (err) {
                error.StorageLocked => return .wait_on_storage_lock,
            };

            const identified = identified_maybe orelse {
                try connection.respondRetNull(1, "please log-in again");
                return .respond;
            };

            var uid_fmt: [roze.he_sdk.Account.Uid.string_length]u8 = undefined;
            const uid = identified.uid.print(&uid_fmt);

            try connection.respondRetEncrypted(roze.he_sdk.FetchCurrentTokenRet, &.{
                .channelUid = uid,
                .sdkUid = uid,
                .passportId = @backingInt(identified.uid),
                .channelToken = &identified.account.token.string,
                .heiToken = &identified.account.token.string,
                .expireTime = std.math.maxInt(u63),
                .type = "cache",
            });

            return .respond;
        },
    }
}

fn decryptAndDecode(body: []u8) ![:0]u8 {
    const percent_encoded = try roze.http.request.formExpectOne(body, "data");
    const base64_encoded = try roze.http.percentDecode(percent_encoded);
    const base64_decoded_length = try std.base64.standard.Decoder.calcSizeForSlice(base64_encoded);

    try std.base64.standard.Decoder.decode(body[0..base64_decoded_length], base64_encoded);
    const decrypted_len = try roze.he_sdk.crypto.decrypt(body[0..base64_decoded_length]);
    assert(body.len > decrypted_len);
    body[decrypted_len] = 0;
    return @ptrCast(body[0..decrypted_len]);
}
