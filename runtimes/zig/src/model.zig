const std = @import("std");

const Allocator = std.mem.Allocator;

pub const MessageKind = enum(u8) {
    Scalar = 0x00,
    Array = 0x01,
    Map = 0x02,
    ShapedObject = 0x03,
    SchemaObject = 0x04,
    TypedVector = 0x05,
    RowBatch = 0x06,
    ColumnBatch = 0x07,
    Control = 0x08,
    Ext = 0x09,
    StatePatch = 0x0A,
    TemplateBatch = 0x0B,
    ControlStream = 0x0C,
    BaseSnapshot = 0x0D,
    SchemaBatch = 0x0E,
    BoundStream = 0x0F,

    pub fn fromByte(byte: u8) ?MessageKind {
        return switch (byte) {
            0x00 => .Scalar,
            0x01 => .Array,
            0x02 => .Map,
            0x03 => .ShapedObject,
            0x04 => .SchemaObject,
            0x05 => .TypedVector,
            0x06 => .RowBatch,
            0x07 => .ColumnBatch,
            0x08 => .Control,
            0x09 => .Ext,
            0x0A => .StatePatch,
            0x0B => .TemplateBatch,
            0x0C => .ControlStream,
            0x0D => .BaseSnapshot,
            0x0E => .SchemaBatch,
            0x0F => .BoundStream,
            else => null,
        };
    }
};

pub const ValueTag = enum {
    Null,
    Bool,
    I64,
    U64,
    F64,
    String,
    Binary,
    Array,
    Map,
};

pub const ValueMapEntry = struct {
    key: []u8,
    value: Value,

    pub fn clone(self: ValueMapEntry, allocator: Allocator) Allocator.Error!ValueMapEntry {
        return .{
            .key = try allocator.dupe(u8, self.key),
            .value = try self.value.clone(allocator),
        };
    }

    pub fn deinit(self: *ValueMapEntry, allocator: Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
    }

    pub fn eql(a: ValueMapEntry, b: ValueMapEntry) bool {
        return std.mem.eql(u8, a.key, b.key) and Value.eql(a.value, b.value);
    }
};

pub const Value = union(ValueTag) {
    Null: void,
    Bool: bool,
    I64: i64,
    U64: u64,
    F64: f64,
    String: []u8,
    Binary: []u8,
    Array: []Value,
    Map: []ValueMapEntry,

    pub fn isScalar(self: Value) bool {
        return switch (self) {
            .Array, .Map => false,
            else => true,
        };
    }

    pub fn clone(self: Value, allocator: Allocator) Allocator.Error!Value {
        return switch (self) {
            .Null => .{ .Null = {} },
            .Bool => |v| .{ .Bool = v },
            .I64 => |v| .{ .I64 = v },
            .U64 => |v| .{ .U64 = v },
            .F64 => |v| .{ .F64 = v },
            .String => |v| .{ .String = try allocator.dupe(u8, v) },
            .Binary => |v| .{ .Binary = try allocator.dupe(u8, v) },
            .Array => |values| .{ .Array = try cloneValues(values, allocator) },
            .Map => |entries| .{ .Map = try cloneValueMapEntries(entries, allocator) },
        };
    }

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .String => |value| allocator.free(value),
            .Binary => |value| allocator.free(value),
            .Array => |values| {
                for (values) |*value| {
                    value.deinit(allocator);
                }
                allocator.free(values);
            },
            .Map => |entries| {
                for (entries) |*entry| {
                    entry.deinit(allocator);
                }
                allocator.free(entries);
            },
            else => {},
        }
    }

    pub fn eql(a: Value, b: Value) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) {
            return false;
        }
        return switch (a) {
            .Null => true,
            .Bool => |av| av == b.Bool,
            .I64 => |av| av == b.I64,
            .U64 => |av| av == b.U64,
            .F64 => |av| av == b.F64,
            .String => |av| std.mem.eql(u8, av, b.String),
            .Binary => |av| std.mem.eql(u8, av, b.Binary),
            .Array => |av| blk: {
                const bv = b.Array;
                if (av.len != bv.len) return false;
                for (av, 0..) |item, idx| {
                    if (!Value.eql(item, bv[idx])) return false;
                }
                break :blk true;
            },
            .Map => |av| blk: {
                const bv = b.Map;
                if (av.len != bv.len) return false;
                for (av, 0..) |entry, idx| {
                    if (!ValueMapEntry.eql(entry, bv[idx])) return false;
                }
                break :blk true;
            },
        };
    }
};

pub const KeyRefTag = enum {
    Literal,
    Id,
};

