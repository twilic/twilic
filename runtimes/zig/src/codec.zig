const std = @import("std");
const TwilicError = @import("error.zig").TwilicError;
const model = @import("model.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Reader = wire.Reader;
const VectorCodec = model.VectorCodec;

pub fn encodeI64Vector(values: []const i64, codec: VectorCodec, out: *std.array_list.Managed(u8)) !void {
    switch (codec) {
        .Rle => try encodeI64Rle(values, out),
        .DirectBitpack => try encodeI64DirectBitpack(values, out),
        .DeltaBitpack => {
            const deltas = try delta(values, out.allocator);
            defer out.allocator.free(deltas);
            try encodeI64DirectBitpack(deltas, out);
        },
        .ForBitpack => {
            if (values.len == 0) {
                try wire.encodeVaruint(0, out);
                return;
            }
            const min = std.mem.min(i64, values);
            try wire.encodeVaruint(wire.encodeZigzag(min), out);
            const shifted = try out.allocator.alloc(i64, values.len);
            defer out.allocator.free(shifted);
            for (values, 0..) |value, idx| {
                shifted[idx] = value - min;
            }
            try encodeI64DirectBitpack(shifted, out);
        },
        .DeltaForBitpack => {
            const deltas = try delta(values, out.allocator);
            defer out.allocator.free(deltas);
            if (deltas.len == 0) {
                try wire.encodeVaruint(0, out);
                return;
            }
            const min = std.mem.min(i64, deltas);
            try wire.encodeVaruint(wire.encodeZigzag(min), out);
            const shifted = try out.allocator.alloc(i64, deltas.len);
            defer out.allocator.free(shifted);
            for (deltas, 0..) |value, idx| {
                shifted[idx] = value - min;
            }
            try encodeI64DirectBitpack(shifted, out);
        },
        .DeltaDeltaBitpack => try encodeI64DeltaDelta(values, out),
        .PatchedFor => try encodeI64PatchedFor(values, out),
        .Simple8b => try encodeI64Simple8b(values, out),
        .Plain, .Dictionary, .StringRef, .PrefixDelta, .XorFloat => try encodeI64Plain(values, out),
    }
}

pub fn decodeI64Vector(reader: *Reader, codec: VectorCodec, allocator: Allocator) ![]i64 {
    return switch (codec) {
        .Rle => decodeI64Rle(reader, allocator),
        .DirectBitpack => decodeI64DirectBitpack(reader, allocator),
        .DeltaBitpack => blk: {
            const deltas = try decodeI64DirectBitpack(reader, allocator);
            errdefer allocator.free(deltas);
            break :blk try undelta(deltas, allocator);
        },
        .ForBitpack => blk: {
            const min = wire.decodeZigzag(try reader.readVaruint());
            if (reader.isEof()) {
                break :blk try allocator.alloc(i64, 0);
            }
            const shifted = try decodeI64DirectBitpack(reader, allocator);
            for (shifted) |*value| {
                value.* += min;
            }
            break :blk shifted;
        },
        .DeltaForBitpack => blk: {
            const min = wire.decodeZigzag(try reader.readVaruint());
            if (reader.isEof()) {
                break :blk try allocator.alloc(i64, 0);
            }
            const shifted = try decodeI64DirectBitpack(reader, allocator);
            for (shifted) |*value| {
                value.* += min;
            }
            break :blk try undelta(shifted, allocator);
        },
        .DeltaDeltaBitpack => decodeI64DeltaDelta(reader, allocator),
        .PatchedFor => decodeI64PatchedFor(reader, allocator),
        .Simple8b => decodeI64Simple8b(reader, allocator),
        .Plain, .Dictionary, .StringRef, .PrefixDelta, .XorFloat => decodeI64Plain(reader, allocator),
    };
}

pub fn encodeU64Vector(values: []const u64, codec: VectorCodec, out: *std.array_list.Managed(u8)) !void {
    switch (codec) {
        .Rle => try encodeU64Rle(values, out),
        .DirectBitpack => try encodeU64DirectBitpack(values, out),
        .ForBitpack => {
            if (values.len == 0) {
                try wire.encodeVaruint(0, out);
                return;
            }
            const min = std.mem.min(u64, values);
            try wire.encodeVaruint(min, out);
            const shifted = try out.allocator.alloc(u64, values.len);
            defer out.allocator.free(shifted);
            for (values, 0..) |value, idx| {
                shifted[idx] = value - min;
            }
            try encodeU64DirectBitpack(shifted, out);
        },
        .Plain => try encodeU64Plain(values, out),
        .Simple8b => try encodeU64Simple8b(values, out),
        .Dictionary, .StringRef, .PrefixDelta, .XorFloat, .DeltaBitpack, .DeltaForBitpack, .DeltaDeltaBitpack, .PatchedFor => try encodeU64Plain(values, out),
    }
}

pub fn decodeU64Vector(reader: *Reader, codec: VectorCodec, allocator: Allocator) ![]u64 {
    return switch (codec) {
        .Rle => decodeU64Rle(reader, allocator),
        .DirectBitpack => decodeU64DirectBitpack(reader, allocator),
        .ForBitpack => blk: {
            const min = try reader.readVaruint();
            if (reader.isEof()) {
                break :blk try allocator.alloc(u64, 0);
            }
            const shifted = try decodeU64DirectBitpack(reader, allocator);
            errdefer allocator.free(shifted);
            for (shifted) |*value| {
                value.* = std.math.add(u64, value.*, min) catch return TwilicError.InvalidData;
            }
            break :blk shifted;
        },
        .Plain => decodeU64Plain(reader, allocator),
        .Simple8b => decodeU64Simple8b(reader, allocator),
        .Dictionary, .StringRef, .PrefixDelta, .XorFloat, .DeltaBitpack, .DeltaForBitpack, .DeltaDeltaBitpack, .PatchedFor => decodeU64Plain(reader, allocator),
    };
}

pub fn encodeF64Vector(values: []const f64, codec: VectorCodec, out: *std.array_list.Managed(u8)) !void {
    if (codec == .XorFloat) {
        try encodeXorFloat(values, out);
        return;
    }
    try wire.encodeVaruint(values.len, out);
    for (values) |value| {
        try out.appendSlice(std.mem.asBytes(&value));
    }
}

pub fn decodeF64Vector(reader: *Reader, codec: VectorCodec, allocator: Allocator) ![]f64 {
    if (codec == .XorFloat) {
        return decodeXorFloat(reader, allocator);
    }
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    const out = try allocator.alloc(f64, len);
    for (out) |*slot| {
        const bytes = try reader.readExact(8);
        slot.* = std.mem.bytesToValue(f64, bytes[0..8]);
    }
    return out;
}

fn encodeU64Plain(values: []const u64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    for (values) |value| {
        try wire.encodeVaruint(value, out);
    }
}

fn decodeU64Plain(reader: *Reader, allocator: Allocator) ![]u64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    const out = try allocator.alloc(u64, len);
    for (out) |*slot| {
        slot.* = try reader.readVaruint();
    }
    return out;
}

