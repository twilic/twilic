const std = @import("std");
const model = @import("model.zig");

const Allocator = std.mem.Allocator;

pub const UnknownReferencePolicy = enum {
    FailFast,
    StatelessRetry,
};

pub const DictionaryFallback = enum(u8) {
    FailFast = 0,
    StatelessRetry = 1,

    pub fn fromByte(byte: u8) ?DictionaryFallback {
        return switch (byte) {
            0 => .FailFast,
            1 => .StatelessRetry,
            else => null,
        };
    }
};

pub const DictionaryProfile = struct {
    version: u64,
    hash: u64,
    expires_at: u64,
    fallback: DictionaryFallback,
};

pub const SessionOptions = struct {
    max_base_snapshots: usize = 8,
    enable_state_patch: bool = true,
    enable_template_batch: bool = true,
    enable_trained_dictionary: bool = true,
    unknown_reference_policy: UnknownReferencePolicy = .FailFast,
};

pub const InternTable = struct {
    by_value: std.StringHashMapUnmanaged(u64) = .{},
    by_id: std.ArrayListUnmanaged([]u8) = .{ .items = &.{}, .capacity = 0 },

    pub fn deinit(self: *InternTable, allocator: Allocator) void {
        self.clear(allocator);
        self.by_value.deinit(allocator);
        self.by_id.deinit(allocator);
    }

    pub fn getId(self: *const InternTable, value: []const u8) ?u64 {
        return self.by_value.get(value);
    }

    pub fn getValue(self: *const InternTable, id: u64) ?[]const u8 {
        const idx = std.math.cast(usize, id) orelse return null;
        if (idx >= self.by_id.items.len) return null;
        return self.by_id.items[idx];
    }

    pub fn register(self: *InternTable, allocator: Allocator, value: []const u8) !u64 {
        if (self.by_value.get(value)) |id| {
            return id;
        }
        const owned = try allocator.dupe(u8, value);
        errdefer allocator.free(owned);
        const id: u64 = @intCast(self.by_id.items.len);
        try self.by_id.append(allocator, owned);
        try self.by_value.put(allocator, owned, id);
        return id;
    }

    pub fn clear(self: *InternTable, allocator: Allocator) void {
        for (self.by_id.items) |value| {
            allocator.free(value);
        }
        self.by_id.clearRetainingCapacity();
        self.by_value.clearRetainingCapacity();
    }
};

const Shape = struct {
    keys: [][]u8,
    fingerprint: []u8,

    fn deinit(self: *Shape, allocator: Allocator) void {
        for (self.keys) |key| {
            allocator.free(key);
        }
        allocator.free(self.keys);
        allocator.free(self.fingerprint);
    }
};

