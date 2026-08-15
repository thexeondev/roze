const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const MultiArrayList = std.MultiArrayList;

const log = std.log.scoped(.@"roze-compile-proto");

// TODO: improve error reporting (low priority because this is not really user-facing)

fn usage(io: Io) noreturn {
    Io.File.stdout().writeStreamingAll(io,
        \\Usage: roze-compile-proto [files]
        \\
        \\Options:
        \\  -h, --help            Print this help and exit
        \\
    ) catch {};
    process.exit(0);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    log.err(fmt, args);
    process.exit(1);
}

const file_size_limit: Io.Limit = .limited(std.math.maxInt(u32));

pub fn main(init: process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var argv = try init.minimal.args.iterateAllocator(arena);
    defer argv.deinit();
    assert(argv.skip());

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = Io.File.writerStreaming(.stdout(), io, &stdout_buffer);

    try stdout_writer.interface.writeAll(
        \\pub fn protoNamespace(comptime Iterator: fn (comptime type, comptime u29) type) type {
        \\return struct {
        \\
        \\
    );

    const cwd: Io.Dir = .cwd();

    while (argv.next()) |arg| {
        if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help"))
            usage(io);

        const path = arg;
        const content = cwd.readFileAllocOptions(
            io,
            path,
            std.heap.page_allocator,
            file_size_limit,
            .of(u8),
            0,
        ) catch |err| switch (err) {
            error.FileNotFound, error.IsDir => {
                log.err("input file {q} doesn't exist", .{path});
                usage(io);
            },
            error.StreamTooLong => fatal("file {q} is too big", .{path}),
            else => |e| return e,
        };

        var t: Tokenizer = .init(content);
        try skipTopLevel(&t);

        var lists: ParserLists = try .init(arena);

        while (try parseOne(arena, &lists, &t)) |item| switch (item) {
            .message => |message| {
                try emitMessage(content, &message, &stdout_writer.interface);
            },
            .@"enum" => |@"enum"| {
                try emitEnum(content, &@"enum", &stdout_writer.interface);
            },
        };
    }

    try stdout_writer.interface.writeAll("\n};}");
    try stdout_writer.interface.flush();
}

const ParserLists = struct {
    idents: ArrayList(Ident),
    numbers: ArrayList(NumberLiteral),
    message_fields: MultiArrayList(Message.Field),

    fn init(arena: Allocator) Allocator.Error!ParserLists {
        return .{
            .idents = try .initCapacity(arena, 1024),
            .numbers = try .initCapacity(arena, 1024),
            .message_fields = try .initCapacity(arena, 128),
        };
    }

    fn reset(lists: *ParserLists) void {
        lists.idents.clearRetainingCapacity();
        lists.numbers.clearRetainingCapacity();
        lists.message_fields.clearRetainingCapacity();
    }
};

const Token = struct {
    kind: Kind,
    /// Index into `content` buffer.
    index: u32,

    const Kind = enum(u8) {
        invalid,
        eof,
        ident,
        string,
        number,

        equals,
        semi,
        comma,
        open_paren,
        close_paren,
        open_square,
        close_square,
        open_curly,
        close_curly,

        keyword_syntax,
        keyword_package,
        keyword_import,
        keyword_option,
        keyword_message,
        keyword_enum,
        keyword_repeated,
        keyword_oneof,
        keyword_true,
    };

    const keywords: std.StaticStringMap(Token.Kind) = .initComptime(.{
        .{ "syntax", .keyword_syntax },
        .{ "package", .keyword_package },
        .{ "import", .keyword_import },
        .{ "option", .keyword_option },
        .{ "message", .keyword_message },
        .{ "enum", .keyword_enum },
        .{ "repeated", .keyword_repeated },
        .{ "oneof", .keyword_oneof },
        .{ "true", .keyword_true },
    });
};

const Tokenizer = struct {
    content: []const u8,
    index: u32,

    pub fn init(content: [:0]const u8) Tokenizer {
        return .{ .content = mem.absorbSentinel(content), .index = 0 };
    }

    pub fn next(t: *Tokenizer) Token {
        if (t.index == t.content.len)
            return .{ .kind = .eof, .index = t.index };

        var result: Token = .{
            .kind = undefined,
            .index = t.index,
        };

        state: switch (State.start) {
            .start => switch (t.content[t.index]) {
                0 => result.kind = .eof,
                '\r', '\n', '\t', ' ' => {
                    t.index += 1;
                    result.index = t.index;
                    continue :state .start;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.kind = .ident;
                    continue :state .ident;
                },
                '0'...'9' => {
                    result.kind = .number;
                    continue :state .number;
                },
                '-' => {
                    t.index += 1;
                    result.kind = .number;
                    continue :state .saw_minus;
                },
                '/' => {
                    t.index += 1;
                    continue :state .saw_one_slash;
                },
                '"' => {
                    result.kind = .string;
                    continue :state .string;
                },
                '=' => {
                    result.kind = .equals;
                    t.index += 1;
                },
                ';' => {
                    result.kind = .semi;
                    t.index += 1;
                },
                ',' => {
                    result.kind = .comma;
                    t.index += 1;
                },
                '(' => {
                    result.kind = .open_paren;
                    t.index += 1;
                },
                ')' => {
                    result.kind = .close_paren;
                    t.index += 1;
                },
                '[' => {
                    result.kind = .open_square;
                    t.index += 1;
                },
                ']' => {
                    result.kind = .close_square;
                    t.index += 1;
                },
                '{' => {
                    result.kind = .open_curly;
                    t.index += 1;
                },
                '}' => {
                    result.kind = .close_curly;
                    t.index += 1;
                },
                else => result.kind = .invalid,
            },
            .ident => {
                t.index += 1;
                switch (t.content[t.index]) {
                    'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                        continue :state .ident;
                    },
                    else => {
                        if (Token.keywords.get(t.content[result.index..t.index])) |kind|
                            result.kind = kind;
                    },
                }
            },
            .number => {
                t.index += 1;
                switch (t.content[t.index]) {
                    '0'...'9' => continue :state .number,
                    'a'...'z', 'A'...'Z', '_' => result.kind = .invalid,
                    else => {},
                }
            },
            .string => {
                t.index += 1;
                switch (t.content[t.index]) {
                    0 => result.kind = .invalid,
                    '"' => t.index += 1,
                    // For simplicity, string escaping is not supported.
                    '\\' => result.kind = .invalid,
                    '\r', '\n' => result.kind = .invalid,
                    else => continue :state .string,
                }
            },
            .saw_minus => switch (t.content[t.index]) {
                '0'...'9' => continue :state .number,
                else => result.kind = .invalid,
            },
            .saw_one_slash => {
                switch (t.content[t.index]) {
                    '/' => {
                        continue :state .skipping_single_line_comment;
                    },
                    '*' => {
                        continue :state .skipping_multi_line_comment;
                    },
                    else => result.kind = .invalid,
                }
            },
            .skipping_single_line_comment => {
                t.index += 1;
                switch (t.content[t.index]) {
                    0 => {
                        result.kind = .eof;
                        result.index = t.index;
                    },
                    '\n' => continue :state .start,
                    else => continue :state .skipping_single_line_comment,
                }
            },
            .skipping_multi_line_comment => {
                t.index += 1;
                switch (t.content[t.index]) {
                    0 => {
                        result.kind = .eof;
                        result.index = t.index;
                    },
                    '*' => continue :state .saw_asterisk_in_multi_line_comment,
                    else => continue :state .skipping_multi_line_comment,
                }
            },
            .saw_asterisk_in_multi_line_comment => {
                t.index += 1;
                switch (t.content[t.index]) {
                    0 => {
                        result.kind = .eof;
                        result.index = t.index;
                    },
                    '/' => {
                        t.index += 1;
                        continue :state .start;
                    },
                    '*' => continue :state .saw_asterisk_in_multi_line_comment,
                    else => continue :state .skipping_multi_line_comment,
                }
            },
        }

        return result;
    }

    const State = enum {
        start,
        ident,
        number,
        string,
        saw_minus,
        saw_one_slash,
        skipping_single_line_comment,
        skipping_multi_line_comment,
        saw_asterisk_in_multi_line_comment,
    };
};

test "empty" {
    try testTokenize("", &.{.eof});
    try testTokenize("\t\t\r\n\n\n   \n\n", &.{.eof});
}

test "idents and keywords" {
    try testTokenize("message", &.{ .keyword_message, .eof });
    try testTokenize("enum", &.{ .keyword_enum, .eof });

    try testTokenize(
        "\n\tpackage   enum\r\nmessage RedRoseDoro\n",
        &.{ .keyword_package, .keyword_enum, .keyword_message, .ident, .eof },
    );
}

test "numbers" {
    try testTokenize("228 1337 z3", &.{ .number, .number, .ident, .eof });
    try testTokenize("3z", &.{.invalid});
}

test "string" {
    const string = ":red_rose_doro:";
    const source = "\"" ++ string ++ "\"";

    const gpa = std.testing.allocator;
    var tokens = try tokenizeAll(gpa, source);
    defer tokens.deinit(gpa);

    try std.testing.expectEqualSlices(Token.Kind, &.{ .string, .eof }, tokens.items(.kind));
    const literal = tokens.get(0);

    const got, _ = mem.cutScalar(u8, source[literal.index + 1 ..], '"').?;
    try std.testing.expectEqualSlices(u8, got, string);
}

test "comments" {
    try testTokenize(
        \\// Copyright 2026, reversedrooms. All bytes reversed.
        \\message // message
    , &.{ .keyword_message, .eof });
}

test "puncts" {
    try testTokenize(
        "{}()[] = ; ,",
        &.{ .open_curly, .close_curly, .open_paren, .close_paren, .open_square, .close_square, .equals, .semi, .comma, .eof },
    );
}

fn testTokenize(source: [:0]const u8, expected: []const Token.Kind) !void {
    const gpa = std.testing.allocator;
    var tokens = try tokenizeAll(gpa, source);
    defer tokens.deinit(gpa);
    try std.testing.expectEqualSlices(Token.Kind, expected, tokens.items(.kind));
}

fn tokenizeAll(allocator: Allocator, source: [:0]const u8) Allocator.Error!MultiArrayList(Token) {
    var tokenizer: Tokenizer = .init(source);
    var tokens: MultiArrayList(Token) = .empty;
    errdefer tokens.deinit(allocator);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);

        if (token.kind == .eof or token.kind == .invalid)
            return tokens;
    }
}