fn encodeU64Rle(values: []const u64, out: *std.array_list.Managed(u8)) !void {
    var runs = std.array_list.Managed(struct { value: u64, count: u64 }).init(out.allocator);
    defer runs.deinit();

    for (values) |value| {
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].value == value) {
            runs.items[runs.items.len - 1].count += 1;
        } else {
            try runs.append(.{ .value = value, .count = 1 });
        }
    }

    try wire.encodeVaruint(runs.items.len, out);
    for (runs.items) |run| {
        try wire.encodeVaruint(run.value, out);
        try wire.encodeVaruint(run.count, out);
    }
}

fn decodeU64Rle(reader: *Reader, allocator: Allocator) ![]u64 {
    const runs_len_u64 = try reader.readCount();
    const runs_len = std.math.cast(usize, runs_len_u64) orelse return TwilicError.InvalidData;
    var out = std.array_list.Managed(u64).init(allocator);
    errdefer out.deinit();

    var run_idx: usize = 0;
    while (run_idx < runs_len) : (run_idx += 1) {
        const value = try reader.readVaruint();
        const count_u64 = try reader.readCount();
        const count = std.math.cast(usize, count_u64) orelse return TwilicError.InvalidData;
        try out.appendNTimes(value, count);
    }

    return out.toOwnedSlice();
}

