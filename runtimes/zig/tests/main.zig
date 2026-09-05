const std = @import("std");
const twilic = @import("twilic");

test "shape promotes after second three-field map" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    var value = try userMapValue(allocator, 1, "alice", "admin");
    defer value.deinit(allocator);

    const first = try codec.encodeValue(&value);
    defer allocator.free(first);
    var first_msg = try codec.decodeMessage(first);
    defer first_msg.deinit(allocator);
    try std.testing.expect(first_msg == .Map);

    const second = try codec.encodeValue(&value);
    defer allocator.free(second);
    var second_msg = try codec.decodeMessage(second);
    defer second_msg.deinit(allocator);
    try std.testing.expect(second_msg == .ShapedObject);
}

test "two-field map keeps map and uses key ids" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    var entries = try allocator.alloc(twilic.model.ValueMapEntry, 2);
    entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = 1 } };
    entries[1] = .{ .key = try allocator.dupe(u8, "name"), .value = .{ .String = try allocator.dupe(u8, "alice") } };
    var value = twilic.Value{ .Map = entries };
    defer value.deinit(allocator);

    const first = try codec.encodeValue(&value);
    defer allocator.free(first);
    var first_msg = try codec.decodeMessage(first);
    defer first_msg.deinit(allocator);
    try std.testing.expect(first_msg == .Map);
    for (first_msg.Map) |entry| {
        try std.testing.expect(entry.key == .Literal);
    }

    const second = try codec.encodeValue(&value);
    defer allocator.free(second);
    var second_msg = try codec.decodeMessage(second);
    defer second_msg.deinit(allocator);
    try std.testing.expect(second_msg == .Map);
    for (second_msg.Map) |entry| {
        try std.testing.expect(entry.key == .Id);
    }
}

test "typed vector threshold is applied" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    var short_values = try allocator.alloc(twilic.Value, 3);
    short_values[0] = .{ .I64 = 1 };
    short_values[1] = .{ .I64 = 2 };
    short_values[2] = .{ .I64 = 3 };
    var short = twilic.Value{ .Array = short_values };
    defer short.deinit(allocator);

    const short_bytes = try codec.encodeValue(&short);
    defer allocator.free(short_bytes);
    var short_msg = try codec.decodeMessage(short_bytes);
    defer short_msg.deinit(allocator);
    try std.testing.expect(short_msg == .Array);

    var long_values = try allocator.alloc(twilic.Value, 4);
    long_values[0] = .{ .I64 = 1 };
    long_values[1] = .{ .I64 = 2 };
    long_values[2] = .{ .I64 = 3 };
    long_values[3] = .{ .I64 = 4 };
    var long = twilic.Value{ .Array = long_values };
    defer long.deinit(allocator);

    const long_bytes = try codec.encodeValue(&long);
    defer allocator.free(long_bytes);
    var long_msg = try codec.decodeMessage(long_bytes);
    defer long_msg.deinit(allocator);
    try std.testing.expect(long_msg == .TypedVector);
}

test "string modes empty ref and prefix delta are used" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const empty_value = twilic.Value{ .String = try allocator.alloc(u8, 0) };
    const empty_bytes = try codec.encodeValue(&empty_value);
    defer allocator.free(empty_bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.Empty)), empty_bytes[2]);

    const literal_value = twilic.Value{ .String = try allocator.dupe(u8, "alpha") };
    defer allocator.free(literal_value.String);
    const literal_bytes = try codec.encodeValue(&literal_value);
    defer allocator.free(literal_bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.Literal)), literal_bytes[2]);

    const ref_bytes = try codec.encodeValue(&literal_value);
    defer allocator.free(ref_bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.Ref)), ref_bytes[2]);

    const base = twilic.Value{ .String = try allocator.dupe(u8, "prefix_common_aaaa") };
    defer allocator.free(base.String);
    const base_bytes = try codec.encodeValue(&base);
    defer allocator.free(base_bytes);

    const pd = twilic.Value{ .String = try allocator.dupe(u8, "prefix_common_bbbb") };
    defer allocator.free(pd.String);
    const pd_bytes = try codec.encodeValue(&pd);
    defer allocator.free(pd_bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.PrefixDelta)), pd_bytes[2]);
}

