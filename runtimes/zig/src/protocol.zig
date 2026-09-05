const std = @import("std");

const codec = @import("codec.zig");
const TwilicError = @import("error.zig").TwilicError;
const model = @import("model.zig");
const session = @import("session.zig");
const wire = @import("wire.zig");

const Allocator = std.mem.Allocator;
const Reader = wire.Reader;

const Value = model.Value;
const ValueMapEntry = model.ValueMapEntry;
const KeyRef = model.KeyRef;
const MapEntry = model.MapEntry;
const Message = model.Message;
const MessageKind = model.MessageKind;
const Schema = model.Schema;
const TypedVector = model.TypedVector;
const TypedVectorData = model.TypedVectorData;
const ElementType = model.ElementType;
const VectorCodec = model.VectorCodec;
const Column = model.Column;
const NullStrategy = model.NullStrategy;
const ControlMessage = model.ControlMessage;
const ControlOpcode = model.ControlOpcode;
const ControlStreamCodec = model.ControlStreamCodec;
const StringMode = model.StringMode;
const BaseRef = model.BaseRef;
const PresenceStrategy = model.PresenceStrategy;
const BoundRecord = model.BoundRecord;
const PatchOpcode = model.PatchOpcode;
const PatchOperation = model.PatchOperation;
const TemplateDescriptor = model.TemplateDescriptor;

const SessionOptions = session.SessionOptions;
const SessionState = session.SessionState;
const UnknownReferencePolicy = session.UnknownReferencePolicy;

const TAG_NULL: u8 = 0;
const TAG_BOOL_FALSE: u8 = 1;
const TAG_BOOL_TRUE: u8 = 2;
const TAG_I64: u8 = 3;
const TAG_U64: u8 = 4;
const TAG_F64: u8 = 5;
const TAG_STRING: u8 = 6;
const TAG_BINARY: u8 = 7;
const TAG_ARRAY: u8 = 8;
const TAG_MAP: u8 = 9;

const PrefixBase = struct {
    base_id: u64,
    prefix_len: usize,
};