const Ident = enum(u32) {
    _,

    pub fn fromToken(t: Token) Ident {
        assert(t.kind == .ident);
        return @fromBackingInt(t.index);
    }

    pub fn get(ident: Ident, source: []const u8) []const u8 {
        var i: u32 = @backingInt(ident);

        char: switch (source[i]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => {
                i += 1;
                continue :char source[i];
            },
            else => return source[@backingInt(ident)..i],
        }
    }
};

const StringLiteral = enum(u32) {
    _,

    pub fn fromToken(t: Token) StringLiteral {
        assert(t.kind == .string);
        return @fromBackingInt(t.index);
    }

    pub fn getUnquoted(sl: StringLiteral, source: []const u8) []const u8 {
        return mem.cutScalar(u8, source[@backingInt(sl) + 1 ..], '"').?.@"0";
    }
};

const NumberLiteral = enum(u32) {
    _,

    pub fn fromToken(t: Token) NumberLiteral {
        assert(t.kind == .number);
        return @fromBackingInt(t.index);
    }

    pub fn get(nl: NumberLiteral, source: []const u8) []const u8 {
        var i: u32 = @backingInt(nl);

        char: switch (source[i]) {
            '0'...'9', '-' => {
                i += 1;
                continue :char source[i];
            },
            else => return source[@backingInt(nl)..i],
        }
    }
};