test "schema id is sent first then omitted" {
    const allocator = std.testing.allocator;
    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    var schema = try userSchema(allocator);
    defer schema.deinit(allocator);
    var value = try userMapValue(allocator, 1005, "alice", "admin");
    defer value.deinit(allocator);

    const first = try enc.encodeWithSchema(schema, &value);
    defer allocator.free(first);
    var first_msg = try enc.decodeMessage(first);
    defer first_msg.deinit(allocator);
    try std.testing.expect(first_msg == .SchemaObject);
    try std.testing.expect(first_msg.SchemaObject.schema_id != null);

    const second = try enc.encodeWithSchema(schema, &value);
    defer allocator.free(second);
    var second_msg = try enc.decodeMessage(second);
    defer second_msg.deinit(allocator);
    try std.testing.expect(second_msg == .SchemaObject);
    try std.testing.expect(second_msg.SchemaObject.schema_id == null);
}

test "encode with schema rejects missing required field" {
    const allocator = std.testing.allocator;
    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    var schema = try userSchema(allocator);
    defer schema.deinit(allocator);

    var entries = try allocator.alloc(twilic.model.ValueMapEntry, 1);
    entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = 1005 } };
    var value = twilic.Value{ .Map = entries };
    defer value.deinit(allocator);

    try std.testing.expectError(twilic.TwilicError.InvalidData, enc.encodeWithSchema(schema, &value));
}

test "batch threshold selects row vs column" {
    const allocator = std.testing.allocator;
    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    const rows_15 = try makeIdRows(allocator, 15);
    defer freeValues(rows_15, allocator);
    const b15 = try enc.encodeBatch(rows_15);
    defer allocator.free(b15);
    var m15 = try enc.decodeMessage(b15);
    defer m15.deinit(allocator);
    try std.testing.expect(m15 == .RowBatch);

    const rows_16 = try makeIdRows(allocator, 16);
    defer freeValues(rows_16, allocator);
    const b16 = try enc.encodeBatch(rows_16);
    defer allocator.free(b16);
    var m16 = try enc.decodeMessage(b16);
    defer m16.deinit(allocator);
    try std.testing.expect(m16 == .ColumnBatch);
}

test "vector codecs roundtrip smoke" {
    const allocator = std.testing.allocator;
    const input_i64 = [_]i64{ 1, 2, 3, -1, 0, 4, -2, 6, 8, 10, -3, 5 };
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try twilic.codec.encodeI64Vector(&input_i64, .Simple8b, &out);
    var reader = twilic.wire.Reader.init(out.items);
    const decoded_i64 = try twilic.codec.decodeI64Vector(&reader, .Simple8b, allocator);
    defer allocator.free(decoded_i64);
    try std.testing.expectEqualSlices(i64, &input_i64, decoded_i64);

    out.clearRetainingCapacity();
    const input_f64 = [_]f64{ 1.0, 1.0, 1.125, 1.25, 1.25, 1.375, 1.5 };
    try twilic.codec.encodeF64Vector(&input_f64, .XorFloat, &out);
    reader = twilic.wire.Reader.init(out.items);
    const decoded_f64 = try twilic.codec.decodeF64Vector(&reader, .XorFloat, allocator);
    defer allocator.free(decoded_f64);
    try std.testing.expectEqualSlices(f64, &input_f64, decoded_f64);
}

test "reset tables clears string interning" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    var value = twilic.Value{ .String = try allocator.dupe(u8, "ephemeral") };
    defer value.deinit(allocator);

    const first = try codec.encodeValue(&value);
    defer allocator.free(first);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.Literal)), scalarStringMode(first));

    const reused = try codec.encodeValue(&value);
    defer allocator.free(reused);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.Ref)), scalarStringMode(reused));

    var reset_msg = twilic.Message{ .Control = .{ .ResetTables = {} } };
    const reset_bytes = try codec.encodeMessage(&reset_msg);
    defer allocator.free(reset_bytes);
    var decoded_reset = try codec.decodeMessage(reset_bytes);
    defer decoded_reset.deinit(allocator);
    try std.testing.expect(decoded_reset == .Control);
    try std.testing.expect(decoded_reset.Control == .ResetTables);

    const after_reset = try codec.encodeValue(&value);
    defer allocator.free(after_reset);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.StringMode.Literal)), scalarStringMode(after_reset));
}