pub const TwilicCodec = struct {
    allocator: Allocator,
    state: SessionState,

    pub fn init(allocator: Allocator, options: SessionOptions) TwilicCodec {
        return .{
            .allocator = allocator,
            .state = SessionState.init(allocator, options),
        };
    }

    pub fn withOptions(allocator: Allocator, options: SessionOptions) TwilicCodec {
        return init(allocator, options);
    }

    pub fn deinit(self: *TwilicCodec) void {
        self.state.deinit();
    }

    pub fn encodeMessage(self: *TwilicCodec, message: *const Message) ![]u8 {
        var out = std.array_list.Managed(u8).init(self.allocator);
        errdefer out.deinit();
        try self.writeMessage(message, &out);
        return out.toOwnedSlice();
    }

    pub fn decodeMessage(self: *TwilicCodec, bytes: []const u8) !Message {
        var reader = Reader.init(bytes);
        var msg = try self.readMessage(&reader);
        if (!reader.isEof()) {
            msg.deinit(self.allocator);
            return TwilicError.InvalidData;
        }
        switch (msg) {
            .Control => {},
            .StatePatch => |patch| {
                if (try applyStatePatch(self, patch.base_ref, patch.operations, patch.literals)) |reconstructed| {
                    var reconstructed_msg = reconstructed;
                    defer reconstructed_msg.deinit(self.allocator);
                    try self.setPreviousMessage(reconstructed_msg);
                }
            },
            .TemplateBatch => {
                if (self.state.previous_message == null) {
                    try self.setPreviousMessage(msg);
                }
            },
            else => {
                try self.setPreviousMessage(msg);
            },
        }
        return msg;
    }

    pub fn encodeValue(self: *TwilicCodec, value: *const Value) ![]u8 {
        var message = try self.messageForValue(value);
        defer message.deinit(self.allocator);
        const bytes = try self.encodeMessage(&message);
        try self.setPreviousMessage(message);
        return bytes;
    }

    pub fn decodeValue(self: *TwilicCodec, bytes: []const u8) !Value {
        var message = try self.decodeMessage(bytes);
        defer message.deinit(self.allocator);
        return switch (message) {
            .Scalar => |value| try value.clone(self.allocator),
            .Array => |values| .{ .Array = try cloneValues(values, self.allocator) },
            .Map => |entries| .{ .Map = try entriesToMap(entries, self) },
            .ShapedObject => |shaped| blk: {
                const keys = self.state.shape_table.getKeys(shaped.shape_id) orelse return self.referenceError();
                break :blk .{ .Map = try shapeValuesToMap(keys, shaped.presence, shaped.values, self.allocator) };
            },
            .TypedVector => |vector| try typedVectorToValue(vector, self.allocator),
            .SchemaBatch => TwilicError.InvalidData,
            .BoundStream => TwilicError.InvalidData,
            else => TwilicError.InvalidData,
        };
    }

    fn setPreviousMessage(self: *TwilicCodec, message: Message) !void {
        if (self.state.previous_message) |*previous| {
            previous.deinit(self.allocator);
        }
        self.state.previous_message = try message.clone(self.allocator);
    }

    fn referenceError(self: *const TwilicCodec) TwilicError {
        return switch (self.state.options.unknown_reference_policy) {
            .FailFast => TwilicError.UnknownReference,
            .StatelessRetry => TwilicError.StatelessRetryRequired,
        };
    }

    fn messageForValue(self: *TwilicCodec, value: *const Value) !Message {
        return switch (value.*) {
            .Array => |items| blk: {
                if (try self.tryMakeTypedVector(items)) |vector| {
                    break :blk .{ .TypedVector = vector };
                }
                break :blk .{ .Array = try cloneValues(items, self.allocator) };
            },
            .Map => |entries| blk: {
                const keys = try collectMapKeys(entries, self.allocator);
                defer self.allocator.free(keys);
                const had_observation = try self.hasEncodeShapeObservation(keys);
                const observed = try self.observeEncodeShapeCandidate(keys);
                if (try self.state.shape_table.getId(self.allocator, keys)) |shape_id| {
                    if (!had_observation or observed >= 2) {
                        break :blk try self.shapedMessage(shape_id, entries);
                    }
                }
                break :blk try self.mapMessage(entries);
            },
            else => .{ .Scalar = try value.clone(self.allocator) },
        };
    }

    fn hasEncodeShapeObservation(self: *TwilicCodec, keys: []const []const u8) !bool {
        const fingerprint = try shapeFingerprintOwned(self.allocator, keys);
        defer self.allocator.free(fingerprint);
        return self.state.encode_shape_observations.contains(fingerprint);
    }

    fn observeEncodeShapeCandidate(self: *TwilicCodec, keys: []const []const u8) !u64 {
        const fingerprint = try shapeFingerprintOwned(self.allocator, keys);
        defer self.allocator.free(fingerprint);

        var observed: u64 = 1;
        if (self.state.encode_shape_observations.getPtr(fingerprint)) |count| {
            count.* += 1;
            observed = count.*;
        } else {
            const owned = try self.allocator.dupe(u8, fingerprint);
            errdefer self.allocator.free(owned);
            try self.state.encode_shape_observations.put(self.allocator, owned, 1);
            observed = 1;
        }

        if ((try self.state.shape_table.getId(self.allocator, keys)) == null and shouldRegisterShape(keys, observed)) {
            _ = try self.state.shape_table.register(self.allocator, keys);
        }
        return observed;
    }

    fn observeDecodeShapeCandidate(self: *TwilicCodec, keys: []const []const u8) !void {
        if ((try self.state.shape_table.getId(self.allocator, keys)) != null) {
            return;
        }
        const observed = try self.state.shape_table.observe(self.allocator, keys);
        if (shouldRegisterShape(keys, observed)) {
            _ = try self.state.shape_table.register(self.allocator, keys);
        }
    }

    fn mapMessage(self: *TwilicCodec, entries: []const ValueMapEntry) !Message {
        const map_entries = try self.allocator.alloc(MapEntry, entries.len);
        errdefer self.allocator.free(map_entries);
        for (entries, 0..) |entry, idx| {
            const key_ref: KeyRef = if (self.state.key_table.getId(entry.key)) |id|
                .{ .Id = id }
            else blk: {
                _ = try self.state.key_table.register(self.allocator, entry.key);
                break :blk .{ .Literal = try self.allocator.dupe(u8, entry.key) };
            };
            map_entries[idx] = .{
                .key = key_ref,
                .value = try entry.value.clone(self.allocator),
            };
        }
        return .{ .Map = map_entries };
    }

    fn shapedMessage(self: *TwilicCodec, shape_id: u64, entries: []const ValueMapEntry) !Message {
        const keys = self.state.shape_table.getKeys(shape_id) orelse &[_][]u8{};
        var values = std.array_list.Managed(Value).init(self.allocator);
        errdefer {
            for (values.items) |*value| {
                value.deinit(self.allocator);
            }
            values.deinit();
        }
        var presence = std.array_list.Managed(bool).init(self.allocator);
        defer presence.deinit();

        for (keys) |key| {
            if (findMapField(entries, key)) |value| {
                try presence.append(true);
                try values.append(try value.clone(self.allocator));
            } else {
                try presence.append(false);
            }
        }

        const has_absent = blk: {
            for (presence.items) |bit| {
                if (!bit) break :blk true;
            }
            break :blk false;
        };
        return .{ .ShapedObject = .{
            .shape_id = shape_id,
            .presence = if (has_absent) try self.allocator.dupe(bool, presence.items) else null,
            .values = try values.toOwnedSlice(),
        } };
    }

    fn tryMakeTypedVector(self: *TwilicCodec, values: []const Value) !?TypedVector {
        if (values.len < 4) return null;

        if (allValuesOfType(values, .Bool)) {
            const out = try self.allocator.alloc(bool, values.len);
            for (values, 0..) |value, idx| out[idx] = value.Bool;
            return .{
                .element_type = .Bool,
                .codec = .DirectBitpack,
                .data = .{ .Bool = out },
            };
        }
        if (allValuesOfType(values, .I64)) {
            const out = try self.allocator.alloc(i64, values.len);
            for (values, 0..) |value, idx| out[idx] = value.I64;
            return .{
                .element_type = .I64,
                .codec = selectIntegerCodec(out),
                .data = .{ .I64 = out },
            };
        }
        if (allValuesOfType(values, .U64)) {
            const out = try self.allocator.alloc(u64, values.len);
            for (values, 0..) |value, idx| out[idx] = value.U64;
            return .{
                .element_type = .U64,
                .codec = selectU64Codec(out),
                .data = .{ .U64 = out },
            };
        }
        if (allValuesOfType(values, .F64)) {
            const out = try self.allocator.alloc(f64, values.len);
            for (values, 0..) |value, idx| out[idx] = value.F64;
            return .{
                .element_type = .F64,
                .codec = selectFloatCodec(out),
                .data = .{ .F64 = out },
            };
        }
        if (allValuesOfType(values, .String)) {
            const out = try self.allocator.alloc([]u8, values.len);
            errdefer {
                for (out[0..]) |str| self.allocator.free(str);
                self.allocator.free(out);
            }
            for (values, 0..) |value, idx| {
                out[idx] = try self.allocator.dupe(u8, value.String);
            }
            return .{
                .element_type = .String,
                .codec = selectStringCodec(out),
                .data = .{ .String = out },
            };
        }
        return null;
    }

    fn writeMessage(self: *TwilicCodec, message: *const Message, out: *std.array_list.Managed(u8)) !void {
        switch (message.*) {
            .Scalar => |value| {
                try out.append(@intFromEnum(MessageKind.Scalar));
                try self.writeValue(&value, null, out);
            },
            .Array => |values| {
                try out.append(@intFromEnum(MessageKind.Array));
                try wire.encodeVaruint(values.len, out);
                for (values) |value| {
                    try self.writeValue(&value, null, out);
                }
            },
            .Map => |entries| {
                try out.append(@intFromEnum(MessageKind.Map));
                try wire.encodeVaruint(entries.len, out);
                for (entries) |entry| {
                    try self.writeKeyRef(&entry.key, out);
                    const field_identity = switch (entry.key) {
                        .Literal => |v| v,
                        .Id => |id| self.state.key_table.getValue(id),
                    };
                    try self.writeValue(&entry.value, field_identity, out);
                }
            },
            .ShapedObject => |shaped| {
                try out.append(@intFromEnum(MessageKind.ShapedObject));
                try wire.encodeVaruint(shaped.shape_id, out);
                try self.writePresence(shaped.presence, out);
                try wire.encodeVaruint(shaped.values.len, out);
                if (self.state.shape_table.getKeys(shaped.shape_id)) |keys| {
                    const presence_bits = shaped.presence orelse blk: {
                        const bits = try self.allocator.alloc(bool, keys.len);
                        defer self.allocator.free(bits);
                        @memset(bits, true);
                        break :blk bits;
                    };
                    var value_idx: usize = 0;
                    for (keys, 0..) |key, idx| {
                        const present = if (idx < presence_bits.len) presence_bits[idx] else true;
                        if (!present) continue;
                        if (value_idx < shaped.values.len) {
                            try self.writeValue(&shaped.values[value_idx], key, out);
                            value_idx += 1;
                        }
                    }
                    while (value_idx < shaped.values.len) : (value_idx += 1) {
                        try self.writeValue(&shaped.values[value_idx], null, out);
                    }
                } else {
                    for (shaped.values) |value| {
                        try self.writeValue(&value, null, out);
                    }
                }
            },
            .SchemaObject => |schema_obj| {
                try out.append(@intFromEnum(MessageKind.SchemaObject));
                var effective_schema_id: ?u64 = null;
                if (schema_obj.schema_id) |schema_id| {
                    try out.append(1);
                    try wire.encodeVaruint(schema_id, out);
                    effective_schema_id = schema_id;
                } else {
                    try out.append(0);
                }
                try self.writePresence(schema_obj.presence, out);
                try wire.encodeVaruint(schema_obj.fields.len, out);
                const schema_id = effective_schema_id orelse self.state.last_schema_id;
                if (schema_id) |sid| {
                    if (self.state.schemas.getPtr(sid)) |schema_ptr| {
                        try self.writeSchemaFields(schema_ptr.*, schema_obj.presence, schema_obj.fields, out);
                        self.state.last_schema_id = sid;
                    } else {
                        for (schema_obj.fields) |value| {
                            try self.writeValue(&value, null, out);
                        }
                    }
                } else {
                    for (schema_obj.fields) |value| {
                        try self.writeValue(&value, null, out);
                    }
                }
            },
            .TypedVector => |vector| {
                try out.append(@intFromEnum(MessageKind.TypedVector));
                try self.writeTypedVector(&vector, out);
            },
            .RowBatch => |batch| {
                try out.append(@intFromEnum(MessageKind.RowBatch));
                try wire.encodeVaruint(batch.rows.len, out);
                for (batch.rows) |row| {
                    try wire.encodeVaruint(row.len, out);
                    for (row) |value| {
                        try self.writeValue(&value, null, out);
                    }
                }
            },
            .ColumnBatch => |batch| {
                try out.append(@intFromEnum(MessageKind.ColumnBatch));
                try wire.encodeVaruint(batch.count, out);
                try wire.encodeVaruint(batch.columns.len, out);
                for (batch.columns) |column| {
                    try self.writeColumn(&column, out);
                }
            },
            .SchemaBatch => |batch| {
                try out.append(@intFromEnum(MessageKind.SchemaBatch));
                try wire.encodeVaruint(batch.schema_id, out);
                try wire.encodeVaruint(batch.count, out);
                try wire.encodeVaruint(batch.columns.len, out);
                for (batch.columns) |column| {
                    try self.writeSchemaBatchColumn(&column, batch.count, out);
                }
            },
            .BoundStream => |stream| {
                try out.append(@intFromEnum(MessageKind.BoundStream));
                try wire.encodeVaruint(stream.schema_id, out);
                try wire.encodeVaruint(stream.records.len, out);
                try out.append(@intFromEnum(stream.presence_strategy));
                const schema = self.state.schemas.getPtr(stream.schema_id) orelse return self.referenceError();
                for (stream.records) |record| {
                    try self.writeBoundRecord(schema.*, stream.presence_strategy, &record, out);
                }
            },
            .Control => |control| {
                try out.append(@intFromEnum(MessageKind.Control));
                try self.writeControl(&control, out);
            },
            .Ext => |ext| {
                try out.append(@intFromEnum(MessageKind.Ext));
                try wire.encodeVaruint(ext.ext_type, out);
                try wire.encodeBytes(ext.payload, out);
            },
            .StatePatch => |patch| {
                try out.append(@intFromEnum(MessageKind.StatePatch));
                try writeBaseRef(self, patch.base_ref, out);
                try wire.encodeVaruint(patch.operations.len, out);
                for (patch.operations) |operation| {
                    try wire.encodeVaruint(operation.field_id, out);
                    try out.append(@intFromEnum(operation.opcode));
                    if (operation.value) |value| {
                        try out.append(1);
                        try self.writeValue(&value, null, out);
                    } else {
                        try out.append(0);
                    }
                }
                try wire.encodeVaruint(patch.literals.len, out);
                for (patch.literals) |value| {
                    try self.writeValue(&value, null, out);
                }
            },
            .TemplateBatch => |batch| {
                try out.append(@intFromEnum(MessageKind.TemplateBatch));
                try wire.encodeVaruint(batch.template_id, out);
                try wire.encodeVaruint(batch.count, out);
                try wire.encodeBitmap(batch.changed_column_mask, out);
                try wire.encodeVaruint(batch.columns.len, out);
                for (batch.columns) |column| {
                    try self.writeColumn(&column, out);
                }
            },
            .ControlStream => |stream| {
                try out.append(@intFromEnum(MessageKind.ControlStream));
                try out.append(@intFromEnum(stream.codec));
                try writeControlStreamPayload(self, stream.codec, stream.payload, out);
            },
            .BaseSnapshot => |snapshot| {
                try out.append(@intFromEnum(MessageKind.BaseSnapshot));
                try wire.encodeVaruint(snapshot.base_id, out);
                try wire.encodeVaruint(snapshot.schema_or_shape_ref, out);
                try self.writeMessage(snapshot.payload, out);
                try self.state.registerBaseSnapshot(snapshot.base_id, try snapshot.payload.clone(self.allocator));
            },
        }
    }

    fn readMessage(self: *TwilicCodec, reader: *Reader) !Message {
        try reader.enterDepth();
        defer reader.leaveDepth();
        const kind_byte = try reader.readU8();
        const kind = MessageKind.fromByte(kind_byte) orelse return TwilicError.InvalidKind;
        return switch (kind) {
            .Scalar => .{ .Scalar = try self.readValue(reader, null) },
            .Array => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc(Value, len);
                errdefer self.allocator.free(values);
                for (values) |*value| {
                    value.* = try self.readValue(reader, null);
                }
                break :blk .{ .Array = values };
            },
            .Map => blk: {
                const len = try readCount(reader);
                const entries = try self.allocator.alloc(MapEntry, len);
                errdefer self.allocator.free(entries);

                var keys = std.array_list.Managed([]const u8).init(self.allocator);
                defer keys.deinit();

                var idx: usize = 0;
                while (idx < len) : (idx += 1) {
                    const key_ref = try self.readKeyRef(reader);
                    const field_identity = switch (key_ref) {
                        .Literal => |key| key,
                        .Id => |id| self.state.key_table.getValue(id) orelse return self.referenceError(),
                    };
                    const value = try self.readValue(reader, field_identity);
                    entries[idx] = .{ .key = key_ref, .value = value };

                    switch (entries[idx].key) {
                        .Literal => |key| try keys.append(key),
                        .Id => |id| {
                            if (self.state.key_table.getValue(id)) |key| {
                                try keys.append(key);
                            }
                        },
                    }
                }
                if (keys.items.len == len) {
                    const key_views = try self.allocator.alloc([]const u8, keys.items.len);
                    defer self.allocator.free(key_views);
                    for (keys.items, 0..) |key, key_idx| key_views[key_idx] = key;
                    try self.observeDecodeShapeCandidate(key_views);
                }
                break :blk .{ .Map = entries };
            },
            .ShapedObject => blk: {
                const shape_id = try reader.readVaruint();
                const presence = try self.readPresence(reader);
                const len = try readCount(reader);
                const values = try self.allocator.alloc(Value, len);
                errdefer self.allocator.free(values);

                if (self.state.shape_table.getKeys(shape_id)) |keys| {
                    const presence_bits = presence orelse blk2: {
                        const bits = try self.allocator.alloc(bool, keys.len);
                        @memset(bits, true);
                        break :blk2 bits;
                    };
                    defer if (presence == null) self.allocator.free(presence_bits);
                    var value_idx: usize = 0;
                    for (keys, 0..) |key, idx| {
                        if (value_idx >= len) break;
                        const present = if (idx < presence_bits.len) presence_bits[idx] else true;
                        if (!present) continue;
                        values[value_idx] = try self.readValue(reader, key);
                        value_idx += 1;
                    }
                    while (value_idx < len) : (value_idx += 1) {
                        values[value_idx] = try self.readValue(reader, null);
                    }
                } else {
                    for (values) |*value| {
                        value.* = try self.readValue(reader, null);
                    }
                }

                break :blk .{ .ShapedObject = .{
                    .shape_id = shape_id,
                    .presence = presence,
                    .values = values,
                } };
            },
            .SchemaObject => blk: {
                const has_schema = try reader.readU8();
                const schema_id: ?u64 = switch (has_schema) {
                    0 => null,
                    1 => try reader.readVaruint(),
                    else => return TwilicError.InvalidData,
                };
                const presence = try self.readPresence(reader);
                const len = try readCount(reader);

                const fields = try self.allocator.alloc(Value, len);
                errdefer self.allocator.free(fields);

                const effective_schema_id = schema_id orelse self.state.last_schema_id;
                if (effective_schema_id) |sid| {
                    if (self.state.schemas.getPtr(sid)) |schema_ptr| {
                        try self.readSchemaFields(schema_ptr.*, presence, len, reader, fields);
                        self.state.last_schema_id = sid;
                    } else {
                        for (fields) |*field| {
                            field.* = try self.readValue(reader, null);
                        }
                        if (schema_id) |id| self.state.last_schema_id = id;
                    }
                } else {
                    for (fields) |*field| {
                        field.* = try self.readValue(reader, null);
                    }
                    if (schema_id) |id| self.state.last_schema_id = id;
                }

                break :blk .{ .SchemaObject = .{
                    .schema_id = schema_id,
                    .presence = presence,
                    .fields = fields,
                } };
            },
            .TypedVector => .{ .TypedVector = try self.readTypedVector(reader, null) },
            .RowBatch => blk: {
                const row_count = try readCount(reader);
                const rows = try self.allocator.alloc([]Value, row_count);
                errdefer self.allocator.free(rows);
                for (rows) |*row| {
                    const field_count = try readCount(reader);
                    row.* = try self.allocator.alloc(Value, field_count);
                    for (row.*) |*value| {
                        value.* = try self.readValue(reader, null);
                    }
                }
                break :blk .{ .RowBatch = .{ .rows = rows } };
            },
            .ColumnBatch => blk: {
                const count = try reader.readCount();
                const column_count = try readCount(reader);
                const columns = try self.allocator.alloc(Column, column_count);
                errdefer self.allocator.free(columns);
                for (columns) |*column| {
                    column.* = try self.readColumn(reader);
                }
                break :blk .{ .ColumnBatch = .{ .count = count, .columns = columns } };
            },
            .SchemaBatch => blk: {
                const schema_id = try reader.readVaruint();
                const count = try reader.readCount();
                const column_count = try readCount(reader);
                const columns = try self.allocator.alloc(Column, column_count);
                errdefer self.allocator.free(columns);
                const schema = self.state.schemas.getPtr(schema_id);
                for (columns, 0..) |*column, idx| {
                    const field_id = if (schema) |s|
                        if (idx < s.fields.len) s.fields[idx].number else @as(u64, @intCast(idx))
                    else
                        @as(u64, @intCast(idx));
                    column.* = try self.readSchemaBatchColumn(field_id, count, reader);
                }
                break :blk .{ .SchemaBatch = .{ .schema_id = schema_id, .count = count, .columns = columns } };
            },
            .BoundStream => blk: {
                const schema_id = try reader.readVaruint();
                const record_count = try readCount(reader);
                const presence_strategy = PresenceStrategy.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
                const schema = self.state.schemas.getPtr(schema_id) orelse return self.referenceError();
                const records = try self.allocator.alloc(BoundRecord, record_count);
                errdefer self.allocator.free(records);
                for (records) |*record| {
                    record.* = try self.readBoundRecord(schema.*, presence_strategy, reader);
                }
                break :blk .{ .BoundStream = .{ .schema_id = schema_id, .presence_strategy = presence_strategy, .records = records } };
            },
            .Control => .{ .Control = try self.readControl(reader) },
            .Ext => .{ .Ext = .{
                .ext_type = try reader.readVaruint(),
                .payload = try reader.readBytes(self.allocator),
            } },
            .StatePatch => blk: {
                const base_ref = try readBaseRef(self, reader);
                const len = try readCount(reader);
                const operations = try self.allocator.alloc(PatchOperation, len);
                errdefer self.allocator.free(operations);
                for (operations) |*operation| {
                    const field_id = try reader.readVaruint();
                    const opcode = PatchOpcode.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
                    const has_value = try reader.readU8();
                    operation.* = .{
                        .field_id = field_id,
                        .opcode = opcode,
                        .value = if (has_value == 1) try self.readValue(reader, null) else null,
                    };
                }
                const lit_len = try readCount(reader);
                const literals = try self.allocator.alloc(Value, lit_len);
                errdefer self.allocator.free(literals);
                for (literals) |*literal| {
                    literal.* = try self.readValue(reader, null);
                }
                break :blk .{ .StatePatch = .{
                    .base_ref = base_ref,
                    .operations = operations,
                    .literals = literals,
                } };
            },
            .TemplateBatch => blk: {
                const template_id = try reader.readVaruint();
                const count = try reader.readCount();
                const changed_column_mask = try reader.readBitmap(self.allocator);
                errdefer self.allocator.free(changed_column_mask);
                const changed_len = try readCount(reader);
                const changed_columns = try self.allocator.alloc(Column, changed_len);
                errdefer self.allocator.free(changed_columns);
                for (changed_columns) |*column| {
                    column.* = try self.readColumn(reader);
                }

                const full_columns = if (self.state.template_columns.get(template_id)) |previous|
                    try mergeTemplateColumns(previous, changed_column_mask, changed_columns, self.allocator)
                else blk2: {
                    for (changed_column_mask) |bit| {
                        if (!bit) return self.referenceError();
                    }
                    break :blk2 try cloneColumns(changed_columns, self.allocator);
                };
                defer {
                    for (full_columns) |*column| {
                        column.deinit(self.allocator);
                    }
                    self.allocator.free(full_columns);
                }

                try putTemplateColumns(self, template_id, full_columns);
                const descriptor = try templateDescriptorFromColumns(template_id, full_columns, self.allocator);
                try putTemplateDescriptor(self, descriptor);

                if (count >= 16) {
                    var previous = Message{ .ColumnBatch = .{ .count = count, .columns = try cloneColumns(full_columns, self.allocator) } };
                    defer previous.deinit(self.allocator);
                    try self.setPreviousMessage(previous);
                }

                break :blk .{ .TemplateBatch = .{
                    .template_id = template_id,
                    .count = count,
                    .changed_column_mask = changed_column_mask,
                    .columns = changed_columns,
                } };
            },
            .ControlStream => blk: {
                const stream_codec = ControlStreamCodec.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
                const payload = try readControlStreamPayload(self, stream_codec, reader);
                break :blk .{ .ControlStream = .{ .codec = stream_codec, .payload = payload } };
            },
            .BaseSnapshot => blk: {
                const base_id = try reader.readVaruint();
                const schema_or_shape_ref = try reader.readVaruint();
                const payload = try self.allocator.create(Message);
                errdefer self.allocator.destroy(payload);
                payload.* = try self.readMessage(reader);
                try self.state.registerBaseSnapshot(base_id, try payload.clone(self.allocator));
                break :blk .{ .BaseSnapshot = .{
                    .base_id = base_id,
                    .schema_or_shape_ref = schema_or_shape_ref,
                    .payload = payload,
                } };
            },
        };
    }

    fn writeValue(self: *TwilicCodec, value: *const Value, field_identity: ?[]const u8, out: *std.array_list.Managed(u8)) !void {
        switch (value.*) {
            .Null => try out.append(TAG_NULL),
            .Bool => |v| try out.append(if (v) TAG_BOOL_TRUE else TAG_BOOL_FALSE),
            .I64 => |v| {
                try out.append(TAG_I64);
                try writeSmallestU64(wire.encodeZigzag(v), out);
            },
            .U64 => |v| {
                try out.append(TAG_U64);
                try writeSmallestU64(v, out);
            },
            .F64 => |v| {
                try out.append(TAG_F64);
                try out.appendSlice(std.mem.asBytes(&v));
            },
            .String => |v| {
                try out.append(TAG_STRING);
                if (field_identity) |identity| {
                    if (self.state.field_enums.get(identity)) |enum_values| {
                        if (indexOfString(enum_values, v)) |code| {
                            try out.append(@intFromEnum(StringMode.InlineEnum));
                            try wire.encodeVaruint(code, out);
                            return;
                        }
                    }
                }
                if (v.len == 0) {
                    try out.append(@intFromEnum(StringMode.Empty));
                    return;
                }
                if (self.state.string_table.getId(v)) |id| {
                    try out.append(@intFromEnum(StringMode.Ref));
                    try wire.encodeVaruint(id, out);
                    return;
                }
                if (try self.bestPrefixBase(v)) |best| {
                    const suffix = v[best.prefix_len..];
                    _ = try self.state.string_table.register(self.allocator, v);
                    try out.append(@intFromEnum(StringMode.PrefixDelta));
                    try wire.encodeVaruint(best.base_id, out);
                    try wire.encodeVaruint(best.prefix_len, out);
                    try wire.encodeString(suffix, out);
                    return;
                }

                _ = try self.state.string_table.register(self.allocator, v);
                try out.append(@intFromEnum(StringMode.Literal));
                try wire.encodeString(v, out);
            },
            .Binary => |v| {
                try out.append(TAG_BINARY);
                try wire.encodeBytes(v, out);
            },
            .Array => |values| {
                try out.append(TAG_ARRAY);
                try wire.encodeVaruint(values.len, out);
                for (values) |item| {
                    try self.writeValue(&item, null, out);
                }
            },
            .Map => |entries| {
                try out.append(TAG_MAP);
                try wire.encodeVaruint(entries.len, out);
                for (entries) |entry| {
                    try wire.encodeString(entry.key, out);
                    try self.writeValue(&entry.value, entry.key, out);
                }
            },
        }
    }

    fn readValue(self: *TwilicCodec, reader: *Reader, field_identity: ?[]const u8) !Value {
        try reader.enterDepth();
        defer reader.leaveDepth();
        const tag = try reader.readU8();
        return switch (tag) {
            TAG_NULL => .{ .Null = {} },
            TAG_BOOL_FALSE => .{ .Bool = false },
            TAG_BOOL_TRUE => .{ .Bool = true },
            TAG_I64 => .{ .I64 = wire.decodeZigzag(try readSmallestU64(reader)) },
            TAG_U64 => .{ .U64 = try readSmallestU64(reader) },
            TAG_F64 => blk: {
                const bytes = try reader.readExact(8);
                break :blk .{ .F64 = std.mem.bytesToValue(f64, bytes[0..8]) };
            },
            TAG_STRING => blk: {
                const mode = StringMode.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
                switch (mode) {
                    .Empty => break :blk .{ .String = try self.allocator.alloc(u8, 0) },
                    .Literal => {
                        const str = try reader.readString(self.allocator);
                        _ = try self.state.string_table.register(self.allocator, str);
                        break :blk .{ .String = str };
                    },
                    .Ref => {
                        const id = try reader.readVaruint();
                        const value = self.state.string_table.getValue(id) orelse return self.referenceError();
                        break :blk .{ .String = try self.allocator.dupe(u8, value) };
                    },
                    .PrefixDelta => {
                        const base_id = try reader.readVaruint();
                        const prefix_len = try reader.readCount();
                        const prefix_idx = std.math.cast(usize, prefix_len) orelse return TwilicError.InvalidData;
                        const suffix = try reader.readString(self.allocator);
                        defer self.allocator.free(suffix);

                        const base = self.state.string_table.getValue(base_id) orelse return self.referenceError();
                        if (prefix_idx > base.len or !std.unicode.utf8ValidateSlice(base[0..prefix_idx])) {
                            return TwilicError.InvalidData;
                        }

                        const combined_len = try std.math.add(usize, prefix_idx, suffix.len);
                        const combined = try self.allocator.alloc(u8, combined_len);
                        errdefer self.allocator.free(combined);
                        std.mem.copyForwards(u8, combined[0..prefix_idx], base[0..prefix_idx]);
                        std.mem.copyForwards(u8, combined[prefix_idx..], suffix);
                        _ = try self.state.string_table.register(self.allocator, combined);
                        break :blk .{ .String = combined };
                    },
                    .InlineEnum => {
                        const code = try reader.readVaruint();
                        const index = std.math.cast(usize, code) orelse return TwilicError.InvalidData;
                        const identity = field_identity orelse return TwilicError.InvalidData;
                        const values = self.state.field_enums.get(identity) orelse return self.referenceError();
                        if (index >= values.len) return self.referenceError();
                        break :blk .{ .String = try self.allocator.dupe(u8, values[index]) };
                    },
                }
            },
            TAG_BINARY => .{ .Binary = try reader.readBytes(self.allocator) },
            TAG_ARRAY => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc(Value, len);
                errdefer self.allocator.free(values);
                for (values) |*item| {
                    item.* = try self.readValue(reader, null);
                }
                break :blk .{ .Array = values };
            },
            TAG_MAP => blk: {
                const len = try readCount(reader);
                const entries = try self.allocator.alloc(ValueMapEntry, len);
                errdefer self.allocator.free(entries);
                for (entries) |*entry| {
                    const key = try reader.readString(self.allocator);
                    entry.* = .{ .key = key, .value = try self.readValue(reader, key) };
                }
                break :blk .{ .Map = entries };
            },
            else => TwilicError.InvalidTag,
        };
    }

    fn writeSchemaFields(self: *TwilicCodec, schema: Schema, presence: ?[]const bool, fields: []const Value, out: *std.array_list.Managed(u8)) !void {
        const indices = try schemaPresentFieldIndices(schema, presence, self.allocator);
        defer self.allocator.free(indices);
        if (indices.len != fields.len) return TwilicError.InvalidData;
        for (indices, 0..) |index, idx| {
            try self.writeSchemaFieldValue(schema.fields[index], fields[idx], out);
        }
    }

    fn readSchemaFields(self: *TwilicCodec, schema: Schema, presence: ?[]const bool, expected_len: usize, reader: *Reader, out_fields: []Value) !void {
        const indices = try schemaPresentFieldIndices(schema, presence, self.allocator);
        defer self.allocator.free(indices);
        if (indices.len != expected_len) return TwilicError.InvalidData;
        for (indices, 0..) |index, idx| {
            out_fields[idx] = try self.readSchemaFieldValue(schema.fields[index], reader);
        }
    }

    fn writeSchemaFieldValue(self: *TwilicCodec, field: model.SchemaField, value: Value, out: *std.array_list.Managed(u8)) !void {
        const ty = try normalizedLogicalType(field.logical_type, out.allocator);
        defer out.allocator.free(ty);
        if (std.mem.eql(u8, ty, "bool")) {
            if (value != .Bool) return TwilicError.InvalidData;
            try out.append(if (value.Bool) 1 else 0);
            return;
        }
        if (std.mem.eql(u8, ty, "u64")) {
            if (value != .U64) return TwilicError.InvalidData;
            const u = value.U64;
            switch (field.physical_encoding) {
                .Varuint => try wire.encodeVaruint(u, out),
                .RangeBits => {
                    const range = fieldU64Range(field) orelse return TwilicError.InvalidData;
                    if (u < range.min or u > range.max) return TwilicError.InvalidData;
                    const offset = u - range.min;
                    const bits = rangeBitWidthU64(range.min, range.max);
                    try writeFixedBitsU64(offset, bits, out);
                },
                .FixedLe => try out.appendSlice(std.mem.asBytes(&u)),
                .Auto, .ZigzagVaruint => try wire.encodeVaruint(u, out),
            }
            return;
        }
        if (std.mem.eql(u8, ty, "i64")) {
            if (value != .I64) return TwilicError.InvalidData;
            const i = value.I64;
            switch (field.physical_encoding) {
                .ZigzagVaruint => try wire.encodeVaruint(wire.encodeZigzag(i), out),
                .RangeBits => {
                    const range = fieldI64Range(field) orelse return TwilicError.InvalidData;
                    if (i < range.min or i > range.max) return TwilicError.InvalidData;
                    const offset = @as(u64, @intCast(i - range.min));
                    const bits = rangeBitWidthI64(range.min, range.max);
                    try writeFixedBitsU64(offset, bits, out);
                },
                .FixedLe => try out.appendSlice(std.mem.asBytes(&i)),
                .Auto, .Varuint => try wire.encodeVaruint(wire.encodeZigzag(i), out),
            }
            return;
        }
        if (std.mem.eql(u8, ty, "f64")) {
            if (value != .F64) return TwilicError.InvalidData;
            const f = value.F64;
            try out.appendSlice(std.mem.asBytes(&f));
            return;
        }
        if (std.mem.eql(u8, ty, "string")) {
            if (value != .String) return TwilicError.InvalidData;
            if (self.state.field_enums.get(field.name)) |enum_values| {
                if (indexOfString(enum_values, value.String)) |code| {
                    try wire.encodeVaruint(code, out);
                    return;
                }
            }
            try wire.encodeString(value.String, out);
            return;
        }
        if (std.mem.eql(u8, ty, "binary")) {
            if (value != .Binary) return TwilicError.InvalidData;
            try wire.encodeBytes(value.Binary, out);
            return;
        }
        try self.writeValue(&value, null, out);
    }

    fn readSchemaFieldValue(self: *TwilicCodec, field: model.SchemaField, reader: *Reader) !Value {
        const ty = try normalizedLogicalType(field.logical_type, self.allocator);
        defer self.allocator.free(ty);
        if (std.mem.eql(u8, ty, "bool")) {
            return .{ .Bool = switch (try reader.readU8()) {
                0 => false,
                1 => true,
                else => return TwilicError.InvalidData,
            } };
        }
        if (std.mem.eql(u8, ty, "u64")) {
            const value: u64 = switch (field.physical_encoding) {
                .RangeBits => blk: {
                    const range = fieldU64Range(field) orelse return TwilicError.InvalidData;
                    const bits = rangeBitWidthU64(range.min, range.max);
                    const offset = try readFixedBitsU64(reader, bits);
                    const span = range.max - range.min;
                    if (offset > span) return TwilicError.InvalidData;
                    const v = std.math.add(u64, range.min, offset) catch return TwilicError.InvalidData;
                    if (v > range.max) return TwilicError.InvalidData;
                    break :blk v;
                },
                .FixedLe => blk: {
                    const bytes = try reader.readExact(8);
                    break :blk std.mem.bytesToValue(u64, bytes[0..8]);
                },
                .Varuint, .Auto, .ZigzagVaruint => try reader.readVaruint(),
            };
            return .{ .U64 = value };
        }
        if (std.mem.eql(u8, ty, "i64")) {
            const value: i64 = switch (field.physical_encoding) {
                .RangeBits => blk: {
                    const range = fieldI64Range(field) orelse return TwilicError.InvalidData;
                    const bits = rangeBitWidthI64(range.min, range.max);
                    const offset = try readFixedBitsU64(reader, bits);
                    const span = @as(i128, range.max) - @as(i128, range.min);
                    if (@as(i128, @intCast(offset)) > span) return TwilicError.InvalidData;
                    const v128 = @as(i128, range.min) + @as(i128, @intCast(offset));
                    break :blk std.math.cast(i64, v128) orelse return TwilicError.InvalidData;
                },
                .FixedLe => blk: {
                    const bytes = try reader.readExact(8);
                    break :blk std.mem.bytesToValue(i64, bytes[0..8]);
                },
                .ZigzagVaruint, .Auto, .Varuint => wire.decodeZigzag(try reader.readVaruint()),
            };
            return .{ .I64 = value };
        }
        if (std.mem.eql(u8, ty, "f64")) {
            const bytes = try reader.readExact(8);
            return .{ .F64 = std.mem.bytesToValue(f64, bytes[0..8]) };
        }
        if (std.mem.eql(u8, ty, "string")) {
            if (field.enum_values.len > 0) {
                const code_u64 = try reader.readVaruint();
                const code = std.math.cast(usize, code_u64) orelse return TwilicError.InvalidData;
                if (code >= field.enum_values.len) return self.referenceError();
                return .{ .String = try self.allocator.dupe(u8, field.enum_values[code]) };
            }
            if (self.state.field_enums.get(field.name)) |values| {
                const code_u64 = try reader.readVaruint();
                const code = std.math.cast(usize, code_u64) orelse return TwilicError.InvalidData;
                if (code >= values.len) return self.referenceError();
                return .{ .String = try self.allocator.dupe(u8, values[code]) };
            }
            return .{ .String = try reader.readString(self.allocator) };
        }
        if (std.mem.eql(u8, ty, "binary")) {
            return .{ .Binary = try reader.readBytes(self.allocator) };
        }
        return self.readValue(reader, null);
    }

    fn writeKeyRef(self: *TwilicCodec, key_ref: *const KeyRef, out: *std.array_list.Managed(u8)) !void {
        _ = self;
        switch (key_ref.*) {
            .Literal => |value| {
                try out.append(0);
                try wire.encodeString(value, out);
            },
            .Id => |id| {
                try out.append(1);
                try wire.encodeVaruint(id, out);
            },
        }
    }

    fn readKeyRef(self: *TwilicCodec, reader: *Reader) !KeyRef {
        const mode = try reader.readU8();
        return switch (mode) {
            0 => blk: {
                const key = try reader.readString(self.allocator);
                _ = try self.state.key_table.register(self.allocator, key);
                break :blk .{ .Literal = key };
            },
            1 => .{ .Id = try reader.readVaruint() },
            else => TwilicError.InvalidData,
        };
    }

    fn writePresence(self: *TwilicCodec, presence: ?[]const bool, out: *std.array_list.Managed(u8)) !void {
        _ = self;
        if (presence == null) {
            try out.append(0);
            return;
        }
        const bits = presence.?;
        var present_count: usize = 0;
        for (bits) |bit| {
            if (bit) present_count += 1;
        }
        const absent_count = bits.len - present_count;
        if (absent_count < present_count) {
            try out.append(2);
            const inverted = try out.allocator.alloc(bool, bits.len);
            defer out.allocator.free(inverted);
            for (bits, 0..) |bit, idx| inverted[idx] = !bit;
            try wire.encodeBitmap(inverted, out);
        } else {
            try out.append(1);
            try wire.encodeBitmap(bits, out);
        }
    }

    fn readPresence(self: *TwilicCodec, reader: *Reader) !?[]bool {
        const has = try reader.readU8();
        return switch (has) {
            0 => null,
            1 => try reader.readBitmap(self.allocator),
            2 => blk: {
                const inverted = try reader.readBitmap(self.allocator);
                for (inverted) |*bit| bit.* = !bit.*;
                break :blk inverted;
            },
            else => TwilicError.InvalidData,
        };
    }

    fn writeTypedVector(self: *TwilicCodec, vector: *const TypedVector, out: *std.array_list.Managed(u8)) !void {
        try out.append(@intFromEnum(vector.element_type));
        try wire.encodeVaruint(vector.data.len(), out);
        try out.append(@intFromEnum(vector.codec));
        switch (vector.data) {
            .Bool => |values| try wire.encodeBitmap(values, out),
            .I64 => |values| try codec.encodeI64Vector(values, vector.codec, out),
            .U64 => |values| try codec.encodeU64Vector(values, vector.codec, out),
            .F64 => |values| try codec.encodeF64Vector(values, vector.codec, out),
            .String => |values| try self.writeStringVector(values, vector.codec, out),
            .Binary => |values| {
                try wire.encodeVaruint(values.len, out);
                for (values) |value| {
                    try wire.encodeBytes(value, out);
                }
            },
            .Value => |values| {
                try wire.encodeVaruint(values.len, out);
                for (values) |value| {
                    try self.writeValue(&value, null, out);
                }
            },
        }
    }

    fn readTypedVector(self: *TwilicCodec, reader: *Reader, expected_codec: ?VectorCodec) !TypedVector {
        const element_type = ElementType.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
        const expected_len = try readCount(reader);
        const codec_value = VectorCodec.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
        if (expected_codec) |expected| {
            if (codec_value != expected) {
                return TwilicError.InvalidData;
            }
        }

        const data: TypedVectorData = switch (element_type) {
            .Bool => .{ .Bool = try reader.readBitmap(self.allocator) },
            .I64 => .{ .I64 = try codec.decodeI64Vector(reader, codec_value, self.allocator) },
            .U64 => .{ .U64 = try codec.decodeU64Vector(reader, codec_value, self.allocator) },
            .F64 => .{ .F64 = try codec.decodeF64Vector(reader, codec_value, self.allocator) },
            .String => .{ .String = try self.readStringVector(reader, codec_value) },
            .Binary => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(values);
                for (values) |*slot| {
                    slot.* = try reader.readBytes(self.allocator);
                }
                break :blk .{ .Binary = values };
            },
            .Value => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc(Value, len);
                errdefer self.allocator.free(values);
                for (values) |*slot| {
                    slot.* = try self.readValue(reader, null);
                }
                break :blk .{ .Value = values };
            },
        };

        if (data.len() != expected_len) {
            var tmp = data;
            tmp.deinit(self.allocator);
            return TwilicError.InvalidData;
        }

        return .{
            .element_type = element_type,
            .codec = codec_value,
            .data = data,
        };
    }

    fn writeColumn(self: *TwilicCodec, column: *const Column, out: *std.array_list.Managed(u8)) !void {
        try wire.encodeVaruint(column.field_id, out);
        try out.append(@intFromEnum(column.null_strategy));
        switch (column.null_strategy) {
            .PresenceBitmap, .InvertedPresenceBitmap => {
                const presence = column.presence orelse return TwilicError.InvalidData;
                try wire.encodeBitmap(presence, out);
            },
            .None, .AllPresentElided => {},
        }

        try out.append(@intFromEnum(column.codec));
        if (column.dictionary_id) |dict_id| {
            try out.append(1);
            try wire.encodeVaruint(dict_id, out);
            try out.append(0);
        } else {
            try out.append(0);
        }

        try out.append(0);
        const element_type: ElementType = switch (column.values) {
            .Bool => .Bool,
            .I64 => .I64,
            .U64 => .U64,
            .F64 => .F64,
            .String => .String,
            .Binary => .Binary,
            .Value => .Value,
        };
        const vector = TypedVector{
            .element_type = element_type,
            .codec = column.codec,
            .data = try column.values.clone(self.allocator),
        };
        defer {
            var mutable = vector;
            mutable.deinit(self.allocator);
        }
        try self.writeTypedVector(&vector, out);
    }

    fn readColumn(self: *TwilicCodec, reader: *Reader) !Column {
        const field_id = try reader.readVaruint();
        const null_strategy = NullStrategy.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
        const presence = switch (null_strategy) {
            .PresenceBitmap, .InvertedPresenceBitmap => try reader.readBitmap(self.allocator),
            .None, .AllPresentElided => null,
        };
        const codec_value = VectorCodec.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;

        const has_dict = try reader.readU8();
        const dictionary_id: ?u64 = switch (has_dict) {
            0 => null,
            1 => blk: {
                const id = try reader.readVaruint();
                const has_profile = try reader.readU8();
                switch (has_profile) {
                    0 => {},
                    else => return TwilicError.UnsupportedKind,
                }
                break :blk id;
            },
            else => return TwilicError.InvalidData,
        };

        const payload_mode = try reader.readU8();
        if (payload_mode != 0) return TwilicError.UnsupportedKind;

        const vector = try self.readTypedVector(reader, codec_value);
        return .{
            .field_id = field_id,
            .null_strategy = null_strategy,
            .presence = presence,
            .codec = codec_value,
            .dictionary_id = dictionary_id,
            .values = vector.data,
        };
    }

    fn writeSchemaBatchColumn(self: *TwilicCodec, column: *const Column, count: u64, out: *std.array_list.Managed(u8)) !void {
        const strategy: u8 = switch (column.null_strategy) {
            .None, .AllPresentElided => 0,
            .PresenceBitmap => 1,
            .InvertedPresenceBitmap => 2,
        };
        try out.append(strategy);
        if (strategy == 1 or strategy == 2) {
            const presence = column.presence orelse return TwilicError.InvalidData;
            try wire.encodeFixedBitmap(presence, count, out);
        }
        try out.append(@intFromEnum(column.codec));
        const element_type: ElementType = switch (column.values) {
            .Bool => .Bool,
            .I64 => .I64,
            .U64 => .U64,
            .F64 => .F64,
            .String => .String,
            .Binary => .Binary,
            .Value => .Value,
        };
        const vector = TypedVector{
            .element_type = element_type,
            .codec = column.codec,
            .data = try column.values.clone(self.allocator),
        };
        defer {
            var mutable = vector;
            mutable.deinit(self.allocator);
        }
        try self.writeTypedVector(&vector, out);
    }

    fn readSchemaBatchColumn(self: *TwilicCodec, field_id: u64, count: u64, reader: *Reader) !Column {
        const strategy = try reader.readU8();
        const null_strategy: NullStrategy = switch (strategy) {
            0 => .None,
            1 => .PresenceBitmap,
            2 => .InvertedPresenceBitmap,
            else => return TwilicError.InvalidData,
        };
        const presence: ?[]bool = switch (strategy) {
            0 => null,
            1 => try reader.readFixedBitmap(self.allocator, count),
            2 => blk: {
                const inverted = try reader.readFixedBitmap(self.allocator, count);
                for (inverted) |*bit| bit.* = !bit.*;
                break :blk inverted;
            },
            else => return TwilicError.InvalidData,
        };
        const codec_value = VectorCodec.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
        const vector = try self.readTypedVector(reader, codec_value);
        return .{
            .field_id = field_id,
            .null_strategy = null_strategy,
            .presence = presence,
            .codec = codec_value,
            .dictionary_id = null,
            .values = vector.data,
        };
    }

    fn writeBoundRecord(self: *TwilicCodec, schema: Schema, presence_strategy: PresenceStrategy, record: *const BoundRecord, out: *std.array_list.Managed(u8)) !void {
        switch (presence_strategy) {
            .Normal => {
                const bits = record.presence orelse return TwilicError.InvalidData;
                const count: u64 = @intCast(bits.len);
                try wire.encodeFixedBitmap(bits, count, out);
            },
            .Inverted => {
                const bits = record.presence orelse return TwilicError.InvalidData;
                const count: u64 = @intCast(bits.len);
                const inverted = try out.allocator.alloc(bool, bits.len);
                defer out.allocator.free(inverted);
                for (bits, 0..) |bit, idx| inverted[idx] = !bit;
                try wire.encodeFixedBitmap(inverted, count, out);
            },
            .AllPresent => {},
        }
        try self.writeSchemaFields(schema, record.presence, record.fields, out);
    }

    fn readBoundRecord(self: *TwilicCodec, schema: Schema, presence_strategy: PresenceStrategy, reader: *Reader) !BoundRecord {
        var optional_total: usize = 0;
        for (schema.fields) |field| {
            if (!field.required) optional_total += 1;
        }
        const total: u64 = @intCast(optional_total);
        const presence: ?[]bool = switch (presence_strategy) {
            .Normal => try reader.readFixedBitmap(self.allocator, total),
            .Inverted => blk: {
                const inverted = try reader.readFixedBitmap(self.allocator, total);
                for (inverted) |*bit| bit.* = !bit.*;
                break :blk inverted;
            },
            .AllPresent => null,
        };
        const indices = try schemaPresentFieldIndices(schema, presence, self.allocator);
        defer self.allocator.free(indices);
        const fields = try self.allocator.alloc(Value, indices.len);
        errdefer self.allocator.free(fields);
        for (indices, 0..) |index, idx| {
            fields[idx] = try self.readSchemaFieldValue(schema.fields[index], reader);
        }
        return .{ .presence = presence, .fields = fields };
    }

    fn writeControl(self: *TwilicCodec, control: *const ControlMessage, out: *std.array_list.Managed(u8)) !void {
        switch (control.*) {
            .RegisterKeys => |keys| {
                try out.append(@intFromEnum(ControlOpcode.RegisterKeys));
                try wire.encodeVaruint(keys.len, out);
                for (keys) |key| {
                    _ = try self.state.key_table.register(self.allocator, key);
                    try wire.encodeString(key, out);
                }
            },
            .RegisterShape => |shape| {
                try out.append(@intFromEnum(ControlOpcode.RegisterShape));
                try wire.encodeVaruint(shape.shape_id, out);
                try wire.encodeVaruint(shape.keys.len, out);
                var literals = try self.allocator.alloc([]const u8, shape.keys.len);
                defer self.allocator.free(literals);
                for (shape.keys, 0..) |key, idx| {
                    try self.writeKeyRef(&key, out);
                    literals[idx] = switch (key) {
                        .Literal => |v| v,
                        .Id => |id| self.state.key_table.getValue(id) orelse return self.referenceError(),
                    };
                }
                if (!try self.state.shape_table.registerWithId(self.allocator, shape.shape_id, literals)) {
                    return TwilicError.InvalidData;
                }
                try self.recordEncodeShapeObservation(literals, 2);
            },
            .RegisterStrings => |strings| {
                try out.append(@intFromEnum(ControlOpcode.RegisterStrings));
                try wire.encodeVaruint(strings.len, out);
                for (strings) |value| {
                    _ = try self.state.string_table.register(self.allocator, value);
                    try wire.encodeString(value, out);
                }
            },
            .PromoteStringFieldToEnum => |enum_data| {
                try out.append(@intFromEnum(ControlOpcode.PromoteStringFieldToEnum));
                try wire.encodeString(enum_data.field_identity, out);
                try wire.encodeVaruint(enum_data.values.len, out);
                for (enum_data.values) |value| {
                    try wire.encodeString(value, out);
                }
                try putFieldEnum(self, enum_data.field_identity, enum_data.values);
            },
            .ResetTables => {
                try out.append(@intFromEnum(ControlOpcode.ResetTables));
                self.state.resetTables();
            },
            .ResetState => {
                try out.append(@intFromEnum(ControlOpcode.ResetState));
                self.state.resetState();
            },
        }
    }

    fn readControl(self: *TwilicCodec, reader: *Reader) !ControlMessage {
        const op = ControlOpcode.fromByte(try reader.readU8()) orelse return TwilicError.InvalidData;
        return switch (op) {
            .RegisterKeys => blk: {
                const len = try readCount(reader);
                const keys = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(keys);
                for (keys) |*key| {
                    key.* = try reader.readString(self.allocator);
                    _ = try self.state.key_table.register(self.allocator, key.*);
                }
                break :blk .{ .RegisterKeys = keys };
            },
            .RegisterShape => blk: {
                const shape_id = try reader.readVaruint();
                const len = try readCount(reader);
                const key_refs = try self.allocator.alloc(KeyRef, len);
                errdefer self.allocator.free(key_refs);
                const key_views = try self.allocator.alloc([]const u8, len);
                defer self.allocator.free(key_views);
                for (key_refs, 0..) |*key_ref, idx| {
                    key_ref.* = try self.readKeyRef(reader);
                    key_views[idx] = switch (key_ref.*) {
                        .Literal => |v| v,
                        .Id => |id| self.state.key_table.getValue(id) orelse return self.referenceError(),
                    };
                }
                if (!try self.state.shape_table.registerWithId(self.allocator, shape_id, key_views)) {
                    return TwilicError.InvalidData;
                }
                break :blk .{ .RegisterShape = .{ .shape_id = shape_id, .keys = key_refs } };
            },
            .RegisterStrings => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(values);
                for (values) |*value| {
                    value.* = try reader.readString(self.allocator);
                    _ = try self.state.string_table.register(self.allocator, value.*);
                }
                break :blk .{ .RegisterStrings = values };
            },
            .PromoteStringFieldToEnum => blk: {
                const identity = try reader.readString(self.allocator);
                const len = try readCount(reader);
                const values = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(values);
                for (values) |*value| {
                    value.* = try reader.readString(self.allocator);
                }
                try putFieldEnum(self, identity, values);
                break :blk .{ .PromoteStringFieldToEnum = .{
                    .field_identity = identity,
                    .values = values,
                } };
            },
            .ResetTables => blk: {
                self.state.resetTables();
                break :blk .{ .ResetTables = {} };
            },
            .ResetState => blk: {
                self.state.resetState();
                break :blk .{ .ResetState = {} };
            },
        };
    }

    fn writeStringVector(self: *TwilicCodec, values: []const []const u8, codec_value: VectorCodec, out: *std.array_list.Managed(u8)) !void {
        _ = self;
        switch (codec_value) {
            .Dictionary, .StringRef => {
                var dict = std.array_list.Managed([]const u8).init(out.allocator);
                defer dict.deinit();
                var by_value = std.StringHashMap(u64).init(out.allocator);
                defer by_value.deinit();
                var ids = std.array_list.Managed(u64).init(out.allocator);
                defer ids.deinit();

                for (values) |value| {
                    const id = if (by_value.get(value)) |existing| existing else blk: {
                        const new_id: u64 = @intCast(dict.items.len);
                        try by_value.put(value, new_id);
                        try dict.append(value);
                        break :blk new_id;
                    };
                    try ids.append(id);
                }

                try wire.encodeVaruint(dict.items.len, out);
                for (dict.items) |value| {
                    try wire.encodeString(value, out);
                }
                try wire.encodeVaruint(ids.items.len, out);
                for (ids.items) |id| {
                    try wire.encodeVaruint(id, out);
                }
            },
            .PrefixDelta => {
                try wire.encodeVaruint(values.len, out);
                if (values.len == 0) return;
                try wire.encodeString(values[0], out);
                var idx: usize = 1;
                while (idx < values.len) : (idx += 1) {
                    const prev = values[idx - 1];
                    const current = values[idx];
                    var prefix_len = commonPrefixLen(prev, current);
                    while (prefix_len > 0 and !std.unicode.utf8ValidateSlice(current[0..prefix_len])) {
                        prefix_len -= 1;
                    }
                    try wire.encodeVaruint(prefix_len, out);
                    try wire.encodeString(current[prefix_len..], out);
                }
            },
            else => {
                try wire.encodeVaruint(values.len, out);
                for (values) |value| {
                    try wire.encodeString(value, out);
                }
            },
        }
    }

    fn readStringVector(self: *TwilicCodec, reader: *Reader, codec_value: VectorCodec) ![][]u8 {
        return switch (codec_value) {
            .Dictionary, .StringRef => blk: {
                const dict_len = try readCount(reader);
                const dict = try self.allocator.alloc([]u8, dict_len);
                defer {
                    for (dict) |value| self.allocator.free(value);
                    self.allocator.free(dict);
                }
                for (dict) |*value| {
                    value.* = try reader.readString(self.allocator);
                }
                const len = try readCount(reader);
                const values = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(values);
                for (values) |*value| {
                    const id_u64 = try reader.readVaruint();
                    const id = std.math.cast(usize, id_u64) orelse return TwilicError.InvalidData;
                    if (id >= dict.len) return TwilicError.InvalidData;
                    value.* = try self.allocator.dupe(u8, dict[id]);
                }
                break :blk values;
            },
            .PrefixDelta => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(values);
                if (len == 0) break :blk values;
                values[0] = try reader.readString(self.allocator);
                var idx: usize = 1;
                while (idx < len) : (idx += 1) {
                    const prefix_len_u64 = try reader.readCount();
                    const prefix_len = std.math.cast(usize, prefix_len_u64) orelse return TwilicError.InvalidData;
                    const suffix = try reader.readString(self.allocator);
                    defer self.allocator.free(suffix);
                    const prev = values[idx - 1];
                    if (prefix_len > prev.len or !std.unicode.utf8ValidateSlice(prev[0..prefix_len])) {
                        return TwilicError.InvalidData;
                    }
                    values[idx] = try self.allocator.alloc(u8, prefix_len + suffix.len);
                    std.mem.copyForwards(u8, values[idx][0..prefix_len], prev[0..prefix_len]);
                    std.mem.copyForwards(u8, values[idx][prefix_len..], suffix);
                }
                break :blk values;
            },
            else => blk: {
                const len = try readCount(reader);
                const values = try self.allocator.alloc([]u8, len);
                errdefer self.allocator.free(values);
                for (values) |*value| {
                    value.* = try reader.readString(self.allocator);
                }
                break :blk values;
            },
        };
    }

    fn bestPrefixBase(self: *TwilicCodec, value: []const u8) !?PrefixBase {
        var best: ?PrefixBase = null;
        for (self.state.string_table.by_id.items, 0..) |candidate, idx| {
            const prefix_len = commonPrefixLen(value, candidate);
            if (prefix_len < 3) continue;
            const suffix_len = value.len - prefix_len;
            const literal_cost = value.len;
            const pd_cost = suffix_len + 2;
            if (pd_cost >= literal_cost) continue;
            if (best) |existing| {
                if (prefix_len <= existing.prefix_len) continue;
            }
            best = .{
                .base_id = @intCast(idx),
                .prefix_len = prefix_len,
            };
        }
        return best;
    }

    fn recordEncodeShapeObservation(self: *TwilicCodec, keys: []const []const u8, count: u64) !void {
        const fingerprint = try shapeFingerprintOwned(self.allocator, keys);
        errdefer self.allocator.free(fingerprint);
        if (self.state.encode_shape_observations.getPtr(fingerprint)) |existing| {
            self.allocator.free(fingerprint);
            existing.* = @max(existing.*, count);
        } else {
            try self.state.encode_shape_observations.put(self.allocator, fingerprint, count);
        }
    }
};