const Enum = struct {
    name: Ident,
    mode: Mode,
    names: []const Ident,
    values: []const NumberLiteral,

    const Mode = enum {
        fields,
        decls,
    };
};

const Option = struct {
    name: Ident,
    value: NumberLiteral,
};

const Message = struct {
    name: Ident,
    fields: MultiArrayList(Field).Slice,
    oneof_names: []const Ident,

    const Field = struct {
        modifier: Modifier,
        type: Ident,
        name: Ident,
        number: NumberLiteral,

        const Modifier = enum(u8) {
            none = 0,
            repeated = 1,
            first_in_oneof = 2,
            subsequent_in_oneof = 3,
        };
    };
};

const Item = union(enum) {
    message: Message,
    @"enum": Enum,
};

fn skipTopLevel(t: *Tokenizer) !void {
    if (t.next().kind != .keyword_syntax) return error.UnexpectedToken;
    if (t.next().kind != .equals) return error.UnexpectedToken;

    const syntax_value = t.next();
    if (syntax_value.kind != .string) return error.UnexpectedToken;

    const syntax_version = StringLiteral.fromToken(syntax_value).getUnquoted(t.content);
    if (!mem.eql(u8, syntax_version, "proto3"))
        fatal("unsupported syntax {q}, this compiler supports only proto3", .{syntax_version});

    if (t.next().kind != .semi) return error.UnexpectedToken;
}

