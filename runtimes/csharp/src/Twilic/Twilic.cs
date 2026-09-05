namespace Twilic;

/// <summary>Public Twilic v2 SDK entry points.</summary>
public static class Twilic
{
    public static byte[] Encode(global::Twilic.Core.Value value) => global::Twilic.Core.Api.Encode(value);

    public static global::Twilic.Core.Value Decode(byte[] bytes) => global::Twilic.Core.Api.Decode(bytes);

    public static byte[] EncodeWithSchema(global::Twilic.Core.Schema schema, global::Twilic.Core.Value value) =>
        global::Twilic.Core.Api.EncodeWithSchema(schema, value);

    public static byte[] EncodeBatch(IReadOnlyList<global::Twilic.Core.Value> values) =>
        global::Twilic.Core.Api.EncodeBatch(values);

    public static global::Twilic.Core.Value NewNull() => global::Twilic.Core.Value.OfNull();

    public static global::Twilic.Core.Value NewBool(bool b) => global::Twilic.Core.Value.OfBool(b);

    public static global::Twilic.Core.Value NewI64(long n) => global::Twilic.Core.Value.OfI64(n);

    public static global::Twilic.Core.Value NewU64(ulong n) => global::Twilic.Core.Value.OfU64(n);

    public static global::Twilic.Core.Value NewF64(double n) => global::Twilic.Core.Value.OfF64(n);

    public static global::Twilic.Core.Value NewString(string s) => global::Twilic.Core.Value.OfString(s);

    public static global::Twilic.Core.Value NewBinary(byte[] b) => global::Twilic.Core.Value.OfBinary(b);

    public static global::Twilic.Core.Value NewArray(IEnumerable<global::Twilic.Core.Value>? items) =>
        global::Twilic.Core.Value.OfArray(items);

    public static global::Twilic.Core.MapEntry Entry(string key, global::Twilic.Core.Value value) =>
        global::Twilic.Core.Value.Entry(key, value);

    public static global::Twilic.Core.Value NewMap(params global::Twilic.Core.MapEntry[] entries) =>
        global::Twilic.Core.Value.OfMap(entries);

    public static bool Equal(global::Twilic.Core.Value a, global::Twilic.Core.Value b) =>
        global::Twilic.Core.ValueOps.Equal(a, b);
}
