const std = @import("std");
const protocol = @import("protocol.zig");
const model = @import("model.zig");
const session = @import("session.zig");

pub fn encode(allocator: std.mem.Allocator, value: *const model.Value) ![]u8 {
    var codec = protocol.TwilicCodec.init(allocator, session.SessionOptions{});
    defer codec.deinit();
    return codec.encodeValue(value);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) !model.Value {
    var codec = protocol.TwilicCodec.init(allocator, session.SessionOptions{});
    defer codec.deinit();
    return codec.decodeValue(bytes);
}