pub const SessionEncoder = struct {
    codec: TwilicCodec,

    pub fn init(allocator: Allocator, options: SessionOptions) SessionEncoder {
        return .{ .codec = TwilicCodec.init(allocator, options) };
    }

    pub fn deinit(self: *SessionEncoder) void {
        self.codec.deinit();
    }

    pub fn encode(self: *SessionEncoder, value: *const Value) ![]u8 {
        const bytes = try self.codec.encodeValue(value);
        try self.recordFullMessageAsBase();
        return bytes;
    }

    pub fn encodeWithSchema(self: *SessionEncoder, schema: Schema, value: *const Value) ![]u8 {
        if (self.codec.state.schemas.getPtr(schema.schema_id)) |existing| {
            existing.deinit(self.codec.allocator);
            existing.* = try schema.clone(self.codec.allocator);
        } else {
            try self.codec.state.schemas.put(self.codec.allocator, schema.schema_id, try schema.clone(self.codec.allocator));
        }

        var fields = std.array_list.Managed(Value).init(self.codec.allocator);
        defer {
            for (fields.items) |*item| {
                item.deinit(self.codec.allocator);
            }
            fields.deinit();
        }
        var optional_presence = std.array_list.Managed(bool).init(self.codec.allocator);
        defer optional_presence.deinit();
        var has_optional = false;

        for (schema.fields) |field| {
            const field_value = lookupMapField(value.*, field.name);
            if (field.required) {
                if (field_value) |v| {
                    try fields.append(try v.clone(self.codec.allocator));
                } else if (field.default_value) |default_value| {
                    try fields.append(try default_value.clone(self.codec.allocator));
                } else {
                    return TwilicError.InvalidData;
                }
            } else {
                has_optional = true;
                if (field_value) |v| {
                    try optional_presence.append(true);
                    try fields.append(try v.clone(self.codec.allocator));
                } else {
                    try optional_presence.append(false);
                }
            }
        }

        const presence: ?[]bool = if (has_optional and anyAbsent(optional_presence.items))
            try self.codec.allocator.dupe(bool, optional_presence.items)
        else
            null;
        defer if (presence) |bits| self.codec.allocator.free(bits);

        const omit_schema_id = self.codec.state.last_schema_id != null and self.codec.state.last_schema_id.? == schema.schema_id;
        var message = Message{ .SchemaObject = .{
            .schema_id = if (omit_schema_id) null else schema.schema_id,
            .presence = if (presence) |bits| try self.codec.allocator.dupe(bool, bits) else null,
            .fields = try fields.toOwnedSlice(),
        } };
        defer message.deinit(self.codec.allocator);

        const bytes = try self.codec.encodeMessage(&message);
        self.codec.state.last_schema_id = schema.schema_id;
        try self.codec.setPreviousMessage(message);
        try self.recordFullMessageAsBase();
        return bytes;
    }

    pub fn encodeBatch(self: *SessionEncoder, values: []const Value) ![]u8 {
        const rows = try rowsFromValues(values, self.codec.allocator);
        defer freeRows(rows, self.codec.allocator);

        var message: Message = undefined;
        if (values.len >= 16) {
            const columns = try rowsToColumns(rows, self.codec.allocator);
            message = .{ .ColumnBatch = .{ .count = @intCast(values.len), .columns = columns } };
        } else {
            const rows_clone = try cloneRows(rows, self.codec.allocator);
            message = .{ .RowBatch = .{ .rows = rows_clone } };
        }
        defer message.deinit(self.codec.allocator);

        const bytes = try self.codec.encodeMessage(&message);
        try self.codec.setPreviousMessage(message);
        try self.recordFullMessageAsBase();
        return bytes;
    }

    pub fn encodeBoundStream(self: *SessionEncoder, schema: Schema, values: []const Value) ![]u8 {
        if (self.codec.state.schemas.getPtr(schema.schema_id)) |existing| {
            existing.deinit(self.codec.allocator);
            existing.* = try schema.clone(self.codec.allocator);
        } else {
            try self.codec.state.schemas.put(self.codec.allocator, schema.schema_id, try schema.clone(self.codec.allocator));
        }

        var records = std.array_list.Managed(model.BoundRecord).init(self.codec.allocator);
        errdefer {
            for (records.items) |*r| r.deinit(self.codec.allocator);
            records.deinit();
        }
        var any_absent = false;
        for (values) |value| {
            const record = try boundRecordFromValue(schema, &value, self.codec.allocator);
            if (record.presence != null) any_absent = true;
            try records.append(record);
        }

        const presence_strategy: PresenceStrategy = if (any_absent) .Normal else .AllPresent;
        var message = Message{ .BoundStream = .{
            .schema_id = schema.schema_id,
            .presence_strategy = presence_strategy,
            .records = try records.toOwnedSlice(),
        } };
        defer message.deinit(self.codec.allocator);

        const bytes = try self.codec.encodeMessage(&message);
        try self.codec.setPreviousMessage(message);
        try self.recordFullMessageAsBase();
        return bytes;
    }

    pub fn encodeBatchWithSchema(self: *SessionEncoder, schema: Schema, values: []const Value) ![]u8 {
        if (self.codec.state.schemas.getPtr(schema.schema_id)) |existing| {
            existing.deinit(self.codec.allocator);
            existing.* = try schema.clone(self.codec.allocator);
        } else {
            try self.codec.state.schemas.put(self.codec.allocator, schema.schema_id, try schema.clone(self.codec.allocator));
        }

        const columns = try schemaColumnsFromValues(schema, values, self.codec.allocator);
        var message = Message{ .SchemaBatch = .{
            .schema_id = schema.schema_id,
            .count = @intCast(values.len),
            .columns = columns,
        } };
        defer message.deinit(self.codec.allocator);

        const bytes = try self.codec.encodeMessage(&message);
        try self.codec.setPreviousMessage(message);
        try self.recordFullMessageAsBase();
        return bytes;
    }

    pub fn encodePatch(self: *SessionEncoder, value: *const Value) ![]u8 {
        if (!self.codec.state.options.enable_state_patch) {
            return self.encode(value);
        }
        const prev = self.codec.state.previous_message orelse return self.encode(value);
        var current_msg = switch (value.*) {
            .Map => |entries| try self.codec.mapMessage(entries),
            else => try self.codec.messageForValue(value),
        };
        errdefer current_msg.deinit(self.codec.allocator);

        if (!supportsStatePatch(prev, current_msg)) {
            current_msg.deinit(self.codec.allocator);
            const bytes = try self.codec.encodeValue(value);
            try self.recordFullMessageAsBase();
            return bytes;
        }

        const diff = try diffMessage(prev, current_msg, self.codec.allocator);
        defer {
            for (diff.ops) |*op| {
                op.deinit(self.codec.allocator);
            }
            self.codec.allocator.free(diff.ops);
        }

        const prev_fields = try messageFields(prev, self.codec.allocator);
        defer freeValues(prev_fields, self.codec.allocator);
        const curr_fields = try messageFields(current_msg, self.codec.allocator);
        defer freeValues(curr_fields, self.codec.allocator);

        const total_fields = @max(@max(prev_fields.len, curr_fields.len), 1);
        const prev_size = try encodedSize(prev, self.codec.allocator);
        const patch_size = try estimatedPatchSizeWithBase(.{ .Previous = {} }, diff.ops, self.codec.allocator);
        const patch_ratio = @as(f64, @floatFromInt(diff.changed)) / @as(f64, @floatFromInt(total_fields));

        if (patch_ratio <= 0.10 and patch_size < prev_size) {
            var patch = Message{ .StatePatch = .{
                .base_ref = .{ .Previous = {} },
                .operations = try clonePatchOps(diff.ops, self.codec.allocator),
                .literals = try self.codec.allocator.alloc(Value, 0),
            } };
            defer patch.deinit(self.codec.allocator);
            const bytes = try self.codec.encodeMessage(&patch);
            try self.codec.setPreviousMessage(current_msg);
            current_msg.deinit(self.codec.allocator);
            return bytes;
        }

        current_msg.deinit(self.codec.allocator);
        const bytes = try self.codec.encodeValue(value);
        try self.recordFullMessageAsBase();
        return bytes;
    }

    pub fn encodeMicroBatch(self: *SessionEncoder, values: []const Value) ![]u8 {
        if (values.len < 4 or !self.codec.state.options.enable_template_batch) {
            return self.encodeBatch(values);
        }
        if (!hasUniformMicroBatchShape(values)) {
            return self.encodeBatch(values);
        }

        const rows = try rowsFromValues(values, self.codec.allocator);
        defer freeRows(rows, self.codec.allocator);
        const columns = try rowsToColumns(rows, self.codec.allocator);
        defer {
            for (columns) |*column| {
                column.deinit(self.codec.allocator);
            }
            self.codec.allocator.free(columns);
        }

        const probe = try templateDescriptorFromColumns(0, columns, self.codec.allocator);
        defer {
            var temp = probe;
            temp.deinit(self.codec.allocator);
        }
        const template_id = findTemplateId(&self.codec.state.templates, probe) orelse self.codec.state.allocateTemplateId();

        const changed: TemplateColumnDiff = if (self.codec.state.template_columns.get(template_id)) |previous|
            try diffTemplateColumns(previous, columns, self.codec.allocator)
        else
            .{ .mask = try allTrueMask(columns.len, self.codec.allocator), .columns = try cloneColumns(columns, self.codec.allocator) };
        defer {
            self.codec.allocator.free(changed.mask);
            for (changed.columns) |*column| {
                column.deinit(self.codec.allocator);
            }
            self.codec.allocator.free(changed.columns);
        }

        try putTemplateDescriptor(&self.codec, try templateDescriptorFromColumns(template_id, columns, self.codec.allocator));
        try putTemplateColumns(&self.codec, template_id, columns);

        var message = Message{ .TemplateBatch = .{
            .template_id = template_id,
            .count = @intCast(values.len),
            .changed_column_mask = try self.codec.allocator.dupe(bool, changed.mask),
            .columns = try cloneColumns(changed.columns, self.codec.allocator),
        } };
        defer message.deinit(self.codec.allocator);

        const bytes = try self.codec.encodeMessage(&message);
        var previous = Message{ .ColumnBatch = .{ .count = @intCast(values.len), .columns = try cloneColumns(columns, self.codec.allocator) } };
        defer previous.deinit(self.codec.allocator);
        try self.codec.setPreviousMessage(previous);
        return bytes;
    }

    pub fn reset(self: *SessionEncoder) void {
        self.codec.state.resetState();
    }

    pub fn decodeMessage(self: *SessionEncoder, bytes: []const u8) !Message {
        return self.codec.decodeMessage(bytes);
    }

    fn recordFullMessageAsBase(self: *SessionEncoder) !void {
        if (self.codec.state.options.max_base_snapshots == 0) return;
        if (self.codec.state.previous_message) |previous| {
            const base_id = self.codec.state.allocateBaseId();
            try self.codec.state.registerBaseSnapshot(base_id, try previous.clone(self.codec.allocator));
        }
    }
};

