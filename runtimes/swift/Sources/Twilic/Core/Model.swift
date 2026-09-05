import Foundation

public enum MessageKind: UInt8, Sendable {
    case scalar = 0x00
    case array = 0x01
    case map = 0x02
    case shapedObject = 0x03
    case schemaObject = 0x04
    case typedVector = 0x05
    case rowBatch = 0x06
    case columnBatch = 0x07
    case control = 0x08
    case ext = 0x09
    case statePatch = 0x0A
    case templateBatch = 0x0B
    case controlStream = 0x0C
    case baseSnapshot = 0x0D
}

public let messageKindScalar = MessageKind.scalar
public let messageKindArray = MessageKind.array
public let messageKindMap = MessageKind.map
public let messageKindShapedObject = MessageKind.shapedObject
public let messageKindSchemaObject = MessageKind.schemaObject
public let messageKindTypedVector = MessageKind.typedVector
public let messageKindRowBatch = MessageKind.rowBatch
public let messageKindColumnBatch = MessageKind.columnBatch
public let messageKindControl = MessageKind.control
public let messageKindExt = MessageKind.ext
public let messageKindStatePatch = MessageKind.statePatch
public let messageKindTemplateBatch = MessageKind.templateBatch
public let messageKindControlStream = MessageKind.controlStream
public let messageKindBaseSnapshot = MessageKind.baseSnapshot

func messageKindFromByte(_ b: UInt8) -> (MessageKind, Bool) {
    MessageKind(rawValue: b).map { ($0, true) } ?? (.scalar, false)
}

public enum ValueKind: UInt8, Sendable {
    case null = 0
    case bool = 1
    case i64 = 2
    case u64 = 3
    case f64 = 4
    case string = 5
    case binary = 6
    case array = 7
    case map = 8
}

public let valueNull = ValueKind.null
public let valueBool = ValueKind.bool
public let valueI64 = ValueKind.i64
public let valueU64 = ValueKind.u64
public let valueF64 = ValueKind.f64
public let valueString = ValueKind.string
public let valueBinary = ValueKind.binary
public let valueArray = ValueKind.array
public let valueMap = ValueKind.map

public final class Value: @unchecked Sendable {
    public var kind: ValueKind = .null
    public var bool: Bool = false
    public var i64: Int64 = 0
    public var u64: UInt64 = 0
    public var f64: Double = 0
    public var str: String = ""
    public var bin: Data = Data()
    public var arr: [Value] = []
    public var map: [MapEntry] = []

    public init() {}

    public func isScalar() -> Bool { kind != .array && kind != .map }

    public func clone() -> Value {
        let out = Value()
        out.kind = kind
        out.bool = bool
        out.i64 = i64
        out.u64 = u64
        out.f64 = f64
        out.str = str
        switch kind {
        case .null, .bool, .i64, .u64, .f64, .string:
            break
        case .binary:
            out.bin = bin
        case .array:
            out.arr = arr.map { $0.clone() }
        case .map:
            out.map = map.map { MapEntry(key: $0.key, value: $0.value.clone()) }
        }
        return out
    }
}

public struct MapEntry: Sendable {
    public var key: String
    public var value: Value
    public init(key: String, value: Value) {
        self.key = key
        self.value = value
    }
}

public struct MessageMapEntry: Sendable {
    public var key: KeyRef
    public var value: Value
    public init(key: KeyRef, value: Value) {
        self.key = key
        self.value = value
    }
}

public func newNull() -> Value { Value() }

public func newBool(_ b: Bool) -> Value {
    let v = Value()
    v.kind = .bool
    v.bool = b
    return v
}

public func newI64(_ n: Int64) -> Value {
    let v = Value()
    v.kind = .i64
    v.i64 = n
    return v
}

public func newU64(_ n: UInt64) -> Value {
    let v = Value()
    v.kind = .u64
    v.u64 = n
    return v
}

public func newF64(_ n: Double) -> Value {
    let v = Value()
    v.kind = .f64
    v.f64 = n
    return v
}

public func newString(_ s: String) -> Value {
    let v = Value()
    v.kind = .string
    v.str = s
    return v
}

public func newBinary(_ b: Data) -> Value {
    let v = Value()
    v.kind = .binary
    v.bin = b
    return v
}

public func newArray(_ items: [Value]) -> Value {
    let v = Value()
    v.kind = .array
    v.arr = items.map { $0.clone() }
    return v
}

