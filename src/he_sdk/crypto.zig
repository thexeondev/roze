const std = @import("std");
const assert = std.debug.assert;

const Aes192 = @import("crypto/Aes192.zig");

pub const DecryptError = error{
    BadCiphertextLength,
    BadPaddingLength,
    BadPaddingBytes,
};

pub const block_size = 16;

const key = "vs0U9Jo1Iz3TpEfnTORHm7Eh";
const iv = "1aORFg5tC2AT5MBM";

/// Performs AES decryption in-place.
pub fn decrypt(buffer: []u8) DecryptError!usize {
    if (buffer.len % block_size != 0)
        return error.BadCiphertextLength;

    var k: Aes192 = undefined;
    k.expand(key);

    const blocks = @divExact(buffer.len, block_size);
    var prev_ct_block: [block_size]u8 = iv.*;
    var i: usize = 0;

    while (i < blocks) : (i += 1) {
        const block = buffer[i * block_size ..][0..block_size];
        const ct_block = block.*;

        k.decrypt(block);
        for (block, prev_ct_block) |*a, b|
            a.* ^= b;

        prev_ct_block = ct_block;
    }

    const padding_length = buffer[buffer.len - 1];
    if (padding_length == 0 or padding_length > block_size)
        return error.BadPaddingLength;

    const padding_start = buffer.len - padding_length;
    for (buffer[padding_start..]) |padding_byte| if (padding_byte != padding_length)
        return error.BadPaddingBytes;

    return buffer[0..padding_start].len;
}

pub const EncryptError = error{
    NoSpaceForPadding,
};

/// Performs AES encryption in-place.
/// `buffer` must have enough space for padding.
pub fn encrypt(buffer: []u8, data_length: usize) EncryptError![]u8 {
    assert(buffer.len % block_size == 0);

    var k: Aes192 = undefined;
    k.expand(key);

    const blocks = @divCeil(data_length + 1, block_size);
    const padded_length = blocks * block_size;
    if (padded_length > buffer.len)
        return error.NoSpaceForPadding;

    var prev: *const [block_size]u8 = iv;
    var i: usize = 0;
    while (i + block_size <= data_length) : (i += block_size) {
        const block = buffer[i..][0..block_size];

        for (block, prev) |*a, b|
            a.* ^= b;

        k.encrypt(block);
        prev = block;
    }

    const last_block = buffer[i..][0..block_size];
    const padding_length: u8 = @intCast(padded_length - data_length);
    const padding = buffer[data_length..][0..padding_length];
    @memset(padding, padding_length);

    for (last_block, prev) |*x, y|
        x.* ^= y;

    k.encrypt(last_block);
    return buffer[0..padded_length];
}