pub const KeyRef = union(KeyRefTag) {
    Literal: []u8,
    Id: u64,

    pub fn clone(self: KeyRef, allocator: Allocator) Allocator.Error!KeyRef {
        return switch (self) {
            .Literal => |v| .{ .Literal = try allocator.dupe(u8, v) },
            .Id => |v| .{ .Id = v },
        };
    }

    pub fn deinit(self: *KeyRef, allocator: Allocator) void {
        switch (self.*) {
            .Literal => |v| allocator.free(v),
            .Id => {},
        }
    }

    pub fn eql(a: KeyRef, b: KeyRef) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) {
            return false;
        }
        return switch (a) {
            .Literal => |v| std.mem.eql(u8, v, b.Literal),
            .Id => |v| v == b.Id,
        };
    }
};

pub const MapEntry = struct {
    key: KeyRef,
    value: Value,

    pub fn clone(self: MapEntry, allocator: Allocator) Allocator.Error!MapEntry {
        return .{
            .key = try self.key.clone(allocator),
            .value = try self.value.clone(allocator),
        };
    }

    pub fn deinit(self: *MapEntry, allocator: Allocator) void {
        self.key.deinit(allocator);
        self.value.deinit(allocator);
    }

    pub fn eql(a: MapEntry, b: MapEntry) bool {
        return KeyRef.eql(a.key, b.key) and Value.eql(a.value, b.value);
    }
};

pub const StringMode = enum(u8) {
    Empty = 0,
    Literal = 1,
    Ref = 2,
    PrefixDelta = 3,
    InlineEnum = 4,

    pub fn fromByte(byte: u8) ?StringMode {
        return switch (byte) {
            0 => .Empty,
            1 => .Literal,
            2 => .Ref,
            3 => .PrefixDelta,
            4 => .InlineEnum,
            else => null,
        };
    }
};

pub const StringValue = struct {
    mode: StringMode,
    value: []u8,
    ref_id: ?u64,
    prefix_len: ?u64,
};

pub const ElementType = enum(u8) {
    Bool = 0,
    I64 = 1,
    U64 = 2,
    F64 = 3,
    String = 4,
    Binary = 5,
    Value = 6,

    pub fn fromByte(byte: u8) ?ElementType {
        return switch (byte) {
            0 => .Bool,
            1 => .I64,
            2 => .U64,
            3 => .F64,
            4 => .String,
            5 => .Binary,
            6 => .Value,
            else => null,
        };
    }
};

pub const VectorCodec = enum(u8) {
    Plain = 0,
    DirectBitpack = 1,
    DeltaBitpack = 2,
    ForBitpack = 3,
    DeltaForBitpack = 4,
    DeltaDeltaBitpack = 5,
    Rle = 6,
    PatchedFor = 7,
    Simple8b = 8,
    XorFloat = 9,
    Dictionary = 10,
    StringRef = 11,
    PrefixDelta = 12,

    pub fn fromByte(byte: u8) ?VectorCodec {
        return switch (byte) {
            0 => .Plain,
            1 => .DirectBitpack,
            2 => .DeltaBitpack,
            3 => .ForBitpack,
            4 => .DeltaForBitpack,
            5 => .DeltaDeltaBitpack,
            6 => .Rle,
            7 => .PatchedFor,
            8 => .Simple8b,
            9 => .XorFloat,
            10 => .Dictionary,
            11 => .StringRef,
            12 => .PrefixDelta,
            else => null,
        };
    }
};

pub const TypedVectorDataTag = enum {
    Bool,
    I64,
    U64,
    F64,
    String,
    Binary,
    Value,
};

pub const TypedVectorData = union(TypedVectorDataTag) {
    Bool: []bool,
    I64: []i64,
    U64: []u64,
    F64: []f64,
    String: [][]u8,
    Binary: [][]u8,
    Value: []Value,

    pub fn clone(self: TypedVectorData, allocator: Allocator) Allocator.Error!TypedVectorData {
        return switch (self) {
            .Bool => |v| .{ .Bool = try allocator.dupe(bool, v) },
            .I64 => |v| .{ .I64 = try allocator.dupe(i64, v) },
            .U64 => |v| .{ .U64 = try allocator.dupe(u64, v) },
            .F64 => |v| .{ .F64 = try allocator.dupe(f64, v) },
            .String => |v| .{ .String = try cloneNestedBytes(v, allocator) },
            .Binary => |v| .{ .Binary = try cloneNestedBytes(v, allocator) },
            .Value => |v| .{ .Value = try cloneValues(v, allocator) },
        };
    }

    pub fn deinit(self: *TypedVectorData, allocator: Allocator) void {
        switch (self.*) {
            .Bool => |values| allocator.free(values),
            .I64 => |values| allocator.free(values),
            .U64 => |values| allocator.free(values),
            .F64 => |values| allocator.free(values),
            .String => |values| freeNestedBytes(values, allocator),
            .Binary => |values| freeNestedBytes(values, allocator),
            .Value => |values| {
                for (values) |*value| {
                    value.deinit(allocator);
                }
                allocator.free(values);
            },
        }
    }

    pub fn eql(a: TypedVectorData, b: TypedVectorData) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) {
            return false;
        }
        return switch (a) {
            .Bool => |av| std.mem.eql(bool, av, b.Bool),
            .I64 => |av| std.mem.eql(i64, av, b.I64),
            .U64 => |av| std.mem.eql(u64, av, b.U64),
            .F64 => |av| std.mem.eql(f64, av, b.F64),
            .String => |av| eqlNestedBytes(av, b.String),
            .Binary => |av| eqlNestedBytes(av, b.Binary),
            .Value => |av| blk: {
                const bv = b.Value;
                if (av.len != bv.len) return false;
                for (av, 0..) |value, idx| {
                    if (!Value.eql(value, bv[idx])) return false;
                }
                break :blk true;
            },
        };
    }

    pub fn len(self: TypedVectorData) usize {
        return switch (self) {
            .Bool => |v| v.len,
            .I64 => |v| v.len,
            .U64 => |v| v.len,
            .F64 => |v| v.len,
            .String => |v| v.len,
            .Binary => |v| v.len,
            .Value => |v| v.len,
        };
    }
};

