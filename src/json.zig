//! Zero-copy and zero-allocation JSON parsing.
const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

pub const ParseError = UnescapeError || error{
    UnexpectedField,
    UnexpectedToken,
    MissingFields,
    TrailingGarbage,
};

/// Parses `source` as a JSON object, mapping its fields to `Struct`.
/// Strings are not copied and are unescaped in-place.
pub fn parse(comptime Struct: type, source: [:0]u8) ParseError!Struct {
    const Field = std.meta.FieldEnum(Struct);
    var set_fields: [@typeInfo(Struct).@"struct".field_names.len]bool = @splat(false);
    var result: Struct = undefined;

    var t: Tokenizer = .init(source);

    const State = enum {
        start,
        object_start,
        object_continuation,
        field_value,
        field_end,
    };

    // readable when state is `field_value`
    var active_field: Field = undefined;

    state: switch (State.start) {
        .start => {
            if (t.next().kind != .open_curly)
                return error.UnexpectedToken;

            continue :state .object_start;
        },
        .object_start => {
            const token = t.next();
            switch (token.kind) {
                .close_curly => {}, // We're done
                .string => {
                    if (t.next().kind != .colon)
                        return error.UnexpectedToken;

                    const field_name = try unescape(source[token.start..token.end]);
                    active_field = std.meta.stringToEnum(Field, field_name) orelse {
                        return error.UnexpectedField;
                    };

                    continue :state .field_value;
                },
                else => return error.UnexpectedToken,
            }
        },
        .object_continuation => {
            const token = t.next();
            switch (token.kind) {
                .string => {
                    if (t.next().kind != .colon)
                        return error.UnexpectedToken;

                    const field_name = try unescape(source[token.start..token.end]);
                    active_field = std.meta.stringToEnum(Field, field_name) orelse {
                        return error.UnexpectedField;
                    };

                    continue :state .field_value;
                },
                else => return error.UnexpectedToken,
            }
        },
        .field_value => {
            // Currently, only string fields are supported.
            const token = t.next();
            switch (token.kind) {
                .string => {
                    const value_unescaped = try unescape(source[token.start..token.end]);

                    switch (active_field) {
                        inline else => |field_comptime| {
                            @field(result, @tagName(field_comptime)) = value_unescaped;
                            set_fields[@backingInt(field_comptime)] = true;
                        },
                    }

                    active_field = undefined;
                    continue :state .field_end;
                },
                else => return error.UnexpectedToken,
            }
        },
        .field_end => switch (t.next().kind) {
            .close_curly => {}, // We're done
            .comma => continue :state .object_continuation,
            else => return error.UnexpectedToken,
        },
    }

    for (set_fields) |field_is_set|
        if (!field_is_set) return error.MissingFields;

    if (t.next().kind != .eof) return error.TrailingGarbage;

    return result;
}

test parse {
    const Struct = struct {
        red: [:0]const u8,
        reversed: [:0]const u8,
        extra: [:0]u8,
    };

    const Extra = struct {
        doro: [:0]const u8,
    };

    const source =
        \\{
        \\    "red": "rose",
        \\    "reversed": "rooms",
        \\    "extra": "{\n\t\"doro\": \":red_rose_doro:\"\n}"
        \\}
    ;

    var source_mut: [source.len:0]u8 = source.*;

    const @"struct" = try parse(Struct, &source_mut);
    try std.testing.expectEqualSlices(u8, @"struct".red, "rose");
    try std.testing.expectEqualSlices(u8, @"struct".reversed, "rooms");

    const extra = try parse(Extra, @"struct".extra);
    try std.testing.expectEqualSlices(u8, extra.doro, ":red_rose_doro:");
}

const Token = struct {
    kind: Kind,
    start: u32,
    end: u32,

    const Kind = enum {
        open_curly,
        close_curly,
        comma,
        colon,
        string,
        eof,
        invalid,
    };
};

const Tokenizer = struct {
    slice: []u8,
    position: u32,

    fn init(sentineled: [:0]u8) Tokenizer {
        return .{
            .slice = mem.absorbSentinel(sentineled),
            .position = 0,
        };
    }

    fn next(t: *Tokenizer) Token {
        var token: Token = .{
            .kind = .invalid,
            .start = t.position,
            .end = t.position,
        };

        state: switch (State.start) {
            .start => switch (t.slice[t.position]) {
                0 => token.kind = .eof,
                '{' => {
                    t.position += 1;
                    token.kind = .open_curly;
                },
                '}' => {
                    t.position += 1;
                    token.kind = .close_curly;
                },
                ',' => {
                    t.position += 1;
                    token.kind = .comma;
                },
                ':' => {
                    t.position += 1;
                    token.kind = .colon;
                },
                ' ', '\n', '\r', '\t' => {
                    t.position += 1;
                    token.start += 1;
                    token.end += 1;
                    continue :state .start;
                },
                '"' => {
                    token.kind = .string;
                    t.position += 1;
                    continue :state .string;
                },
                else => {
                    token.kind = .invalid;
                },
            },
            .string => switch (t.slice[t.position]) {
                0 => token.kind = .invalid,
                '"' => {
                    t.position += 1;
                    token.end = t.position;
                },
                '\\' => {
                    t.position += 1;
                    continue :state .escape;
                },
                else => {
                    t.position += 1;
                    continue :state .string;
                },
            },
            .escape => switch (t.slice[t.position]) {
                0 => token.kind = .invalid,
                else => {
                    // Only simple escape sequences (that consist of one char) are supported.
                    t.position += 1;
                    continue :state .string;
                },
            },
        }

        return token;
    }

    const State = enum {
        start,
        string,
        escape,
    };
};