test "register shape with key ids roundtrips" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const reg_keys_values = try allocator.alloc([]u8, 2);
    reg_keys_values[0] = try allocator.dupe(u8, "id");
    reg_keys_values[1] = try allocator.dupe(u8, "name");
    var reg_keys = twilic.Message{ .Control = .{ .RegisterKeys = reg_keys_values } };
    defer reg_keys.deinit(allocator);

    const reg_keys_bytes = try codec.encodeMessage(&reg_keys);
    defer allocator.free(reg_keys_bytes);
    var reg_keys_decoded = try codec.decodeMessage(reg_keys_bytes);
    defer reg_keys_decoded.deinit(allocator);
    try std.testing.expect(reg_keys_decoded == .Control);

    const shape_keys = try allocator.alloc(twilic.model.KeyRef, 2);
    shape_keys[0] = .{ .Id = 0 };
    shape_keys[1] = .{ .Id = 1 };
    var reg_shape = twilic.Message{ .Control = .{ .RegisterShape = .{ .shape_id = 99, .keys = shape_keys } } };
    defer reg_shape.deinit(allocator);

    const reg_shape_bytes = try codec.encodeMessage(&reg_shape);
    defer allocator.free(reg_shape_bytes);
    var reg_shape_decoded = try codec.decodeMessage(reg_shape_bytes);
    defer reg_shape_decoded.deinit(allocator);
    try std.testing.expect(twilic.model.Message.eql(reg_shape_decoded, reg_shape));

    const shaped_values = try allocator.alloc(twilic.Value, 2);
    shaped_values[0] = .{ .U64 = 1 };
    shaped_values[1] = .{ .String = try allocator.dupe(u8, "alice") };
    var shaped = twilic.Message{ .ShapedObject = .{ .shape_id = 99, .presence = null, .values = shaped_values } };
    defer shaped.deinit(allocator);

    const shaped_bytes = try codec.encodeMessage(&shaped);
    defer allocator.free(shaped_bytes);
    var decoded_value = try codec.decodeValue(shaped_bytes);
    defer decoded_value.deinit(allocator);

    var expected = try idNameMapValue(allocator, 1, "alice");
    defer expected.deinit(allocator);
    try std.testing.expect(twilic.Value.eql(decoded_value, expected));
}

test "reset state clears shape resolution" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const shape_keys = try allocator.alloc(twilic.model.KeyRef, 2);
    shape_keys[0] = .{ .Literal = try allocator.dupe(u8, "id") };
    shape_keys[1] = .{ .Literal = try allocator.dupe(u8, "name") };
    var reg_shape = twilic.Message{ .Control = .{ .RegisterShape = .{ .shape_id = 7, .keys = shape_keys } } };
    defer reg_shape.deinit(allocator);

    const reg_bytes = try codec.encodeMessage(&reg_shape);
    defer allocator.free(reg_bytes);
    var reg_decoded = try codec.decodeMessage(reg_bytes);
    defer reg_decoded.deinit(allocator);

    var reset = twilic.Message{ .Control = .{ .ResetState = {} } };
    const reset_bytes = try codec.encodeMessage(&reset);
    defer allocator.free(reset_bytes);
    var reset_decoded = try codec.decodeMessage(reset_bytes);
    defer reset_decoded.deinit(allocator);

    const shaped_values = try allocator.alloc(twilic.Value, 2);
    shaped_values[0] = .{ .U64 = 1 };
    shaped_values[1] = .{ .String = try allocator.dupe(u8, "alice") };
    var shaped = twilic.Message{ .ShapedObject = .{ .shape_id = 7, .presence = null, .values = shaped_values } };
    defer shaped.deinit(allocator);

    const shaped_bytes = try codec.encodeMessage(&shaped);
    defer allocator.free(shaped_bytes);
    try std.testing.expectError(twilic.TwilicError.UnknownReference, codec.decodeValue(shaped_bytes));
}

test "unknown key reference honors policies" {
    const allocator = std.testing.allocator;
    const bytes = try unknownKeyMapBytes(allocator, 42);
    defer allocator.free(bytes);

    var fail_fast = twilic.TwilicCodec.init(allocator, .{});
    defer fail_fast.deinit();
    try std.testing.expectError(twilic.TwilicError.UnknownReference, fail_fast.decodeMessage(bytes));

    var stateless_retry = twilic.TwilicCodec.init(allocator, .{ .unknown_reference_policy = .StatelessRetry });
    defer stateless_retry.deinit();
    try std.testing.expectError(twilic.TwilicError.StatelessRetryRequired, stateless_retry.decodeMessage(bytes));
}