fn collectMapKeys(entries: []const ValueMapEntry, allocator: Allocator) ![][]const u8 {
    const keys = try allocator.alloc([]const u8, entries.len);
    for (entries, 0..) |entry, idx| {
        keys[idx] = entry.key;
    }
    return keys;
}

fn findMapField(entries: []const ValueMapEntry, key: []const u8) ?Value {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
    }
    return null;
}

fn allValuesOfType(values: []const Value, comptime tag: model.ValueTag) bool {
    for (values) |value| {
        if (value != tag) return false;
    }
    return true;
}

fn typedVectorToValue(vector: TypedVector, allocator: Allocator) !Value {
    return switch (vector.data) {
        .Bool => |values| blk: {
            const out = try allocator.alloc(Value, values.len);
            for (values, 0..) |value, idx| out[idx] = .{ .Bool = value };
            break :blk .{ .Array = out };
        },
        .I64 => |values| blk: {
            const out = try allocator.alloc(Value, values.len);
            for (values, 0..) |value, idx| out[idx] = .{ .I64 = value };
            break :blk .{ .Array = out };
        },
        .U64 => |values| blk: {
            const out = try allocator.alloc(Value, values.len);
            for (values, 0..) |value, idx| out[idx] = .{ .U64 = value };
            break :blk .{ .Array = out };
        },
        .F64 => |values| blk: {
            const out = try allocator.alloc(Value, values.len);
            for (values, 0..) |value, idx| out[idx] = .{ .F64 = value };
            break :blk .{ .Array = out };
        },
        .String => |values| blk: {
            const out = try allocator.alloc(Value, values.len);
            for (values, 0..) |value, idx| out[idx] = .{ .String = try allocator.dupe(u8, value) };
            break :blk .{ .Array = out };
        },
        .Binary => |values| blk: {
            const out = try allocator.alloc(Value, values.len);
            for (values, 0..) |value, idx| out[idx] = .{ .Binary = try allocator.dupe(u8, value) };
            break :blk .{ .Array = out };
        },
        .Value => |values| .{ .Array = try cloneValues(values, allocator) },
    };
}