fn parseOne(arena: Allocator, lists: *ParserLists, t: *Tokenizer) !?Item {
    lists.reset();

    while (true) {
        switch (t.next().kind) {
            .keyword_package => {
                if (t.next().kind != .ident) return error.UnexpectedToken;
                if (t.next().kind != .semi) return error.UnexpectedToken;
            },
            .keyword_import => {
                if (t.next().kind != .string) return error.UnexpectedToken;
                if (t.next().kind != .semi) return error.UnexpectedToken;
            },
            .keyword_option => {
                if (t.next().kind != .ident) return error.UnexpectedToken;
                if (t.next().kind != .equals) return error.UnexpectedToken;
                if (t.next().kind != .string) return error.UnexpectedToken;
                if (t.next().kind != .semi) return error.UnexpectedToken;
            },
            .keyword_message => {
                const message_name = t.next();
                if (message_name.kind != .ident) return error.UnexpectedToken;
                if (t.next().kind != .open_curly) return error.UnexpectedToken;

                const State = union(enum) {
                    start,
                    saw_field_type: struct {
                        master: Ident,
                        slave: ?Ident,
                        modifier: Message.Field.Modifier,
                    },
                    in_oneof,
                };

                message: switch (@as(State, .start)) {
                    .start => {
                        const token = t.next();
                        switch (token.kind) {
                            .close_curly => {},
                            .ident => continue :message .{ .saw_field_type = .{
                                .master = .fromToken(token),
                                .slave = null,
                                .modifier = .none,
                            } },
                            .keyword_repeated => {
                                const type_ident = t.next();
                                if (type_ident.kind != .ident)
                                    fatal("expected ident, got {t}", .{type_ident.kind});

                                continue :message .{ .saw_field_type = .{
                                    .master = .fromToken(type_ident),
                                    .slave = null,
                                    .modifier = .repeated,
                                } };
                            },
                            .keyword_oneof => {
                                const oneof_name = t.next();
                                if (oneof_name.kind != .ident) fatal("expected ident, got {t}", .{oneof_name.kind});

                                switch (t.next().kind) {
                                    .open_curly => {},
                                    else => |kind| fatal("expected '{{', got {t}", .{kind}),
                                }

                                const first_in_oneof = t.next();
                                switch (first_in_oneof.kind) {
                                    .ident => {},
                                    .close_curly => continue :message .start, // empty oneof
                                    else => |kind| fatal("expected oneof entry, got {t}", .{kind}),
                                }

                                try lists.idents.append(arena, .fromToken(oneof_name));

                                continue :message .{ .saw_field_type = .{
                                    .master = .fromToken(first_in_oneof),
                                    .slave = null,
                                    .modifier = .first_in_oneof,
                                } };
                            },
                            else => fatal("unexpected in message: {t}", .{token.kind}),
                        }
                    },
                    .in_oneof => {
                        const subsequent_in_oneof = t.next();
                        switch (subsequent_in_oneof.kind) {
                            .ident => {},
                            .close_curly => continue :message .start, // oneof closed
                            else => |kind| fatal("expected oneof entry, got {t}", .{kind}),
                        }

                        continue :message .{ .saw_field_type = .{
                            .master = .fromToken(subsequent_in_oneof),
                            .slave = null,
                            .modifier = .subsequent_in_oneof,
                        } };
                    },
                    .saw_field_type => |field_type| {
                        const field_name = t.next();
                        if (field_name.kind != .ident)
                            fatal("expected ident, got {t}", .{field_name.kind});

                        switch (t.next().kind) {
                            .equals => {},
                            else => |kind| fatal("expected '=', got {t}", .{kind}),
                        }

                        const field_number = t.next();
                        if (field_number.kind != .number)
                            fatal("expected number, got {t}", .{field_number.kind});

                        const semi = t.next();
                        if (semi.kind != .semi)
                            fatal("expected ;, got {t}", .{semi.kind});

                        try lists.message_fields.append(arena, .{
                            .modifier = field_type.modifier,
                            .type = field_type.master,
                            .name = .fromToken(field_name),
                            .number = .fromToken(field_number),
                        });

                        switch (field_type.modifier) {
                            .first_in_oneof, .subsequent_in_oneof => continue :message .in_oneof,
                            else => continue :message .start,
                        }
                    },
                }

                return .{ .message = .{
                    .name = .fromToken(message_name),
                    .fields = lists.message_fields.slice(),
                    .oneof_names = lists.idents.items,
                } };
            },
            .keyword_enum => {
                const enum_name = t.next();
                if (enum_name.kind != .ident) fatal("expected ident, got {t}", .{enum_name.kind});

                switch (t.next().kind) {
                    .open_curly => {},
                    else => |kind| fatal("expected '{{', got {t}", .{kind}),
                }

                var allow_alias: bool = false;

                while (true) {
                    const field_name_or_end = t.next();
                    switch (field_name_or_end.kind) {
                        .keyword_option => {
                            const option_name_token = t.next();
                            if (option_name_token.kind != .ident)
                                fatal("expected ident, got {t}", .{option_name_token.kind});

                            const option_name = Ident.fromToken(option_name_token).get(t.content);
                            if (!mem.eql(u8, option_name, "allow_alias"))
                                fatal("unsupported message option {q}", .{option_name});

                            switch (t.next().kind) {
                                .equals => {},
                                else => |kind| fatal("expected '=', got {t}", .{kind}),
                            }

                            const option_value_token = t.next();
                            if (option_value_token.kind != .keyword_true)
                                fatal("expected 'true', got {t}", .{option_value_token.kind});

                            allow_alias = true;

                            switch (t.next().kind) {
                                .semi => {},
                                else => |kind| fatal("expected ';', got {t}", .{kind}),
                            }
                        },
                        .ident => {
                            switch (t.next().kind) {
                                .equals => {},
                                else => |kind| fatal("expected '=', got {t}", .{kind}),
                            }

                            const field_value = t.next();
                            if (field_value.kind != .number)
                                fatal("expected number, got {t}", .{field_value.kind});

                            switch (t.next().kind) {
                                .semi => {},
                                else => |kind| fatal("expected ';', got {t}", .{kind}),
                            }

                            try lists.idents.append(arena, .fromToken(field_name_or_end));
                            try lists.numbers.append(arena, .fromToken(field_value));
                        },
                        .close_curly => break,
                        else => |kind| fatal("unexpected in enum: {t}", .{kind}),
                    }
                }

                return .{ .@"enum" = .{
                    .name = .fromToken(enum_name),
                    .mode = if (allow_alias) .decls else .fields,
                    .names = lists.idents.items,
                    .values = lists.numbers.items,
                } };
            },
            .eof => break,
            .semi => continue,
            else => |kind| fatal("unexpected: {t}", .{kind}),
        }
    }

    return null;
}

