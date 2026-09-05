import Foundation

public enum UnknownReferencePolicy: Int, Sendable {
    case failFast = 0
    case statelessRetry = 1
}

public let unknownReferencePolicyFailFast = UnknownReferencePolicy.failFast
public let unknownReferencePolicyStatelessRetry = UnknownReferencePolicy.statelessRetry

public enum DictionaryFallback: Int, Sendable {
    case failFast = 0
    case statelessRetry = 1
}

public let dictionaryFallbackFailFast = DictionaryFallback.failFast
public let dictionaryFallbackStatelessRetry = DictionaryFallback.statelessRetry

func dictionaryFallbackFromByte(_ b: UInt8) -> (DictionaryFallback, Bool) {
    if b == 0 { return (.failFast, true) }
    if b == 1 { return (.statelessRetry, true) }
    return (.failFast, false)
}

public struct DictionaryProfile: Sendable {
    public var version: UInt64
    public var hash: UInt64
    public var expiresAt: UInt64
    public var fallback: DictionaryFallback
}

public struct SessionOptions: Sendable {
    public var maxBaseSnapshots: Int = 8
    public var enableStatePatch: Bool = true
    public var enableTemplateBatch: Bool = true
    public var enableTrainedDictionary: Bool = true
    public var unknownReferencePolicy: UnknownReferencePolicy = .failFast
}

public func defaultSessionOptions() -> SessionOptions { SessionOptions() }

public final class InternTable {
    private var byValue: [String: UInt64] = [:]
    private var byID: [String] = []

    func getID(_ value: String) -> (UInt64, Bool) {
        if let refID = byValue[value] { return (refID, true) }
        return (0, false)
    }

    func getValue(_ refID: UInt64) -> (String, Bool) {
        guard refID < UInt64(byID.count) else { return ("", false) }
        return (byID[Int(refID)], true)
    }

    @discardableResult
    func register(_ value: String) -> UInt64 {
        if let existing = byValue[value] { return existing }
        let refID = UInt64(byID.count)
        byID.append(value)
        byValue[value] = refID
        return refID
    }

    func clear() {
        byValue = [:]
        byID = []
    }

    var registeredStringsInOrder: [String] { byID }
}

func shapeKey(_ keys: [String]) -> String { keys.joined(separator: "\0") }

public final class ShapeTable {
    private var byKeys: [String: UInt64] = [:]
    private var byID: [UInt64: [String]] = [:]
    private var observations: [String: Int] = [:]
    private(set) var nextID: UInt64 = 0

    func getID(_ keys: [String]) -> (UInt64, Bool) {
        let sk = shapeKey(keys)
        if let refID = byKeys[sk] { return (refID, true) }
        return (0, false)
    }

    func getKeys(_ refID: UInt64) -> ([String], Bool) {
        if let keys = byID[refID] { return (keys, true) }
        return ([], false)
    }

    @discardableResult
    func register(_ keys: [String]) -> UInt64 {
        let sk = shapeKey(keys)
        if let existing = byKeys[sk] { return existing }
        let refID = nextID
        nextID += 1
        byID[refID] = keys
        byKeys[sk] = refID
        return refID
    }

    func registerWithID(_ shapeID: UInt64, _ keys: [String]) -> Bool {
        let sk = shapeKey(keys)
        if let existing = byID[shapeID] {
            return shapeKey(existing) == sk
        }
        if let existingID = byKeys[sk], existingID != shapeID { return false }
        byID[shapeID] = keys
        byKeys[sk] = shapeID
        if shapeID + 1 > nextID { nextID = shapeID + 1 }
        return true
    }

    func observe(_ keys: [String]) -> Int {
        let sk = shapeKey(keys)
        let count = (observations[sk] ?? 0) + 1
        observations[sk] = count
        return count
    }

    func clear() {
        byKeys = [:]
        byID = [:]
        observations = [:]
        nextID = 0
    }
}

public struct BaseSnapshotEntry {
    var id: UInt64
    var message: Message
}

public final class SessionState: @unchecked Sendable {
    public var options: SessionOptions = defaultSessionOptions()
    public let keyTable = InternTable()
    public let stringTable = InternTable()
    public let shapeTable = ShapeTable()
    public var encodeShapeObservations: [String: Int] = [:]
    public var baseSnapshots: [BaseSnapshotEntry] = []
    public var templates: [UInt64: TemplateDescriptor] = [:]
    public var templateColumns: [UInt64: [Column]] = [:]
    public var fieldEnums: [String: [String]] = [:]
    public var dictionaries: [UInt64: Data] = [:]
    public var dictionaryProfiles: [UInt64: DictionaryProfile] = [:]
    public var schemas: [UInt64: Schema] = [:]
    public var lastSchemaID: UInt64?
    public var previousMessage: Message?
    public var previousMessageSize: Int?
    public var nextBaseID: UInt64 = 0
    public var nextTemplateID: UInt64 = 0
    public var nextDictionaryID: UInt64 = 0
}

public func newSessionState() -> SessionState { SessionState() }

public func newSessionStateWithOptions(_ options: SessionOptions) -> SessionState {
    let s = SessionState()
    s.options = options
    return s
}

func registerBaseSnapshot(_ state: SessionState, _ baseID: UInt64, _ message: Message) {
    var filtered = state.baseSnapshots.filter { $0.id != baseID }
    filtered.append(BaseSnapshotEntry(id: baseID, message: message.clone()))
    while filtered.count > state.options.maxBaseSnapshots {
        filtered.removeFirst()
    }
    state.baseSnapshots = filtered
}

func allocateBaseID(_ state: SessionState) -> UInt64 {
    let refID = state.nextBaseID
    state.nextBaseID += 1
    return refID
}

func allocateTemplateID(_ state: SessionState) -> UInt64 {
    let refID = state.nextTemplateID
    state.nextTemplateID += 1
    return refID
}

func allocateDictionaryID(_ state: SessionState) -> UInt64 {
    let refID = state.nextDictionaryID
    state.nextDictionaryID += 1
    return refID
}

func getBaseSnapshot(_ state: SessionState, _ baseID: UInt64) -> (Message?, Bool) {
    for entry in state.baseSnapshots where entry.id == baseID {
        return (entry.message.clone(), true)
    }
    return (nil, false)
}

func resetTables(_ state: SessionState) {
    state.keyTable.clear()
    state.stringTable.clear()
    state.shapeTable.clear()
    state.encodeShapeObservations = [:]
    state.fieldEnums = [:]
}

func resetState(_ state: SessionState) {
    resetTables(state)
    state.baseSnapshots = []
    state.templates = [:]
    state.templateColumns = [:]
    state.dictionaries = [:]
    state.dictionaryProfiles = [:]
    state.schemas = [:]
    state.lastSchemaID = nil
    state.previousMessage = nil
    state.previousMessageSize = nil
    state.nextBaseID = 0
    state.nextTemplateID = 0
    state.nextDictionaryID = 0
}
