import Foundation

private let nullTag: UInt8 = 0xC0
private let falseTag: UInt8 = 0xC1
private let trueTag: UInt8 = 0xC2
private let f64Tag: UInt8 = 0xC3
private let u8Tag: UInt8 = 0xC4
private let u16Tag: UInt8 = 0xC5
private let u32Tag: UInt8 = 0xC6
private let u64Tag: UInt8 = 0xC7
private let i8Tag: UInt8 = 0xC8
private let i16Tag: UInt8 = 0xC9
private let i32Tag: UInt8 = 0xCA
private let i64Tag: UInt8 = 0xCB
private let bin8Tag: UInt8 = 0xCC
private let bin16Tag: UInt8 = 0xCD
private let bin32Tag: UInt8 = 0xCE
private let str8Tag: UInt8 = 0xCF
private let str16Tag: UInt8 = 0xD0
private let str32Tag: UInt8 = 0xD1
private let array16Tag: UInt8 = 0xD2
private let array32Tag: UInt8 = 0xD3
private let map16Tag: UInt8 = 0xD4
private let map32Tag: UInt8 = 0xD5
private let shapeDefTag: UInt8 = 0xD6
private let keyRefTag: UInt8 = 0xD8
private let strRefTag: UInt8 = 0xD9

private final class V2EncodeState {
    var keyIDs: [String: UInt64] = [:]
    var strIDs: [String: UInt64] = [:]
    var shapeIDs: [String: UInt64] = [:]
    var nextKeyID: UInt64 = 0
    var nextStrID: UInt64 = 0
    var nextShapeID: UInt64 = 0
}

private final class V2DecodeState {
    var keys: [String] = []
    var strings: [String] = []
    var shapes: [[String]?] = []
}

public func encodeV2(_ value: Value) throws -> Data {
    var out = Data()
    let state = V2EncodeState()
    try encodeV2Value(value, &out, state)
    return out
}

public func decodeV2(_ data: Data) throws -> Value {
    let reader = Wire.newReader(data)
    let state = V2DecodeState()
    let value = try decodeV2Value(reader, state)
    if !reader.isEOF {
        throw TwilicErrors.invalidData("trailing bytes in v2 decode")
    }
    return value
}

private func encodeV2Value(_ value: Value, _ out: inout Data, _ state: V2EncodeState) throws {
    switch value.kind {
    case .null:
        out.append(nullTag)
    case .bool:
        out.append(value.bool ? trueTag : falseTag)
    case .i64:
        encodeV2I64(value.i64, &out)
    case .u64:
        encodeV2U64(value.u64, &out)
    case .f64:
        out.append(f64Tag)
        Wire.appendF64LE(&out, value.f64)
    case .string:
        if let refID = state.strIDs[value.str] {
            out.append(strRefTag)
            Wire.encodeVaruint(refID, &out)
        } else {
            encodeV2StringLiteral(value.str, &out)
            state.strIDs[value.str] = state.nextStrID
            state.nextStrID += 1
        }
    case .binary:
        encodeV2Binary(value.bin, &out)
    case .array:
        try encodeV2Array(value.arr, &out, state)
    case .map:
        try encodeV2Map(value.map, &out, state)
    }
}

private func encodeV2Array(_ values: [Value], _ out: inout Data, _ state: V2EncodeState) throws {
    if let shapeKeys = detectShapeKeys(values) {
        let sk = shapeKey(shapeKeys)
        var shapeID = state.shapeIDs[sk]
        if shapeID == nil {
            shapeID = state.nextShapeID
            state.nextShapeID += 1
            state.shapeIDs[sk] = shapeID!
        }
        writeV2ArrayHeader(values.count, &out)
        out.append(shapeDefTag)
        Wire.encodeVaruint(shapeID!, &out)
        Wire.encodeVaruint(UInt64(shapeKeys.count), &out)
        for key in shapeKeys {
            encodeV2Key(key, &out, state)
        }
        for value in values {
            guard value.kind == .map else {
                throw TwilicErrors.invalidData("shape array row must be map")
            }
            for field in value.map {
                try encodeV2Value(field.value, &out, state)
            }
        }
        return
    }
    writeV2ArrayHeader(values.count, &out)
    for value in values {
        try encodeV2Value(value, &out, state)
    }
}