test "vector codec simple8b u64 edge cases" {
    const allocator = std.testing.allocator;

    var long_zero_runs = try allocator.alloc(u64, 385);
    defer allocator.free(long_zero_runs);
    @memset(long_zero_runs[0..130], 0);
    long_zero_runs[130] = 1;
    long_zero_runs[131] = 2;
    long_zero_runs[132] = 3;
    long_zero_runs[133] = 4;
    long_zero_runs[134] = 5;
    @memset(long_zero_runs[135..], 0);

    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();

    try twilic.codec.encodeU64Vector(long_zero_runs, .Simple8b, &out);
    var reader = twilic.wire.Reader.init(out.items);
    const decoded_long = try twilic.codec.decodeU64Vector(&reader, .Simple8b, allocator);
    defer allocator.free(decoded_long);
    try std.testing.expectEqualSlices(u64, long_zero_runs, decoded_long);

    out.clearRetainingCapacity();
    const large_values = [_]u64{ @as(u64, 1) << 61, (@as(u64, 1) << 61) + 7, (@as(u64, 1) << 61) + 99 };
    try twilic.codec.encodeU64Vector(&large_values, .Simple8b, &out);
    reader = twilic.wire.Reader.init(out.items);
    const decoded_large = try twilic.codec.decodeU64Vector(&reader, .Simple8b, allocator);
    defer allocator.free(decoded_large);
    try std.testing.expectEqualSlices(u64, &large_values, decoded_large);
}

test "vector codec rejects malformed inputs" {
    const allocator = std.testing.allocator;

    var overflow_bytes = std.array_list.Managed(u8).init(allocator);
    defer overflow_bytes.deinit();
    try twilic.wire.encodeVaruint(std.math.maxInt(u64), &overflow_bytes);
    try twilic.wire.encodeVaruint(1, &overflow_bytes);
    try overflow_bytes.append(1);
    try overflow_bytes.append(1);
    var overflow_reader = twilic.wire.Reader.init(overflow_bytes.items);
    try std.testing.expectError(twilic.TwilicError.InvalidData, twilic.codec.decodeU64Vector(&overflow_reader, .ForBitpack, allocator));

    var invalid_width_bytes = std.array_list.Managed(u8).init(allocator);
    defer invalid_width_bytes.deinit();
    try twilic.wire.encodeVaruint(1, &invalid_width_bytes);
    try invalid_width_bytes.append(0);
    var width_reader = twilic.wire.Reader.init(invalid_width_bytes.items);
    try std.testing.expectError(twilic.TwilicError.InvalidData, twilic.codec.decodeI64Vector(&width_reader, .DirectBitpack, allocator));
}

test "decode value rejects control messages" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    var reset = twilic.Message{ .Control = .{ .ResetTables = {} } };
    const bytes = try codec.encodeMessage(&reset);
    defer allocator.free(bytes);

    try std.testing.expectError(twilic.TwilicError.InvalidData, codec.decodeValue(bytes));
}

test "public api encode decode wrapper roundtrip" {
    const allocator = std.testing.allocator;
    var value = try idNameMapValue(allocator, 7, "alice");
    defer value.deinit(allocator);

    const encoded = try twilic.encode(allocator, &value);
    defer allocator.free(encoded);

    var decoded = try twilic.decode(allocator, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expect(twilic.Value.eql(decoded, value));
}

test "control stream roundtrips for all declared codecs" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const payload = [_]u8{ 0, 0, 1, 1, 1, 2, 3, 3, 3, 3, 4 };
    const codecs = [_]twilic.model.ControlStreamCodec{ .Plain, .Rle, .Bitpack, .Huffman, .Fse };
    for (codecs) |stream_codec| {
        var msg = twilic.Message{ .ControlStream = .{
            .codec = stream_codec,
            .payload = try allocator.dupe(u8, &payload),
        } };
        defer msg.deinit(allocator);

        const bytes = try codec.encodeMessage(&msg);
        defer allocator.free(bytes);
        var decoded = try codec.decodeMessage(bytes);
        defer decoded.deinit(allocator);
        try std.testing.expect(twilic.model.Message.eql(decoded, msg));
    }
}

test "control stream bitpack compacts repetitive payloads" {
    const allocator = std.testing.allocator;

    const binary_payload = try allocator.alloc(u8, 512);
    defer allocator.free(binary_payload);
    for (binary_payload, 0..) |*slot, idx| slot.* = @intCast(idx % 2);
    const plain_binary_len = try encodedControlStreamLen(allocator, .Plain, binary_payload);
    const bitpack_len = try encodedControlStreamLen(allocator, .Bitpack, binary_payload);
    try std.testing.expect(bitpack_len < plain_binary_len);

    const rle_friendly = try allocator.alloc(u8, 512);
    defer allocator.free(rle_friendly);
    @memset(rle_friendly, 7);
    const plain_rle_len = try encodedControlStreamLen(allocator, .Plain, rle_friendly);
    const huffman_len = try encodedControlStreamLen(allocator, .Huffman, rle_friendly);
    try std.testing.expect(huffman_len <= plain_rle_len);
}

