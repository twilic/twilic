import Foundation

// Protocol codec port in progress — see docs/reference/ProtocolCodec.java.txt
// and scripts/java_protocol_to_swift.py / scripts/port_protocol_from_python.py

public final class TwilicCodec {
    public var state: SessionState

    public init(state: SessionState? = nil) {
        self.state = state ?? newSessionState()
    }

    public func encodeValue(_ value: Value) throws -> Data {
        throw TwilicErrors.invalidData("TwilicCodec.encodeValue: protocol layer not yet ported to Swift")
    }

    public func decodeValue(_ data: Data) throws -> Value {
        throw TwilicErrors.invalidData("TwilicCodec.decodeValue: protocol layer not yet ported to Swift")
    }

    public func encodeMessage(_ message: Message) throws -> Data {
        throw TwilicErrors.invalidData("TwilicCodec.encodeMessage: protocol layer not yet ported to Swift")
    }

    public func decodeMessage(_ data: Data) throws -> Message {
        throw TwilicErrors.invalidData("TwilicCodec.decodeMessage: protocol layer not yet ported to Swift")
    }
}

public final class SessionEncoder {
    public let codec: TwilicCodec

    public init(options: SessionOptions? = nil) {
        let opts = options ?? defaultSessionOptions()
        codec = TwilicCodec(state: newSessionStateWithOptions(opts))
    }

    public func encode(_ value: Value) throws -> Data {
        try codec.encodeValue(value)
    }

    public func encodeWithSchema(schema: Schema, value: Value) throws -> Data {
        _ = schema
        _ = value
        throw TwilicErrors.invalidData("SessionEncoder.encodeWithSchema: protocol layer not yet ported to Swift")
    }

    public func encodeBatch(_ values: [Value]) throws -> Data {
        _ = values
        throw TwilicErrors.invalidData("SessionEncoder.encodeBatch: protocol layer not yet ported to Swift")
    }

    public func decodeMessage(_ data: Data) throws -> Message {
        try codec.decodeMessage(data)
    }
}

public func newTwilicCodec() -> TwilicCodec { TwilicCodec() }

public func twilicCodecWithOptions(_ options: SessionOptions) -> TwilicCodec {
    TwilicCodec(state: newSessionStateWithOptions(options))
}

public func newSessionEncoder(_ options: SessionOptions? = nil) -> SessionEncoder {
    SessionEncoder(options: options)
}