private func encodeV2Map(_ entries: [MapEntry], _ out: inout Data, _ state: V2EncodeState) throws {
    writeV2MapHeader(entries.count, &out)
    for e in entries {
        encodeV2Key(e.key, &out, state)
        try encodeV2Value(e.value, &out, state)
    }
}

private func encodeV2Key(_ key: String, _ out: inout Data, _ state: V2EncodeState) {
    if let refID = state.keyIDs[key] {
        out.append(keyRefTag)
        Wire.encodeVaruint(refID, &out)
        return
    }
    encodeV2StringLiteral(key, &out)
    state.keyIDs[key] = state.nextKeyID
    state.nextKeyID += 1
}

private func encodeV2StringLiteral(_ value: String, _ out: inout Data) {
    let raw = Data(value.utf8)
    let length = raw.count
    if length <= 31 {
        out.append(UInt8(0x80 | length))
    } else if length <= 0xFF {
        out.append(str8Tag)
        out.append(UInt8(length))
    } else if length <= 0xFFFF {
        out.append(str16Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
    } else {
        out.append(str32Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 24) & 0xFF))
    }
    out.append(raw)
}

private func encodeV2Binary(_ value: Data, _ out: inout Data) {
    let length = value.count
    if length <= 0xFF {
        out.append(bin8Tag)
        out.append(UInt8(length))
    } else if length <= 0xFFFF {
        out.append(bin16Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
    } else {
        out.append(bin32Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 24) & 0xFF))
    }
    out.append(value)
}

private func encodeV2U64(_ value: UInt64, _ out: inout Data) {
    if value <= 127 {
        out.append(UInt8(value))
    } else if value <= 0xFF {
        out.append(u8Tag)
        out.append(UInt8(value))
    } else if value <= 0xFFFF {
        out.append(u16Tag)
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    } else if value <= 0xFFFFFFFF {
        out.append(u32Tag)
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    } else {
        out.append(u64Tag)
        Wire.appendU64LE(&out, value)
    }
}

private func encodeV2I64(_ value: Int64, _ out: inout Data) {
    if (-32 ... -1).contains(value) {
        out.append(UInt8(bitPattern: Int8(value)))
    } else if (0 ... 127).contains(value) {
        out.append(UInt8(value))
    } else if (-128 ... 127).contains(value) {
        out.append(i8Tag)
        out.append(UInt8(bitPattern: Int8(value)))
    } else if (-32768 ... 32767).contains(value) {
        out.append(i16Tag)
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
    } else if (-2147483648 ... 2147483647).contains(value) {
        out.append(i32Tag)
        out.append(UInt8(value & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 24) & 0xFF))
    } else {
        out.append(i64Tag)
        Wire.appendU64LE(&out, UInt64(bitPattern: value))
    }
}

private func writeV2ArrayHeader(_ length: Int, _ out: inout Data) {
    if length <= 15 {
        out.append(UInt8(0xA0 | length))
    } else if length <= 0xFFFF {
        out.append(array16Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
    } else {
        out.append(array32Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 24) & 0xFF))
    }
}