public func entry(_ key: String, _ value: Value) -> MapEntry {
    MapEntry(key: key, value: value)
}

public func newMap(_ entries: MapEntry...) -> Value {
    newMapEntries(entries)
}

public func newMapEntries(_ entries: [MapEntry]) -> Value {
    let v = Value()
    v.kind = .map
    v.map = entries.map { MapEntry(key: $0.key, value: $0.value.clone()) }
    return v
}

public func equal(_ a: Value, _ b: Value) -> Bool {
    if a.kind != b.kind { return false }
    switch a.kind {
    case .null: return true
    case .bool: return a.bool == b.bool
    case .i64: return a.i64 == b.i64
    case .u64: return a.u64 == b.u64
    case .f64: return a.f64 == b.f64
    case .string: return a.str == b.str
    case .binary: return a.bin == b.bin
    case .array:
        if a.arr.count != b.arr.count { return false }
        return zip(a.arr, b.arr).allSatisfy { equal($0, $1) }
    case .map:
        if a.map.count != b.map.count { return false }
        for i in 0 ..< a.map.count {
            if a.map[i].key != b.map[i].key || !equal(a.map[i].value, b.map[i].value) { return false }
        }
        return true
    }
}

public struct KeyRef: Sendable {
    public var literal: String = ""
    public var id: UInt64 = 0
    public var isID: Bool = false
    public init(literal: String = "", id: UInt64 = 0, isID: Bool = false) {
        self.literal = literal
        self.id = id
        self.isID = isID
    }
}

public func keyRefLiteral(_ s: String) -> KeyRef { KeyRef(literal: s) }
public func keyRefID(_ refID: UInt64) -> KeyRef { KeyRef(id: refID, isID: true) }

public enum StringMode: UInt8, Sendable {
    case empty = 0
    case literal = 1
    case ref = 2
    case prefixDelta = 3
    case inlineEnum = 4
}

public let stringModeEmpty = StringMode.empty
public let stringModeLiteral = StringMode.literal
public let stringModeRef = StringMode.ref
public let stringModePrefixDelta = StringMode.prefixDelta
public let stringModeInlineEnum = StringMode.inlineEnum

func stringModeFromByte(_ b: UInt8) -> (StringMode, Bool) {
    if b <= 4 { return (StringMode(rawValue: b) ?? .empty, true) }
    return (.empty, false)
}

public struct StringValue: Sendable {
    public var mode: StringMode
    public var value: String = ""
    public var refID: UInt64?
    public var prefixLen: Int?
}

public enum ElementType: UInt8, Sendable {
    case bool = 0
    case i64 = 1
    case u64 = 2
    case f64 = 3
    case string = 4
    case binary = 5
    case value = 6
}

public let elementTypeBool = ElementType.bool
public let elementTypeI64 = ElementType.i64
public let elementTypeU64 = ElementType.u64
public let elementTypeF64 = ElementType.f64
public let elementTypeString = ElementType.string
public let elementTypeBinary = ElementType.binary
public let elementTypeValue = ElementType.value

func elementTypeFromByte(_ b: UInt8) -> (ElementType, Bool) {
    if b <= 6 { return (ElementType(rawValue: b) ?? .bool, true) }
    return (.bool, false)
}

public enum VectorCodec: UInt8, Sendable {
    case plain = 0
    case directBitpack = 1
    case deltaBitpack = 2
    case forBitpack = 3
    case deltaForBitpack = 4
    case deltaDeltaBitpack = 5
    case rle = 6
    case patchedFor = 7
    case simple8b = 8
    case xorFloat = 9
    case dictionary = 10
    case stringRef = 11
    case prefixDelta = 12
}

public let vectorCodecPlain = VectorCodec.plain
public let vectorCodecDirectBitpack = VectorCodec.directBitpack
public let vectorCodecDeltaBitpack = VectorCodec.deltaBitpack
public let vectorCodecForBitpack = VectorCodec.forBitpack
public let vectorCodecDeltaForBitpack = VectorCodec.deltaForBitpack
public let vectorCodecDeltaDeltaBitpack = VectorCodec.deltaDeltaBitpack
public let vectorCodecRle = VectorCodec.rle
public let vectorCodecPatchedFor = VectorCodec.patchedFor
public let vectorCodecSimple8b = VectorCodec.simple8b
public let vectorCodecXorFloat = VectorCodec.xorFloat
public let vectorCodecDictionary = VectorCodec.dictionary
public let vectorCodecStringRef = VectorCodec.stringRef
public let vectorCodecPrefixDelta = VectorCodec.prefixDelta

