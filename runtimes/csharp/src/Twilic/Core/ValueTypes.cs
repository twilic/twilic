#nullable enable

namespace Twilic.Core;

public sealed class MapEntry
{
    public string Key;
    public Value Value;

    public MapEntry(string key, Value value)
    {
        Key = key;
        Value = value;
    }
}

public sealed class KeyRef
{
    public string Literal = "";
    public ulong Id;
    public bool IsId;

    public static KeyRef LiteralRef(string s) => new() { Literal = s };
    public static KeyRef IdRef(ulong id) => new() { Id = id, IsId = true };
}

public sealed class BaseRef
{
    public bool Previous;
    public ulong BaseId;

    public static BaseRef PreviousRef() => new() { Previous = true };
    public static BaseRef IdRef(ulong id) => new() { BaseId = id };
}

public sealed class SchemaField
{
    public int Number;
    public string Name = "";
    public string LogicalType = "";
    public bool Required;
    public Value? DefaultValue;
    public long? Min;
    public long? Max;
    public List<string> EnumValues = new();
}

public sealed class Schema
{
    public ulong SchemaId;
    public string Name = "";
    public List<SchemaField> Fields = new();
}

public sealed class Value
{
    public ValueKind Kind = ValueKind.Null;
    public bool Bool;
    public long I64;
    public ulong U64;
    public double F64;
    public string Str = "";
    public byte[] Bin = Array.Empty<byte>();
    public List<Value> Arr = new();
    public List<MapEntry> Map = new();

    public static Value OfNull() => new() { Kind = ValueKind.Null };

    public static Value OfBool(bool b) => new() { Kind = ValueKind.Bool, Bool = b };

    public static Value OfI64(long n) => new() { Kind = ValueKind.I64, I64 = n };

    public static Value OfU64(ulong n) => new() { Kind = ValueKind.U64, U64 = n };

    public static Value OfF64(double n) => new() { Kind = ValueKind.F64, F64 = n };

    public static Value OfString(string s) => new() { Kind = ValueKind.String, Str = s ?? "" };

    public static Value OfBinary(byte[] b) =>
        new() { Kind = ValueKind.Binary, Bin = (byte[])b.Clone() };

    public static Value OfArray(IEnumerable<Value>? items)
    {
        var v = new Value { Kind = ValueKind.Array };
        if (items != null)
            foreach (var item in items)
                v.Arr.Add(item?.CloneValue() ?? OfNull());
        return v;
    }

    public static Value OfMap(IEnumerable<MapEntry>? entries)
    {
        var v = new Value { Kind = ValueKind.Map };
        if (entries != null)
            foreach (var e in entries)
                v.Map.Add(new MapEntry(e.Key, e.Value?.CloneValue() ?? OfNull()));
        return v;
    }

    public static MapEntry Entry(string key, Value value) => new(key, value);

    public Value CloneValue()
    {
        var outV = new Value
        {
            Kind = Kind,
            Bool = Bool,
            I64 = I64,
            U64 = U64,
            F64 = F64,
            Str = Str,
            Bin = (byte[])Bin.Clone(),
        };
        foreach (var item in Arr)
            outV.Arr.Add(item?.CloneValue() ?? OfNull());
        foreach (var e in Map)
            outV.Map.Add(new MapEntry(e.Key, e.Value?.CloneValue() ?? OfNull()));
        return outV;
    }
}

internal static class ValueOps
{
    internal static bool Equal(Value a, Value b)
    {
        if (a.Kind != b.Kind)
            return false;
        return a.Kind switch
        {
            ValueKind.Null => true,
            ValueKind.Bool => a.Bool == b.Bool,
            ValueKind.I64 => a.I64 == b.I64,
            ValueKind.U64 => a.U64 == b.U64,
            ValueKind.F64 => a.F64 == b.F64,
            ValueKind.String => a.Str == b.Str,
            ValueKind.Binary => a.Bin.AsSpan().SequenceEqual(b.Bin),
            ValueKind.Array =>
                a.Arr.Count == b.Arr.Count && !a.Arr.Where((t, i) => !Equal(t, b.Arr[i])).Any(),
            ValueKind.Map =>
                a.Map.Count == b.Map.Count
                && !a.Map.Where((e, i) => e.Key != b.Map[i].Key || !Equal(e.Value, b.Map[i].Value))
                    .Any(),
            _ => false,
        };
    }
}