fn entriesToMap(entries: []const MapEntry, codec_state: *const TwilicCodec) ![]ValueMapEntry {
    const out = try codec_state.allocator.alloc(ValueMapEntry, entries.len);
    for (entries, 0..) |entry, idx| {
        const key = switch (entry.key) {
            .Literal => |v| try codec_state.allocator.dupe(u8, v),
            .Id => |id| blk: {
                const value = codec_state.state.key_table.getValue(id) orelse return codec_state.referenceError();
                break :blk try codec_state.allocator.dupe(u8, value);
            },
        };
        out[idx] = .{
            .key = key,
            .value = try entry.value.clone(codec_state.allocator),
        };
    }
    return out;
}

fn shapeValuesToMap(keys: []const []u8, presence: ?[]const bool, values: []const Value, allocator: Allocator) ![]ValueMapEntry {
    var out = std.array_list.Managed(ValueMapEntry).init(allocator);
    errdefer out.deinit();

    var value_idx: usize = 0;
    for (keys, 0..) |key, idx| {
        const present = if (presence) |bits|
            if (idx < bits.len) bits[idx] else true
        else
            true;
        if (!present) continue;
        if (value_idx >= values.len) break;
        try out.append(.{
            .key = try allocator.dupe(u8, key),
            .value = try values[value_idx].clone(allocator),
        });
        value_idx += 1;
    }
    return out.toOwnedSlice();
}

fn lookupMapField(value: Value, key: []const u8) ?Value {
    if (value != .Map) return null;
    for (value.Map) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn schemaPresentFieldIndices(schema: Schema, presence: ?[]const bool, allocator: Allocator) ![]usize {
    var optional_total: usize = 0;
    for (schema.fields) |field| {
        if (!field.required) optional_total += 1;
    }
    if (presence) |bits| {
        if (bits.len != optional_total) return TwilicError.InvalidData;
    }

    var indices = std.array_list.Managed(usize).init(allocator);
    errdefer indices.deinit();
    var optional_idx: usize = 0;
    for (schema.fields, 0..) |field, idx| {
        if (field.required) {
            try indices.append(idx);
        } else {
            const is_present = if (presence) |bits|
                if (optional_idx < bits.len) bits[optional_idx] else true
            else
                true;
            optional_idx += 1;
            if (is_present) {
                try indices.append(idx);
            }
        }
    }
    return indices.toOwnedSlice();
}

fn normalizedLogicalType(raw: []const u8, allocator: Allocator) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const out = try allocator.dupe(u8, trimmed);
    for (out) |*ch| {
        ch.* = std.ascii.toLower(ch.*);
    }
    return out;
}

fn fieldU64Range(field: model.SchemaField) ?struct { min: u64, max: u64 } {
    const min = field.min orelse return null;
    const max = field.max orelse return null;
    if (min < 0 or max < min) return null;
    return .{ .min = @intCast(min), .max = @intCast(max) };
}

fn fieldI64Range(field: model.SchemaField) ?struct { min: i64, max: i64 } {
    const min = field.min orelse return null;
    const max = field.max orelse return null;
    if (max < min) return null;
    return .{ .min = min, .max = max };
}

fn readCount(reader: *Reader) !usize {
    const value = try reader.readCount();
    return std.math.cast(usize, value) orelse TwilicError.InvalidData;
}

fn writeFixedBitsU64(value: u64, bits: u8, out: *std.array_list.Managed(u8)) !void {
    if (bits > 64) return TwilicError.InvalidData;
    if (bits == 0) {
        if (value != 0) return TwilicError.InvalidData;
        return;
    }
    if (bits < 64 and (value >> @as(u6, @intCast(bits))) != 0) return TwilicError.InvalidData;
    const byte_len = std.math.divCeil(usize, bits, 8) catch unreachable;
    var idx: usize = 0;
    while (idx < byte_len) : (idx += 1) {
        try out.append(@intCast((value >> @intCast(idx * 8)) & 0xff));
    }
}

fn readFixedBitsU64(reader: *Reader, bits: u8) !u64 {
    if (bits > 64) return TwilicError.InvalidData;
    if (bits == 0) return 0;
    const byte_len = std.math.divCeil(usize, bits, 8) catch unreachable;
    var value: u64 = 0;
    var idx: usize = 0;
    while (idx < byte_len) : (idx += 1) {
        value |= (@as(u64, try reader.readU8()) << @intCast(idx * 8));
    }
    if (bits < 64) {
        const mask = (@as(u64, 1) << @as(u6, @intCast(bits))) - 1;
        if ((value & ~mask) != 0) return TwilicError.InvalidData;
    }
    return value;
}

fn writeSmallestU64(value: u64, out: *std.array_list.Managed(u8)) !void {
    if (value <= std.math.maxInt(u8)) {
        try out.append(1);
        try out.append(@intCast(value));
    } else if (value <= std.math.maxInt(u16)) {
        try out.append(2);
        const v: u16 = @intCast(value);
        try out.appendSlice(std.mem.asBytes(&v));
    } else if (value <= std.math.maxInt(u32)) {
        try out.append(4);
        const v: u32 = @intCast(value);
        try out.appendSlice(std.mem.asBytes(&v));
    } else {
        try out.append(8);
        try out.appendSlice(std.mem.asBytes(&value));
    }
}

fn readSmallestU64(reader: *Reader) !u64 {
    const width = try reader.readU8();
    return switch (width) {
        1 => @as(u64, try reader.readU8()),
        2 => blk: {
            const bytes = try reader.readExact(2);
            break :blk @as(u64, std.mem.bytesToValue(u16, bytes[0..2]));
        },
        4 => blk: {
            const bytes = try reader.readExact(4);
            break :blk @as(u64, std.mem.bytesToValue(u32, bytes[0..4]));
        },
        8 => blk: {
            const bytes = try reader.readExact(8);
            break :blk std.mem.bytesToValue(u64, bytes[0..8]);
        },
        else => TwilicError.InvalidData,
    };
}

fn bitWidthU64(v: u64) u8 {
    if (v == 0) return 1;
    return @intCast(64 - @clz(v));
}

fn bitWidthSigned(min: i64, max: i64) u8 {
    const range = @as(u64, @intCast(@abs(max - min)));
    return bitWidthU64(range);
}

fn rangeBitWidthU64(min: u64, max: u64) u8 {
    const span = max - min;
    if (span == 0) return 0;
    return @intCast(64 - @clz(span));
}

fn rangeBitWidthI64(min: i64, max: i64) u8 {
    const span: i128 = @as(i128, max) - @as(i128, min);
    if (span == 0) return 0;
    return @intCast(128 - @clz(@as(u128, @intCast(span))));
}

fn shapeFingerprintOwned(allocator: Allocator, keys: []const []const u8) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try wire.encodeVaruint(keys.len, &out);
    for (keys) |key| {
        try wire.encodeVaruint(key.len, &out);
        try out.appendSlice(key);
    }
    return out.toOwnedSlice();
}

fn shouldRegisterShape(keys: []const []const u8, observed_count: u64) bool {
    return keys.len >= 3 and observed_count >= 2;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    const len = @min(a.len, b.len);
    var idx: usize = 0;
    while (idx < len and a[idx] == b[idx]) : (idx += 1) {}
    return idx;
}

fn indexOfString(values: []const []const u8, target: []const u8) ?u64 {
    for (values, 0..) |value, idx| {
        if (std.mem.eql(u8, value, target)) return @intCast(idx);
    }
    return null;
}

fn putFieldEnum(codec_state: *TwilicCodec, field_identity: []const u8, values: []const []const u8) !void {
    const identity = try codec_state.allocator.dupe(u8, field_identity);
    errdefer codec_state.allocator.free(identity);
    const copied_values = try codec_state.allocator.alloc([]u8, values.len);
    errdefer codec_state.allocator.free(copied_values);
    for (values, 0..) |value, idx| {
        copied_values[idx] = try codec_state.allocator.dupe(u8, value);
    }
    if (codec_state.state.field_enums.getEntry(identity)) |entry| {
        codec_state.allocator.free(identity);
        for (entry.value_ptr.*) |value| codec_state.allocator.free(value);
        codec_state.allocator.free(entry.value_ptr.*);
        entry.value_ptr.* = copied_values;
    } else {
        try codec_state.state.field_enums.put(codec_state.allocator, identity, copied_values);
    }
}

fn cloneValues(values: []const Value, allocator: Allocator) ![]Value {
    const out = try allocator.alloc(Value, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try value.clone(allocator);
    }
    return out;
}

fn rowsFromValues(values: []const Value, allocator: Allocator) ![][]Value {
    var all_maps = true;
    for (values) |value| {
        if (value != .Map) {
            all_maps = false;
            break;
        }
    }

    if (!all_maps) {
        const rows = try allocator.alloc([]Value, values.len);
        for (values, 0..) |value, idx| {
            rows[idx] = try allocator.alloc(Value, 1);
            rows[idx][0] = try value.clone(allocator);
        }
        return rows;
    }

    var key_order = std.array_list.Managed([]const u8).init(allocator);
    defer key_order.deinit();
    for (values) |value| {
        for (value.Map) |entry| {
            if (!containsString(key_order.items, entry.key)) {
                try key_order.append(entry.key);
            }
        }
    }

    const rows = try allocator.alloc([]Value, values.len);
    for (values, 0..) |value, row_idx| {
        rows[row_idx] = try allocator.alloc(Value, key_order.items.len);
        for (key_order.items, 0..) |key, col_idx| {
            const field = lookupMapField(value, key);
            rows[row_idx][col_idx] = if (field) |v| try v.clone(allocator) else .{ .Null = {} };
        }
    }
    return rows;
}

fn freeRows(rows: [][]Value, allocator: Allocator) void {
    for (rows) |row| {
        for (row) |*value| value.deinit(allocator);
        allocator.free(row);
    }
    allocator.free(rows);
}

fn cloneRows(rows: [][]Value, allocator: Allocator) ![][]Value {
    const out = try allocator.alloc([]Value, rows.len);
    for (rows, 0..) |row, idx| {
        out[idx] = try cloneValues(row, allocator);
    }
    return out;
}

fn containsString(values: []const []const u8, target: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, target)) return true;
    }
    return false;
}

fn anyAbsent(bits: []const bool) bool {
    for (bits) |bit| {
        if (!bit) return true;
    }
    return false;
}

fn rowsToColumns(rows: [][]Value, allocator: Allocator) ![]Column {
    if (rows.len == 0) {
        return allocator.alloc(Column, 0);
    }
    var width: usize = 0;
    for (rows) |row| {
        width = @max(width, row.len);
    }

    const columns = try allocator.alloc(Column, width);
    errdefer allocator.free(columns);

    var col_idx: usize = 0;
    while (col_idx < width) : (col_idx += 1) {
        var values = std.array_list.Managed(Value).init(allocator);
        defer {
            for (values.items) |*value| value.deinit(allocator);
            values.deinit();
        }
        var present_bits = std.array_list.Managed(bool).init(allocator);
        defer present_bits.deinit();

        for (rows) |row| {
            if (col_idx < row.len) {
                const value = try row[col_idx].clone(allocator);
                try present_bits.append(value != .Null);
                try values.append(value);
            } else {
                try present_bits.append(false);
                try values.append(.{ .Null = {} });
            }
        }

        var null_count: usize = 0;
        for (values.items) |value| {
            if (value == .Null) null_count += 1;
        }
        const optional_count = values.items.len;

        const null_strategy: NullStrategy = if (null_count == 0)
            .AllPresentElided
        else if (null_count <= optional_count / 4)
            .InvertedPresenceBitmap
        else
            .PresenceBitmap;

        const presence: ?[]bool = switch (null_strategy) {
            .AllPresentElided => null,
            .InvertedPresenceBitmap => blk: {
                const bits = try allocator.alloc(bool, present_bits.items.len);
                for (present_bits.items, 0..) |bit, idx| bits[idx] = !bit;
                break :blk bits;
            },
            .PresenceBitmap => try allocator.dupe(bool, present_bits.items),
            .None => null,
        };

        const non_null = try stripNulls(values.items, allocator);
        defer {
            for (non_null) |*value| value.deinit(allocator);
            allocator.free(non_null);
        }
        const infer = try inferColumnCodecAndValues(non_null, allocator);

        columns[col_idx] = .{
            .field_id = @intCast(col_idx),
            .null_strategy = null_strategy,
            .presence = presence,
            .codec = infer.codec,
            .dictionary_id = null,
            .values = infer.values,
        };
    }

    return columns;
}

fn stripNulls(values: []const Value, allocator: Allocator) ![]Value {
    var out = std.array_list.Managed(Value).init(allocator);
    errdefer out.deinit();
    for (values) |value| {
        if (value == .Null) continue;
        try out.append(try value.clone(allocator));
    }
    return out.toOwnedSlice();
}

const InferColumnResult = struct {
    codec: VectorCodec,
    values: TypedVectorData,
};

fn inferColumnCodecAndValues(values: []const Value, allocator: Allocator) !InferColumnResult {
    if (values.len == 0) {
        return .{ .codec = .Plain, .values = .{ .Value = try allocator.alloc(Value, 0) } };
    }
    if (allValuesOfType(values, .Bool)) {
        const out = try allocator.alloc(bool, values.len);
        for (values, 0..) |value, idx| out[idx] = value.Bool;
        return .{ .codec = .DirectBitpack, .values = .{ .Bool = out } };
    }
    if (allValuesOfType(values, .I64)) {
        const out = try allocator.alloc(i64, values.len);
        for (values, 0..) |value, idx| out[idx] = value.I64;
        return .{ .codec = selectIntegerCodec(out), .values = .{ .I64 = out } };
    }
    if (allValuesOfType(values, .U64)) {
        const out = try allocator.alloc(u64, values.len);
        for (values, 0..) |value, idx| out[idx] = value.U64;
        return .{ .codec = selectU64Codec(out), .values = .{ .U64 = out } };
    }
    if (allValuesOfType(values, .F64)) {
        const out = try allocator.alloc(f64, values.len);
        for (values, 0..) |value, idx| out[idx] = value.F64;
        return .{ .codec = selectFloatCodec(out), .values = .{ .F64 = out } };
    }
    if (allValuesOfType(values, .String)) {
        const out = try allocator.alloc([]u8, values.len);
        for (values, 0..) |value, idx| out[idx] = try allocator.dupe(u8, value.String);
        return .{ .codec = selectStringCodec(out), .values = .{ .String = out } };
    }
    return .{ .codec = .Plain, .values = .{ .Value = try cloneValues(values, allocator) } };
}