fn encodeU64DirectBitpack(values: []const u64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    if (values.len == 0) {
        try out.append(0);
        return;
    }
    var width: u8 = 1;
    for (values) |value| {
        width = @max(width, bitWidth(value));
    }
    try out.append(width);
    try packU64Values(values, width, out);
}

fn decodeU64DirectBitpack(reader: *Reader, allocator: Allocator) ![]u64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    const width = try reader.readU8();
    if (len == 0) {
        return try allocator.alloc(u64, 0);
    }
    if (width == 0 or width > 64) {
        return TwilicError.InvalidData;
    }
    return unpackU64Values(reader, len, width, allocator);
}

fn encodeI64Plain(values: []const i64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    for (values) |value| {
        try wire.encodeVaruint(wire.encodeZigzag(value), out);
    }
}

fn decodeI64Plain(reader: *Reader, allocator: Allocator) ![]i64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    const out = try allocator.alloc(i64, len);
    for (out) |*slot| {
        slot.* = wire.decodeZigzag(try reader.readVaruint());
    }
    return out;
}

fn encodeI64Simple8b(values: []const i64, out: *std.array_list.Managed(u8)) !void {
    const encoded = try out.allocator.alloc(u64, values.len);
    defer out.allocator.free(encoded);
    for (values, 0..) |value, idx| {
        encoded[idx] = wire.encodeZigzag(value);
    }
    try encodeU64Simple8bInner(encoded, out);
}

fn decodeI64Simple8b(reader: *Reader, allocator: Allocator) ![]i64 {
    const encoded = try decodeU64Simple8bInner(reader, allocator);
    errdefer allocator.free(encoded);
    const out = try allocator.alloc(i64, encoded.len);
    for (encoded, 0..) |value, idx| {
        out[idx] = wire.decodeZigzag(value);
    }
    allocator.free(encoded);
    return out;
}

fn encodeU64Simple8b(values: []const u64, out: *std.array_list.Managed(u8)) !void {
    try encodeU64Simple8bInner(values, out);
}

fn decodeU64Simple8b(reader: *Reader, allocator: Allocator) ![]u64 {
    return decodeU64Simple8bInner(reader, allocator);
}

const Simple8bSlot = struct { count: usize, width: u8 };

const SIMPLE8B_SLOTS = [_]Simple8bSlot{
    .{ .count = 60, .width = 1 },
    .{ .count = 30, .width = 2 },
    .{ .count = 20, .width = 3 },
    .{ .count = 15, .width = 4 },
    .{ .count = 12, .width = 5 },
    .{ .count = 10, .width = 6 },
    .{ .count = 8, .width = 7 },
    .{ .count = 7, .width = 8 },
    .{ .count = 6, .width = 10 },
    .{ .count = 5, .width = 12 },
    .{ .count = 4, .width = 15 },
    .{ .count = 3, .width = 20 },
    .{ .count = 2, .width = 30 },
    .{ .count = 1, .width = 60 },
};