test "control stream fse falls back to plain frame mode" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const payload = try allocator.alloc(u8, 512);
    defer allocator.free(payload);
    for (payload, 0..) |*slot, idx| slot.* = @intCast(idx % 4);

    var msg = twilic.Message{ .ControlStream = .{ .codec = .Fse, .payload = try allocator.dupe(u8, payload) } };
    defer msg.deinit(allocator);

    const bytes = try codec.encodeMessage(&msg);
    defer allocator.free(bytes);

    var reader = twilic.wire.Reader.init(bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.MessageKind.ControlStream)), try reader.readU8());
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.ControlStreamCodec.Fse)), try reader.readU8());
    const framed = try reader.readBytes(allocator);
    defer allocator.free(framed);
    try std.testing.expect(framed.len > 0);
    try std.testing.expectEqual(@as(u8, 0), framed[0]);
}

test "micro batch reuses template and emits changed mask" {
    const allocator = std.testing.allocator;
    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    const rows1 = try makeUserRows(allocator, &[_][]const u8{ "a", "b", "c", "d" });
    defer freeValues(rows1, allocator);

    const first = try enc.encodeMicroBatch(rows1);
    defer allocator.free(first);
    var first_msg = try enc.decodeMessage(first);
    defer first_msg.deinit(allocator);
    try std.testing.expect(first_msg == .TemplateBatch);
    for (first_msg.TemplateBatch.changed_column_mask) |bit| {
        try std.testing.expect(bit);
    }
    const template_id = first_msg.TemplateBatch.template_id;

    const rows2 = try makeUserRows(allocator, &[_][]const u8{ "aa", "bb", "cc", "dd" });
    defer freeValues(rows2, allocator);
    const second = try enc.encodeMicroBatch(rows2);
    defer allocator.free(second);
    var second_msg = try enc.decodeMessage(second);
    defer second_msg.deinit(allocator);
    try std.testing.expect(second_msg == .TemplateBatch);
    try std.testing.expectEqual(template_id, second_msg.TemplateBatch.template_id);
    var has_unchanged = false;
    for (second_msg.TemplateBatch.changed_column_mask) |bit| {
        if (!bit) has_unchanged = true;
    }
    try std.testing.expect(has_unchanged);
}

test "state patch uses recommended ratio threshold" {
    const allocator = std.testing.allocator;
    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    const base_values = try allocator.alloc(twilic.Value, 100);
    defer freeValues(base_values, allocator);
    for (base_values, 0..) |*slot, idx| slot.* = .{ .I64 = @intCast(idx) };
    var base = twilic.Value{ .Array = base_values };

    var one_change_values = try cloneValuesForTest(base_values, allocator);
    defer freeValues(one_change_values, allocator);
    one_change_values[0].deinit(allocator);
    one_change_values[0] = .{ .I64 = 10_000 };
    var one_change = twilic.Value{ .Array = one_change_values };

    var many_change_values = try cloneValuesForTest(base_values, allocator);
    defer freeValues(many_change_values, allocator);
    for (many_change_values[0..12], 0..) |*slot, idx| {
        slot.deinit(allocator);
        slot.* = .{ .I64 = @intCast(10_000 + idx) };
    }
    var many_change = twilic.Value{ .Array = many_change_values };

    const _base_bytes = try enc.encode(&base);
    defer allocator.free(_base_bytes);

    const patch_bytes = try enc.encodePatch(&one_change);
    defer allocator.free(patch_bytes);
    var patch_msg = try enc.decodeMessage(patch_bytes);
    defer patch_msg.deinit(allocator);
    try std.testing.expect(patch_msg == .StatePatch);

    const full_bytes = try enc.encodePatch(&many_change);
    defer allocator.free(full_bytes);
    var full_msg = try enc.decodeMessage(full_bytes);
    defer full_msg.deinit(allocator);
    try std.testing.expect(full_msg != .StatePatch);
}

