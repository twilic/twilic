const std = @import("std");
const TwilicError = @import("error.zig").TwilicError;

pub fn encodeVaruint(value: u64, out: *std.array_list.Managed(u8)) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) {
            byte |= 0x80;
        }
        try out.append(byte);
        if (v == 0) {
            break;
        }
    }
}

pub fn encodeZigzag(value: i64) u64 {
    return @bitCast((value << 1) ^ (value >> 63));
}

pub fn decodeZigzag(value: u64) i64 {
    const shifted: i64 = @intCast(value >> 1);
    const sign: i64 = -@as(i64, @intCast(value & 1));
    return shifted ^ sign;
}

pub fn encodeBytes(bytes: []const u8, out: *std.array_list.Managed(u8)) !void {
    try encodeVaruint(bytes.len, out);
    try out.appendSlice(bytes);
}

pub fn encodeString(value: []const u8, out: *std.array_list.Managed(u8)) !void {
    try encodeBytes(value, out);
}

pub fn encodeBitmap(bits: []const bool, out: *std.array_list.Managed(u8)) !void {
    try encodeVaruint(bits.len, out);
    var current: u8 = 0;
    for (bits, 0..) |bit, idx| {
        if (bit) {
            current |= @as(u8, 1) << @intCast(idx % 8);
        }
        if (idx % 8 == 7) {
            try out.append(current);
            current = 0;
        }
    }
    if (bits.len % 8 != 0) {
        try out.append(current);
    }
}

pub fn encodeFixedBitmap(bits: []const bool, count: u64, out: *std.array_list.Managed(u8)) !void {
    const c = std.math.cast(usize, count) orelse return TwilicError.InvalidData;
    if (bits.len != c) return TwilicError.InvalidData;
    var current: u8 = 0;
    for (bits, 0..) |bit, idx| {
        if (bit) {
            current |= @as(u8, 1) << @intCast(idx % 8);
        }
        if (idx % 8 == 7) {
            try out.append(current);
            current = 0;
        }
    }
    if (bits.len % 8 != 0) {
        try out.append(current);
    }
}

pub const Reader = struct {
    input: []const u8,
    offset: usize,
    depth: usize = 0,
    budget: usize,

    pub fn init(input: []const u8) Reader {
        return .{ .input = input, .offset = 0, .budget = @as(usize, @min(input.len, 1024)) * 1024 };
    }

    pub fn claimOutput(self: *Reader, count: u64) TwilicError!void {
        if (count > 1 << 20 or count > self.budget / 8) return TwilicError.InvalidData;
        self.budget -= @as(usize, @intCast(count)) * 8;
    }
    pub fn readCount(self: *Reader) TwilicError!u64 {
        const count = try self.readVaruint();
        try self.claimOutput(count);
        return count;
    }
    pub fn enterDepth(self: *Reader) TwilicError!void {
        if (self.depth >= 64) return TwilicError.InvalidData;
        self.depth += 1;
    }
    pub fn leaveDepth(self: *Reader) void {
        self.depth -= 1;
    }

    pub fn position(self: *const Reader) usize {
        return self.offset;
    }

    pub fn isEof(self: *const Reader) bool {
        return self.offset >= self.input.len;
    }

    pub fn readU8(self: *Reader) TwilicError!u8 {
        if (self.offset >= self.input.len) {
            return TwilicError.UnexpectedEof;
        }
        const byte = self.input[self.offset];
        self.offset += 1;
        return byte;
    }

    pub fn readExact(self: *Reader, len: usize) TwilicError![]const u8 {
        if (len > self.input.len - self.offset) return TwilicError.UnexpectedEof;
        const end = self.offset + len;
        const slice = self.input[self.offset..end];
        self.offset = end;
        return slice;
    }

    pub fn readVaruint(self: *Reader) TwilicError!u64 {
        var shift: u8 = 0;
        var result: u64 = 0;
        while (true) {
            if (shift >= 64) {
                return TwilicError.InvalidData;
            }
            const byte = try self.readU8();
            if (shift == 63 and (byte & 0x7e) != 0) return TwilicError.InvalidData;
            result |= (@as(u64, byte & 0x7f) << @as(u6, @intCast(shift)));
            if ((byte & 0x80) == 0) {
                return result;
            }
            shift += 7;
        }
    }

    pub fn readI64Zigzag(self: *Reader) TwilicError!i64 {
        const encoded = try self.readVaruint();
        return decodeZigzag(encoded);
    }

    pub fn readBytes(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const len = try self.readVaruint();
        const usize_len = std.math.cast(usize, len) orelse return TwilicError.InvalidData;
        const raw = try self.readExact(usize_len);
        return try allocator.dupe(u8, raw);
    }

    pub fn readString(self: *Reader, allocator: std.mem.Allocator) ![]u8 {
        const bytes = try self.readBytes(allocator);
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            allocator.free(bytes);
            return TwilicError.Utf8Error;
        }
        return bytes;
    }

    pub fn readBitmap(self: *Reader, allocator: std.mem.Allocator) ![]bool {
        const bit_count_u64 = try self.readCount();
        const bit_count = std.math.cast(usize, bit_count_u64) orelse return TwilicError.InvalidData;
        const byte_count = std.math.divCeil(usize, bit_count, 8) catch unreachable;
        const bytes = try self.readExact(byte_count);
        const bits = try allocator.alloc(bool, bit_count);
        for (bits, 0..) |*bit, idx| {
            const byte = bytes[idx / 8];
            bit.* = ((byte >> @intCast(idx % 8)) & 1) == 1;
        }
        return bits;
    }

    pub fn readFixedBitmap(self: *Reader, allocator: std.mem.Allocator, count: u64) ![]bool {
        const bit_count = std.math.cast(usize, count) orelse return TwilicError.InvalidData;
        const byte_count = std.math.divCeil(usize, bit_count, 8) catch unreachable;
        const bytes = try self.readExact(byte_count);
        const bits = try allocator.alloc(bool, bit_count);
        for (bits, 0..) |*bit, idx| {
            const byte = bytes[idx / 8];
            bit.* = ((byte >> @intCast(idx % 8)) & 1) == 1;
        }
        return bits;
    }
};

test "decode budget and varuint termination" {
    var reader = Reader.init(&.{0});
    try reader.claimOutput(100);
    try std.testing.expectError(TwilicError.InvalidData, reader.claimOutput(100));
    const continuation = [_]u8{0x80} ** 10;
    var integer = Reader.init(&continuation);
    try std.testing.expectError(TwilicError.InvalidData, integer.readVaruint());
}