pub const ShapeTable = struct {
    by_keys: std.StringHashMapUnmanaged(u64) = .{},
    by_id: std.AutoHashMapUnmanaged(u64, Shape) = .{},
    observations: std.StringHashMapUnmanaged(u64) = .{},
    next_id: u64 = 0,

    pub fn deinit(self: *ShapeTable, allocator: Allocator) void {
        self.clear(allocator);
        self.by_keys.deinit(allocator);
        self.by_id.deinit(allocator);
        self.observations.deinit(allocator);
    }

    pub fn getId(self: *const ShapeTable, allocator: Allocator, keys: []const []const u8) !?u64 {
        var fp = std.array_list.Managed(u8).init(allocator);
        defer fp.deinit();
        try appendShapeFingerprint(&fp, keys);
        return self.by_keys.get(fp.items);
    }

    pub fn getKeys(self: *const ShapeTable, id: u64) ?[]const []u8 {
        const shape = self.by_id.get(id) orelse return null;
        return shape.keys;
    }

    pub fn register(self: *ShapeTable, allocator: Allocator, keys: []const []const u8) !u64 {
        if (try self.getId(allocator, keys)) |id| {
            return id;
        }
        const id = self.next_id;
        self.next_id +%= 1;
        try self.insertShape(allocator, id, keys);
        return id;
    }

    pub fn registerWithId(self: *ShapeTable, allocator: Allocator, shape_id: u64, keys: []const []const u8) !bool {
        if (self.by_id.get(shape_id)) |existing| {
            return eqlNestedBytes(existing.keys, keys);
        }

        if (try self.getId(allocator, keys)) |existing_id| {
            if (existing_id != shape_id) {
                return false;
            }
        }

        try self.insertShape(allocator, shape_id, keys);
        if (self.next_id <= shape_id) {
            self.next_id = shape_id + 1;
        }
        return true;
    }

    pub fn observe(self: *ShapeTable, allocator: Allocator, keys: []const []const u8) !u64 {
        var fp = std.array_list.Managed(u8).init(allocator);
        defer fp.deinit();
        try appendShapeFingerprint(&fp, keys);
        if (self.observations.getPtr(fp.items)) |count| {
            count.* += 1;
            return count.*;
        }
        const owned = try allocator.dupe(u8, fp.items);
        errdefer allocator.free(owned);
        try self.observations.put(allocator, owned, 1);
        return 1;
    }

    pub fn clear(self: *ShapeTable, allocator: Allocator) void {
        var by_id_iter = self.by_id.iterator();
        while (by_id_iter.next()) |entry| {
            var shape = entry.value_ptr.*;
            shape.deinit(allocator);
        }
        self.by_id.clearRetainingCapacity();
        self.by_keys.clearRetainingCapacity();

        var obs_iter = self.observations.iterator();
        while (obs_iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        self.observations.clearRetainingCapacity();
        self.next_id = 0;
    }

    fn insertShape(self: *ShapeTable, allocator: Allocator, id: u64, keys: []const []const u8) !void {
        const fingerprint = try shapeFingerprintOwned(allocator, keys);
        errdefer allocator.free(fingerprint);
        const keys_owned = try cloneNestedBytes(allocator, keys);
        errdefer freeNestedBytes(allocator, keys_owned);
        try self.by_id.put(allocator, id, .{ .keys = keys_owned, .fingerprint = fingerprint });
        try self.by_keys.put(allocator, fingerprint, id);
    }
};

const BaseSnapshotItem = struct {
    id: u64,
    message: model.Message,

    fn deinit(self: *BaseSnapshotItem, allocator: Allocator) void {
        self.message.deinit(allocator);
    }
};

pub const SessionState = struct {
    allocator: Allocator,
    options: SessionOptions,
    key_table: InternTable = .{},
    string_table: InternTable = .{},
    shape_table: ShapeTable = .{},
    encode_shape_observations: std.StringHashMapUnmanaged(u64) = .{},
    base_snapshots: std.ArrayListUnmanaged(BaseSnapshotItem) = .{ .items = &.{}, .capacity = 0 },
    templates: std.AutoHashMapUnmanaged(u64, model.TemplateDescriptor) = .{},
    template_columns: std.AutoHashMapUnmanaged(u64, []model.Column) = .{},
    field_enums: std.StringHashMapUnmanaged([][]u8) = .{},
    dictionaries: std.AutoHashMapUnmanaged(u64, []u8) = .{},
    dictionary_profiles: std.AutoHashMapUnmanaged(u64, DictionaryProfile) = .{},
    schemas: std.AutoHashMapUnmanaged(u64, model.Schema) = .{},
    last_schema_id: ?u64 = null,
    previous_message: ?model.Message = null,
    next_base_id: u64 = 0,
    next_template_id: u64 = 0,
    next_dictionary_id: u64 = 0,

    pub fn init(allocator: Allocator, options: SessionOptions) SessionState {
        return .{
            .allocator = allocator,
            .options = options,
        };
    }

    pub fn deinit(self: *SessionState) void {
        self.resetState();
        self.key_table.deinit(self.allocator);
        self.string_table.deinit(self.allocator);
        self.shape_table.deinit(self.allocator);
        self.encode_shape_observations.deinit(self.allocator);
        self.base_snapshots.deinit(self.allocator);
        self.templates.deinit(self.allocator);
        self.template_columns.deinit(self.allocator);
        self.field_enums.deinit(self.allocator);
        self.dictionaries.deinit(self.allocator);
        self.dictionary_profiles.deinit(self.allocator);
        self.schemas.deinit(self.allocator);
    }

    pub fn registerBaseSnapshot(self: *SessionState, base_id: u64, message: model.Message) !void {
        var idx: usize = 0;
        while (idx < self.base_snapshots.items.len) : (idx += 1) {
            if (self.base_snapshots.items[idx].id == base_id) {
                self.base_snapshots.items[idx].deinit(self.allocator);
                _ = self.base_snapshots.orderedRemove(idx);
                break;
            }
        }
        try self.base_snapshots.append(self.allocator, .{ .id = base_id, .message = message });
        while (self.base_snapshots.items.len > self.options.max_base_snapshots) {
            var removed = self.base_snapshots.orderedRemove(0);
            removed.deinit(self.allocator);
        }
    }

    pub fn allocateBaseId(self: *SessionState) u64 {
        const id = self.next_base_id;
        self.next_base_id +%= 1;
        return id;
    }

    pub fn allocateTemplateId(self: *SessionState) u64 {
        const id = self.next_template_id;
        self.next_template_id +%= 1;
        return id;
    }

    pub fn allocateDictionaryId(self: *SessionState) u64 {
        const id = self.next_dictionary_id;
        self.next_dictionary_id +%= 1;
        return id;
    }

    pub fn getBaseSnapshot(self: *const SessionState, base_id: u64) ?*const model.Message {
        for (self.base_snapshots.items) |*item| {
            if (item.id == base_id) {
                return &item.message;
            }
        }
        return null;
    }

    pub fn resetTables(self: *SessionState) void {
        self.key_table.clear(self.allocator);
        self.string_table.clear(self.allocator);
        self.shape_table.clear(self.allocator);
        clearStringToU64Map(&self.encode_shape_observations, self.allocator);
        clearFieldEnums(&self.field_enums, self.allocator);
    }

    pub fn resetState(self: *SessionState) void {
        self.resetTables();

        for (self.base_snapshots.items) |*item| {
            item.deinit(self.allocator);
        }
        self.base_snapshots.clearRetainingCapacity();

        var templates_iter = self.templates.iterator();
        while (templates_iter.next()) |entry| {
            var descriptor = entry.value_ptr.*;
            descriptor.deinit(self.allocator);
        }
        self.templates.clearRetainingCapacity();

        var template_columns_iter = self.template_columns.iterator();
        while (template_columns_iter.next()) |entry| {
            for (entry.value_ptr.*) |*column| {
                column.deinit(self.allocator);
            }
            self.allocator.free(entry.value_ptr.*);
        }
        self.template_columns.clearRetainingCapacity();

        var dictionaries_iter = self.dictionaries.iterator();
        while (dictionaries_iter.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.dictionaries.clearRetainingCapacity();
        self.dictionary_profiles.clearRetainingCapacity();

        var schemas_iter = self.schemas.iterator();
        while (schemas_iter.next()) |entry| {
            var schema = entry.value_ptr.*;
            schema.deinit(self.allocator);
        }
        self.schemas.clearRetainingCapacity();

        if (self.previous_message) |*message| {
            message.deinit(self.allocator);
        }
        self.previous_message = null;
        self.last_schema_id = null;
        self.next_base_id = 0;
        self.next_template_id = 0;
        self.next_dictionary_id = 0;
    }
};

fn appendShapeFingerprint(out: *std.array_list.Managed(u8), keys: []const []const u8) !void {
    try appendVaruint(out, keys.len);
    for (keys) |key| {
        try appendVaruint(out, key.len);
        try out.appendSlice(key);
    }
}

fn appendVaruint(out: *std.array_list.Managed(u8), value: usize) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) {
            byte |= 0x80;
        }
        try out.append(byte);
        if (v == 0) break;
    }
}

fn shapeFingerprintOwned(allocator: Allocator, keys: []const []const u8) ![]u8 {
    var fp = std.array_list.Managed(u8).init(allocator);
    errdefer fp.deinit();
    try appendShapeFingerprint(&fp, keys);
    return try fp.toOwnedSlice();
}

fn cloneNestedBytes(allocator: Allocator, values: []const []const u8) ![][]u8 {
    const out = try allocator.alloc([]u8, values.len);
    errdefer allocator.free(out);
    for (values, 0..) |value, idx| {
        out[idx] = try allocator.dupe(u8, value);
    }
    return out;
}

fn freeNestedBytes(allocator: Allocator, values: [][]u8) void {
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

fn clearStringToU64Map(map: *std.StringHashMapUnmanaged(u64), allocator: Allocator) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
    }
    map.clearRetainingCapacity();
}

fn clearFieldEnums(map: *std.StringHashMapUnmanaged([][]u8), allocator: Allocator) void {
    var iter = map.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        freeNestedBytes(allocator, entry.value_ptr.*);
    }
    map.clearRetainingCapacity();
}
