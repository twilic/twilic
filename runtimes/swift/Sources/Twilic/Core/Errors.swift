import Foundation

public enum TwilicErrorKind: Int, Sendable {
    case errUnexpectedEOF = 0
    case errInvalidKind = 1
    case errInvalidTag = 2
    case errInvalidData = 3
    case errUTF8 = 4
    case errUnknownReference = 5
    case errStatelessRetryRequired = 6
}

public let errUnexpectedEOF = TwilicErrorKind.errUnexpectedEOF
public let errInvalidKind = TwilicErrorKind.errInvalidKind
public let errInvalidTag = TwilicErrorKind.errInvalidTag
public let errInvalidData = TwilicErrorKind.errInvalidData
public let errUTF8 = TwilicErrorKind.errUTF8
public let errUnknownReference = TwilicErrorKind.errUnknownReference
public let errStatelessRetryRequired = TwilicErrorKind.errStatelessRetryRequired

public struct TwilicError: Error, CustomStringConvertible, Sendable {
    public let kind: TwilicErrorKind
    public let byte: UInt8
    public let msg: String
    public let refKind: String
    public let refID: UInt64

    public init(
        kind: TwilicErrorKind,
        byte: UInt8 = 0,
        msg: String = "",
        refKind: String = "",
        refID: UInt64 = 0
    ) {
        self.kind = kind
        self.byte = byte
        self.msg = msg
        self.refKind = refKind
        self.refID = refID
    }

    public var description: String {
        switch kind {
        case .errUnexpectedEOF:
            return "unexpected end of input"
        case .errInvalidKind:
            return String(format: "invalid message kind: %#04x", byte)
        case .errInvalidTag:
            return String(format: "invalid value tag: %#04x", byte)
        case .errInvalidData:
            return "invalid data: \(msg)"
        case .errUTF8:
            return "utf8 decode error"
        case .errUnknownReference:
            return "unknown reference: \(refKind)=\(refID)"
        case .errStatelessRetryRequired:
            return "stateless retry required for reference: \(refKind)=\(refID)"
        }
    }
}

enum TwilicErrors {
    static func unexpectedEOF() -> TwilicError { TwilicError(kind: .errUnexpectedEOF) }
    static func invalidKind(_ b: UInt8) -> TwilicError { TwilicError(kind: .errInvalidKind, byte: b) }
    static func invalidTag(_ b: UInt8) -> TwilicError { TwilicError(kind: .errInvalidTag, byte: b) }
    static func invalidData(_ msg: String) -> TwilicError { TwilicError(kind: .errInvalidData, msg: msg) }
    static func utf8Error() -> TwilicError { TwilicError(kind: .errUTF8) }
    static func unknownReference(_ kind: String, _ refID: UInt64) -> TwilicError {
        TwilicError(kind: .errUnknownReference, refKind: kind, refID: refID)
    }
    static func statelessRetryRequired(_ kind: String, _ refID: UInt64) -> TwilicError {
        TwilicError(kind: .errStatelessRetryRequired, refKind: kind, refID: refID)
    }
    static func isStatelessRetry(_ err: Error) -> Bool {
        guard let e = err as? TwilicError else { return false }
        return e.kind == .errStatelessRetryRequired
    }
    static func isUnknownReference(_ err: Error) -> Bool {
        guard let e = err as? TwilicError else { return false }
        return e.kind == .errUnknownReference
    }
}