test "unknown base id honors stateless retry policy" {
    const allocator = std.testing.allocator;
    var enc = twilic.SessionEncoder.init(allocator, .{ .unknown_reference_policy = .StatelessRetry });
    defer enc.deinit();

    var patch = twilic.Message{ .StatePatch = .{
        .base_ref = .{ .BaseId = 12345 },
        .operations = try allocator.alloc(twilic.model.PatchOperation, 0),
        .literals = try allocator.alloc(twilic.Value, 0),
    } };
    defer patch.deinit(allocator);

    var plain = twilic.TwilicCodec.init(allocator, .{});
    defer plain.deinit();
    const bytes = try plain.encodeMessage(&patch);
    defer allocator.free(bytes);

    try std.testing.expectError(twilic.TwilicError.StatelessRetryRequired, enc.decodeMessage(bytes));
}

test "state patch map insert and delete reconstructs previous message" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const base_entries = try allocator.alloc(twilic.model.MapEntry, 2);
    base_entries[0] = .{ .key = .{ .Literal = try allocator.dupe(u8, "id") }, .value = .{ .U64 = 1 } };
    base_entries[1] = .{ .key = .{ .Literal = try allocator.dupe(u8, "name") }, .value = .{ .String = try allocator.dupe(u8, "alice") } };
    var base = twilic.Message{ .Map = base_entries };
    defer base.deinit(allocator);

    const base_bytes = try codec.encodeMessage(&base);
    defer allocator.free(base_bytes);
    var base_decoded = try codec.decodeMessage(base_bytes);
    defer base_decoded.deinit(allocator);

    const insert_ops = try allocator.alloc(twilic.model.PatchOperation, 1);
    insert_ops[0] = .{
        .field_id = 2,
        .opcode = .InsertField,
        .value = try singleEntryMapValue(allocator, "role", .{ .String = try allocator.dupe(u8, "admin") }),
    };
    var insert_patch = twilic.Message{ .StatePatch = .{
        .base_ref = .{ .Previous = {} },
        .operations = insert_ops,
        .literals = try allocator.alloc(twilic.Value, 0),
    } };
    defer insert_patch.deinit(allocator);

    const insert_bytes = try codec.encodeMessage(&insert_patch);
    defer allocator.free(insert_bytes);
    var insert_decoded = try codec.decodeMessage(insert_bytes);
    defer insert_decoded.deinit(allocator);
    try std.testing.expect(insert_decoded == .StatePatch);

    try std.testing.expect(codec.state.previous_message != null);
    const inserted = codec.state.previous_message.?;
    try std.testing.expect(inserted == .Map);
    try std.testing.expectEqual(@as(usize, 3), inserted.Map.len);

    const delete_ops = try allocator.alloc(twilic.model.PatchOperation, 1);
    delete_ops[0] = .{ .field_id = 2, .opcode = .DeleteField, .value = null };
    var delete_patch = twilic.Message{ .StatePatch = .{
        .base_ref = .{ .Previous = {} },
        .operations = delete_ops,
        .literals = try allocator.alloc(twilic.Value, 0),
    } };
    defer delete_patch.deinit(allocator);

    const delete_bytes = try codec.encodeMessage(&delete_patch);
    defer allocator.free(delete_bytes);
    var delete_decoded = try codec.decodeMessage(delete_bytes);
    defer delete_decoded.deinit(allocator);
    try std.testing.expect(delete_decoded == .StatePatch);

    try std.testing.expect(codec.state.previous_message != null);
    const deleted = codec.state.previous_message.?;
    try std.testing.expect(deleted == .Map);
    try std.testing.expectEqual(@as(usize, 2), deleted.Map.len);
}

test "encode bound stream roundtrips and creates bound stream" {
    const allocator = std.testing.allocator;
    var schema = try userSchema(allocator);
    defer schema.deinit(allocator);

    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    var value = try userMapValue(allocator, 1005, "alice", "admin");
    defer value.deinit(allocator);
    var value2 = try userMapValue(allocator, 1006, "bob", "user");
    defer value2.deinit(allocator);

    const values = [_]twilic.Value{ value, value2 };
    const bytes = try enc.encodeBoundStream(schema, &values);
    defer allocator.free(bytes);

    var msg = try enc.decodeMessage(bytes);
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .BoundStream);
    try std.testing.expectEqual(@as(u64, 41), msg.BoundStream.schema_id);
    try std.testing.expectEqual(@as(usize, 2), msg.BoundStream.records.len);
    try std.testing.expectEqual(@as(u8, @intFromEnum(twilic.model.PresenceStrategy.Normal)), @intFromEnum(msg.BoundStream.presence_strategy));
    try std.testing.expectEqual(@as(usize, 2), msg.BoundStream.records[0].fields.len);
}

