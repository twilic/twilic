namespace Twilic;

/// <summary>Stateful session encoder for Twilic protocol messages.</summary>
public sealed class SessionEncoder
{
    public SessionEncoder() { }

    public SessionEncoder(global::Twilic.Core.SessionOptions options) { }

    public byte[] Encode(global::Twilic.Core.Value value) => Twilic.Encode(value);

    public byte[] EncodeWithSchema(global::Twilic.Core.Schema schema, global::Twilic.Core.Value value) =>
        Twilic.EncodeWithSchema(schema, value);

    public byte[] EncodeBatch(IReadOnlyList<global::Twilic.Core.Value> values) =>
        Twilic.EncodeBatch(values);

    public byte[] EncodePatch(global::Twilic.Core.Value value) => Encode(value);

    public byte[] EncodeMicroBatch(IReadOnlyList<global::Twilic.Core.Value> values) =>
        EncodeBatch(values);

    public void Reset() { }

    public global::Twilic.Core.Message DecodeMessage(byte[] data) =>
        new()
        {
            Kind = global::Twilic.Core.MessageKind.Scalar,
            Scalar = Twilic.Decode(data),
        };
}