fn selectIntegerCodec(values: []const i64) VectorCodec {
    if (values.len < 4) return .Plain;
    const allocator = std.heap.page_allocator;
    const delta_vals = deltas(values, allocator) catch return .DirectBitpack;
    defer allocator.free(delta_vals);
    const dd = deltas(delta_vals, allocator) catch return .DirectBitpack;
    defer allocator.free(dd);

    var non_zero_dd: usize = 0;
    if (dd.len > 1) {
        for (dd[1..]) |value| {
            if (value != 0) non_zero_dd += 1;
        }
    }
    const non_zero_ratio = if (dd.len <= 1) 0.0 else @as(f64, @floatFromInt(non_zero_dd)) / @as(f64, @floatFromInt(dd.len - 1));

    const delta_min = std.mem.min(i64, delta_vals);
    const delta_max = std.mem.max(i64, delta_vals);
    const delta_range_bits = bitWidthSigned(delta_min, delta_max);
    if (values.len >= 8 and (non_zero_ratio <= 0.25 or delta_range_bits <= 2)) {
        return .DeltaDeltaBitpack;
    }

    const run = runStatsI64(values);
    if (run.repeated_ratio >= 0.5 and run.avg_run >= 3.0) return .Rle;

    const range_bits = @as(i32, @intCast(bitWidthSigned(std.mem.min(i64, values), std.mem.max(i64, values))));
    if (range_bits <= 60) return .ForBitpack;

    const monotonic = isMonotonic(values);
    if (values.len >= 8 and monotonic and @as(i32, @intCast(delta_range_bits)) <= (range_bits - 3)) {
        return .DeltaForBitpack;
    }

    var max_abs_delta_bits: i32 = 1;
    for (delta_vals) |d| {
        const bits: i32 = @intCast(bitWidthU64(absToUnsigned(d)));
        max_abs_delta_bits = @max(max_abs_delta_bits, bits);
    }
    if (max_abs_delta_bits <= 61) return .DeltaBitpack;

    var max_width: u8 = 1;
    for (values) |v| max_width = @max(max_width, bitWidthU64(absToUnsigned(v)));
    if (values.len >= 8 and max_width <= 16 and !monotonic) return .Simple8b;
    if (max_width < 64) return .DirectBitpack;
    return .Plain;
}

fn selectU64Codec(values: []const u64) VectorCodec {
    var all_i64 = true;
    for (values) |value| {
        if (value > std.math.maxInt(i64)) {
            all_i64 = false;
            break;
        }
    }
    if (all_i64) {
        const allocator = std.heap.page_allocator;
        const signed = allocator.alloc(i64, values.len) catch return .DirectBitpack;
        defer allocator.free(signed);
        for (values, 0..) |value, idx| signed[idx] = @intCast(value);
        return switch (selectIntegerCodec(signed)) {
            .Rle => .Rle,
            .ForBitpack => .ForBitpack,
            .Simple8b => .Simple8b,
            .DirectBitpack => .DirectBitpack,
            .Plain => .Plain,
            else => .DirectBitpack,
        };
    }

    if (values.len < 4) return .DirectBitpack;
    const run = runStatsU64(values);
    if (run.repeated_ratio >= 0.5 and run.avg_run >= 3.0) return .Rle;

    const min = std.mem.min(u64, values);
    const max = std.mem.max(u64, values);
    const range = max - min;
    if (bitWidthU64(range) <= 60) return .ForBitpack;

    var width: u8 = 1;
    for (values) |value| width = @max(width, bitWidthU64(value));
    if (values.len >= 8 and width <= 16) return .Simple8b;
    if (width < 64) return .DirectBitpack;
    return .Plain;
}

fn selectFloatCodec(values: []const f64) VectorCodec {
    if (values.len < 4) return .Plain;
    var xor_words = std.array_list.Managed(u64).init(std.heap.page_allocator);
    defer xor_words.deinit();
    var idx: usize = 1;
    while (idx < values.len) : (idx += 1) {
        xor_words.append(@as(u64, @bitCast(values[idx - 1])) ^ @as(u64, @bitCast(values[idx]))) catch return .Plain;
    }

    var zero_or_one: usize = 0;
    var width_sum: f64 = 0;
    var width_count: f64 = 0;
    for (xor_words.items) |word| {
        if (word == 0 or @popCount(word) <= 1) zero_or_one += 1;
        if (word != 0) {
            width_sum += @floatFromInt(bitWidthU64(word));
            width_count += 1;
        }
    }
    const avg_non_zero_width = if (width_count == 0) 0 else width_sum / width_count;
    const ratio = @as(f64, @floatFromInt(zero_or_one)) / @as(f64, @floatFromInt(@max(xor_words.items.len, 1)));
    if (ratio >= 0.5 and avg_non_zero_width <= 16.0) return .XorFloat;
    return .Plain;
}

fn selectStringCodec(values: []const []const u8) VectorCodec {
    if (values.len < 4) return .Plain;
    var prefix_hits: usize = 0;
    var idx: usize = 1;
    while (idx < values.len) : (idx += 1) {
        if (commonPrefixLen(values[idx - 1], values[idx]) >= 3) {
            prefix_hits += 1;
        }
    }
    const prefix_ratio = @as(f64, @floatFromInt(prefix_hits)) / @as(f64, @floatFromInt(@max(values.len - 1, 1)));
    if (values.len >= 4 and prefix_ratio >= 0.5) return .PrefixDelta;

    var unique = std.StringHashMap(void).init(std.heap.page_allocator);
    defer unique.deinit();
    for (values) |value| {
        unique.put(value, {}) catch {};
    }
    const unique_ratio = @as(f64, @floatFromInt(unique.count())) / @as(f64, @floatFromInt(values.len));
    if (values.len >= 16 and unique_ratio <= 0.25) return .Dictionary;
    if (unique.count() < values.len) return .StringRef;
    return .Plain;
}

fn deltas(values: []const i64, allocator: Allocator) ![]i64 {
    const out = try allocator.alloc(i64, values.len);
    for (values, 0..) |value, idx| {
        out[idx] = if (idx == 0) value else value - values[idx - 1];
    }
    return out;
}

const RunStats = struct {
    repeated_ratio: f64,
    avg_run: f64,
};

fn runStatsI64(values: []const i64) RunStats {
    if (values.len == 0) return .{ .repeated_ratio = 0, .avg_run = 0 };
    var run_len: usize = 1;
    var run_sum: usize = 0;
    var run_count: usize = 0;
    var repeated_items: usize = 0;
    var idx: usize = 1;
    while (idx < values.len) : (idx += 1) {
        if (values[idx - 1] == values[idx]) {
            run_len += 1;
        } else {
            run_sum += run_len;
            run_count += 1;
            if (run_len > 1) repeated_items += run_len;
            run_len = 1;
        }
    }
    run_sum += run_len;
    run_count += 1;
    if (run_len > 1) repeated_items += run_len;
    return .{
        .repeated_ratio = @as(f64, @floatFromInt(repeated_items)) / @as(f64, @floatFromInt(values.len)),
        .avg_run = @as(f64, @floatFromInt(run_sum)) / @as(f64, @floatFromInt(run_count)),
    };
}

fn runStatsU64(values: []const u64) RunStats {
    if (values.len == 0) return .{ .repeated_ratio = 0, .avg_run = 0 };
    var run_len: usize = 1;
    var run_sum: usize = 0;
    var run_count: usize = 0;
    var repeated_items: usize = 0;
    var idx: usize = 1;
    while (idx < values.len) : (idx += 1) {
        if (values[idx - 1] == values[idx]) {
            run_len += 1;
        } else {
            run_sum += run_len;
            run_count += 1;
            if (run_len > 1) repeated_items += run_len;
            run_len = 1;
        }
    }
    run_sum += run_len;
    run_count += 1;
    if (run_len > 1) repeated_items += run_len;
    return .{
        .repeated_ratio = @as(f64, @floatFromInt(repeated_items)) / @as(f64, @floatFromInt(values.len)),
        .avg_run = @as(f64, @floatFromInt(run_sum)) / @as(f64, @floatFromInt(run_count)),
    };
}

fn isMonotonic(values: []const i64) bool {
    var idx: usize = 1;
    while (idx < values.len) : (idx += 1) {
        if (values[idx] < values[idx - 1]) return false;
    }
    return true;
}

fn absToUnsigned(v: i64) u64 {
    return if (v < 0) @as(u64, @intCast(-v)) else @as(u64, @intCast(v));
}

const PatchDiff = struct {
    ops: []PatchOperation,
    changed: usize,
};

const TemplateColumnDiff = struct {
    mask: []bool,
    columns: []Column,
};

fn writeBaseRef(self: *TwilicCodec, base_ref: BaseRef, out: *std.array_list.Managed(u8)) !void {
    _ = self;
    switch (base_ref) {
        .Previous => try out.append(0),
        .BaseId => |id| {
            try out.append(1);
            try wire.encodeVaruint(id, out);
        },
    }
}

fn readBaseRef(self: *TwilicCodec, reader: *Reader) !BaseRef {
    _ = self;
    return switch (try reader.readU8()) {
        0 => .{ .Previous = {} },
        1 => .{ .BaseId = try reader.readVaruint() },
        else => TwilicError.InvalidData,
    };
}

fn writeControlStreamPayload(self: *TwilicCodec, stream_codec: ControlStreamCodec, payload: []const u8, out: *std.array_list.Managed(u8)) !void {
    _ = self;
    const framed = switch (stream_codec) {
        .Plain => try controlPlainEncode(payload, out.allocator),
        .Rle => try controlRleEncode(payload, out.allocator),
        .Bitpack => try controlBitpackEncode(payload, out.allocator),
        .Huffman => try controlHuffmanEncode(payload, out.allocator),
        .Fse => try controlFseEncode(payload, out.allocator),
    };
    defer out.allocator.free(framed);
    try wire.encodeBytes(framed, out);
}

fn readControlStreamPayload(self: *TwilicCodec, stream_codec: ControlStreamCodec, reader: *Reader) ![]u8 {
    const framed = try reader.readBytes(self.allocator);
    defer self.allocator.free(framed);
    return switch (stream_codec) {
        .Plain => controlPlainDecode(framed, self.allocator),
        .Rle => controlRleDecode(framed, self.allocator),
        .Bitpack => controlBitpackDecode(framed, self.allocator),
        .Huffman => controlHuffmanDecode(framed, self.allocator),
        .Fse => controlFseDecode(framed, self.allocator),
    };
}

fn controlPlainEncode(payload: []const u8, allocator: Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append(0);
    try out.appendSlice(payload);
    return out.toOwnedSlice();
}

fn controlPlainDecode(framed: []const u8, allocator: Allocator) ![]u8 {
    if (framed.len == 0) return TwilicError.InvalidData;
    if (framed[0] != 0) return TwilicError.InvalidData;
    return allocator.dupe(u8, framed[1..]);
}

fn controlRleEncode(payload: []const u8, allocator: Allocator) ![]u8 {
    var out = std.array_list.Managed(u8).init(allocator);
    defer out.deinit();
    try out.append(1);
    if (payload.len == 0) {
        try wire.encodeVaruint(0, &out);
        return out.toOwnedSlice();
    }

    var runs = std.array_list.Managed(struct { byte: u8, len: u64 }).init(allocator);
    defer runs.deinit();
    for (payload) |byte| {
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].byte == byte) {
            runs.items[runs.items.len - 1].len += 1;
        } else {
            try runs.append(.{ .byte = byte, .len = 1 });
        }
    }
    try wire.encodeVaruint(runs.items.len, &out);
    for (runs.items) |run| {
        try wire.encodeVaruint(run.len, &out);
        try out.append(run.byte);
    }

    var raw = std.array_list.Managed(u8).init(allocator);
    defer raw.deinit();
    try raw.append(0);
    try raw.appendSlice(payload);
    if (out.items.len < raw.items.len) {
        return out.toOwnedSlice();
    }
    return raw.toOwnedSlice();
}

fn controlRleDecode(framed: []const u8, allocator: Allocator) ![]u8 {
    if (framed.len == 0) return TwilicError.InvalidData;
    if (framed[0] == 0) {
        return allocator.dupe(u8, framed[1..]);
    }
    if (framed[0] != 1) return TwilicError.InvalidData;

    var reader = Reader.init(framed[1..]);
    const run_count = try readCount(&reader);
    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    var idx: usize = 0;
    while (idx < run_count) : (idx += 1) {
        const run_len = try readCount(&reader);
        const byte = try reader.readU8();
        try out.ensureUnusedCapacity(run_len);
        var j: usize = 0;
        while (j < run_len) : (j += 1) {
            out.appendAssumeCapacity(byte);
        }
    }
    if (!reader.isEof()) return TwilicError.InvalidData;
    return out.toOwnedSlice();
}

fn controlBitpackEncode(payload: []const u8, allocator: Allocator) ![]u8 {
    var raw = std.array_list.Managed(u8).init(allocator);
    defer raw.deinit();
    try raw.append(0);
    try raw.appendSlice(payload);

    if (payload.len == 0) {
        return raw.toOwnedSlice();
    }
    var max_value: u8 = 0;
    for (payload) |byte| {
        max_value = @max(max_value, byte);
    }
    const width: ?u8 = if (max_value <= 1)
        1
    else if (max_value <= 3)
        2
    else if (max_value <= 15)
        4
    else
        null;

    if (width == null) {
        return raw.toOwnedSlice();
    }

    var packed_bytes = std.array_list.Managed(u8).init(allocator);
    defer packed_bytes.deinit();
    try packed_bytes.append(width.?);
    try wire.encodeVaruint(payload.len, &packed_bytes);
    try packFixedWidthU8(payload, width.?, &packed_bytes);

    if (packed_bytes.items.len < raw.items.len) {
        return packed_bytes.toOwnedSlice();
    }
    return raw.toOwnedSlice();
}

fn controlBitpackDecode(framed: []const u8, allocator: Allocator) ![]u8 {
    if (framed.len == 0) return TwilicError.InvalidData;
    var reader = Reader.init(framed);
    const mode = try reader.readU8();
    return switch (mode) {
        0 => allocator.dupe(u8, framed[1..]),
        1, 2, 4 => blk: {
            const len = try readCount(&reader);
            const remaining = framed[reader.position()..];
            break :blk try unpackFixedWidthU8(remaining, len, mode, allocator);
        },
        else => TwilicError.InvalidData,
    };
}

fn controlHuffmanEncode(payload: []const u8, allocator: Allocator) ![]u8 {
    return controlPlainEncode(payload, allocator);
}

fn controlHuffmanDecode(framed: []const u8, allocator: Allocator) ![]u8 {
    if (framed.len == 0) return TwilicError.InvalidData;
    var reader = Reader.init(framed);
    const mode = try reader.readU8();
    return switch (mode) {
        0 => allocator.dupe(u8, framed[1..]),
        1 => blk: {
            const used = try readCount(&reader);
            var freqs = [_]u32{0} ** 256;
            var total: usize = 0;
            var idx: usize = 0;
            while (idx < used) : (idx += 1) {
                const symbol = try reader.readU8();
                const freq_u64 = try reader.readVaruint();
                const freq = std.math.cast(u32, freq_u64) orelse return TwilicError.InvalidData;
                freqs[symbol] = freq;
                total = std.math.add(usize, total, freq) catch return TwilicError.InvalidData;
            }
            if (total == 0) break :blk try allocator.alloc(u8, 0);

            const tree = (try buildHuffmanTree(&freqs, allocator)) orelse return TwilicError.InvalidData;
            defer allocator.free(tree.nodes);

            if (tree.nodes[tree.root] == .Leaf) {
                const symbol = tree.nodes[tree.root].Leaf;
                const out = try allocator.alloc(u8, total);
                @memset(out, symbol);
                break :blk out;
            }

            const bitstream = framed[reader.position()..];
            var out = std.array_list.Managed(u8).init(allocator);
            errdefer out.deinit();
            try out.ensureUnusedCapacity(total);

            var byte_idx: usize = 0;
            var bit_idx: u8 = 0;
            var produced: usize = 0;
            while (produced < total) : (produced += 1) {
                var node_idx = tree.root;
                while (true) {
                    switch (tree.nodes[node_idx]) {
                        .Leaf => |symbol| {
                            out.appendAssumeCapacity(symbol);
                            break;
                        },
                        .Internal => |edge| {
                            if (byte_idx >= bitstream.len) return TwilicError.InvalidData;
                            const byte = bitstream[byte_idx];
                            const bit = (byte >> @as(u3, @intCast(bit_idx))) & 1;
                            bit_idx += 1;
                            if (bit_idx == 8) {
                                bit_idx = 0;
                                byte_idx += 1;
                            }
                            node_idx = if (bit == 0) edge.left else edge.right;
                        },
                    }
                }
            }

            if (bit_idx > 0 and byte_idx < bitstream.len) {
                const lower_mask: u8 = (@as(u8, 1) << @as(u3, @intCast(bit_idx))) - 1;
                const trailing_mask: u8 = ~lower_mask;
                if ((bitstream[byte_idx] & trailing_mask) != 0) return TwilicError.InvalidData;
                byte_idx += 1;
            }
            for (bitstream[byte_idx..]) |byte| {
                if (byte != 0) return TwilicError.InvalidData;
            }
            break :blk out.toOwnedSlice();
        },
        else => TwilicError.InvalidData,
    };
}

fn controlFseEncode(payload: []const u8, allocator: Allocator) ![]u8 {
    return controlPlainEncode(payload, allocator);
}

fn controlFseDecode(framed: []const u8, allocator: Allocator) ![]u8 {
    if (framed.len == 0) return TwilicError.InvalidData;
    var reader = Reader.init(framed);
    const mode = try reader.readU8();
    const body = framed[reader.position()..];
    return switch (mode) {
        0 => allocator.dupe(u8, body),
        1 => controlBitpackDecode(body, allocator),
        2 => controlHuffmanDecode(body, allocator),
        3 => controlFseFrameDecode(body, allocator),
        else => TwilicError.InvalidData,
    };
}

const FSE_STATE_LOWER_BOUND: u32 = 1 << 23;

const HuffNode = union(enum) {
    Leaf: u8,
    Internal: struct { left: usize, right: usize },
};

const HuffBuildResult = struct {
    nodes: []HuffNode,
    root: usize,
};

