const std = @import("std");
const Writer = std.Io.Writer;
const mem = std.mem;

pub const request = struct {
    pub const Line = struct {
        method: []const u8,
        target: []const u8,

        pub const ParseError = error{
            /// More data has to be read.
            ReadMore,
            BadRequestLine,
        };

        pub fn parse(line: *Line, cursor: *[]u8) ParseError!void {
            var string, _ = mem.cutScalar(u8, cursor.*, '\n') orelse
                return error.ReadMore;

            cursor.* = cursor.*[string.len + 1 ..];

            if (string.len <= 4 or string[string.len - 1] != '\r') return error.BadRequestLine;
            line.method, string = mem.cutScalar(u8, string, ' ') orelse return error.BadRequestLine;
            line.target, string = mem.cutScalar(u8, string, ' ') orelse return error.BadRequestLine;
        }
    };

    pub const Headers = struct {
        content_length: ?u64,

        pub const init: Headers = .{ .content_length = null };

        pub const ParseError = error{
            /// More data has to be read.
            ReadMore,
            HeadersMalformed,
            IllegalHeaderValue,
            TooManyHeaders,
        };

        pub fn parse(headers: *Headers, cursor: *[]u8) ParseError!void {
            var headers_limit: usize = 16;

            while (headers_limit > 0) : (headers_limit -= 1) {
                const header, _ = mem.cutScalar(u8, cursor.*, '\n') orelse
                    return error.ReadMore;

                cursor.* = cursor.*[header.len + 1 ..];

                if (header.len < 1 or header[header.len - 1] != '\r')
                    return error.HeadersMalformed;

                if (header.len == 1) // "\r\n" only, this is the end.
                    return;

                const prefix, const value = mem.cutScalar(u8, header[0 .. header.len - 1], ' ') orelse
                    return error.HeadersMalformed;

                if (std.ascii.eqlIgnoreCase(prefix, "content-length:")) {
                    headers.content_length = std.fmt.parseInt(u64, value, 10) catch
                        return error.IllegalHeaderValue;
                }
            } else return error.TooManyHeaders;
        }
    };

    pub const FormExpectError = error{
        FormHasUnexpectedField,
        FormHasMultipleFields,
        FormMalformed,
    };

    pub fn formExpectOne(body: []u8, expected: []const u8) FormExpectError![]u8 {
        if (mem.findScalar(u8, body, '&') != null)
            return error.FormHasMultipleFields;

        const name, const content = mem.cutScalar(u8, body, '=') orelse
            return error.FormMalformed;

        if (!mem.eql(u8, name, expected))
            return error.FormHasUnexpectedField;

        return @constCast(content);
    }
};

const PercentDecodeError = error{BadPercentEncoding};

/// Decodes "percent encoding" in-place.
pub fn percentDecode(encoded: []u8) PercentDecodeError![]u8 {
    var decoded = encoded;

    while (mem.findScalar(u8, decoded, '%')) |percent_pos| {
        const percent_slice = decoded[percent_pos..];
        if (percent_slice.len < 3) return error.BadPercentEncoding;

        const byte = std.fmt.parseInt(u8, percent_slice[1..3], 16) catch
            return error.BadPercentEncoding;

        const percent_end = percent_pos + 2;
        decoded[percent_end] = byte;

        @memmove(decoded[2..percent_end], decoded[0..percent_pos]);
        decoded = decoded[2..];
    }

    return decoded;
}

test percentDecode {
    try testPercentDecoding("Hello,%20World!", "Hello, World!");
    try testPercentDecoding("'%2F'%20'%2B'%20", "'/' '+' ");
}

fn testPercentDecoding(comptime encoded: []const u8, expected_decoded: []const u8) !void {
    var buf: [encoded.len]u8 = undefined;
    @memcpy(&buf, encoded);
    const decoded = try percentDecode(&buf);
    try std.testing.expectEqualSlices(u8, expected_decoded, decoded);
}

pub const response = struct {
    pub const Error = error{ResponseTooLong};

    pub fn putJson(buffer: []u8, comptime Data: type, data: *const Data) Error!usize {
        const json_fmt = std.json.fmt(data, .{});

        var trash_buffer: [128]u8 = undefined;
        var discarding: Writer.Discarding = .init(&trash_buffer);
        discarding.writer.print("{f}", .{json_fmt}) catch unreachable;

        var writer: Writer = .fixed(buffer);
        writer.print(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{discarding.fullCount()},
        ) catch return error.ResponseTooLong;

        writer.print("{f}", .{json_fmt}) catch return error.ResponseTooLong;
        return writer.end;
    }

    pub fn putCustomString(
        buffer: []u8,
        status: u16,
        phrase: []const u8,
        data: []const u8,
    ) Error!usize {
        var writer: Writer = .fixed(buffer);
        writer.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
            .{ status, phrase, data.len },
        ) catch return error.ResponseTooLong;

        writer.writeAll(data) catch return error.ResponseTooLong;
        return writer.end;
    }
};