fn encodeU64Simple8bInner(values: []const u64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    if (values.len == 0) {
        return;
    }
    var max_value: u64 = 0;
    for (values) |value| {
        max_value = @max(max_value, value);
    }
    if (max_value > ((@as(u64, 1) << 60) - 1)) {
        try out.append(0);
        for (values) |value| {
            try wire.encodeVaruint(value, out);
        }
        return;
    }

    try out.append(1);
    var idx: usize = 0;
    while (idx < values.len) {
        var zero_run: usize = 0;
        while (idx + zero_run < values.len and values[idx + zero_run] == 0 and zero_run < 240) {
            zero_run += 1;
        }

        if (zero_run >= 120) {
            const take: usize = if (zero_run >= 240) 240 else 120;
            const word: u64 = if (take == 240) 0 else (@as(u64, 1) << 60);
            try out.appendSlice(std.mem.asBytes(&word));
            idx += take;
            continue;
        }

        var did_pack = false;
        for (SIMPLE8B_SLOTS, 0..) |slot, selector_idx| {
            if (idx + slot.count > values.len) continue;
            const max_encodable: u64 = if (slot.width == 64) std.math.maxInt(u64) else ((@as(u64, 1) << @as(u6, @intCast(slot.width))) - 1);
            var fits = true;
            var j: usize = 0;
            while (j < slot.count) : (j += 1) {
                if (values[idx + j] > max_encodable) {
                    fits = false;
                    break;
                }
            }
            if (!fits) continue;

            const selector: u64 = @intCast(selector_idx + 2);
            var payload: u64 = 0;
            var shift: u6 = 0;
            j = 0;
            while (j < slot.count) : (j += 1) {
                payload |= values[idx + j] << shift;
                shift += @intCast(slot.width);
            }
            const word: u64 = (selector << 60) | payload;
            try out.appendSlice(std.mem.asBytes(&word));
            idx += slot.count;
            did_pack = true;
            break;
        }

        if (!did_pack) {
            const selector: u64 = 15;
            const word: u64 = (selector << 60) | (values[idx] & ((@as(u64, 1) << 60) - 1));
            try out.appendSlice(std.mem.asBytes(&word));
            idx += 1;
        }
    }
}

fn decodeU64Simple8bInner(reader: *Reader, allocator: Allocator) ![]u64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    if (len == 0) {
        return try allocator.alloc(u64, 0);
    }
    const mode = try reader.readU8();
    if (mode == 0) {
        const out = try allocator.alloc(u64, len);
        for (out) |*slot| {
            slot.* = try reader.readVaruint();
        }
        return out;
    }
    if (mode != 1) {
        return TwilicError.InvalidData;
    }

    var out = std.array_list.Managed(u64).init(allocator);
    errdefer out.deinit();
    while (out.items.len < len) {
        const word_bytes = try reader.readExact(8);
        const packed_word = std.mem.bytesToValue(u64, word_bytes[0..8]);
        const selector: usize = @intCast(packed_word >> 60);
        const payload: u64 = packed_word & ((@as(u64, 1) << 60) - 1);

        switch (selector) {
            0, 1 => {
                const count: usize = if (selector == 0) 240 else 120;
                const remain = len - out.items.len;
                try out.appendNTimes(0, @min(count, remain));
            },
            2...15 => {
                const slot: Simple8bSlot = if (selector == 15)
                    .{ .count = @as(usize, 1), .width = @as(u8, 60) }
                else
                    SIMPLE8B_SLOTS[selector - 2];
                const mask: u64 = if (slot.width == 64) std.math.maxInt(u64) else ((@as(u64, 1) << @as(u6, @intCast(slot.width))) - 1);
                var shift: u6 = 0;
                const remain = len - out.items.len;
                const take = @min(slot.count, remain);
                var idx: usize = 0;
                while (idx < take) : (idx += 1) {
                    try out.append((payload >> shift) & mask);
                    shift += @as(u6, @intCast(slot.width));
                }
            },
            else => return TwilicError.InvalidData,
        }
    }
    return out.toOwnedSlice();
}

fn delta(values: []const i64, allocator: Allocator) ![]i64 {
    const out = try allocator.alloc(i64, values.len);
    var prev: i64 = 0;
    for (values, 0..) |value, idx| {
        if (idx == 0) {
            out[idx] = value;
        } else {
            out[idx] = value - prev;
        }
        prev = value;
    }
    return out;
}

