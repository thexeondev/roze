const builtin = @import("builtin");

const std = @import("std");
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const roze = @import("roze");
const Io = roze.Io;
const Maybe = roze.Maybe;
const Ip4Address = roze.Io.Ip4Address;

const default_listen_address = "127.0.0.1:30002";
const default_listen_backlog: u31 = 64;
const default_concurrency: u32 = 1024;
const default_server_id: u32 = 517;
const default_world_id: u32 = 909;
const default_server_name = "roze";
const default_scene_server_address = "127.0.0.1:30003";

const log = std.log.scoped(.@"roze-dir-server");

pub const std_options: std.Options = .{
    .logFn = Io.std_log.logFn,
};

const Option = enum {
    @"--help",
    @"--listen-address",
    @"--listen-backlog",
    @"--concurrency",
    @"--server-id",
    @"--world-id",
    @"--server-name",
    @"--scene-server-address",
};

fn usage() noreturn {
    Io.File.Preopen.stdout.writeAllBlocking(std.fmt.comptimePrint(
        \\Usage: roze-dir-server [options]
        \\
        \\Options:
        \\  --help                  Print this help and exit
        \\  --listen-address        The address to listen on via TCP; default is {q}
        \\  --listen-backlog        The kernel backlog size for the listening socket; default is {d}
        \\  --concurrency           The amount of connections allowed to be processed concurrently; default is {d}
        \\  --server-id             The identifier of the server communicated to the clients; default is {d}
        \\  --world-id              The identifier of the logical world communicated to the clients; default is {d}
        \\  --server-name           The display name of the server; default is {q}
        \\  --scene-server-address  The outer scene server address; default is {q}
        \\
    ,
        .{
            default_listen_address,
            default_listen_backlog,
            default_concurrency,
            default_server_id,
            default_world_id,
            default_server_name,
            default_scene_server_address,
        },
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
    var server_options: Responses.Options = .{
        .server_id = default_server_id,
        .world_id = default_world_id,
        .server_name = default_server_name,
        .scene_server_address = comptime Ip4Address.parseLiteral(default_scene_server_address) catch unreachable,
    };

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
            .@"--server-id" => {
                server_options.server_id = std.fmt.parseInt(u32, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --server-id: {t}", .{err});
            },
            .@"--world-id" => {
                server_options.world_id = std.fmt.parseInt(u32, argv.next() orelse usage(), 10) catch |err|
                    fatal("bad --world-id: {t}", .{err});
            },
            .@"--server-name" => {
                server_options.server_name = try arena.dupe(u8, argv.next() orelse usage());
            },
            .@"--scene-server-address" => {
                const literal = argv.next() orelse usage();
                server_options.scene_server_address = Ip4Address.parseLiteral(literal) catch |err|
                    fatal("bad --scene-server-address: {t}", .{err});
            },
        }
    }

    var responses: Responses = undefined;
    try responses.init(arena, &server_options);

    const connections = try arena.alloc(Connection, concurrency);

    const listening = io.listen(&listen_address, listen_options) catch |err| switch (err) {
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
                    connection.state = tick(io, &responses, connection, &maybe) catch |err| {
                        if (err != error.EndOfStream and err != error.ConnectionResetByPeer)
                            log.err("connection tick failed: {t}", .{err});

                        connection.closeAndSubmitAccept(io, &listening);
                        continue;
                    };
                },
                else => {
                    var maybe: Maybe(Io.Operation.Result) = .{ .ptr_maybe = &storage.completion.result };
                    connection.state = tick(io, &responses, connection, &maybe) catch |err| {
                        if (err != error.EndOfStream and err != error.ConnectionResetByPeer)
                            log.err("connection tick failed: {t}", .{err});

                        connection.closeAndSubmitAccept(io, &listening);
                        continue;
                    };
                },
            }
        }
    }
}

fn tick(
    io: *Io,
    responses: *const Responses,
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
                continue :state .{ .serve = .{ .request_line = request_line } };
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

            connection.read_buffer_seek += reading_body.content_length;
            continue :state .{ .serve = .{ .request_line = reading_body.request_line } };
        },
        .serve => |serve| {
            assert(io_result_maybe.take() == null);

            const path, _ = mem.cutScalar(u8, serve.request_line.target, '?') orelse
                .{ serve.request_line.target, "" };

            if (mem.eql(u8, path, "/0.10/Release/server_info")) {
                try connection.respond(200, "OK", responses.server_info_json);
            } else {
                log.warn("unhandled path: {s}", .{path});
                try connection.respond(404, "Not Found", "Not Found");
            }

            continue :state .writing_response;
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
        },
        writing_response,
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

    fn respond(connection: *Connection, status: u16, phrase: []const u8, data: []const u8) !void {
        connection.write_buffer_seek = 0;
        connection.write_buffer_end = try roze.http.response.putCustomString(
            &connection.write_buffer,
            status,
            phrase,
            data,
        );
    }
};

const Responses = struct {
    server_info_json: []const u8,

    const Options = struct {
        server_id: u32,
        world_id: u32,
        server_name: []const u8,
        scene_server_address: Ip4Address,
    };

    fn init(responses: *Responses, arena: Allocator, options: *const Options) Allocator.Error!void {
        const addr_fmt: AddressFmt = .{ .indentation = 2, .ip4 = &options.scene_server_address };

        responses.server_info_json = try arena.print(
            \\{{
            \\    "Code": 200,
            \\    "ErrorMsg": "",
            \\    "server_info": [{{
            \\        "id": {d},
            \\        "world_id": {d},
            \\        "name": {q},
            \\        "addr": {f},
            \\        "addrs": [{f}],
            \\        "branch": "0.10",
            \\        "private": 0,
            \\        "tag": "Release",
            \\        "status": 1
            \\    }}],
            \\    "auth_info": {{
            \\        "phone": "",
            \\        "mail": ""
            \\    }}
            \\}}
        , .{ options.server_id, options.world_id, options.server_name, &addr_fmt, &addr_fmt });
    }

    const AddressFmt = struct {
        indentation: u8,
        ip4: *const Ip4Address,

        pub fn format(af: *const AddressFmt, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const b = af.ip4.getBytes();

            try writer.writeAll("{\n");
            try writer.splatByteAll(' ', (af.indentation + 1) * 4);
            try writer.print("\"ip\": \"{d}.{d}.{d}.{d}\",\n", .{ b[0], b[1], b[2], b[3] });
            try writer.splatByteAll(' ', (af.indentation + 1) * 4);
            try writer.print("\"port\": {d}\n", .{af.ip4.getPort()});
            try writer.splatByteAll(' ', af.indentation * 4);
            try writer.writeByte('}');
        }
    };
};
