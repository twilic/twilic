# Twilic (Zig)

Zig implementation of the Twilic wire format and session-aware encoder/decoder.

Supports Twilic v3 (Dynamic, Bound, Batch, Stateful profiles).

## What this package provides

### v3 APIs

- `encodeBoundStream(schema, values)` — schema-bound compact record stream (`BOUND_STREAM`)
- `encodeBatchWithSchema(schema, values)` — schema-aware columnar batch (`SCHEMA_BATCH`)

### v2 APIs (also available)

- Dynamic encoding/decoding (`encode`, `decode`)
- Schema-aware encoding (`encodeWithSchema`)
- Batch encoding (`encodeBatch`)
- Session table behavior (key/string interning, shape promotion, reset controls)
- Vector codecs (Simple8b, RLE, FOR/direct bitpack, XOR float, and plain)
- Stateful extensions (state patch, template batch, base snapshot, control stream)

### v3 type enhancements

- `SchemaField` now carries `physical_encoding` (`Auto`, `Varuint`, `ZigzagVaruint`, `RangeBits`, `FixedLe`)
- `PhysicalEncoding` enum for explicit per-field integer encoding
- `PresenceStrategy` enum (`Normal`, `Inverted`, `AllPresent`)
- `BoundRecord` struct for compact record bodies
- No per-field fallback mode bytes on the wire (per v3 spec)

## Requirements

- Zig 0.16.0 (minimum `0.16.0`)

## Quick start

```zig
const std = @import("std");
const twilic = @import("twilic");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var entries = try allocator.alloc(twilic.model.ValueMapEntry, 2);
    entries[0] = .{ .key = try allocator.dupe(u8, "id"), .value = .{ .U64 = 1001 } };
    entries[1] = .{ .key = try allocator.dupe(u8, "name"), .value = .{ .String = try allocator.dupe(u8, "alice") } };

    var value = twilic.Value{ .Map = entries };
    defer value.deinit(allocator);

    const bytes = try twilic.encode(allocator, &value);
    defer allocator.free(bytes);

    var decoded = try twilic.decode(allocator, bytes);
    defer decoded.deinit(allocator);

    std.debug.assert(twilic.Value.eql(decoded, value));
}
```

## Development

Run checks locally:

```bash
zig fmt build.zig build.zig.zon src tests
zig build test
```

Rust client interop smoke check (Zig server -> Rust client):

```bash
bash scripts/check-rust-client-interop.sh
```

Zig client interop smoke check (Rust server -> Zig client):

```bash
bash scripts/check-zig-client-interop.sh
```

Run both directions:

```bash
bash scripts/check-interop.sh
```

Note: these scripts use the sibling `../rust` runtime in this monorepo.

## CI and release (GitHub Actions)

- CI workflow: `.github/workflows/ci.yml`
  - `zig fmt --check`
  - `zig build test`
- Release workflow: `.github/workflows/publish-release.yml`
  - Triggers on `v*` tags or manual dispatch
  - Verifies tag/version match against `build.zig.zon`
  - Re-runs checks and publishes a GitHub Release

Release steps:

1. Bump `.version` in `build.zig.zon`.
2. Create and push matching tag `v<version>`.

Example:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
