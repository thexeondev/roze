const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;

pub const packers = @import("protobuf/packers.zig");

pub const gen = @import("roze-proto").protoNamespace(Iterator);

pub const EncodeError = Io.Writer.Error;

pub fn encode(comptime Message: type, message: *const Message, writer: *Io.Writer) EncodeError!void {
    const struct_info = @typeInfo(Message).@"struct";

    @setEvalBranchQuota(struct_info.field_names.len);
    inline for (
        struct_info.field_names,
        struct_info.field_types,
    ) |field_name, FieldType| {
        const value = &@field(message, field_name);

        if (shouldEncode(FieldType, value)) switch (@typeInfo(FieldType)) {
            .bool, .int, .float => try encodeValue(Message, field_name, FieldType, value, writer),
            .@"struct" => try encodeValue(Message, field_name, FieldType, value, writer),
            .pointer => |pointer| {
                comptime assert(pointer.size == .slice);

                // Byte arrays are special
                if (FieldType == []const u8) {
                    try encodeValue(Message, field_name, FieldType, value, writer);
                } else {
                    for (value.*) |*item|
                        try encodeValue(Message, field_name, pointer.child, item, writer);
                }
            },
            .optional => |optional| switch (@typeInfo(optional.child)) {
                // It's safe to unwrap the optional because `shouldEncode` checked it.
                .@"struct" => try encodeValue(Message, field_name, optional.child, &value.*.?, writer),
                .@"enum" => try encodeValue(Message, field_name, optional.child, &value.*.?, writer),
                .@"union" => switch (value.*.?) {
                    inline else => |*unwrapped, tag| {
                        try encodeValue(Message, @tagName(tag), @TypeOf(unwrapped.*), unwrapped, writer);
                    },
                },
                else => @compileError("unexpected optional: " ++ @typeName(optional.child)),
            },
            else => @compileError("unsupported type: " ++ @typeName(FieldType)),
        };
    }
}

/// Encodes a singular value.
fn encodeValue(
    comptime Message: type,
    comptime field_name: []const u8,
    comptime Value: type,
    value: *const Value,
    writer: *Io.Writer,
) Io.Writer.Error!void {
    const descriptor = Message.descriptor;
    const field_number = @backingInt(@field(descriptor.FieldNumber, field_name));

    switch (@typeInfo(Value)) {
        .bool => {
            const wire_tag: WireTag = .{ .wire_type = .var_int, .field_number = field_number };
            try writeVarInt(u32, writer, @bitCast(wire_tag));
            try writeVarInt(u1, writer, @intFromBool(value.*));
        },
        .int => {
            const wire_tag: WireTag = .{ .wire_type = .var_int, .field_number = field_number };
            try writeVarInt(u32, writer, @bitCast(wire_tag));
            try writeVarInt(Value, writer, value.*);
        },
        .float => |float| {
            const wire_tag: WireTag = .{ .wire_type = .of(Value), .field_number = field_number };
            try writeVarInt(u32, writer, @bitCast(wire_tag));
            try writer.writeInt(@Int(.unsigned, float.bits), @bitCast(value.*), .little);
        },
        .@"struct" => {
            const wire_tag: WireTag = .{ .wire_type = .length_prefixed, .field_number = field_number };
            try writeVarInt(u32, writer, @bitCast(wire_tag));

            const length = encodingLength(Value, value);
            try writeVarInt(u64, writer, length);
            try encode(Value, value, writer);
        },
        .pointer => {
            comptime assert(Value == []const u8); // `encode` should've iterated over a slice

            const wire_tag: WireTag = .{ .wire_type = .length_prefixed, .field_number = field_number };
            try writeVarInt(u32, writer, @bitCast(wire_tag));

            try writeVarInt(u64, writer, @intCast(value.*.len));
            try writer.writeAll(value.*);
        },
        .@"enum" => {
            const wire_tag: WireTag = .{ .wire_type = .var_int, .field_number = field_number };
            try writeVarInt(u32, writer, @bitCast(wire_tag));
            try writeVarInt(i32, writer, @backingInt(value.*));
        },
        .optional => comptime unreachable, // `encode` should've unwrapped the optional
        .@"union" => comptime unreachable, // `encode` should've unwrapped the union
        else => comptime unreachable, // `encode` should've filtered invalid types out
    }
}