pub const TypedVector = struct {
    element_type: ElementType,
    codec: VectorCodec,
    data: TypedVectorData,

    pub fn clone(self: TypedVector, allocator: Allocator) Allocator.Error!TypedVector {
        return .{
            .element_type = self.element_type,
            .codec = self.codec,
            .data = try self.data.clone(allocator),
        };
    }

    pub fn deinit(self: *TypedVector, allocator: Allocator) void {
        self.data.deinit(allocator);
    }

    pub fn eql(a: TypedVector, b: TypedVector) bool {
        return a.element_type == b.element_type and a.codec == b.codec and TypedVectorData.eql(a.data, b.data);
    }
};

pub const PhysicalEncoding = enum(u8) {
    Auto = 0,
    Varuint = 1,
    ZigzagVaruint = 2,
    RangeBits = 3,
    FixedLe = 4,

    pub fn fromByte(byte: u8) ?PhysicalEncoding {
        return switch (byte) {
            0 => .Auto,
            1 => .Varuint,
            2 => .ZigzagVaruint,
            3 => .RangeBits,
            4 => .FixedLe,
            else => null,
        };
    }
};

pub const SchemaField = struct {
    number: u64,
    name: []u8,
    logical_type: []u8,
    physical_encoding: PhysicalEncoding,
    required: bool,
    default_value: ?Value,
    min: ?i64,
    max: ?i64,
    enum_values: [][]u8,

    pub fn clone(self: SchemaField, allocator: Allocator) Allocator.Error!SchemaField {
        return .{
            .number = self.number,
            .name = try allocator.dupe(u8, self.name),
            .logical_type = try allocator.dupe(u8, self.logical_type),
            .physical_encoding = self.physical_encoding,
            .required = self.required,
            .default_value = if (self.default_value) |value| try value.clone(allocator) else null,
            .min = self.min,
            .max = self.max,
            .enum_values = try cloneNestedBytes(self.enum_values, allocator),
        };
    }

    pub fn deinit(self: *SchemaField, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.logical_type);
        if (self.default_value) |*value| {
            value.deinit(allocator);
        }
        freeNestedBytes(self.enum_values, allocator);
    }

    pub fn eql(a: SchemaField, b: SchemaField) bool {
        if (a.number != b.number or !std.mem.eql(u8, a.name, b.name) or !std.mem.eql(u8, a.logical_type, b.logical_type) or a.physical_encoding != b.physical_encoding or a.required != b.required or a.min != b.min or a.max != b.max) {
            return false;
        }
        if ((a.default_value == null) != (b.default_value == null)) return false;
        if (a.default_value) |value| {
            if (!Value.eql(value, b.default_value.?)) return false;
        }
        return eqlNestedBytes(a.enum_values, b.enum_values);
    }
};

pub const Schema = struct {
    schema_id: u64,
    name: []u8,
    fields: []SchemaField,

    pub fn clone(self: Schema, allocator: Allocator) Allocator.Error!Schema {
        const fields = try allocator.alloc(SchemaField, self.fields.len);
        errdefer allocator.free(fields);
        for (self.fields, 0..) |field, idx| {
            fields[idx] = try field.clone(allocator);
        }
        return .{
            .schema_id = self.schema_id,
            .name = try allocator.dupe(u8, self.name),
            .fields = fields,
        };
    }

    pub fn deinit(self: *Schema, allocator: Allocator) void {
        allocator.free(self.name);
        for (self.fields) |*field| {
            field.deinit(allocator);
        }
        allocator.free(self.fields);
    }

    pub fn eql(a: Schema, b: Schema) bool {
        if (a.schema_id != b.schema_id or !std.mem.eql(u8, a.name, b.name) or a.fields.len != b.fields.len) {
            return false;
        }
        for (a.fields, 0..) |field, idx| {
            if (!SchemaField.eql(field, b.fields[idx])) return false;
        }
        return true;
    }
};