fn emitEnum(source: []const u8, @"enum": *const Enum, writer: *Io.Writer) !void {
    const enum_name = @"enum".name.get(source);

    try writer.print("pub const {s} = enum(i32) {{\n", .{enum_name});
    try writer.writeAll("    pub const Decoded = @This();\n");
    try writer.print("    pub const init: {s} = @fromBackingInt(0);\n", .{@"enum".name.get(source)});

    switch (@"enum".mode) {
        .fields => {
            for (@"enum".names, @"enum".values) |name, value|
                try printIndented(writer, 1, "{s} = {s},\n", .{ name.get(source), value.get(source) });
        },
        .decls => {
            try printIndented(writer, 1, "_,\n", .{});

            for (@"enum".names, @"enum".values) |name, value|
                try printIndented(
                    writer,
                    1,
                    "pub const {s}: {s} = @fromBackingInt({s});\n",
                    .{ name.get(source), enum_name, value.get(source) },
                );
        },
    }

    try writer.writeAll("};\n\n");
}

fn emitMessage(source: []const u8, message: *const Message, writer: *Io.Writer) !void {
    const message_name = message.name.get(source);

    try writer.print("pub const {s} = struct {{\n", .{message_name});
    try printIndented(writer, 1, "pub const init: {s} = .{{}};\n\n", .{message_name});

    try printIndented(writer, 1, "pub const descriptor = struct {{\n", .{});
    {
        try printIndented(writer, 2, "pub const FieldNumber = enum(u29) {{\n", .{});
        for (message.fields.items(.name), message.fields.items(.number)) |name, number| {
            try printIndented(writer, 3, "{s} = {s},\n", .{ name.get(source), number.get(source) });
        }
        try printIndented(writer, 3, "_,\n", .{});
        try printIndented(writer, 2, "}};\n\n", .{});

        try printIndented(writer, 2, "pub const oneofs = struct {{\n", .{});

        var oneof_i: i32 = -1;

        for (message.fields.items(.name), message.fields.items(.modifier)) |name, modifier| {
            const oneof_name = switch (modifier) {
                .first_in_oneof => advance: {
                    oneof_i += 1;
                    break :advance message.oneof_names[@intCast(oneof_i)];
                },
                .subsequent_in_oneof => message.oneof_names[@intCast(oneof_i)],
                else => continue,
            };

            if (modifier != .first_in_oneof and modifier != .subsequent_in_oneof) continue;

            const field_name = name.get(source);

            try printIndented(
                writer,
                3,
                "pub const @\"{s}\" = {q};\n",
                .{ field_name, oneof_name.get(source) },
            );
        }

        try printIndented(writer, 2, "}};\n", .{});
    }
    try printIndented(writer, 1, "}};\n\n", .{});

    // Emit encodeable message fields
    try printEncodeableFields(source, message, writer);
    try writer.writeByte('\n');

    try printIndented(writer, 1, "pub const Decoded = struct {{\n", .{});
    try printIndented(writer, 2, "pub const descriptor = {s}.descriptor;\n\n", .{message_name});
    try printIndented(writer, 2, "pub const init: {s}.Decoded = .{{}};\n\n", .{message_name});
    try printDecodeableFields(source, message, writer);
    try printIndented(writer, 1, "}};\n", .{});

    try writer.writeAll("};\n\n");
}