pub fn encodingLength(comptime Message: type, message: *const Message) u64 {
    // TODO: iterate over all fields and calculate their lengths instead of this.

    var trash_buffer: [128]u8 = undefined;
    var discarding: Io.Writer.Discarding = .init(&trash_buffer);
    encode(Message, message, &discarding.writer) catch unreachable;

    return discarding.fullCount();
}

fn shouldEncode(comptime FieldType: type, value: *const FieldType) bool {
    return switch (@typeInfo(FieldType)) {
        .bool => value.*,
        .int => value.* != 0,
        .float => value.* != 0,
        // in proto3, enums must have a zero variant which is the default
        .@"enum" => @backingInt(value.*) != 0,
        // repeated fields (slices)
        .pointer => value.*.len != 0,
        // * nested messages (optional structs)
        // * oneofs (optional tagged unions)
        .optional => value.* != null,
        else => @compileError("unexpected field type: " ++ @typeName(FieldType)),
    };
}

pub fn writeVarInt(comptime Int: type, writer: *Io.Writer, int: Int) Io.Writer.Error!void {
    const unsigned: @Int(.unsigned, @typeInfo(Int).int.bits) = @bitCast(int);
    try writeRawVarInt(writer, unsigned);
}

pub fn writeRawVarInt(writer: *Io.Writer, raw: u64) Io.Writer.Error!void {
    const Shift = std.math.Log2Int(u64);
    comptime var shift: Shift = 0;
    inline while (shift < 64) : (shift += 7) {
        const byte: VByte = .{
            .value = @truncate(raw >> shift),
            .continuation = (raw >> shift) >= 0x80,
        };

        try writer.writeByte(@bitCast(byte));

        if (!byte.continuation)
            return;

        if (shift == std.math.maxInt(Shift))
            break;
    }
}

pub fn varIntByteCount(comptime Int: type, int: Int) u32 {
    var count: u32 = 1;
    var v: @Int(.unsigned, @typeInfo(Int).int.bits) = @bitCast(int);

    while (v >= 0x80) : (v >>= 7)
        count += 1;

    return count;
}

pub const DecodeError = error{
    OutOfBounds,
} || VarIntError || WireType.Error;

pub fn decode(comptime Message: type, data: []const u8) DecodeError!Message {
    var message: Message = .init;
    try decodeMessage(Message, &message, data);
    return message;
}