test "encode batch with schema roundtrips" {
    const allocator = std.testing.allocator;
    var schema = try userSchema(allocator);
    defer schema.deinit(allocator);

    var enc = twilic.SessionEncoder.init(allocator, .{});
    defer enc.deinit();

    var value = try userMapValue(allocator, 1005, "alice", "admin");
    defer value.deinit(allocator);
    var value2 = try userMapValue(allocator, 1006, "bob", "user");
    defer value2.deinit(allocator);

    const values = [_]twilic.Value{ value, value2 };
    const bytes = try enc.encodeBatchWithSchema(schema, &values);
    defer allocator.free(bytes);

    var msg = try enc.decodeMessage(bytes);
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .SchemaBatch);
    try std.testing.expectEqual(@as(u64, 41), msg.SchemaBatch.schema_id);
    try std.testing.expectEqual(@as(u64, 2), msg.SchemaBatch.count);
}

test "encode bound stream public api roundtrips" {
    const allocator = std.testing.allocator;
    var schema = try userSchema(allocator);
    defer schema.deinit(allocator);

    var value = try userMapValue(allocator, 1005, "alice", "admin");
    defer value.deinit(allocator);
    var value2 = try userMapValue(allocator, 1006, "bob", "user");
    defer value2.deinit(allocator);

    const values = [_]twilic.Value{ value, value2 };
    const bytes = try twilic.encodeBoundStream(allocator, schema, &values);
    defer allocator.free(bytes);

    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();
    try codec.state.schemas.put(allocator, schema.schema_id, try schema.clone(allocator));

    var msg = try codec.decodeMessage(bytes);
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .BoundStream);
    try std.testing.expectEqual(@as(usize, 2), msg.BoundStream.records.len);
}

test "encode batch with schema public api roundtrips" {
    const allocator = std.testing.allocator;
    var schema = try userSchema(allocator);
    defer schema.deinit(allocator);

    var value = try userMapValue(allocator, 1005, "alice", "admin");
    defer value.deinit(allocator);
    var value2 = try userMapValue(allocator, 1006, "bob", "user");
    defer value2.deinit(allocator);

    const values = [_]twilic.Value{ value, value2 };
    const bytes = try twilic.encodeBatchWithSchema(allocator, schema, &values);
    defer allocator.free(bytes);

    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();
    try codec.state.schemas.put(allocator, schema.schema_id, try schema.clone(allocator));

    var msg = try codec.decodeMessage(bytes);
    defer msg.deinit(allocator);
    try std.testing.expect(msg == .SchemaBatch);
    try std.testing.expectEqual(@as(u64, 2), msg.SchemaBatch.count);
}

test "base snapshot roundtrips and registers by id" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    const payload = try allocator.create(twilic.Message);
    payload.* = .{ .Scalar = .{ .I64 = 42 } };
    var msg = twilic.Message{ .BaseSnapshot = .{ .base_id = 77, .schema_or_shape_ref = 0, .payload = payload } };
    defer msg.deinit(allocator);

    const bytes = try codec.encodeMessage(&msg);
    defer allocator.free(bytes);
    var decoded = try codec.decodeMessage(bytes);
    defer decoded.deinit(allocator);
    try std.testing.expect(twilic.model.Message.eql(decoded, msg));

    const registered = codec.state.getBaseSnapshot(77);
    try std.testing.expect(registered != null);
    try std.testing.expect(registered.?.* == .Scalar);
}

fn userMapValue(allocator: std.mem.Allocator, id: u64, name: []const u8, role: []const u8) !twilic.Value {
    var entries = try allocator.alloc(twilic.model.ValueMapEntry, 3);
    entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = id } };
    entries[1] = .{ .key = try allocator.dupe(u8, "name"), .value = .{ .String = try allocator.dupe(u8, name) } };
    entries[2] = .{ .key = try allocator.dupe(u8, "role"), .value = .{ .String = try allocator.dupe(u8, role) } };
    return .{ .Map = entries };
}

fn idNameMapValue(allocator: std.mem.Allocator, id: u64, name: []const u8) !twilic.Value {
    var entries = try allocator.alloc(twilic.model.ValueMapEntry, 2);
    entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = id } };
    entries[1] = .{ .key = try allocator.dupe(u8, "name"), .value = .{ .String = try allocator.dupe(u8, name) } };
    return .{ .Map = entries };
}

fn cloneValuesForTest(values: []const twilic.Value, allocator: std.mem.Allocator) ![]twilic.Value {
    const out = try allocator.alloc(twilic.Value, values.len);
    for (values, 0..) |value, idx| {
        out[idx] = try value.clone(allocator);
    }
    return out;
}