pub const NullStrategy = enum(u8) {
    None = 0,
    PresenceBitmap = 1,
    InvertedPresenceBitmap = 2,
    AllPresentElided = 3,

    pub fn fromByte(byte: u8) ?NullStrategy {
        return switch (byte) {
            0 => .None,
            1 => .PresenceBitmap,
            2 => .InvertedPresenceBitmap,
            3 => .AllPresentElided,
            else => null,
        };
    }
};

pub const Column = struct {
    field_id: u64,
    null_strategy: NullStrategy,
    presence: ?[]bool,
    codec: VectorCodec,
    dictionary_id: ?u64,
    values: TypedVectorData,

    pub fn clone(self: Column, allocator: Allocator) Allocator.Error!Column {
        return .{
            .field_id = self.field_id,
            .null_strategy = self.null_strategy,
            .presence = if (self.presence) |bits| try allocator.dupe(bool, bits) else null,
            .codec = self.codec,
            .dictionary_id = self.dictionary_id,
            .values = try self.values.clone(allocator),
        };
    }

    pub fn deinit(self: *Column, allocator: Allocator) void {
        if (self.presence) |bits| {
            allocator.free(bits);
        }
        self.values.deinit(allocator);
    }

    pub fn eql(a: Column, b: Column) bool {
        if (a.field_id != b.field_id or a.null_strategy != b.null_strategy or a.codec != b.codec or a.dictionary_id != b.dictionary_id) {
            return false;
        }
        if ((a.presence == null) != (b.presence == null)) return false;
        if (a.presence) |bits| {
            if (!std.mem.eql(bool, bits, b.presence.?)) return false;
        }
        return TypedVectorData.eql(a.values, b.values);
    }
};

pub const ControlOpcode = enum(u8) {
    RegisterKeys = 0,
    RegisterShape = 1,
    RegisterStrings = 2,
    PromoteStringFieldToEnum = 3,
    ResetTables = 4,
    ResetState = 5,

    pub fn fromByte(byte: u8) ?ControlOpcode {
        return switch (byte) {
            0 => .RegisterKeys,
            1 => .RegisterShape,
            2 => .RegisterStrings,
            3 => .PromoteStringFieldToEnum,
            4 => .ResetTables,
            5 => .ResetState,
            else => null,
        };
    }
};

pub const ControlMessageTag = enum {
    RegisterKeys,
    RegisterShape,
    RegisterStrings,
    PromoteStringFieldToEnum,
    ResetTables,
    ResetState,
};

pub const ControlMessage = union(ControlMessageTag) {
    RegisterKeys: [][]u8,
    RegisterShape: struct { shape_id: u64, keys: []KeyRef },
    RegisterStrings: [][]u8,
    PromoteStringFieldToEnum: struct { field_identity: []u8, values: [][]u8 },
    ResetTables: void,
    ResetState: void,

    pub fn clone(self: ControlMessage, allocator: Allocator) Allocator.Error!ControlMessage {
        return switch (self) {
            .RegisterKeys => |values| .{ .RegisterKeys = try cloneNestedBytes(values, allocator) },
            .RegisterShape => |shape| .{
                .RegisterShape = .{
                    .shape_id = shape.shape_id,
                    .keys = try cloneKeyRefs(shape.keys, allocator),
                },
            },
            .RegisterStrings => |values| .{ .RegisterStrings = try cloneNestedBytes(values, allocator) },
            .PromoteStringFieldToEnum => |enum_data| .{
                .PromoteStringFieldToEnum = .{
                    .field_identity = try allocator.dupe(u8, enum_data.field_identity),
                    .values = try cloneNestedBytes(enum_data.values, allocator),
                },
            },
            .ResetTables => .{ .ResetTables = {} },
            .ResetState => .{ .ResetState = {} },
        };
    }

    pub fn deinit(self: *ControlMessage, allocator: Allocator) void {
        switch (self.*) {
            .RegisterKeys => |values| freeNestedBytes(values, allocator),
            .RegisterShape => |shape| {
                for (shape.keys) |*key| {
                    key.deinit(allocator);
                }
                allocator.free(shape.keys);
            },
            .RegisterStrings => |values| freeNestedBytes(values, allocator),
            .PromoteStringFieldToEnum => |enum_data| {
                allocator.free(enum_data.field_identity);
                freeNestedBytes(enum_data.values, allocator);
            },
            .ResetTables, .ResetState => {},
        }
    }

    pub fn eql(a: ControlMessage, b: ControlMessage) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .RegisterKeys => |values| eqlNestedBytes(values, b.RegisterKeys),
            .RegisterShape => |shape| blk: {
                const rhs = b.RegisterShape;
                if (shape.shape_id != rhs.shape_id or shape.keys.len != rhs.keys.len) return false;
                for (shape.keys, 0..) |key, idx| {
                    if (!KeyRef.eql(key, rhs.keys[idx])) return false;
                }
                break :blk true;
            },
            .RegisterStrings => |values| eqlNestedBytes(values, b.RegisterStrings),
            .PromoteStringFieldToEnum => |enum_data| blk: {
                const rhs = b.PromoteStringFieldToEnum;
                break :blk std.mem.eql(u8, enum_data.field_identity, rhs.field_identity) and eqlNestedBytes(enum_data.values, rhs.values);
            },
            .ResetTables => true,
            .ResetState => true,
        };
    }
};

