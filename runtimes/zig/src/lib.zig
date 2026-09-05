pub const codec = @import("codec.zig");
pub const errors = @import("error.zig");
pub const model = @import("model.zig");
pub const protocol = @import("protocol.zig");
pub const session = @import("session.zig");
pub const v2 = @import("v2.zig");
pub const wire = @import("wire.zig");

const std = @import("std");

pub const TwilicError = errors.TwilicError;
pub const Value = model.Value;
pub const Schema = model.Schema;
pub const Message = model.Message;
pub const TwilicCodec = protocol.TwilicCodec;
pub const SessionEncoder = protocol.SessionEncoder;
pub const SessionOptions = session.SessionOptions;
pub const UnknownReferencePolicy = session.UnknownReferencePolicy;

pub fn encode(allocator: std.mem.Allocator, value: *const Value) ![]u8 {
    return v2.encode(allocator, value);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !Value {
    return v2.decode(allocator, bytes);
}

pub fn encodeWithSchema(allocator: std.mem.Allocator, schema: Schema, value: *const Value) ![]u8 {
    var enc = SessionEncoder.init(allocator, .{});
    defer enc.deinit();
    return enc.encodeWithSchema(schema, value);
}

pub fn encodeBatch(allocator: std.mem.Allocator, values: []const Value) ![]u8 {
    var enc = SessionEncoder.init(allocator, .{});
    defer enc.deinit();
    return enc.encodeBatch(values);
}

pub fn encodeBoundStream(allocator: std.mem.Allocator, schema: Schema, values: []const Value) ![]u8 {
    var enc = SessionEncoder.init(allocator, .{});
    defer enc.deinit();
    return enc.encodeBoundStream(schema, values);
}

pub fn encodeBatchWithSchema(allocator: std.mem.Allocator, schema: Schema, values: []const Value) ![]u8 {
    var enc = SessionEncoder.init(allocator, .{});
    defer enc.deinit();
    return enc.encodeBatchWithSchema(schema, values);
}

pub fn createSessionEncoder(allocator: std.mem.Allocator, options: SessionOptions) SessionEncoder {
    return SessionEncoder.init(allocator, options);
}

test "roundtrip dynamic value" {
    const allocator = std.testing.allocator;
    var map_entries = try allocator.alloc(model.ValueMapEntry, 2);
    map_entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = 1001 } };
    map_entries[1] = .{ .key = try allocator.dupe(u8, "name"), .value = .{ .String = try allocator.dupe(u8, "alice") } };
    var value = Value{ .Map = map_entries };
    defer value.deinit(allocator);

    var codec_impl = TwilicCodec.init(allocator, .{});
    defer codec_impl.deinit();

    const encoded = try codec_impl.encodeValue(&value);
    defer allocator.free(encoded);
    var decoded = try codec_impl.decodeValue(encoded);
    defer decoded.deinit(allocator);
    try std.testing.expect(Value.eql(decoded, value));
}