/// Given a contiguous, protobuf-encoded array of bytes, decodes the `Message`.
/// `message` may not point to uninitialized memory.
fn decodeMessage(comptime Message: type, message: *Message, data: []const u8) DecodeError!void {
    const descriptor = Message.descriptor;

    // Don't expose `Io.Reader` API because we're targeting contiguous arrays.
    var reader: Io.Reader = .fixed(data);
    while (takeVarInt(u32, &reader)) |wire_tag_raw| {
        const wire_tag: WireTag = @bitCast(wire_tag_raw);
        const field_number: descriptor.FieldNumber = @fromBackingInt(wire_tag.field_number);

        @setEvalBranchQuota(@typeInfo(descriptor.FieldNumber).@"enum".field_names.len);
        switch (field_number) {
            _ => skipField(&reader, wire_tag.wire_type) catch |err| switch (err) {
                error.EndOfStream => return error.OutOfBounds,
                error.WireTypeInvalid => |e| return e,
                error.VarIntOverflow => |e| return e,
                error.ReadFailed => unreachable,
            },
            inline else => |field_number_comptime| {
                const Value, const value =
                    value: {
                        if (@hasDecl(descriptor.oneofs, @tagName(field_number_comptime))) {
                            const Oneof = @typeInfo(@FieldType(
                                Message,
                                @field(descriptor.oneofs, @tagName(field_number_comptime)),
                            )).optional.child;

                            const oneof: *?Oneof = &@field(
                                message,
                                @field(descriptor.oneofs, @tagName(field_number_comptime)),
                            );

                            const Value = @FieldType(Oneof, @tagName(field_number_comptime));
                            oneof.* = @unionInit(Oneof, @tagName(field_number_comptime), defaultValue(Value));

                            break :value .{ Value, &@field(oneof.*.?, @tagName(field_number_comptime)) };
                        } else {
                            const Value = @FieldType(Message, @tagName(field_number_comptime));
                            const value = &@field(message, @tagName(field_number_comptime));
                            break :value .{ Value, value };
                        }
                    };

                switch (@typeInfo(Value)) {
                    .optional => |optional| {
                        value.* = .init;
                        const value_unwrapped = &value.*.?;
                        decodeValue(optional.child, value_unwrapped, wire_tag.wire_type, &reader) catch |err| switch (err) {
                            error.EndOfStream => return error.OutOfBounds,
                            error.ReadFailed => unreachable,
                            error.OutOfBounds, error.VarIntOverflow, error.WireTypeInvalid => |e| return e,
                        };
                    },
                    else => decodeValue(Value, value, wire_tag.wire_type, &reader) catch |err| switch (err) {
                        error.EndOfStream => return error.OutOfBounds,
                        error.ReadFailed => unreachable,
                        error.OutOfBounds, error.VarIntOverflow, error.WireTypeInvalid => |e| return e,
                    },
                }
            },
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => unreachable,
        error.VarIntOverflow => |e| return e,
    }
}

inline fn defaultValue(comptime Value: type) Value {
    return switch (@typeInfo(Value)) {
        .bool => false,
        .float, .int => 0,
        .@"enum" => @fromBackingInt(0),
        .@"struct" => .init,
        .optional => null,
        .pointer => &.{},
        else => @compileError("unsupported type: " ++ @typeName(Value)),
    };
}

fn decodeValue(
    comptime Value: type,
    value: *Value,
    wire_type: WireType,
    reader: *Io.Reader,
) (DecodeError || Io.Reader.Error)!void {
    if (@typeInfo(Value) == .@"struct" and @hasDecl(Value, "Item")) { // Iterator(T)
        return try decodeRepeatedField(Value, value, wire_type, reader);
    }

    switch (Value) {
        bool => {
            const int = try takeVarInt(u8, reader);
            value.* = int != 0;
        },
        []const u8 => {
            if (wire_type != .length_prefixed) return error.WireTypeInvalid;
            const length = try takeVarInt(u64, reader);
            value.* = try reader.take(length);
        },
        i32, i64, u32, u64 => |Int| {
            value.* = try takeVarInt(Int, reader);
        },
        f32, f64 => |Float| {
            const bits = @typeInfo(Float).float.bits;
            value.* = @bitCast(try reader.takeInt(@Int(.unsigned, bits), .little));
        },
        else => switch (@typeInfo(Value)) {
            .@"enum" => {
                const int = try takeVarInt(i32, reader);
                value.* = std.enums.fromInt(Value, int) orelse @fromBackingInt(0);
            },
            .@"struct" => {
                if (wire_type != .length_prefixed) return error.WireTypeInvalid;
                value.* = .init;
                const length = try takeVarInt(u64, reader);
                const data = try reader.take(length);
                try decodeMessage(Value, value, data);
            },
            else => @compileError("unsupported type: " ++ @typeName(Value)),
        },
    }
}

fn decodeRepeatedField(
    comptime Repeated: type,
    repeated: *Repeated,
    wire_type: WireType,
    reader: *Io.Reader,
) !void {
    var seek_start = reader.seek;

    const mode: RepeatedFieldMode = skip_loop: while (true) {
        switch (wire_type) {
            _ => return error.WireTypeInvalid,
            inline .var_int, .int64, .int32 => |wire_type_comptime| {
                try skipField(reader, wire_type_comptime);

                const seek = reader.seek;
                const next_wire_tag_raw = takeVarInt(u32, reader) catch |err| switch (err) {
                    error.VarIntOverflow => |e| return e,
                    error.EndOfStream => {
                        // This was the last field of the message.
                        break :skip_loop .field_sequence;
                    },
                    error.ReadFailed => unreachable,
                };

                const next_wire_tag: WireTag = @bitCast(next_wire_tag_raw);
                if (next_wire_tag.field_number != Repeated.field_number) {
                    // We're done with this repeated field, revert seek position
                    reader.seek = seek;
                    break :skip_loop .field_sequence;
                }
            },
            .length_prefixed => {
                if (WireType.of(Repeated.Item) != .length_prefixed) {
                    // Packed integer values.
                    const length = takeVarInt(u64, reader) catch |err| switch (err) {
                        error.VarIntOverflow => |e| return e,
                        error.EndOfStream => return error.OutOfBounds,
                        error.ReadFailed => unreachable,
                    };

                    seek_start = reader.seek; // Place seek start after the length prefix
                    try reader.discardAll64(length);
                    break :skip_loop .packed_values;
                } else {
                    // Many length-prefixed values of the same field number.
                    const length = takeVarInt(u64, reader) catch |err| switch (err) {
                        error.VarIntOverflow => |e| return e,
                        error.EndOfStream => return error.OutOfBounds,
                        error.ReadFailed => unreachable,
                    };

                    try reader.discardAll64(length);

                    const seek = reader.seek;
                    const next_wire_tag_raw = takeVarInt(u32, reader) catch |err| switch (err) {
                        error.VarIntOverflow => |e| return e,
                        error.EndOfStream => {
                            // This was the last field of the message.
                            break :skip_loop .field_sequence;
                        },
                        error.ReadFailed => unreachable,
                    };

                    const next_wire_tag: WireTag = @bitCast(next_wire_tag_raw);
                    if (next_wire_tag.field_number != Repeated.field_number) {
                        // We're done with this repeated field, revert seek position
                        reader.seek = seek;
                        break :skip_loop .field_sequence;
                    }
                }
            },
        }
    };

    repeated.* = .{
        .data = reader.buffer[seek_start..reader.seek],
        .mode = mode,
        .wire_type = wire_type,
    };
}

const WireType = enum(u3) {
    var_int = 0,
    int64 = 1,
    length_prefixed = 2,
    int32 = 5,
    _,

    pub const Error = error{WireTypeInvalid};

    // Inline function so that `WireType` can be known at comptime.
    inline fn of(comptime T: type) WireType {
        return switch (T) {
            u32, i32, u64, i64, bool => .var_int,
            f32 => .int32,
            f64 => .int64,
            []const u8 => .length_prefixed,
            else => switch (@typeInfo(T)) {
                .@"enum" => .var_int,
                .@"struct" => .length_prefixed,
                .optional, .pointer => |container| of(container.child),
                else => @compileError("unsupported type: " ++ @typeName(T)),
            },
        };
    }
};

pub const WireTag = packed struct(u32) {
    wire_type: WireType,
    field_number: u29,
};

const VarIntError = error{VarIntOverflow};

const VByte = packed struct(u8) {
    value: u7,
    continuation: bool,
};

fn takeVarInt(comptime Int: type, reader: *Io.Reader) (Io.Reader.Error || VarIntError)!Int {
    var raw_value: u64 = 0;
    var shift: std.math.Log2Int(u64) = 0;

    while (shift < @bitSizeOf(u64) - @bitSizeOf(u7)) : (shift += 7) {
        const byte: VByte = @bitCast(try reader.takeByte());
        raw_value |= @as(u64, byte.value) << shift;

        if (!byte.continuation)
            return std.math.cast(Int, raw_value) orelse error.VarIntOverflow;
    } else return error.VarIntOverflow;
}

const SkipFieldError = WireType.Error || VarIntError || Io.Reader.Error;

fn skipField(r: *Io.Reader, wire_type: WireType) SkipFieldError!void {
    switch (wire_type) {
        .var_int => _ = try takeVarInt(u64, r),
        .int32 => try r.discardAll(@sizeOf(u32)),
        .int64 => try r.discardAll(@sizeOf(u64)),
        .length_prefixed => try r.discardAll64(try takeVarInt(u64, r)),
        _ => return error.WireTypeInvalid,
    }
}

const RepeatedFieldMode = enum {
    field_sequence,
    packed_values,
};

pub fn Iterator(comptime T: type, comptime number: u29) type {
    return struct {
        const It = @This();

        data: []const u8,
        mode: RepeatedFieldMode,
        wire_type: WireType,

        pub const Item = T;

        pub const field_number: u29 = number;

        pub const empty: It = .{
            .data = &.{},

            // When `data.len` is zero, these are not accessed.
            .mode = undefined,
            .wire_type = undefined,
        };

        pub fn next(it: *It) DecodeError!?Item {
            if (it.data.len == 0) return null;

            var reader: Io.Reader = .fixed(it.data);
            var item = defaultValue(Item);

            decodeValue(Item, &item, it.wire_type, &reader) catch |err| switch (err) {
                error.EndOfStream => return error.OutOfBounds,
                error.ReadFailed => unreachable,
                error.OutOfBounds, error.VarIntOverflow, error.WireTypeInvalid => |e| return e,
            };

            if (reader.seek != reader.end) {
                switch (it.mode) {
                    .packed_values => {},
                    .field_sequence => _ = takeVarInt(u32, &reader) catch |err| switch (err) {
                        error.EndOfStream => return error.OutOfBounds,
                        error.ReadFailed => unreachable,
                        error.VarIntOverflow => |e| return e,
                    },
                }
            }

            it.data = reader.buffer[reader.seek..];
            return item;
        }
    };
}