private func writeV2MapHeader(_ length: Int, _ out: inout Data) {
    if length <= 15 {
        out.append(UInt8(0xB0 | length))
    } else if length <= 0xFFFF {
        out.append(map16Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
    } else {
        out.append(map32Tag)
        out.append(UInt8(length & 0xFF))
        out.append(UInt8((length >> 8) & 0xFF))
        out.append(UInt8((length >> 16) & 0xFF))
        out.append(UInt8((length >> 24) & 0xFF))
    }
}

private func detectShapeKeys(_ values: [Value]) -> [String]? {
    guard values.count >= 2, values[0].kind == .map, !values[0].map.isEmpty else { return nil }
    let keys = values[0].map.map(\.key)
    for value in values.dropFirst() {
        guard value.kind == .map, value.map.count == keys.count else { return nil }
        for (i, e) in value.map.enumerated() where e.key != keys[i] { return nil }
    }
    return keys
}

private func decodeV2Value(_ reader: Wire.Reader, _ state: V2DecodeState) throws -> Value {
    let tag = try reader.readU8()
    return try decodeV2ValueFromTag(reader, state, tag)
}

private func decodeV2ValueFromTag(_ reader: Wire.Reader, _ state: V2DecodeState, _ tag: UInt8) throws -> Value {
    if tag <= 0x7F { return newU64(UInt64(tag)) }
    if (0x80 ... 0x9F).contains(tag) {
        let length = Int(tag & 0x1F)
        let raw = try reader.readExact(length)
        guard let s = String(data: raw, encoding: .utf8) else { throw TwilicErrors.utf8Error() }
        state.strings.append(s)
        return newString(s)
    }
    if (0xA0 ... 0xAF).contains(tag) {
        return try decodeV2ArrayBody(reader, state, Int(tag & 0x0F))
    }
    if (0xB0 ... 0xBF).contains(tag) {
        return try decodeV2MapBody(reader, state, Int(tag & 0x0F))
    }
    if tag >= 0xE0 {
        let v = Int64(tag) < 128 ? Int64(tag) : Int64(tag) - 256
        return newI64(v)
    }
    switch tag {
    case nullTag: return newNull()
    case falseTag: return newBool(false)
    case trueTag: return newBool(true)
    case f64Tag: return newF64(try Wire.readF64LE(reader))
    case u8Tag: return newU64(UInt64(try reader.readU8()))
    case u16Tag:
        let b = try reader.readExact(2)
        return newU64(UInt64(b[0]) | (UInt64(b[1]) << 8))
    case u32Tag:
        let b = try reader.readExact(4)
        return newU64(UInt64(b[0]) | (UInt64(b[1]) << 8) | (UInt64(b[2]) << 16) | (UInt64(b[3]) << 24))
    case u64Tag: return newU64(try Wire.readU64LE(reader))
    case i8Tag:
        let b = try reader.readU8()
        return newI64(b < 128 ? Int64(b) : Int64(b) - 256)
    case i16Tag:
        let b = try reader.readExact(2)
        let v = Int16(bitPattern: UInt16(b[0]) | (UInt16(b[1]) << 8))
        return newI64(Int64(v))
    case i32Tag:
        let b = try reader.readExact(4)
        let v = Int32(bitPattern: UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24))
        return newI64(Int64(v))
    case i64Tag:
        let b = try reader.readExact(8)
        return newI64(Int64(bitPattern: Wire.u64FromLEBytes(b)))
    case bin8Tag:
        let n = Int(try reader.readU8())
        return newBinary(try reader.readExact(n))
    case bin16Tag:
        let b = try reader.readExact(2)
        let n = Int(b[0]) | (Int(b[1]) << 8)
        return newBinary(try reader.readExact(n))
    case bin32Tag:
        let b = try reader.readExact(4)
        let n = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
        return newBinary(try reader.readExact(n))
    case str8Tag, str16Tag, str32Tag:
        return try decodeV2StringTag(reader, state, tag)
    case array16Tag:
        let b = try reader.readExact(2)
        let n = Int(b[0]) | (Int(b[1]) << 8)
        return try decodeV2ArrayBody(reader, state, n)
    case array32Tag:
        let b = try reader.readExact(4)
        let n = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
        return try decodeV2ArrayBody(reader, state, n)
    case map16Tag:
        let b = try reader.readExact(2)
        let n = Int(b[0]) | (Int(b[1]) << 8)
        return try decodeV2MapBody(reader, state, n)
    case map32Tag:
        let b = try reader.readExact(4)
        let n = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
        return try decodeV2MapBody(reader, state, n)
    case strRefTag:
        let refID = try reader.readIndex()
        guard refID < UInt64(state.strings.count) else {
            throw TwilicErrors.invalidData("unknown str_ref id")
        }
        return newString(state.strings[Int(refID)])
    default:
        throw TwilicErrors.invalidTag(tag)
    }
}