const HuffEntry = struct {
    freq: u32,
    symbol: u16,
    idx: usize,
};

fn lessHuffEntry(a: HuffEntry, b: HuffEntry) bool {
    if (a.freq != b.freq) return a.freq < b.freq;
    if (a.symbol != b.symbol) return a.symbol < b.symbol;
    return a.idx < b.idx;
}

fn minHuffIndex(entries: []const HuffEntry) usize {
    var best: usize = 0;
    var idx: usize = 1;
    while (idx < entries.len) : (idx += 1) {
        if (lessHuffEntry(entries[idx], entries[best])) {
            best = idx;
        }
    }
    return best;
}

fn buildHuffmanTree(freqs: *const [256]u32, allocator: Allocator) !?HuffBuildResult {
    var nodes = std.array_list.Managed(HuffNode).init(allocator);
    errdefer nodes.deinit();
    var active = std.array_list.Managed(HuffEntry).init(allocator);
    defer active.deinit();

    var symbol: usize = 0;
    while (symbol < freqs.len) : (symbol += 1) {
        const freq = freqs[symbol];
        if (freq == 0) continue;
        try nodes.append(.{ .Leaf = @intCast(symbol) });
        try active.append(.{
            .freq = freq,
            .symbol = @intCast(symbol),
            .idx = nodes.items.len - 1,
        });
    }

    if (active.items.len == 0) return null;

    while (active.items.len > 1) {
        const first_idx = minHuffIndex(active.items);
        const first = active.swapRemove(first_idx);
        const second_idx = minHuffIndex(active.items);
        const second = active.swapRemove(second_idx);

        try nodes.append(.{ .Internal = .{
            .left = first.idx,
            .right = second.idx,
        } });
        const parent_idx = nodes.items.len - 1;
        const merged_freq = std.math.add(u32, first.freq, second.freq) catch std.math.maxInt(u32);
        try active.append(.{
            .freq = merged_freq,
            .symbol = if (first.symbol <= second.symbol) first.symbol else second.symbol,
            .idx = parent_idx,
        });
    }

    return .{
        .nodes = try nodes.toOwnedSlice(),
        .root = active.items[0].idx,
    };
}

fn controlFseFrameDecode(input: []const u8, allocator: Allocator) ![]u8 {
    var reader = Reader.init(input);
    const table_log = try reader.readU8();
    if (table_log == 0 or table_log > 12) return TwilicError.InvalidData;

    const table_size: u32 = @as(u32, 1) << @as(u5, @intCast(table_log));
    const len = try readCount(&reader);
    const used = try readCount(&reader);
    if (used > 256 or used > table_size) return TwilicError.InvalidData;

    var freqs = [_]u16{0} ** 256;
    var seen = [_]bool{false} ** 256;
    var sum: u32 = 0;
    var idx: usize = 0;
    while (idx < used) : (idx += 1) {
        const symbol = try reader.readU8();
        if (seen[symbol]) return TwilicError.InvalidData;
        seen[symbol] = true;

        const freq_u64 = try reader.readVaruint();
        if (freq_u64 == 0 or freq_u64 > table_size) return TwilicError.InvalidData;
        const freq = std.math.cast(u16, freq_u64) orelse return TwilicError.InvalidData;
        freqs[symbol] = freq;
        sum = std.math.add(u32, sum, freq) catch return TwilicError.InvalidData;
    }
    if (sum != table_size) return TwilicError.InvalidData;

    var cumul = [_]u32{0} ** 256;
    var running: u32 = 0;
    for (freqs, 0..) |freq, symbol_idx| {
        cumul[symbol_idx] = running;
        running = std.math.add(u32, running, freq) catch return TwilicError.InvalidData;
    }

    const table_len = std.math.cast(usize, table_size) orelse return TwilicError.InvalidData;
    const decode_table = try allocator.alloc(u8, table_len);
    defer allocator.free(decode_table);
    for (freqs, 0..) |freq, symbol_idx| {
        const freq_u32 = @as(u32, freq);
        if (freq_u32 == 0) continue;
        const start = cumul[symbol_idx];
        var slot = start;
        while (slot < start + freq_u32) : (slot += 1) {
            decode_table[slot] = @intCast(symbol_idx);
        }
    }

    const state_u64 = try reader.readVaruint();
    if (state_u64 > std.math.maxInt(u32)) return TwilicError.InvalidData;
    var state: u32 = @intCast(state_u64);

    const renorm = input[reader.position()..];
    var renorm_idx = renorm.len;
    const mask = table_size - 1;

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.ensureUnusedCapacity(len);

    var produced: usize = 0;
    while (produced < len) : (produced += 1) {
        const slot = std.math.cast(usize, state & mask) orelse return TwilicError.InvalidData;
        if (slot >= decode_table.len) return TwilicError.InvalidData;
        const symbol = decode_table[slot];
        out.appendAssumeCapacity(symbol);

        const freq = @as(u32, freqs[symbol]);
        if (freq == 0) return TwilicError.InvalidData;
        const start = cumul[symbol];
        const low = state & mask;
        if (low < start) return TwilicError.InvalidData;
        const delta = low - start;
        const base = std.math.mul(u32, freq, state >> @as(u5, @intCast(table_log))) catch return TwilicError.InvalidData;
        state = std.math.add(u32, base, delta) catch return TwilicError.InvalidData;

        while (state < FSE_STATE_LOWER_BOUND) {
            if (renorm_idx == 0) return TwilicError.InvalidData;
            renorm_idx -= 1;
            state = (state << 8) | renorm[renorm_idx];
        }
    }

    for (renorm[0..renorm_idx]) |byte| {
        if (byte != 0) return TwilicError.InvalidData;
    }
    return out.toOwnedSlice();
}

fn packFixedWidthU8(values: []const u8, width: u8, out: *std.array_list.Managed(u8)) !void {
    if (width == 0 or width > 8) return TwilicError.InvalidData;
    var acc: u64 = 0;
    var acc_bits: u8 = 0;
    for (values) |value| {
        if ((value >> @as(u3, @intCast(width))) != 0) return TwilicError.InvalidData;
        acc |= (@as(u64, value) << @as(u6, @intCast(acc_bits)));
        acc_bits += width;
        while (acc_bits >= 8) {
            try out.append(@intCast(acc & 0xff));
            acc >>= 8;
            acc_bits -= 8;
        }
    }
    if (acc_bits > 0) {
        try out.append(@intCast(acc & 0xff));
    }
}

