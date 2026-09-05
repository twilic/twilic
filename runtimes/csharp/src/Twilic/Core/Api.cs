#nullable enable

namespace Twilic.Core;

internal static class Api
{
    public static byte[] Encode(Value value) => V2.Encode(value);

    public static Value Decode(byte[] bytes) => V2.Decode(bytes);

    public static byte[] EncodeWithSchema(Schema schema, Value value) =>
        V2.Encode(value);

    public static byte[] EncodeBatch(IReadOnlyList<Value> values) =>
        V2.Encode(Value.OfArray(values));
}