private func decodeV2StringTag(_ reader: Wire.Reader, _ state: V2DecodeState, _ tag: UInt8) throws -> Value {
    let length: Int
    switch tag {
    case str8Tag: length = Int(try reader.readU8())
    case str16Tag:
        let b = try reader.readExact(2)
        length = Int(b[0]) | (Int(b[1]) << 8)
    case str32Tag:
        let b = try reader.readExact(4)
        length = Int(b[0]) | (Int(b[1]) << 8) | (Int(b[2]) << 16) | (Int(b[3]) << 24)
    default:
        throw TwilicErrors.invalidData("invalid string tag")
    }
    let raw = try reader.readExact(length)
    guard let s = String(data: raw, encoding: .utf8) else { throw TwilicErrors.utf8Error() }
    state.strings.append(s)
    return newString(s)
}

private func decodeV2ArrayBody(_ reader: Wire.Reader, _ state: V2DecodeState, _ length: Int) throws -> Value {
    try reader.claimOutput(length)
    try reader.enterDepth()
    defer { reader.leaveDepth() }
    if length == 0 { return newArray([]) }
    let firstTag = try reader.readU8()
    if firstTag == shapeDefTag {
        let shapeID = try reader.readCount(65535)
        let keyCount = try reader.readCount(256)
        var keys: [String] = []
        for _ in 0 ..< keyCount {
            keys.append(try decodeV2Key(reader, state))
        }
        while state.shapes.count <= Int(shapeID) {
            state.shapes.append(nil)
        }
        state.shapes[Int(shapeID)] = keys
        var values: [Value] = []
        for _ in 0 ..< length {
            try reader.claimOutput(keys.count)
            var row: [MapEntry] = []
            for key in keys {
                row.append(entry(key, try decodeV2Value(reader, state)))
            }
            values.append(newMapEntries(row))
        }
        return newArray(values)
    }
    var values: [Value] = []
    values.append(try decodeV2ValueFromTag(reader, state, firstTag))
    for _ in 1 ..< length {
        values.append(try decodeV2Value(reader, state))
    }
    return newArray(values)
}

private func decodeV2MapBody(_ reader: Wire.Reader, _ state: V2DecodeState, _ length: Int) throws -> Value {
    try reader.claimOutput(length)
    try reader.enterDepth()
    defer { reader.leaveDepth() }
    var entries: [MapEntry] = []
    for _ in 0 ..< length {
        let key = try decodeV2Key(reader, state)
        let value = try decodeV2Value(reader, state)
        entries.append(entry(key, value))
    }
    return newMapEntries(entries)
}

private func decodeV2Key(_ reader: Wire.Reader, _ state: V2DecodeState) throws -> String {
    let tag = try reader.readU8()
    if tag == keyRefTag {
        let refID = try reader.readIndex()
        guard refID < UInt64(state.keys.count) else {
            throw TwilicErrors.invalidData("unknown key_ref id")
        }
        return state.keys[Int(refID)]
    }
    if (0x80 ... 0x9F).contains(tag) {
        let length = Int(tag & 0x1F)
        let key = String(data: try reader.readExact(length), encoding: .utf8) ?? ""
        state.keys.append(key)
        return key
    }
    if tag == str8Tag || tag == str16Tag || tag == str32Tag {
        let v = try decodeV2ValueFromTag(reader, state, tag)
        guard v.kind == .string else { throw TwilicErrors.invalidData("expected string key") }
        state.keys.append(v.str)
        return v.str
    }
    throw TwilicErrors.invalidData("map key must be key_ref or string")
}