fn singleEntryMapValue(allocator: std.mem.Allocator, key: []const u8, value: twilic.Value) !twilic.Value {
    const entries = try allocator.alloc(twilic.model.ValueMapEntry, 1);
    entries[0] = .{ .key = try allocator.dupe(u8, key), .value = value };
    return .{ .Map = entries };
}

fn makeUserRows(allocator: std.mem.Allocator, names: []const []const u8) ![]twilic.Value {
    const rows = try allocator.alloc(twilic.Value, names.len);
    for (names, 0..) |name, idx| {
        var entries = try allocator.alloc(twilic.model.ValueMapEntry, 2);
        entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = @intCast(idx + 1) } };
        entries[1] = .{ .key = try allocator.dupe(u8, "name"), .value = .{ .String = try allocator.dupe(u8, name) } };
        rows[idx] = .{ .Map = entries };
    }
    return rows;
}

fn encodedControlStreamLen(allocator: std.mem.Allocator, stream_codec: twilic.model.ControlStreamCodec, payload: []const u8) !usize {
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();

    var msg = twilic.Message{ .ControlStream = .{ .codec = stream_codec, .payload = try allocator.dupe(u8, payload) } };
    defer msg.deinit(allocator);
    const bytes = try codec.encodeMessage(&msg);
    defer allocator.free(bytes);
    return bytes.len;
}

fn scalarStringMode(bytes: []const u8) u8 {
    return bytes[2];
}

fn unknownKeyMapBytes(allocator: std.mem.Allocator, key_id: u64) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    try out.append(@intFromEnum(twilic.model.MessageKind.Map));
    try twilic.wire.encodeVaruint(1, &out);
    try out.append(1);
    try twilic.wire.encodeVaruint(key_id, &out);
    try out.append(0);

    return out.toOwnedSlice();
}

fn userSchema(allocator: std.mem.Allocator) !twilic.Schema {
    var fields = try allocator.alloc(twilic.model.SchemaField, 3);
    fields[0] = .{
        .number = 1,
        .name = try allocator.dupe(u8, "id"),
        .logical_type = try allocator.dupe(u8, "u64"),
        .physical_encoding = .Auto,
        .required = true,
        .default_value = null,
        .min = 1000,
        .max = 1100,
        .enum_values = try allocator.alloc([]u8, 0),
    };
    fields[1] = .{
        .number = 2,
        .name = try allocator.dupe(u8, "name"),
        .logical_type = try allocator.dupe(u8, "string"),
        .physical_encoding = .Auto,
        .required = true,
        .default_value = null,
        .min = null,
        .max = null,
        .enum_values = try allocator.alloc([]u8, 0),
    };
    fields[2] = .{
        .number = 3,
        .name = try allocator.dupe(u8, "score"),
        .logical_type = try allocator.dupe(u8, "i64"),
        .physical_encoding = .Auto,
        .required = false,
        .default_value = null,
        .min = 0,
        .max = 100,
        .enum_values = try allocator.alloc([]u8, 0),
    };

    return .{
        .schema_id = 41,
        .name = try allocator.dupe(u8, "User"),
        .fields = fields,
    };
}

fn makeIdRows(allocator: std.mem.Allocator, count: usize) ![]twilic.Value {
    const out = try allocator.alloc(twilic.Value, count);
    for (out, 0..) |*slot, idx| {
        var entries = try allocator.alloc(twilic.model.ValueMapEntry, 1);
        entries[0] = .{
            .key = try allocator.dupe(u8, "id"),
            .value = .{ .U64 = @intCast(idx) },
        };
        slot.* = .{ .Map = entries };
    }
    return out;
}

fn freeValues(values: []twilic.Value, allocator: std.mem.Allocator) void {
    for (values) |*value| {
        value.deinit(allocator);
    }
    allocator.free(values);
}

test "nested session input returns an error and decoding remains usable" {
    const allocator = std.testing.allocator;
    var codec = twilic.TwilicCodec.init(allocator, .{});
    defer codec.deinit();
    var bytes = [_]u8{0} ** 142;
    for (0..70) |i| {
        bytes[1 + i * 2] = 8;
        bytes[2 + i * 2] = 1;
    }
    try std.testing.expectError(twilic.TwilicError.InvalidData, codec.decodeMessage(&bytes));
    var message = try codec.decodeMessage(&.{ 0, 0 });
    defer message.deinit(allocator);
    try std.testing.expect(message == .Scalar);
}