fn printEncodeableFields(source: []const u8, message: *const Message, writer: *Io.Writer) !void {
    var oneof_i: u32 = 0;
    var was_in_oneof: bool = false;

    for (
        message.fields.items(.modifier),
        message.fields.items(.name),
        message.fields.items(.type),
    ) |modifier, name_ident, @"type"| {
        const name = name_ident.get(source);

        modifier: switch (modifier) {
            .none => {
                if (was_in_oneof) {
                    was_in_oneof = false;
                    try printIndented(writer, 1, "}} = null,\n", .{});
                }

                try printIndented(
                    writer,
                    1,
                    "{s}: {f} = {f},\n",
                    .{ name, fmtZigType(source, @"type", .alone, .encode), fmtDefaultValue(source, @"type") },
                );
            },
            .repeated => {
                if (was_in_oneof) {
                    was_in_oneof = false;
                    try printIndented(writer, 1, "}} = null,\n", .{});
                }

                try printIndented(
                    writer,
                    1,
                    "{s}: []const {f} = &.{{}},\n",
                    .{ name, fmtZigType(source, @"type", .in_container, .encode) },
                );
            },
            .first_in_oneof => {
                const oneof_name = message.oneof_names[oneof_i].get(source);
                oneof_i += 1;

                try printIndented(writer, 1, "{s}: ?union(enum) {{\n", .{oneof_name});
                was_in_oneof = true;

                continue :modifier .subsequent_in_oneof;
            },
            .subsequent_in_oneof => {
                try printIndented(writer, 2, "{s}: {f},\n", .{
                    name,
                    fmtZigType(source, @"type", .in_container, .encode),
                });
            },
        }
    }

    if (was_in_oneof) {
        try printIndented(writer, 1, "}} = null,\n", .{});
    }
}