fn undelta(values: []i64, allocator: Allocator) ![]i64 {
    const out = try allocator.alloc(i64, values.len);
    var prev: i64 = 0;
    for (values, 0..) |value, idx| {
        if (idx == 0) {
            out[idx] = value;
            prev = value;
            continue;
        }
        const next = std.math.add(i64, prev, value) catch return TwilicError.InvalidData;
        out[idx] = next;
        prev = next;
    }
    allocator.free(values);
    return out;
}

fn encodeI64Rle(values: []const i64, out: *std.array_list.Managed(u8)) !void {
    var runs = std.array_list.Managed(struct { value: i64, count: u64 }).init(out.allocator);
    defer runs.deinit();

    for (values) |value| {
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].value == value) {
            runs.items[runs.items.len - 1].count += 1;
        } else {
            try runs.append(.{ .value = value, .count = 1 });
        }
    }

    try wire.encodeVaruint(runs.items.len, out);
    for (runs.items) |run| {
        try wire.encodeVaruint(wire.encodeZigzag(run.value), out);
        try wire.encodeVaruint(run.count, out);
    }
}

fn decodeI64Rle(reader: *Reader, allocator: Allocator) ![]i64 {
    const runs_len_u64 = try reader.readCount();
    const runs_len = std.math.cast(usize, runs_len_u64) orelse return TwilicError.InvalidData;
    var out = std.array_list.Managed(i64).init(allocator);
    errdefer out.deinit();

    var idx: usize = 0;
    while (idx < runs_len) : (idx += 1) {
        const value = wire.decodeZigzag(try reader.readVaruint());
        const count_u64 = try reader.readCount();
        const count = std.math.cast(usize, count_u64) orelse return TwilicError.InvalidData;
        try out.appendNTimes(value, count);
    }
    return out.toOwnedSlice();
}

fn encodeI64PatchedFor(values: []const i64, out: *std.array_list.Managed(u8)) !void {
    if (values.len == 0) {
        try wire.encodeVaruint(0, out);
        return;
    }

    const base = std.mem.min(i64, values);
    const shifted = try out.allocator.alloc(i64, values.len);
    defer out.allocator.free(shifted);
    for (values, 0..) |value, idx| {
        shifted[idx] = value - base;
    }

    try wire.encodeVaruint(shifted.len, out);
    try wire.encodeVaruint(wire.encodeZigzag(base), out);

    var max_shifted: i64 = 0;
    for (shifted) |value| {
        if (value > max_shifted) max_shifted = value;
    }
    const base_width = bitWidth(@intCast(max_shifted)) -| 2;
    try out.append(base_width);

    var patch_positions = std.array_list.Managed(struct { pos: u64, value: i64 }).init(out.allocator);
    defer patch_positions.deinit();
    var idx: usize = 0;
    while (idx < shifted.len) : (idx += 1) {
        const value = shifted[idx];
        if (bitWidth(@intCast(value)) > base_width) {
            try patch_positions.append(.{ .pos = @intCast(idx), .value = value });
            const masked = if (base_width == 0)
                0
            else
                value & (@as(i64, 1) << @intCast(base_width)) - 1;
            try wire.encodeVaruint(@intCast(@max(masked, 0)), out);
        } else {
            try wire.encodeVaruint(@intCast(value), out);
        }
    }

    try wire.encodeVaruint(patch_positions.items.len, out);
    for (patch_positions.items) |patch| {
        try wire.encodeVaruint(patch.pos, out);
        try wire.encodeVaruint(@intCast(patch.value), out);
    }
}