pub const PatchOpcode = enum(u8) {
    Keep = 0,
    ReplaceScalar = 1,
    ReplaceVector = 2,
    AppendVector = 3,
    TruncateVector = 4,
    DeleteField = 5,
    InsertField = 6,
    StringRef = 7,
    PrefixDelta = 8,

    pub fn fromByte(byte: u8) ?PatchOpcode {
        return switch (byte) {
            0 => .Keep,
            1 => .ReplaceScalar,
            2 => .ReplaceVector,
            3 => .AppendVector,
            4 => .TruncateVector,
            5 => .DeleteField,
            6 => .InsertField,
            7 => .StringRef,
            8 => .PrefixDelta,
            else => null,
        };
    }
};

pub const BaseRefTag = enum {
    Previous,
    BaseId,
};

pub const BaseRef = union(BaseRefTag) {
    Previous: void,
    BaseId: u64,

    pub fn eql(a: BaseRef, b: BaseRef) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .Previous => true,
            .BaseId => |id| id == b.BaseId,
        };
    }
};

pub const PatchOperation = struct {
    field_id: u64,
    opcode: PatchOpcode,
    value: ?Value,

    pub fn clone(self: PatchOperation, allocator: Allocator) Allocator.Error!PatchOperation {
        return .{
            .field_id = self.field_id,
            .opcode = self.opcode,
            .value = if (self.value) |v| try v.clone(allocator) else null,
        };
    }

    pub fn deinit(self: *PatchOperation, allocator: Allocator) void {
        if (self.value) |*value| {
            value.deinit(allocator);
        }
    }

    pub fn eql(a: PatchOperation, b: PatchOperation) bool {
        if (a.field_id != b.field_id or a.opcode != b.opcode) return false;
        if ((a.value == null) != (b.value == null)) return false;
        if (a.value) |value| {
            if (!Value.eql(value, b.value.?)) return false;
        }
        return true;
    }
};

pub const ControlStreamCodec = enum(u8) {
    Plain = 0,
    Rle = 1,
    Bitpack = 2,
    Huffman = 3,
    Fse = 4,

    pub fn fromByte(byte: u8) ?ControlStreamCodec {
        return switch (byte) {
            0 => .Plain,
            1 => .Rle,
            2 => .Bitpack,
            3 => .Huffman,
            4 => .Fse,
            else => null,
        };
    }
};

pub const PresenceStrategy = enum(u8) {
    Normal = 0,
    Inverted = 1,
    AllPresent = 2,

    pub fn fromByte(byte: u8) ?PresenceStrategy {
        return switch (byte) {
            0 => .Normal,
            1 => .Inverted,
            2 => .AllPresent,
            else => null,
        };
    }
};

pub const BoundRecord = struct {
    presence: ?[]bool,
    fields: []Value,

    pub fn clone(self: BoundRecord, allocator: Allocator) Allocator.Error!BoundRecord {
        return .{
            .presence = if (self.presence) |bits| try allocator.dupe(bool, bits) else null,
            .fields = try cloneValues(self.fields, allocator),
        };
    }

    pub fn deinit(self: *BoundRecord, allocator: Allocator) void {
        if (self.presence) |bits| allocator.free(bits);
        for (self.fields) |*value| value.deinit(allocator);
        allocator.free(self.fields);
    }

    pub fn eql(a: BoundRecord, b: BoundRecord) bool {
        if ((a.presence == null) != (b.presence == null)) return false;
        if (a.presence) |bits| {
            if (!std.mem.eql(bool, bits, b.presence.?)) return false;
        }
        return eqlValues(a.fields, b.fields);
    }
};

pub const MessageTag = enum {
    Scalar,
    Array,
    Map,
    ShapedObject,
    SchemaObject,
    TypedVector,
    RowBatch,
    ColumnBatch,
    SchemaBatch,
    BoundStream,
    Control,
    Ext,
    StatePatch,
    TemplateBatch,
    ControlStream,
    BaseSnapshot,
};