pub const UnescapeError = error{UnexpectedEscapeSequence};

/// Unescapes and sentinels `escaped` in-place
fn unescape(escaped: []u8) UnescapeError![:0]u8 {
    const unescaped = escaped;
    var unescaped_i: usize = 0;
    var escaped_i: usize = 0;

    const State = enum {
        start,
        string,
        escape,
    };

    // No boundary checks because we expect `escaped` to be well-formed,
    // the tokenizer has already validated everything.
    state: switch (State.start) {
        .start => {
            assert(escaped[escaped_i] == '"');
            escaped_i += 1;
            continue :state .string;
        },
        .string => switch (escaped[escaped_i]) {
            '\\' => {
                escaped_i += 1;
                continue :state .escape;
            },
            '"' => {
                // We're done here.
                escaped_i += 1;
                assert(escaped_i == escaped.len); // tokenizer misbehaved
            },
            else => |char| {
                unescaped[unescaped_i] = char;
                unescaped_i += 1;
                escaped_i += 1;
                continue :state .string;
            },
        },
        .escape => switch (escaped[escaped_i]) {
            'n' => {
                unescaped[unescaped_i] = '\n';
                unescaped_i += 1;
                escaped_i += 1;
                continue :state .string;
            },
            'r' => {
                unescaped[unescaped_i] = '\r';
                unescaped_i += 1;
                escaped_i += 1;
                continue :state .string;
            },
            't' => {
                unescaped[unescaped_i] = '\t';
                unescaped_i += 1;
                escaped_i += 1;
                continue :state .string;
            },
            '"' => {
                unescaped[unescaped_i] = '"';
                unescaped_i += 1;
                escaped_i += 1;
                continue :state .string;
            },
            '\\' => {
                unescaped[unescaped_i] = '\\';
                unescaped_i += 1;
                escaped_i += 1;
                continue :state .string;
            },
            else => return error.UnexpectedEscapeSequence,
        },
    }

    assert(unescaped_i < escaped.len); // at least one '"' must get eliminated

    // Sentinel it so we can parse it if it's a nested json.
    unescaped[unescaped_i] = 0;
    return @ptrCast(unescaped[0..unescaped_i]);
}

test Tokenizer {
    try testTokenizer("{}", &.{ .open_curly, .close_curly });
    try testTokenizer(
        \\{"red": "rose"}
    , &.{ .open_curly, .string, .colon, .string, .close_curly });
    try testTokenizer(
        \\{
        \\    "red\t\n": "roze\r\n",
        \\    "\"reversed\"": "\\rooms"
        \\}
    , &.{ .open_curly, .string, .colon, .string, .comma, .string, .colon, .string, .close_curly });
}

fn testTokenizer(comptime source: [:0]const u8, expected_kinds: []const Token.Kind) !void {
    var source_mut: [source.len:0]u8 = source[0..source.len].*;
    var t: Tokenizer = .init(&source_mut);
    var i: usize = 0;

    while (i < expected_kinds.len) : (i += 1) {
        const token = t.next();
        try std.testing.expectEqual(expected_kinds[i], token.kind);
    }

    try std.testing.expectEqual(.eof, t.next().kind);
}

test unescape {
    try testUnescape("\\r", "\r");
    try testUnescape("\\\\n", "\\n");
    try testUnescape(
        \\{\n    \"red\": \"rose\"\n}
    ,
        \\{
        \\    "red": "rose"
        \\}
    );
}

fn testUnescape(comptime escaped: []const u8, expected_unescaped: []const u8) !void {
    var escaped_mut: [escaped.len + 2]u8 = undefined;
    escaped_mut[0] = '"';
    @memcpy(escaped_mut[1..][0..escaped.len], escaped);
    escaped_mut[escaped.len + 1] = '"';

    const unescaped = try unescape(&escaped_mut);
    try std.testing.expectEqualSlices(u8, expected_unescaped, unescaped);
}