func vectorCodecFromByte(_ b: UInt8) -> (VectorCodec, Bool) {
    if b <= 12 { return (VectorCodec(rawValue: b) ?? .plain, true) }
    return (.plain, false)
}

public final class TypedVectorData: @unchecked Sendable {
    public var kind: ElementType = .bool
    public var bools: [Bool] = []
    public var i64s: [Int64] = []
    public var u64s: [UInt64] = []
    public var f64s: [Double] = []
    public var strings: [String] = []
    public var binary: [Data] = []
    public var values: [Value] = []
}

public struct TypedVector: Sendable {
    public var elementType: ElementType
    public var codec: VectorCodec
    public var data: TypedVectorData
    public init(elementType: ElementType, codec: VectorCodec, data: TypedVectorData) {
        self.elementType = elementType
        self.codec = codec
        self.data = data
    }
}

public struct SchemaField: Sendable {
    public var number: Int
    public var name: String
    public var logicalType: String = ""
    public var required: Bool = false
    public var defaultValue: Value?
    public var min: Int64?
    public var max: Int64?
    public var enumValues: [String] = []
}

public struct Schema: Sendable {
    public var schemaID: UInt64
    public var name: String
    public var fields: [SchemaField]
}

public enum NullStrategy: UInt8, Sendable {
    case none = 0
    case presenceBitmap = 1
    case invertedPresenceBitmap = 2
    case allPresentElided = 3
}

public let nullStrategyNone = NullStrategy.none
public let nullStrategyPresenceBitmap = NullStrategy.presenceBitmap
public let nullStrategyInvertedPresenceBitmap = NullStrategy.invertedPresenceBitmap
public let nullStrategyAllPresentElided = NullStrategy.allPresentElided

func nullStrategyFromByte(_ b: UInt8) -> (NullStrategy, Bool) {
    if b <= 3 { return (NullStrategy(rawValue: b) ?? .none, true) }
    return (.none, false)
}

public struct Column: Sendable {
    public var fieldID: UInt64
    public var nullStrategy: NullStrategy
    public var presence: [Bool] = []
    public var hasPresence: Bool = false
    public var codec: VectorCodec = .plain
    public var dictionaryID: UInt64?
    public var values: TypedVectorData = TypedVectorData()
}

public enum ControlOpcode: UInt8, Sendable {
    case registerKeys = 0
    case registerShape = 1
    case registerStrings = 2
    case promoteStringFieldToEnum = 3
    case resetTables = 4
    case resetState = 5
}

public let controlOpcodeRegisterKeys = ControlOpcode.registerKeys
public let controlOpcodeRegisterShape = ControlOpcode.registerShape
public let controlOpcodeRegisterStrings = ControlOpcode.registerStrings
public let controlOpcodePromoteStringFieldToEnum = ControlOpcode.promoteStringFieldToEnum
public let controlOpcodeResetTables = ControlOpcode.resetTables
public let controlOpcodeResetState = ControlOpcode.resetState

func controlOpcodeFromByte(_ b: UInt8) -> (ControlOpcode, Bool) {
    if b <= 5 { return (ControlOpcode(rawValue: b) ?? .registerKeys, true) }
    return (.registerKeys, false)
}

public struct RegisterShapeControl: Sendable {
    public var shapeID: UInt64
    public var keys: [KeyRef]
}

public struct PromoteEnumControl: Sendable {
    public var fieldIdentity: String
    public var values: [String]
}

public struct ControlMessage: Sendable {
    public var opcode: ControlOpcode
    public var registerKeys: [String] = []
    public var registerShape: RegisterShapeControl?
    public var registerStrings: [String] = []
    public var promoteStringFieldToEnum: PromoteEnumControl?
    public var resetTables: Bool = false
    public var resetState: Bool = false
}

public enum PatchOpcode: UInt8, Sendable {
    case keep = 0
    case replaceScalar = 1
    case replaceVector = 2
    case appendVector = 3
    case truncateVector = 4
    case deleteField = 5
    case insertField = 6
    case stringRef = 7
    case prefixDelta = 8
}