pub const Message = union(MessageTag) {
    Scalar: Value,
    Array: []Value,
    Map: []MapEntry,
    ShapedObject: struct { shape_id: u64, presence: ?[]bool, values: []Value },
    SchemaObject: struct { schema_id: ?u64, presence: ?[]bool, fields: []Value },
    TypedVector: TypedVector,
    RowBatch: struct { rows: [][]Value },
    ColumnBatch: struct { count: u64, columns: []Column },
    SchemaBatch: struct { schema_id: u64, count: u64, columns: []Column },
    BoundStream: struct { schema_id: u64, presence_strategy: PresenceStrategy, records: []BoundRecord },
    Control: ControlMessage,
    Ext: struct { ext_type: u64, payload: []u8 },
    StatePatch: struct { base_ref: BaseRef, operations: []PatchOperation, literals: []Value },
    TemplateBatch: struct {
        template_id: u64,
        count: u64,
        changed_column_mask: []bool,
        columns: []Column,
    },
    ControlStream: struct { codec: ControlStreamCodec, payload: []u8 },
    BaseSnapshot: struct { base_id: u64, schema_or_shape_ref: u64, payload: *Message },

    pub fn clone(self: Message, allocator: Allocator) Allocator.Error!Message {
        return switch (self) {
            .Scalar => |value| .{ .Scalar = try value.clone(allocator) },
            .Array => |values| .{ .Array = try cloneValues(values, allocator) },
            .Map => |entries| .{ .Map = try cloneMapEntries(entries, allocator) },
            .ShapedObject => |shaped| .{ .ShapedObject = .{
                .shape_id = shaped.shape_id,
                .presence = if (shaped.presence) |bits| try allocator.dupe(bool, bits) else null,
                .values = try cloneValues(shaped.values, allocator),
            } },
            .SchemaObject => |schema_obj| .{ .SchemaObject = .{
                .schema_id = schema_obj.schema_id,
                .presence = if (schema_obj.presence) |bits| try allocator.dupe(bool, bits) else null,
                .fields = try cloneValues(schema_obj.fields, allocator),
            } },
            .TypedVector => |vector| .{ .TypedVector = try vector.clone(allocator) },
            .RowBatch => |batch| .{ .RowBatch = .{ .rows = try cloneRowValues(batch.rows, allocator) } },
            .ColumnBatch => |batch| .{ .ColumnBatch = .{
                .count = batch.count,
                .columns = try cloneColumns(batch.columns, allocator),
            } },
            .SchemaBatch => |batch| .{ .SchemaBatch = .{
                .schema_id = batch.schema_id,
                .count = batch.count,
                .columns = try cloneColumns(batch.columns, allocator),
            } },
            .BoundStream => |stream| .{ .BoundStream = .{
                .schema_id = stream.schema_id,
                .presence_strategy = stream.presence_strategy,
                .records = try cloneBoundRecords(stream.records, allocator),
            } },
            .Control => |control| .{ .Control = try control.clone(allocator) },
            .Ext => |ext| .{ .Ext = .{
                .ext_type = ext.ext_type,
                .payload = try allocator.dupe(u8, ext.payload),
            } },
            .StatePatch => |patch| .{ .StatePatch = .{
                .base_ref = patch.base_ref,
                .operations = try clonePatchOperations(patch.operations, allocator),
                .literals = try cloneValues(patch.literals, allocator),
            } },
            .TemplateBatch => |batch| .{ .TemplateBatch = .{
                .template_id = batch.template_id,
                .count = batch.count,
                .changed_column_mask = try allocator.dupe(bool, batch.changed_column_mask),
                .columns = try cloneColumns(batch.columns, allocator),
            } },
            .ControlStream => |stream| .{ .ControlStream = .{
                .codec = stream.codec,
                .payload = try allocator.dupe(u8, stream.payload),
            } },
            .BaseSnapshot => |snapshot| blk: {
                const payload = try allocator.create(Message);
                errdefer allocator.destroy(payload);
                payload.* = try snapshot.payload.clone(allocator);
                break :blk .{ .BaseSnapshot = .{
                    .base_id = snapshot.base_id,
                    .schema_or_shape_ref = snapshot.schema_or_shape_ref,
                    .payload = payload,
                } };
            },
        };
    }

    pub fn deinit(self: *Message, allocator: Allocator) void {
        switch (self.*) {
            .Scalar => |*value| value.deinit(allocator),
            .Array => |values| {
                for (values) |*value| value.deinit(allocator);
                allocator.free(values);
            },
            .Map => |entries| {
                for (entries) |*entry| entry.deinit(allocator);
                allocator.free(entries);
            },
            .ShapedObject => |shaped| {
                if (shaped.presence) |bits| allocator.free(bits);
                for (shaped.values) |*value| value.deinit(allocator);
                allocator.free(shaped.values);
            },
            .SchemaObject => |schema_obj| {
                if (schema_obj.presence) |bits| allocator.free(bits);
                for (schema_obj.fields) |*value| value.deinit(allocator);
                allocator.free(schema_obj.fields);
            },
            .TypedVector => |*vector| vector.deinit(allocator),
            .RowBatch => |batch| {
                for (batch.rows) |row| {
                    for (row) |*value| value.deinit(allocator);
                    allocator.free(row);
                }
                allocator.free(batch.rows);
            },
            .ColumnBatch => |batch| {
                for (batch.columns) |*column| column.deinit(allocator);
                allocator.free(batch.columns);
            },
            .SchemaBatch => |batch| {
                for (batch.columns) |*column| column.deinit(allocator);
                allocator.free(batch.columns);
            },
            .BoundStream => |stream| {
                for (stream.records) |*record| record.deinit(allocator);
                allocator.free(stream.records);
            },
            .Control => |*control| control.deinit(allocator),
            .Ext => |ext| allocator.free(ext.payload),
            .StatePatch => |patch| {
                for (patch.operations) |*op| op.deinit(allocator);
                allocator.free(patch.operations);
                for (patch.literals) |*value| value.deinit(allocator);
                allocator.free(patch.literals);
            },
            .TemplateBatch => |batch| {
                allocator.free(batch.changed_column_mask);
                for (batch.columns) |*column| column.deinit(allocator);
                allocator.free(batch.columns);
            },
            .ControlStream => |stream| allocator.free(stream.payload),
            .BaseSnapshot => |snapshot| {
                snapshot.payload.deinit(allocator);
                allocator.destroy(snapshot.payload);
            },
        }
    }

    pub fn eql(a: Message, b: Message) bool {
        if (@intFromEnum(a) != @intFromEnum(b)) return false;
        return switch (a) {
            .Scalar => |value| Value.eql(value, b.Scalar),
            .Array => |values| eqlValues(values, b.Array),
            .Map => |entries| eqlMapEntries(entries, b.Map),
            .ShapedObject => |shaped| blk: {
                const rhs = b.ShapedObject;
                break :blk shaped.shape_id == rhs.shape_id and eqlOptionalBools(shaped.presence, rhs.presence) and eqlValues(shaped.values, rhs.values);
            },
            .SchemaObject => |schema_obj| blk: {
                const rhs = b.SchemaObject;
                break :blk schema_obj.schema_id == rhs.schema_id and eqlOptionalBools(schema_obj.presence, rhs.presence) and eqlValues(schema_obj.fields, rhs.fields);
            },
            .TypedVector => |vector| TypedVector.eql(vector, b.TypedVector),
            .RowBatch => |batch| eqlRowValues(batch.rows, b.RowBatch.rows),
            .ColumnBatch => |batch| blk: {
                const rhs = b.ColumnBatch;
                if (batch.count != rhs.count or batch.columns.len != rhs.columns.len) return false;
                for (batch.columns, 0..) |column, idx| {
                    if (!Column.eql(column, rhs.columns[idx])) return false;
                }
                break :blk true;
            },
            .SchemaBatch => |batch| blk: {
                const rhs = b.SchemaBatch;
                if (batch.schema_id != rhs.schema_id or batch.count != rhs.count or batch.columns.len != rhs.columns.len) return false;
                for (batch.columns, 0..) |column, idx| {
                    if (!Column.eql(column, rhs.columns[idx])) return false;
                }
                break :blk true;
            },
            .BoundStream => |stream| blk: {
                const rhs = b.BoundStream;
                if (stream.schema_id != rhs.schema_id or stream.presence_strategy != rhs.presence_strategy) return false;
                if (stream.records.len != rhs.records.len) return false;
                for (stream.records, 0..) |record, idx| {
                    if (!BoundRecord.eql(record, rhs.records[idx])) return false;
                }
                break :blk true;
            },
            .Control => |control| ControlMessage.eql(control, b.Control),
            .Ext => |ext| ext.ext_type == b.Ext.ext_type and std.mem.eql(u8, ext.payload, b.Ext.payload),
            .StatePatch => |patch| blk: {
                const rhs = b.StatePatch;
                if (!BaseRef.eql(patch.base_ref, rhs.base_ref)) return false;
                if (patch.operations.len != rhs.operations.len or patch.literals.len != rhs.literals.len) return false;
                for (patch.operations, 0..) |op, idx| {
                    if (!PatchOperation.eql(op, rhs.operations[idx])) return false;
                }
                break :blk eqlValues(patch.literals, rhs.literals);
            },
            .TemplateBatch => |batch| blk: {
                const rhs = b.TemplateBatch;
                if (batch.template_id != rhs.template_id or batch.count != rhs.count) return false;
                if (!std.mem.eql(bool, batch.changed_column_mask, rhs.changed_column_mask)) return false;
                if (batch.columns.len != rhs.columns.len) return false;
                for (batch.columns, 0..) |column, idx| {
                    if (!Column.eql(column, rhs.columns[idx])) return false;
                }
                break :blk true;
            },
            .ControlStream => |stream| stream.codec == b.ControlStream.codec and std.mem.eql(u8, stream.payload, b.ControlStream.payload),
            .BaseSnapshot => |snapshot| blk: {
                const rhs = b.BaseSnapshot;
                break :blk snapshot.base_id == rhs.base_id and snapshot.schema_or_shape_ref == rhs.schema_or_shape_ref and Message.eql(snapshot.payload.*, rhs.payload.*);
            },
        };
    }
};

