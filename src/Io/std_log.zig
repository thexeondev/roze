//! logFn implementation without dependency on `std.Io`
const std = @import("std");

const roze = @import("../roze.zig");
const Io = roze.Io;

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buffer: [64]u8 = undefined;

    var writer: std.Io.Writer = .{
        .buffer = &buffer,
        .vtable = &.{ .drain = drainBlocking },
    };

    const terminal: std.Io.Terminal = .{
        .writer = &writer,
        .mode = .escape_codes,
    };

    std.log.defaultLogFileTerminal(level, scope, format, args, terminal) catch {};
    writer.flush() catch {};
}

fn drainBlocking(io_w: *std.Io.Writer, data: []const []const u8, _: usize) std.Io.Writer.Error!usize {
    const stderr: Io.File.Preopen = .stderr;

    if (io_w.buffered().len == 0) {
        return stderr.writeBlocking(data[0]) catch
            return error.WriteFailed;
    } else {
        const written = stderr.writeBlocking(io_w.buffered()) catch
            return error.WriteFailed;

        _ = io_w.consume(written);
        return 0;
    }
}
