const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;

const roze = @import("roze.zig");
const protobuf = roze.protobuf;

pub const message_size_max = std.math.maxInt(u16);

pub const Header = struct {
    pub const size = 11;

    unk_0: u16 = 0,
    opcode: Opcode,
    encrypted_len: u16,
    decrypted_len: u16,
    seq: u32,

    pub fn decode(data: *const [size]u8) Header {
        return .{
            .unk_0 = mem.readInt(u16, data[0..2], .little),
            .opcode = @fromBackingInt(data[2]),
            .encrypted_len = mem.readInt(u16, data[3..5], .little),
            .decrypted_len = mem.readInt(u16, data[5..7], .little),
            .seq = mem.readInt(u32, data[7..11], .little),
        };
    }

    pub fn encode(header: *const Header, buffer: *[size]u8) void {
        mem.writeInt(u16, buffer[0..2], header.unk_0, .little);
        buffer[2] = @backingInt(header.opcode);
        mem.writeInt(u16, buffer[3..5], header.encrypted_len, .little);
        mem.writeInt(u16, buffer[5..7], header.decrypted_len, .little);
        mem.writeInt(u32, buffer[7..11], header.seq, .little);
    }
};

pub const Opcode = enum(u8) {
    NONE = 0,
    CONN = 1,
    PROTO = 2,
    HB = 3,
    RECONNECT = 4,
    RECONNECT_ACK = 5,
    SVR_MODE_WAIT = 6,
    SET_MODE = 7,
    SET_MODE_ACK = 8,
    ENC_ACK = 9,
    HANDSHAKE1 = 10,
    HANDSHAKE1_ACK = 11,
    HANDSHAKE2 = 12,
    HANDSHAKE2_ACK = 13,
    _,
};

pub const Mode = enum(u8) {
    encrypted = 1,
    unencrypted = 2,
    _,
};

pub const SetModeAck = struct {
    pub const size_headerless: usize = 2;
    pub const full_size: usize = Header.size + size_headerless;

    ret: Ret,
    mode: Mode,

    pub const Ret = enum(u8) {
        success = 0,
        _,
    };

    pub fn encode(ack: *const SetModeAck, header: *const Header, buffer: *[full_size]u8) void {
        header.encode(buffer[0..Header.size]);
        buffer[Header.size] = @backingInt(ack.ret);
        buffer[Header.size + 1] = @backingInt(ack.mode);
    }
};

pub const Heartbeat = struct {
    pub const size_headerless: usize = 12;
    pub const full_size: usize = Header.size + size_headerless;

    timestamp_ms: u64,
    rtt: u32,

    pub fn encode(hb: *const Heartbeat, header: *const Header, buffer: *[full_size]u8) void {
        header.encode(buffer[0..Header.size]);
        mem.writeInt(u64, buffer[Header.size..][0..8], hb.timestamp_ms, .little);
        mem.writeInt(u32, buffer[Header.size + 8 ..][0..4], hb.rtt, .little);
    }
};

pub const Sink = struct {
    buffer: []u8,
    end: *usize,
    send_seq: *u32,

    pub const Error = error{SinkOverflow};

    pub fn send(sink: *const Sink, tag: protobuf.gen.EClientServerCmds, cmd: anytype) Sink.Error!void {
        const CSMsgPkg = protobuf.gen.CSMsgPkg;
        const CSMsgHead = protobuf.gen.CSMsgHead;
        const Cmd = @TypeOf(cmd);

        const head_tag: protobuf.WireTag = .{
            .wire_type = .length_prefixed,
            .field_number = @backingInt(CSMsgPkg.descriptor.FieldNumber.head),
        };

        const body_tag: protobuf.WireTag = .{
            .wire_type = .length_prefixed,
            .field_number = @backingInt(CSMsgPkg.descriptor.FieldNumber.body),
        };

        const head: CSMsgHead = .{
            .version = 1,
            .cmd = @intCast(@backingInt(tag)),
            .game_id = 1,
        };

        const head_len = protobuf.encodingLength(CSMsgHead, &head);
        const body_len = protobuf.encodingLength(Cmd, &cmd);

        const package_overhead = protobuf.varIntByteCount(u32, @bitCast(head_tag)) +
            protobuf.varIntByteCount(u32, @bitCast(body_tag)) +
            protobuf.varIntByteCount(u64, head_len) +
            protobuf.varIntByteCount(u64, body_len);

        const package_len = package_overhead + head_len + body_len;

        const header: Header = .{
            .opcode = .PROTO,
            .encrypted_len = @intCast(package_len),
            .decrypted_len = @intCast(package_len),
            .seq = sink.send_seq.*,
        };

        if (sink.buffer.len - sink.end.* < Header.size + package_len)
            return error.SinkOverflow;

        errdefer comptime unreachable;

        const buffer = sink.buffer[sink.end.*..][0 .. Header.size + package_len];
        sink.end.* += buffer.len;

        var buffer_w: std.Io.Writer = .fixed(buffer);
        defer assert(buffer_w.end == buffer.len);

        sink.send_seq.* +%= 1;

        // Every function below cannot fail, because all of the required space is reserved.
        header.encode(buffer_w.writableArray(Header.size) catch unreachable);
        protobuf.writeVarInt(u32, &buffer_w, @bitCast(head_tag)) catch unreachable;
        protobuf.writeVarInt(u64, &buffer_w, head_len) catch unreachable;
        protobuf.encode(CSMsgHead, &head, &buffer_w) catch unreachable;
        protobuf.writeVarInt(u32, &buffer_w, @bitCast(body_tag)) catch unreachable;
        protobuf.writeVarInt(u64, &buffer_w, body_len) catch unreachable;
        protobuf.encode(Cmd, &cmd, &buffer_w) catch unreachable;
    }
};