pub const TemplateDescriptor = struct {
    template_id: u64,
    field_ids: []u64,
    null_strategies: []NullStrategy,
    codecs: []VectorCodec,

    pub fn clone(self: TemplateDescriptor, allocator: Allocator) Allocator.Error!TemplateDescriptor {
        return .{
            .template_id = self.template_id,
            .field_ids = try allocator.dupe(u64, self.field_ids),
            .null_strategies = try allocator.dupe(NullStrategy, self.null_strategies),
            .codecs = try allocator.dupe(VectorCodec, self.codecs),
        };
    }

    pub fn deinit(self: *TemplateDescriptor, allocator: Allocator) void {
        allocator.free(self.field_ids);
        allocator.free(self.null_strategies);
        allocator.free(self.codecs);
    }
};

pub const MetadataMap = std.StringHashMap([]u8);

fn cloneValues(values: []const Value, allocator: Allocator) Allocator.Error![]Value {
    const out = try allocator.alloc(Value, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try value.clone(allocator);
    }
    return out;
}

fn eqlValues(a: []const Value, b: []const Value) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |value, idx| {
        if (!Value.eql(value, b[idx])) return false;
    }
    return true;
}

fn cloneValueMapEntries(entries: []const ValueMapEntry, allocator: Allocator) Allocator.Error![]ValueMapEntry {
    const out = try allocator.alloc(ValueMapEntry, entries.len);
    errdefer allocator.free(out);
    for (entries, 0..) |entry, idx| {
        out[idx] = try entry.clone(allocator);
    }
    return out;
}