fn decodeI64PatchedFor(reader: *Reader, allocator: Allocator) ![]i64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    if (len == 0) {
        return try allocator.alloc(i64, 0);
    }
    const base = wire.decodeZigzag(try reader.readVaruint());
    _ = try reader.readU8();

    const values = try allocator.alloc(i64, len);
    for (values) |*slot| {
        slot.* = @intCast(try reader.readVaruint());
    }

    const patch_count_u64 = try reader.readCount();
    const patch_count = std.math.cast(usize, patch_count_u64) orelse return TwilicError.InvalidData;
    var idx: usize = 0;
    while (idx < patch_count) : (idx += 1) {
        const pos_u64 = try reader.readVaruint();
        const pos = std.math.cast(usize, pos_u64) orelse return TwilicError.InvalidData;
        const patch = @as(i64, @intCast(try reader.readVaruint()));
        if (pos < values.len) {
            values[pos] = patch;
        }
    }

    for (values) |*slot| {
        slot.* += base;
    }
    return values;
}

fn encodeXorFloat(values: []const f64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    if (values.len == 0) return;

    var first = @as(u64, @bitCast(values[0]));
    try out.appendSlice(std.mem.asBytes(&first));
    var prev = first;
    for (values[1..]) |value| {
        const bits = @as(u64, @bitCast(value));
        const x = prev ^ bits;
        if (x == 0) {
            try out.append(0);
        } else {
            try out.append(1);
            const leading = @as(u64, @intCast(@clz(x)));
            const trailing = @as(u64, @intCast(@ctz(x)));
            const width: u64 = 64 - leading - trailing;
            try wire.encodeVaruint(leading, out);
            try wire.encodeVaruint(trailing, out);
            try wire.encodeVaruint(width, out);
            const payload = if (width == 64) x else ((x >> @intCast(trailing)) & ((@as(u64, 1) << @intCast(width)) - 1));
            try wire.encodeVaruint(payload, out);
        }
        prev = bits;
    }
}

fn decodeXorFloat(reader: *Reader, allocator: Allocator) ![]f64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    if (len == 0) {
        return try allocator.alloc(f64, 0);
    }

    const first_bytes = try reader.readExact(8);
    const first_bits = std.mem.bytesToValue(u64, first_bytes[0..8]);
    const out = try allocator.alloc(f64, len);
    out[0] = @bitCast(first_bits);
    var prev = first_bits;
    var idx: usize = 1;
    while (idx < len) : (idx += 1) {
        const flag = try reader.readU8();
        const bits = if (flag == 0) prev else blk: {
            const leading = try reader.readVaruint();
            const trailing = try reader.readVaruint();
            const width = try reader.readVaruint();
            const payload = try reader.readVaruint();
            if (leading + trailing + width > 64) {
                return TwilicError.InvalidData;
            }
            const x = if (width == 64) payload else payload << @intCast(trailing);
            break :blk prev ^ x;
        };
        out[idx] = @bitCast(bits);
        prev = bits;
    }
    return out;
}

fn encodeI64DirectBitpack(values: []const i64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    if (values.len == 0) {
        try out.append(0);
        return;
    }
    const encoded = try out.allocator.alloc(u64, values.len);
    defer out.allocator.free(encoded);
    var width: u8 = 1;
    for (values, 0..) |value, idx| {
        encoded[idx] = wire.encodeZigzag(value);
        width = @max(width, bitWidth(encoded[idx]));
    }
    try out.append(width);
    try packU64Values(encoded, width, out);
}

fn decodeI64DirectBitpack(reader: *Reader, allocator: Allocator) ![]i64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    const width = try reader.readU8();
    if (len == 0) {
        return try allocator.alloc(i64, 0);
    }
    if (width == 0 or width > 64) {
        return TwilicError.InvalidData;
    }
    const encoded = try unpackU64Values(reader, len, width, allocator);
    errdefer allocator.free(encoded);
    const out = try allocator.alloc(i64, len);
    for (encoded, 0..) |value, idx| {
        out[idx] = wire.decodeZigzag(value);
    }
    allocator.free(encoded);
    return out;
}