fn printDecodeableFields(source: []const u8, message: *const Message, writer: *Io.Writer) !void {
    var oneof_i: u32 = 0;
    var was_in_oneof: bool = false;

    for (
        message.fields.items(.modifier),
        message.fields.items(.name),
        message.fields.items(.type),
        message.fields.items(.number),
    ) |modifier, name_ident, @"type", number_literal| {
        const name = name_ident.get(source);
        const number = number_literal.get(source);

        modifier: switch (modifier) {
            .none => {
                if (was_in_oneof) {
                    was_in_oneof = false;
                    try printIndented(writer, 2, "}} = null,\n", .{});
                }

                try printIndented(
                    writer,
                    2,
                    "{s}: {f} = {f},\n",
                    .{ name, fmtZigType(source, @"type", .alone, .decode), fmtDefaultValue(source, @"type") },
                );
            },
            .repeated => {
                if (was_in_oneof) {
                    was_in_oneof = false;
                    try printIndented(writer, 2, "}} = null,\n", .{});
                }

                try printIndented(
                    writer,
                    2,
                    "{s}: Iterator({f}, {s}) = .empty,\n",
                    .{ name, fmtZigType(source, @"type", .in_container, .decode), number },
                );
            },
            .first_in_oneof => {
                const oneof_name = message.oneof_names[oneof_i].get(source);
                oneof_i += 1;

                try printIndented(writer, 2, "{s}: ?union(enum) {{\n", .{oneof_name});
                was_in_oneof = true;

                continue :modifier .subsequent_in_oneof;
            },
            .subsequent_in_oneof => {
                try printIndented(writer, 3, "{s}: {f},\n", .{
                    name,
                    fmtZigType(source, @"type", .in_container, .decode),
                });
            },
        }
    }

    if (was_in_oneof) {
        try printIndented(writer, 2, "}} = null,\n", .{});
    }
}

fn fmtZigType(source: []const u8, protobuf_type: Ident, mode: ZigType.Mode, encoding: ZigType.Encoding) ZigType {
    return .{
        .source = source,
        .protobuf_type = protobuf_type,
        .mode = mode,
        .encoding = encoding,
    };
}

fn fmtDefaultValue(source: []const u8, protobuf_type: Ident) DefaultValue {
    return .{ .source = source, .protobuf_type = protobuf_type };
}

const ZigType = struct {
    source: []const u8,
    protobuf_type: Ident,
    mode: Mode,
    encoding: Encoding,

    const Mode = enum {
        alone,
        in_container,
    };

    const Encoding = enum {
        encode,
        decode,
    };

    const Primitive = enum {
        uint32,
        int32,
        uint64,
        int64,
        bool,
        float,
        double,
        bytes,
        string,
    };

    pub fn format(zt: ZigType, writer: *Io.Writer) !void {
        const name = zt.protobuf_type.get(zt.source);
        const primitive = std.meta.stringToEnum(Primitive, name) orelse {
            if (zt.mode == .alone) try writer.writeByte('?');
            try writer.print("{s}", .{name});
            if (zt.encoding == .decode) try writer.writeAll(".Decoded");
            return;
        };

        return switch (primitive) {
            .uint32 => try writer.writeAll("u32"),
            .int32 => try writer.writeAll("i32"),
            .uint64 => try writer.writeAll("u64"),
            .int64 => try writer.writeAll("i64"),
            .bool => try writer.writeAll("bool"),
            .float => try writer.writeAll("f32"),
            .double => try writer.writeAll("f64"),
            .bytes, .string => try writer.writeAll("[]const u8"),
        };
    }
};

const DefaultValue = struct {
    source: []const u8,
    protobuf_type: Ident,

    const Primitive = enum {
        uint32,
        int32,
        uint64,
        int64,
        bool,
        float,
        double,
        bytes,
        string,
    };

    pub fn format(dv: DefaultValue, writer: *Io.Writer) !void {
        const name = dv.protobuf_type.get(dv.source);
        const primitive = std.meta.stringToEnum(Primitive, name) orelse {
            return try writer.writeAll("null");
        };

        return switch (primitive) {
            .uint32,
            .int32,
            .uint64,
            .int64,
            .float,
            .double,
            => try writer.writeAll("0"),
            .bool => try writer.writeAll("false"),
            .bytes, .string => try writer.writeAll("&.{}"),
        };
    }
};

fn printIndented(w: *Io.Writer, comptime level: usize, comptime fmt: []const u8, args: anytype) !void {
    const final_fmt = @as([level * 4]u8, @splat(' ')) ++ fmt;
    try w.print(final_fmt, args);
}

test "parse top level" {
    const source =
        \\syntax = "proto3";
    ;

    var t: Tokenizer = .init(source);
    try skipTopLevel(&t);
}