public let patchOpcodeKeep = PatchOpcode.keep
public let patchOpcodeReplaceScalar = PatchOpcode.replaceScalar
public let patchOpcodeReplaceVector = PatchOpcode.replaceVector
public let patchOpcodeAppendVector = PatchOpcode.appendVector
public let patchOpcodeTruncateVector = PatchOpcode.truncateVector
public let patchOpcodeDeleteField = PatchOpcode.deleteField
public let patchOpcodeInsertField = PatchOpcode.insertField
public let patchOpcodeStringRef = PatchOpcode.stringRef
public let patchOpcodePrefixDelta = PatchOpcode.prefixDelta

func patchOpcodeFromByte(_ b: UInt8) -> (PatchOpcode, Bool) {
    if b <= 8 { return (PatchOpcode(rawValue: b) ?? .keep, true) }
    return (.keep, false)
}

public struct BaseRef: Sendable {
    public var previous: Bool = false
    public var baseID: UInt64 = 0
}

public func baseRefPrevious() -> BaseRef { BaseRef(previous: true) }
public func baseRefID(_ refID: UInt64) -> BaseRef { BaseRef(baseID: refID) }

public struct PatchOperation: Sendable {
    public var fieldID: UInt64
    public var opcode: PatchOpcode
    public var value: Value?
}

public enum ControlStreamCodec: UInt8, Sendable {
    case plain = 0
    case rle = 1
    case bitpack = 2
    case huffman = 3
    case fse = 4
}

public let controlStreamCodecPlain = ControlStreamCodec.plain
public let controlStreamCodecRle = ControlStreamCodec.rle
public let controlStreamCodecBitpack = ControlStreamCodec.bitpack
public let controlStreamCodecHuffman = ControlStreamCodec.huffman
public let controlStreamCodecFse = ControlStreamCodec.fse

func controlStreamCodecFromByte(_ b: UInt8) -> (ControlStreamCodec, Bool) {
    if b <= 4 { return (ControlStreamCodec(rawValue: b) ?? .plain, true) }
    return (.plain, false)
}

public struct ShapedObjectMessage: Sendable {
    public var shapeID: UInt64
    public var values: [Value]
    public var presence: [Bool] = []
    public var hasPresence: Bool = false
}

public struct SchemaObjectMessage: Sendable {
    public var fields: [Value]
    public var schemaID: UInt64?
    public var presence: [Bool] = []
    public var hasPresence: Bool = false
}

public struct RowBatchMessage: Sendable {
    public var rows: [[Value]]
}

public struct ColumnBatchMessage: Sendable {
    public var count: UInt64
    public var columns: [Column]
}

public struct ExtMessage: Sendable {
    public var extType: UInt64
    public var payload: Data
}

public struct StatePatchMessage: Sendable {
    public var baseRef: BaseRef
    public var operations: [PatchOperation]
    public var literals: [Value] = []
}

public struct TemplateBatchMessage: Sendable {
    public var templateID: UInt64
    public var count: UInt64
    public var changedColumnMask: [Bool]
    public var columns: [Column]
}

public struct ControlStreamMessage: Sendable {
    public var codec: ControlStreamCodec
    public var payload: Data
}

public struct BaseSnapshotMessage: Sendable {
    public var baseID: UInt64
    public var schemaOrShapeRef: UInt64
    public var payload: Message
}

public struct TemplateDescriptor: Sendable {
    public var templateID: UInt64
    public var fieldIDs: [UInt64] = []
    public var nullStrategies: [NullStrategy] = []
    public var codecs: [VectorCodec] = []
}

public final class Message: @unchecked Sendable {
    public var kind: MessageKind
    public var scalar: Value?
    public var array: [Value] = []
    public var map: [MessageMapEntry] = []
    public var shapedObject: ShapedObjectMessage?
    public var schemaObject: SchemaObjectMessage?
    public var typedVector: TypedVector?
    public var rowBatch: RowBatchMessage?
    public var columnBatch: ColumnBatchMessage?
    public var control: ControlMessage?
    public var ext: ExtMessage?
    public var statePatch: StatePatchMessage?
    public var templateBatch: TemplateBatchMessage?
    public var controlStream: ControlStreamMessage?
    public var baseSnapshot: BaseSnapshotMessage?

    public init(kind: MessageKind) {
        self.kind = kind
    }

