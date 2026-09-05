const std = @import("std");
const twilic = @import("twilic");

const Allocator = std.mem.Allocator;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input = try std.fs.File.stdin().readToEndAlloc(allocator, 32 * 1024 * 1024);
    defer allocator.free(input);

    var codec_stream = twilic.TwilicCodec.init(allocator, .{});
    defer codec_stream.deinit();
    var session_stream = twilic.TwilicCodec.init(allocator, .{});
    defer session_stream.deinit();

    var decoded_count: usize = 0;
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;

        const parsed = try parseFrameLine(line);
        const bytes = try decodeHex(allocator, parsed.hex);
        defer allocator.free(bytes);

        const decoder: *twilic.TwilicCodec = if (std.mem.eql(u8, parsed.stream, "codec"))
            &codec_stream
        else if (std.mem.eql(u8, parsed.stream, "session"))
            &session_stream
        else
            return error.InvalidFrame;

        var message = try decoder.decodeMessage(bytes);
        defer message.deinit(allocator);
        decoded_count += 1;
    }

    if (decoded_count == 0) {
        return error.NoFrames;
    }

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("Zig client decode succeeded for {d} Rust frames\n", .{decoded_count});
    try stdout.flush();
}

const ParsedFrame = struct {
    stream: []const u8,
    label: []const u8,
    hex: []const u8,
};

fn parseFrameLine(line: []const u8) !ParsedFrame {
    const first = std.mem.indexOfScalar(u8, line, '|') orelse return error.InvalidFrame;
    const second_rel = std.mem.indexOfScalar(u8, line[first + 1 ..], '|') orelse return error.InvalidFrame;
    const second = first + 1 + second_rel;
    if (first == 0 or second <= first + 1 or second + 1 > line.len) return error.InvalidFrame;
    return .{
        .stream = line[0..first],
        .label = line[first + 1 .. second],
        .hex = line[second + 1 ..],
    };
}

fn decodeHex(allocator: Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.InvalidHex;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);

    var idx: usize = 0;
    while (idx < out.len) : (idx += 1) {
        const hi = try hexNibble(hex[idx * 2]);
        const lo = try hexNibble(hex[idx * 2 + 1]);
        out[idx] = (hi << 4) | lo;
    }
    return out;
}

fn hexNibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => error.InvalidHex,
    };
}