fn encodeI64DeltaDelta(values: []const i64, out: *std.array_list.Managed(u8)) !void {
    try wire.encodeVaruint(values.len, out);
    if (values.len == 0) return;
    try wire.encodeVaruint(wire.encodeZigzag(values[0]), out);
    if (values.len == 1) return;
    const d1 = values[1] - values[0];
    try wire.encodeVaruint(wire.encodeZigzag(d1), out);

    const dd = try out.allocator.alloc(i64, values.len - 2);
    defer out.allocator.free(dd);
    var prev_delta = d1;
    var idx: usize = 0;
    while (idx < values.len - 2) : (idx += 1) {
        const d = values[idx + 2] - values[idx + 1];
        dd[idx] = d - prev_delta;
        prev_delta = d;
    }
    try encodeI64DirectBitpack(dd, out);
}

fn decodeI64DeltaDelta(reader: *Reader, allocator: Allocator) ![]i64 {
    const len_u64 = try reader.readCount();
    const len = std.math.cast(usize, len_u64) orelse return TwilicError.InvalidData;
    if (len == 0) {
        return try allocator.alloc(i64, 0);
    }
    const first = wire.decodeZigzag(try reader.readVaruint());
    if (len == 1) {
        const out = try allocator.alloc(i64, 1);
        out[0] = first;
        return out;
    }
    const first_delta = wire.decodeZigzag(try reader.readVaruint());
    const dd = try decodeI64DirectBitpack(reader, allocator);
    defer allocator.free(dd);
    if (dd.len != len - 2) {
        return TwilicError.InvalidData;
    }

    const out = try allocator.alloc(i64, len);
    out[0] = first;
    out[1] = std.math.add(i64, first, first_delta) catch return TwilicError.InvalidData;
    var prev = out[1];
    var prev_delta = first_delta;
    for (dd, 0..) |ddv, idx| {
        const delta_value = std.math.add(i64, prev_delta, ddv) catch return TwilicError.InvalidData;
        const next = std.math.add(i64, prev, delta_value) catch return TwilicError.InvalidData;
        out[idx + 2] = next;
        prev = next;
        prev_delta = delta_value;
    }
    return out;
}

fn packU64Values(values: []const u64, width: u8, out: *std.array_list.Managed(u8)) !void {
    var acc: u128 = 0;
    var acc_bits: u8 = 0;
    for (values) |value| {
        acc |= (@as(u128, value) << @as(std.math.Log2Int(u128), @intCast(acc_bits)));
        acc_bits +%= width;
        while (acc_bits >= 8) {
            try out.append(@intCast(acc & 0xff));
            acc >>= 8;
            acc_bits -%= 8;
        }
    }
    if (acc_bits > 0) {
        try out.append(@intCast(acc));
    }
}

fn unpackU64Values(reader: *Reader, len: usize, width: u8, allocator: Allocator) ![]u64 {
    const total_bits = len * width;
    const byte_len = std.math.divCeil(usize, total_bits, 8) catch unreachable;
    const bytes = try reader.readExact(byte_len);
    const out = try allocator.alloc(u64, len);

    var acc: u128 = 0;
    var acc_bits: u8 = 0;
    var idx: usize = 0;
    for (out) |*slot| {
        while (acc_bits < width) {
            if (idx >= bytes.len) {
                allocator.free(out);
                return TwilicError.InvalidData;
            }
            acc |= (@as(u128, bytes[idx]) << @as(std.math.Log2Int(u128), @intCast(acc_bits)));
            idx += 1;
            acc_bits += 8;
        }
        const mask: u128 = if (width == 64) @as(u128, std.math.maxInt(u64)) else ((@as(u128, 1) << @as(std.math.Log2Int(u128), @intCast(width))) - 1);
        slot.* = @intCast(acc & mask);
        acc >>= @as(std.math.Log2Int(u128), @intCast(width));
        acc_bits -%= width;
    }
    return out;
}

fn bitWidth(v: u64) u8 {
    if (v == 0) {
        return 1;
    }
    return @intCast(64 - @clz(v));
}