    public func clone() -> Message {
        let m = Message(kind: kind)
        switch kind {
        case .scalar:
            m.scalar = scalar?.clone() ?? newNull()
        case .array:
            m.array = array.map { $0.clone() }
        case .map:
            m.map = map.map { MessageMapEntry(key: $0.key, value: $0.value.clone()) }
        case .shapedObject:
            if let s = shapedObject {
                m.shapedObject = ShapedObjectMessage(
                    shapeID: s.shapeID,
                    values: s.values.map { $0.clone() },
                    presence: s.hasPresence ? s.presence : [],
                    hasPresence: s.hasPresence
                )
            }
        case .schemaObject:
            if let s = schemaObject {
                m.schemaObject = SchemaObjectMessage(
                    fields: s.fields.map { $0.clone() },
                    schemaID: s.schemaID,
                    presence: s.hasPresence ? s.presence : [],
                    hasPresence: s.hasPresence
                )
            }
        case .typedVector:
            m.typedVector = cloneTypedVector(typedVector)
        case .rowBatch:
            if let rb = rowBatch {
                m.rowBatch = RowBatchMessage(rows: rb.rows.map { $0.map { $0.clone() } })
            }
        case .columnBatch:
            if let cb = columnBatch {
                m.columnBatch = ColumnBatchMessage(count: cb.count, columns: cb.columns.map { cloneColumn($0) })
            }
        case .control:
            m.control = cloneControl(control)
        case .ext:
            if let e = ext {
                m.ext = ExtMessage(extType: e.extType, payload: e.payload)
            }
        case .statePatch:
            if let sp = statePatch {
                m.statePatch = StatePatchMessage(
                    baseRef: sp.baseRef,
                    operations: sp.operations.map {
                        PatchOperation(fieldID: $0.fieldID, opcode: $0.opcode, value: $0.value?.clone())
                    },
                    literals: sp.literals.map { $0.clone() }
                )
            }
        case .templateBatch:
            if let tb = templateBatch {
                m.templateBatch = TemplateBatchMessage(
                    templateID: tb.templateID,
                    count: tb.count,
                    changedColumnMask: tb.changedColumnMask,
                    columns: tb.columns.map { cloneColumn($0) }
                )
            }
        case .controlStream:
            if let cs = controlStream {
                m.controlStream = ControlStreamMessage(codec: cs.codec, payload: cs.payload)
            }
        case .baseSnapshot:
            if let bs = baseSnapshot {
                m.baseSnapshot = BaseSnapshotMessage(
                    baseID: bs.baseID,
                    schemaOrShapeRef: bs.schemaOrShapeRef,
                    payload: bs.payload.clone()
                )
            }
        default:
            m.scalar = newNull()
        }
        return m
    }
}

func cloneTypedVector(_ tv: TypedVector?) -> TypedVector? {
    guard let tv else { return nil }
    let outData = TypedVectorData()
    outData.kind = tv.elementType
    switch tv.elementType {
    case .bool: outData.bools = tv.data.bools
    case .i64: outData.i64s = tv.data.i64s
    case .u64: outData.u64s = tv.data.u64s
    case .f64: outData.f64s = tv.data.f64s
    case .string: outData.strings = tv.data.strings
    case .binary: outData.binary = tv.data.binary
    case .value: outData.values = tv.data.values.map { $0.clone() }
    }
    return TypedVector(elementType: tv.elementType, codec: tv.codec, data: outData)
}

func cloneColumn(_ c: Column) -> Column {
    var out = Column(
        fieldID: c.fieldID,
        nullStrategy: c.nullStrategy,
        presence: c.hasPresence ? c.presence : [],
        hasPresence: c.hasPresence,
        codec: c.codec,
        dictionaryID: c.dictionaryID,
        values: cloneTypedVectorData(c.values)
    )
    return out
}

func cloneTypedVectorData(_ d: TypedVectorData) -> TypedVectorData {
    let out = TypedVectorData()
    out.kind = d.kind
    out.bools = d.bools
    out.i64s = d.i64s
    out.u64s = d.u64s
    out.f64s = d.f64s
    out.strings = d.strings
    out.binary = d.binary
    out.values = d.values.map { $0.clone() }
    return out
}

func cloneControl(_ c: ControlMessage?) -> ControlMessage? {
    guard let c else { return nil }
    var out = ControlMessage(opcode: c.opcode, registerKeys: c.registerKeys, registerStrings: c.registerStrings)
    out.resetTables = c.resetTables
    out.resetState = c.resetState
    if let rs = c.registerShape {
        out.registerShape = RegisterShapeControl(shapeID: rs.shapeID, keys: rs.keys)
    }
    if let p = c.promoteStringFieldToEnum {
        out.promoteStringFieldToEnum = PromoteEnumControl(fieldIdentity: p.fieldIdentity, values: p.values)
    }
    return out
}