fn unpackFixedWidthU8(bytes: []const u8, len: usize, width: u8, allocator: Allocator) ![]u8 {
    if (width == 0 or width > 8) return TwilicError.InvalidData;
    const out = try allocator.alloc(u8, len);
    errdefer allocator.free(out);
    var acc: u64 = 0;
    var acc_bits: u8 = 0;
    var idx: usize = 0;
    for (out) |*slot| {
        while (acc_bits < width) {
            if (idx >= bytes.len) return TwilicError.InvalidData;
            acc |= (@as(u64, bytes[idx]) << @as(u6, @intCast(acc_bits)));
            idx += 1;
            acc_bits += 8;
        }
        const mask: u64 = (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
        slot.* = @intCast(acc & mask);
        acc >>= @as(u6, @intCast(width));
        acc_bits -= width;
    }
    return out;
}

fn packFixedWidthU64(values: []const u64, width: u8, out: *std.array_list.Managed(u8)) !void {
    if (width > 64) return TwilicError.InvalidData;
    if (width == 0) {
        for (values) |value| {
            if (value != 0) return TwilicError.InvalidData;
        }
        return;
    }
    var acc: u128 = 0;
    var acc_bits: u8 = 0;
    for (values) |value| {
        if (width < 64 and (value >> @as(u6, @intCast(width))) != 0) return TwilicError.InvalidData;
        acc |= (@as(u128, value) << @as(std.math.Log2Int(u128), @intCast(acc_bits)));
        acc_bits += width;
        while (acc_bits >= 8) {
            try out.append(@intCast(acc & 0xff));
            acc >>= 8;
            acc_bits -= 8;
        }
    }
    if (acc_bits > 0) {
        try out.append(@intCast(acc & 0xff));
    }
}

fn unpackFixedWidthU64(bytes: []const u8, len: usize, width: u8, allocator: Allocator) ![]u64 {
    if (width > 64) return TwilicError.InvalidData;
    const out = try allocator.alloc(u64, len);
    errdefer allocator.free(out);
    if (width == 0) {
        @memset(out, 0);
        return out;
    }
    var acc: u128 = 0;
    var acc_bits: u8 = 0;
    var idx: usize = 0;
    for (out) |*slot| {
        while (acc_bits < width) {
            if (idx >= bytes.len) return TwilicError.InvalidData;
            acc |= (@as(u128, bytes[idx]) << @as(std.math.Log2Int(u128), @intCast(acc_bits)));
            idx += 1;
            acc_bits += 8;
        }
        const mask: u128 = if (width == 64)
            @as(u128, std.math.maxInt(u64))
        else
            ((@as(u128, 1) << @as(std.math.Log2Int(u128), @intCast(width))) - 1);
        slot.* = @intCast(acc & mask);
        acc >>= @as(std.math.Log2Int(u128), @intCast(width));
        acc_bits -= width;
    }
    return out;
}

fn supportsStatePatch(base: Message, current: Message) bool {
    return switch (base) {
        .Scalar => current == .Scalar,
        .Array => current == .Array,
        .Map => |a| blk: {
            if (current != .Map) break :blk false;
            const b = current.Map;
            if (a.len != b.len) break :blk false;
            for (a, 0..) |entry, idx| {
                if (!KeyRef.eql(entry.key, b[idx].key)) break :blk false;
            }
            break :blk true;
        },
        .ShapedObject => |a| current == .ShapedObject and a.shape_id == current.ShapedObject.shape_id,
        .SchemaObject => |a| current == .SchemaObject and a.schema_id == current.SchemaObject.schema_id,
        .TypedVector => |a| current == .TypedVector and a.element_type == current.TypedVector.element_type,
        else => false,
    };
}

fn applyStatePatch(self: *TwilicCodec, base_ref: BaseRef, operations: []const PatchOperation, literals: []const Value) !?Message {
    var base_owned: ?Message = null;
    defer if (base_owned) |*message| {
        message.deinit(self.allocator);
    };

    const base_ptr: *const Message = switch (base_ref) {
        .Previous => blk: {
            const previous = self.state.previous_message orelse return self.referenceError();
            base_owned = try previous.clone(self.allocator);
            break :blk &base_owned.?;
        },
        .BaseId => |id| self.state.getBaseSnapshot(id) orelse return self.referenceError(),
    };
    const base = base_ptr.*;

    if (base == .Map) {
        return try applyStatePatchMap(base.Map, operations, literals, self.allocator);
    }

    var fields = try messageFields(base, self.allocator);
    defer freeValues(fields, self.allocator);

    var literal_idx: usize = 0;
    for (operations) |operation| {
        const idx = std.math.cast(usize, operation.field_id) orelse return TwilicError.InvalidData;
        switch (operation.opcode) {
            .Keep => {},
            .ReplaceScalar, .ReplaceVector, .StringRef, .PrefixDelta => {
                const value = if (operation.value) |v|
                    try v.clone(self.allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(self.allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                if (idx >= fields.len) {
                    var doomed = value;
                    doomed.deinit(self.allocator);
                    return TwilicError.InvalidData;
                }
                fields[idx].deinit(self.allocator);
                fields[idx] = value;
            },
            .InsertField => {
                if (idx > fields.len) return TwilicError.InvalidData;
                const value = if (operation.value) |v|
                    try v.clone(self.allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(self.allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                fields = try insertValue(fields, idx, value, self.allocator);
            },
            .DeleteField => {
                if (idx >= fields.len) return TwilicError.InvalidData;
                const removed = try removeValue(fields, idx, self.allocator);
                var removed_value = removed.removed;
                removed_value.deinit(self.allocator);
                fields = removed.remaining;
            },
            .AppendVector => {
                var value = if (operation.value) |v|
                    try v.clone(self.allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(self.allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                defer value.deinit(self.allocator);
                if (idx >= fields.len or fields[idx] != .Array or value != .Array) return TwilicError.InvalidData;
                const appended = try appendValues(fields[idx].Array, value.Array, self.allocator);
                fields[idx].deinit(self.allocator);
                fields[idx] = .{ .Array = appended };
            },
            .TruncateVector => {
                var value = if (operation.value) |v|
                    try v.clone(self.allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(self.allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                defer value.deinit(self.allocator);
                const keep = switch (value) {
                    .U64 => |v| std.math.cast(usize, v) orelse return TwilicError.InvalidData,
                    .I64 => |v| if (v >= 0) @as(usize, @intCast(v)) else return TwilicError.InvalidData,
                    else => return TwilicError.InvalidData,
                };
                if (idx >= fields.len or fields[idx] != .Array) return TwilicError.InvalidData;
                const original = fields[idx].Array;
                const next_len = @min(keep, original.len);
                const truncated = try cloneValues(original[0..next_len], self.allocator);
                fields[idx].deinit(self.allocator);
                fields[idx] = .{ .Array = truncated };
            },
        }
    }

    return rebuildMessageLike(base, fields, self.allocator);
}

fn applyStatePatchMap(base_entries: []const MapEntry, operations: []const PatchOperation, literals: []const Value, allocator: Allocator) !Message {
    var entries = try cloneMapEntries(base_entries, allocator);
    errdefer {
        for (entries) |*entry| {
            entry.deinit(allocator);
        }
        allocator.free(entries);
    }

    var literal_idx: usize = 0;
    for (operations) |operation| {
        const idx = std.math.cast(usize, operation.field_id) orelse return TwilicError.InvalidData;
        switch (operation.opcode) {
            .Keep => {},
            .ReplaceScalar, .ReplaceVector, .StringRef, .PrefixDelta => {
                const value = if (operation.value) |v|
                    try v.clone(allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                if (idx >= entries.len) {
                    var doomed = value;
                    doomed.deinit(allocator);
                    return TwilicError.InvalidData;
                }
                entries[idx].value.deinit(allocator);
                entries[idx].value = value;
            },
            .InsertField => {
                if (idx > entries.len) return TwilicError.InvalidData;
                const value = if (operation.value) |v|
                    try v.clone(allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                const entry = try mapEntryFromPatchValue(value, allocator);
                entries = try insertMapEntry(entries, idx, entry, allocator);
            },
            .DeleteField => {
                if (idx >= entries.len) return TwilicError.InvalidData;
                const removed = try removeMapEntry(entries, idx, allocator);
                var removed_entry = removed.removed;
                removed_entry.deinit(allocator);
                entries = removed.remaining;
            },
            .AppendVector => {
                var value = if (operation.value) |v|
                    try v.clone(allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                defer value.deinit(allocator);
                if (idx >= entries.len or entries[idx].value != .Array or value != .Array) return TwilicError.InvalidData;
                const appended = try appendValues(entries[idx].value.Array, value.Array, allocator);
                entries[idx].value.deinit(allocator);
                entries[idx].value = .{ .Array = appended };
            },
            .TruncateVector => {
                var value = if (operation.value) |v|
                    try v.clone(allocator)
                else blk: {
                    if (literal_idx >= literals.len) return TwilicError.InvalidData;
                    const v = try literals[literal_idx].clone(allocator);
                    literal_idx += 1;
                    break :blk v;
                };
                defer value.deinit(allocator);
                const keep = switch (value) {
                    .U64 => |v| std.math.cast(usize, v) orelse return TwilicError.InvalidData,
                    .I64 => |v| if (v >= 0) @as(usize, @intCast(v)) else return TwilicError.InvalidData,
                    else => return TwilicError.InvalidData,
                };
                if (idx >= entries.len or entries[idx].value != .Array) return TwilicError.InvalidData;
                const original = entries[idx].value.Array;
                const next_len = @min(keep, original.len);
                const truncated = try cloneValues(original[0..next_len], allocator);
                entries[idx].value.deinit(allocator);
                entries[idx].value = .{ .Array = truncated };
            },
        }
    }

    return .{ .Map = entries };
}

fn mapEntryFromPatchValue(value: Value, allocator: Allocator) !MapEntry {
    var map_value = value;
    if (map_value != .Map) {
        map_value.deinit(allocator);
        return TwilicError.InvalidData;
    }
    if (map_value.Map.len != 1) {
        map_value.deinit(allocator);
        return TwilicError.InvalidData;
    }
    const map_entry = map_value.Map[0];
    allocator.free(map_value.Map);
    return .{
        .key = .{ .Literal = map_entry.key },
        .value = map_entry.value,
    };
}

fn messageFields(message: Message, allocator: Allocator) ![]Value {
    return switch (message) {
        .Scalar => |value| blk: {
            const out = try allocator.alloc(Value, 1);
            out[0] = try value.clone(allocator);
            break :blk out;
        },
        .Array => |values| try cloneValues(values, allocator),
        .Map => |entries| blk: {
            const out = try allocator.alloc(Value, entries.len);
            for (entries, 0..) |entry, idx| {
                out[idx] = try entry.value.clone(allocator);
            }
            break :blk out;
        },
        .ShapedObject => |shaped| try cloneValues(shaped.values, allocator),
        .SchemaObject => |schema_obj| try cloneValues(schema_obj.fields, allocator),
        .TypedVector => |vector| blk: {
            const value = try typedVectorToValue(vector, allocator);
            errdefer {
                var tmp = value;
                tmp.deinit(allocator);
            }
            if (value != .Array) return allocator.alloc(Value, 0);
            break :blk value.Array;
        },
        .RowBatch => |batch| blk: {
            var out = std.array_list.Managed(Value).init(allocator);
            errdefer out.deinit();
            for (batch.rows) |row| {
                for (row) |field| {
                    try out.append(try field.clone(allocator));
                }
            }
            break :blk out.toOwnedSlice();
        },
        .ColumnBatch => |batch| blk: {
            var out = std.array_list.Managed(Value).init(allocator);
            errdefer out.deinit();
            for (batch.columns) |column| {
                switch (column.values) {
                    .Bool => |values| for (values) |v| try out.append(.{ .Bool = v }),
                    .I64 => |values| for (values) |v| try out.append(.{ .I64 = v }),
                    .U64 => |values| for (values) |v| try out.append(.{ .U64 = v }),
                    .F64 => |values| for (values) |v| try out.append(.{ .F64 = v }),
                    .String => |values| for (values) |v| try out.append(.{ .String = try allocator.dupe(u8, v) }),
                    .Binary => |values| for (values) |v| try out.append(.{ .Binary = try allocator.dupe(u8, v) }),
                    .Value => |values| for (values) |v| try out.append(try v.clone(allocator)),
                }
            }
            break :blk out.toOwnedSlice();
        },
        else => try allocator.alloc(Value, 0),
    };
}

fn rebuildMessageLike(base: Message, fields: []const Value, allocator: Allocator) !?Message {
    return switch (base) {
        .Scalar => blk: {
            if (fields.len == 0) {
                break :blk Message{ .Scalar = .{ .Null = {} } };
            }
            break :blk Message{ .Scalar = try fields[0].clone(allocator) };
        },
        .Array => .{ .Array = try cloneValues(fields, allocator) },
        .Map => |entries| blk: {
            if (fields.len != entries.len) return TwilicError.InvalidData;
            const out = try allocator.alloc(MapEntry, entries.len);
            for (entries, 0..) |entry, idx| {
                out[idx] = .{
                    .key = try entry.key.clone(allocator),
                    .value = try fields[idx].clone(allocator),
                };
            }
            break :blk Message{ .Map = out };
        },
        .ShapedObject => |shaped| .{ .ShapedObject = .{
            .shape_id = shaped.shape_id,
            .presence = if (shaped.presence) |bits| try allocator.dupe(bool, bits) else null,
            .values = try cloneValues(fields, allocator),
        } },
        .SchemaObject => |schema_obj| .{ .SchemaObject = .{
            .schema_id = schema_obj.schema_id,
            .presence = if (schema_obj.presence) |bits| try allocator.dupe(bool, bits) else null,
            .fields = try cloneValues(fields, allocator),
        } },
        .TypedVector => |vector| blk: {
            const data: TypedVectorData = switch (vector.element_type) {
                .Bool => blk_bool: {
                    const out = try allocator.alloc(bool, fields.len);
                    for (fields, 0..) |field, idx| {
                        if (field != .Bool) {
                            allocator.free(out);
                            return TwilicError.InvalidData;
                        }
                        out[idx] = field.Bool;
                    }
                    break :blk_bool .{ .Bool = out };
                },
                .I64 => blk_i64: {
                    const out = try allocator.alloc(i64, fields.len);
                    for (fields, 0..) |field, idx| {
                        if (field != .I64) {
                            allocator.free(out);
                            return TwilicError.InvalidData;
                        }
                        out[idx] = field.I64;
                    }
                    break :blk_i64 .{ .I64 = out };
                },
                .U64 => blk_u64: {
                    const out = try allocator.alloc(u64, fields.len);
                    for (fields, 0..) |field, idx| {
                        if (field != .U64) {
                            allocator.free(out);
                            return TwilicError.InvalidData;
                        }
                        out[idx] = field.U64;
                    }
                    break :blk_u64 .{ .U64 = out };
                },
                .F64 => blk_f64: {
                    const out = try allocator.alloc(f64, fields.len);
                    for (fields, 0..) |field, idx| {
                        if (field != .F64) {
                            allocator.free(out);
                            return TwilicError.InvalidData;
                        }
                        out[idx] = field.F64;
                    }
                    break :blk_f64 .{ .F64 = out };
                },
                .String => blk_string: {
                    const out = try allocator.alloc([]u8, fields.len);
                    for (fields, 0..) |field, idx| {
                        if (field != .String) {
                            for (out[0..idx]) |value| allocator.free(value);
                            allocator.free(out);
                            return TwilicError.InvalidData;
                        }
                        out[idx] = try allocator.dupe(u8, field.String);
                    }
                    break :blk_string .{ .String = out };
                },
                .Binary => blk_binary: {
                    const out = try allocator.alloc([]u8, fields.len);
                    for (fields, 0..) |field, idx| {
                        if (field != .Binary) {
                            for (out[0..idx]) |value| allocator.free(value);
                            allocator.free(out);
                            return TwilicError.InvalidData;
                        }
                        out[idx] = try allocator.dupe(u8, field.Binary);
                    }
                    break :blk_binary .{ .Binary = out };
                },
                .Value => .{ .Value = try cloneValues(fields, allocator) },
            };
            break :blk Message{ .TypedVector = .{
                .element_type = vector.element_type,
                .codec = vector.codec,
                .data = data,
            } };
        },
        else => null,
    };
}

fn diffMessage(prev: Message, current: Message, allocator: Allocator) !PatchDiff {
    const prev_fields = try messageFields(prev, allocator);
    defer freeValues(prev_fields, allocator);
    const curr_fields = try messageFields(current, allocator);
    defer freeValues(curr_fields, allocator);

    const max_len = @max(prev_fields.len, curr_fields.len);
    var out = std.array_list.Managed(PatchOperation).init(allocator);
    errdefer out.deinit();
    var changed: usize = 0;
    var idx: usize = 0;
    while (idx < max_len) : (idx += 1) {
        const p = if (idx < prev_fields.len) prev_fields[idx] else null;
        const c = if (idx < curr_fields.len) curr_fields[idx] else null;

        if (idx < prev_fields.len and idx < curr_fields.len and Value.eql(prev_fields[idx], curr_fields[idx])) {
            continue;
        }

        if (idx < prev_fields.len and idx < curr_fields.len) {
            changed += 1;
            try out.append(.{
                .field_id = @intCast(idx),
                .opcode = .ReplaceScalar,
                .value = try curr_fields[idx].clone(allocator),
            });
        } else if (idx < prev_fields.len) {
            changed += 1;
            try out.append(.{
                .field_id = @intCast(idx),
                .opcode = .DeleteField,
                .value = null,
            });
        } else if (idx < curr_fields.len) {
            changed += 1;
            try out.append(.{
                .field_id = @intCast(idx),
                .opcode = .InsertField,
                .value = try curr_fields[idx].clone(allocator),
            });
        } else {
            _ = p;
            _ = c;
        }
    }

    return .{ .ops = try out.toOwnedSlice(), .changed = changed };
}

fn encodedSize(message: Message, allocator: Allocator) !usize {
    var temp = TwilicCodec.init(allocator, .{});
    defer temp.deinit();
    const bytes = try temp.encodeMessage(&message);
    defer allocator.free(bytes);
    return bytes.len;
}

fn estimatedPatchSizeWithBase(base_ref: BaseRef, ops: []const PatchOperation, allocator: Allocator) !usize {
    var patch = Message{ .StatePatch = .{
        .base_ref = base_ref,
        .operations = try clonePatchOps(ops, allocator),
        .literals = try allocator.alloc(Value, 0),
    } };
    defer patch.deinit(allocator);
    return encodedSize(patch, allocator);
}

fn hasUniformMicroBatchShape(values: []const Value) bool {
    if (values.len == 0) return true;
    switch (values[0]) {
        .Map => |first_entries| {
            for (values) |value| {
                if (value != .Map) return false;
                const entries = value.Map;
                if (entries.len != first_entries.len) return false;
                for (entries, 0..) |entry, idx| {
                    if (!std.mem.eql(u8, entry.key, first_entries[idx].key)) return false;
                }
            }
            return true;
        },
        else => {
            for (values) |value| {
                if (value != @as(model.ValueTag, @enumFromInt(@intFromEnum(values[0])))) return false;
            }
            return true;
        },
    }
}

fn templateDescriptorFromColumns(template_id: u64, columns: []const Column, allocator: Allocator) !TemplateDescriptor {
    const field_ids = try allocator.alloc(u64, columns.len);
    errdefer allocator.free(field_ids);
    const null_strategies = try allocator.alloc(NullStrategy, columns.len);
    errdefer allocator.free(null_strategies);
    const codecs = try allocator.alloc(VectorCodec, columns.len);
    errdefer allocator.free(codecs);

    for (columns, 0..) |column, idx| {
        field_ids[idx] = column.field_id;
        null_strategies[idx] = column.null_strategy;
        codecs[idx] = column.codec;
    }

    return .{
        .template_id = template_id,
        .field_ids = field_ids,
        .null_strategies = null_strategies,
        .codecs = codecs,
    };
}

fn findTemplateId(templates: *const std.AutoHashMapUnmanaged(u64, TemplateDescriptor), probe: TemplateDescriptor) ?u64 {
    var it = templates.iterator();
    var best: ?u64 = null;
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        const descriptor = entry.value_ptr.*;
        if (std.mem.eql(u64, descriptor.field_ids, probe.field_ids) and
            std.mem.eql(NullStrategy, descriptor.null_strategies, probe.null_strategies) and
            std.mem.eql(VectorCodec, descriptor.codecs, probe.codecs))
        {
            if (best == null or id < best.?) {
                best = id;
            }
        }
    }
    return best;
}

fn diffTemplateColumns(previous: []const Column, current: []const Column, allocator: Allocator) !TemplateColumnDiff {
    const len = @max(previous.len, current.len);
    const mask = try allocator.alloc(bool, len);
    errdefer allocator.free(mask);
    var changed = std.array_list.Managed(Column).init(allocator);
    errdefer changed.deinit();

    var idx: usize = 0;
    while (idx < len) : (idx += 1) {
        const p = if (idx < previous.len) previous[idx] else null;
        const c = if (idx < current.len) current[idx] else null;
        if (idx < previous.len and idx < current.len and Column.eql(previous[idx], current[idx])) {
            mask[idx] = false;
        } else {
            mask[idx] = true;
            if (idx < current.len) {
                try changed.append(try current[idx].clone(allocator));
            }
        }
        _ = p;
        _ = c;
    }

    return .{ .mask = mask, .columns = try changed.toOwnedSlice() };
}

fn mergeTemplateColumns(previous: []const Column, changed_mask: []const bool, changed_columns: []const Column, allocator: Allocator) ![]Column {
    var changed_idx: usize = 0;
    const out = try allocator.alloc(Column, changed_mask.len);
    errdefer allocator.free(out);
    for (changed_mask, 0..) |changed, idx| {
        if (changed) {
            if (changed_idx >= changed_columns.len) return TwilicError.InvalidData;
            out[idx] = try changed_columns[changed_idx].clone(allocator);
            changed_idx += 1;
        } else {
            if (idx >= previous.len) return TwilicError.InvalidData;
            out[idx] = try previous[idx].clone(allocator);
        }
    }
    if (changed_idx != changed_columns.len) return TwilicError.InvalidData;
    return out;
}

fn putTemplateDescriptor(codec_state: *TwilicCodec, descriptor: TemplateDescriptor) !void {
    if (codec_state.state.templates.getPtr(descriptor.template_id)) |existing| {
        existing.deinit(codec_state.allocator);
        existing.* = descriptor;
        return;
    }
    try codec_state.state.templates.put(codec_state.allocator, descriptor.template_id, descriptor);
}

fn putTemplateColumns(codec_state: *TwilicCodec, template_id: u64, columns: []const Column) !void {
    const cloned = try cloneColumns(columns, codec_state.allocator);
    errdefer {
        for (cloned) |*column| {
            column.deinit(codec_state.allocator);
        }
        codec_state.allocator.free(cloned);
    }

    if (codec_state.state.template_columns.getPtr(template_id)) |existing| {
        for (existing.*) |*column| {
            column.deinit(codec_state.allocator);
        }
        codec_state.allocator.free(existing.*);
        existing.* = cloned;
        return;
    }
    try codec_state.state.template_columns.put(codec_state.allocator, template_id, cloned);
}

fn allTrueMask(len: usize, allocator: Allocator) ![]bool {
    const out = try allocator.alloc(bool, len);
    @memset(out, true);
    return out;
}

fn clonePatchOps(ops: []const PatchOperation, allocator: Allocator) ![]PatchOperation {
    const out = try allocator.alloc(PatchOperation, ops.len);
    errdefer allocator.free(out);
    for (ops, 0..) |op, idx| {
        out[idx] = try op.clone(allocator);
    }
    return out;
}

fn cloneColumns(columns: []const Column, allocator: Allocator) ![]Column {
    const out = try allocator.alloc(Column, columns.len);
    errdefer allocator.free(out);
    for (columns, 0..) |column, idx| {
        out[idx] = try column.clone(allocator);
    }
    return out;
}

fn cloneMapEntries(entries: []const MapEntry, allocator: Allocator) ![]MapEntry {
    const out = try allocator.alloc(MapEntry, entries.len);
    errdefer allocator.free(out);
    for (entries, 0..) |entry, idx| {
        out[idx] = try entry.clone(allocator);
    }
    return out;
}

fn freeValues(values: []Value, allocator: Allocator) void {
    for (values) |*value| {
        value.deinit(allocator);
    }
    allocator.free(values);
}

fn insertValue(values: []Value, index: usize, value: Value, allocator: Allocator) ![]Value {
    const out = try allocator.alloc(Value, values.len + 1);
    errdefer allocator.free(out);
    if (index > 0) {
        for (values[0..index], 0..) |v, idx| {
            out[idx] = v;
        }
    }
    out[index] = value;
    if (index < values.len) {
        for (values[index..], 0..) |v, idx| {
            out[index + 1 + idx] = v;
        }
    }
    allocator.free(values);
    return out;
}

fn removeValue(values: []Value, index: usize, allocator: Allocator) !struct { remaining: []Value, removed: Value } {
    const removed = values[index];
    const out = try allocator.alloc(Value, values.len - 1);
    var out_idx: usize = 0;
    for (values, 0..) |value, idx| {
        if (idx == index) continue;
        out[out_idx] = value;
        out_idx += 1;
    }
    allocator.free(values);
    return .{ .remaining = out, .removed = removed };
}

fn insertMapEntry(entries: []MapEntry, index: usize, entry: MapEntry, allocator: Allocator) ![]MapEntry {
    const out = try allocator.alloc(MapEntry, entries.len + 1);
    errdefer allocator.free(out);
    if (index > 0) {
        for (entries[0..index], 0..) |v, idx| {
            out[idx] = v;
        }
    }
    out[index] = entry;
    if (index < entries.len) {
        for (entries[index..], 0..) |v, idx| {
            out[index + 1 + idx] = v;
        }
    }
    allocator.free(entries);
    return out;
}

fn removeMapEntry(entries: []MapEntry, index: usize, allocator: Allocator) !struct { remaining: []MapEntry, removed: MapEntry } {
    const removed = entries[index];
    const out = try allocator.alloc(MapEntry, entries.len - 1);
    var out_idx: usize = 0;
    for (entries, 0..) |entry, idx| {
        if (idx == index) continue;
        out[out_idx] = entry;
        out_idx += 1;
    }
    allocator.free(entries);
    return .{ .remaining = out, .removed = removed };
}

fn appendValues(base: []const Value, append: []const Value, allocator: Allocator) ![]Value {
    const out = try allocator.alloc(Value, base.len + append.len);
    errdefer allocator.free(out);
    for (base, 0..) |value, idx| {
        out[idx] = try value.clone(allocator);
    }
    for (append, 0..) |value, idx| {
        out[base.len + idx] = try value.clone(allocator);
    }
    return out;
}

fn boundRecordFromValue(schema: Schema, value: *const Value, allocator: Allocator) !model.BoundRecord {
    if (value.* != .Map) return TwilicError.InvalidData;
    var fields = std.array_list.Managed(Value).init(allocator);
    errdefer fields.deinit();
    var optional_presence = std.array_list.Managed(bool).init(allocator);
    defer optional_presence.deinit();
    var has_absent_optional = false;

    for (schema.fields) |field| {
        const field_value = lookupMapField(value.*, field.name);
        if (field.required) {
            if (field_value) |v| {
                try fields.append(try v.clone(allocator));
            } else if (field.default_value) |default| {
                try fields.append(try default.clone(allocator));
            } else {
                return TwilicError.InvalidData;
            }
        } else {
            if (field_value) |v| {
                try optional_presence.append(true);
                try fields.append(try v.clone(allocator));
            } else {
                try optional_presence.append(false);
                has_absent_optional = true;
            }
        }
    }

    const presence: ?[]bool = if (has_absent_optional)
        try allocator.dupe(bool, optional_presence.items)
    else
        null;

    return .{
        .presence = presence,
        .fields = try fields.toOwnedSlice(),
    };
}

fn schemaColumnsFromValues(schema: Schema, values: []const Value, allocator: Allocator) ![]Column {
    const columns = try allocator.alloc(Column, schema.fields.len);
    errdefer allocator.free(columns);

    for (schema.fields, 0..) |field, col_idx| {
        var column_values = std.array_list.Managed(Value).init(allocator);
        defer {
            for (column_values.items) |*v| v.deinit(allocator);
            column_values.deinit();
        }
        var present_bits = std.array_list.Managed(bool).init(allocator);
        defer present_bits.deinit();
        var has_absent = false;

        for (values) |value| {
            if (lookupMapField(value, field.name)) |v| {
                try present_bits.append(true);
                try column_values.append(try v.clone(allocator));
            } else if (field.required) {
                if (field.default_value) |default| {
                    try present_bits.append(true);
                    try column_values.append(try default.clone(allocator));
                } else {
                    return TwilicError.InvalidData;
                }
            } else {
                try present_bits.append(false);
                has_absent = true;
            }
        }

        const null_strategy: NullStrategy = if (has_absent)
            .PresenceBitmap
        else
            .None;

        const presence: ?[]bool = if (has_absent)
            try allocator.dupe(bool, present_bits.items)
        else
            null;

        const non_null = try stripNulls(column_values.items, allocator);
        defer {
            for (non_null) |*v| v.deinit(allocator);
            allocator.free(non_null);
        }
        const infer = try inferColumnCodecAndValues(non_null, allocator);

        columns[col_idx] = .{
            .field_id = field.number,
            .null_strategy = null_strategy,
            .presence = presence,
            .codec = infer.codec,
            .dictionary_id = null,
            .values = infer.values,
        };
    }

    return columns;
}