fn cloneMapEntries(entries: []const MapEntry, allocator: Allocator) Allocator.Error![]MapEntry {
    const out = try allocator.alloc(MapEntry, entries.len);
    errdefer allocator.free(out);
    for (entries, 0..) |entry, idx| {
        out[idx] = try entry.clone(allocator);
    }
    return out;
}

fn eqlMapEntries(a: []const MapEntry, b: []const MapEntry) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |entry, idx| {
        if (!MapEntry.eql(entry, b[idx])) return false;
    }
    return true;
}

fn cloneNestedBytes(values: []const []const u8, allocator: Allocator) Allocator.Error![][]u8 {
    const out = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
    }
    return out;
}

fn freeNestedBytes(values: [][]u8, allocator: Allocator) void {
    for (values) |value| {
        allocator.free(value);
    }
    allocator.free(values);
}

fn eqlNestedBytes(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |value, idx| {
        if (!std.mem.eql(u8, value, b[idx])) return false;
    }
    return true;
}

fn cloneKeyRefs(keys: []const KeyRef, allocator: Allocator) Allocator.Error![]KeyRef {
    const out = try allocator.alloc(KeyRef, keys.len);
    errdefer allocator.free(out);
    for (keys, 0..) |key, idx| {
        out[idx] = try key.clone(allocator);
    }
    return out;
}

fn cloneColumns(columns: []const Column, allocator: Allocator) Allocator.Error![]Column {
    const out = try allocator.alloc(Column, columns.len);
    errdefer allocator.free(out);
    for (columns, 0..) |column, idx| {
        out[idx] = try column.clone(allocator);
    }
    return out;
}

fn clonePatchOperations(ops: []const PatchOperation, allocator: Allocator) Allocator.Error![]PatchOperation {
    const out = try allocator.alloc(PatchOperation, ops.len);
    errdefer allocator.free(out);
    for (ops, 0..) |op, idx| {
        out[idx] = try op.clone(allocator);
    }
    return out;
}

fn cloneBoundRecords(records: []const BoundRecord, allocator: Allocator) Allocator.Error![]BoundRecord {
    const out = try allocator.alloc(BoundRecord, records.len);
    errdefer allocator.free(out);
    for (records, 0..) |record, idx| {
        out[idx] = try record.clone(allocator);
    }
    return out;
}

fn cloneRowValues(rows: []const []const Value, allocator: Allocator) Allocator.Error![][]Value {
    const out = try allocator.alloc([]Value, rows.len);
    errdefer allocator.free(out);
    for (rows, 0..) |row, idx| {
        out[idx] = try cloneValues(row, allocator);
    }
    return out;
}

fn eqlRowValues(a: []const []const Value, b: []const []const Value) bool {
    if (a.len != b.len) return false;
    for (a, 0..) |row, idx| {
        if (!eqlValues(row, b[idx])) return false;
    }
    return true;
}

fn eqlOptionalBools(a: ?[]const bool, b: ?[]const bool) bool {
    if ((a == null) != (b == null)) return false;
    if (a) |bits| {
        return std.mem.eql(bool, bits, b.?);
    }
    return true;
}
