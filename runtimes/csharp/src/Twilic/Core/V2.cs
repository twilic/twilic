#nullable enable

using System.Text;

namespace Twilic.Core;

internal static class V2
{
    const byte NullTag = 0xC0;
    const byte FalseTag = 0xC1;
    const byte TrueTag = 0xC2;
    const byte F64Tag = 0xC3;
    const byte U8Tag = 0xC4;
    const byte U16Tag = 0xC5;
    const byte U32Tag = 0xC6;
    const byte U64Tag = 0xC7;
    const byte I8Tag = 0xC8;
    const byte I16Tag = 0xC9;
    const byte I32Tag = 0xCA;
    const byte I64Tag = 0xCB;
    const byte Bin8Tag = 0xCC;
    const byte Bin16Tag = 0xCD;
    const byte Bin32Tag = 0xCE;
    const byte Str8Tag = 0xCF;
    const byte Str16Tag = 0xD0;
    const byte Str32Tag = 0xD1;
    const byte Array16Tag = 0xD2;
    const byte Array32Tag = 0xD3;
    const byte Map16Tag = 0xD4;
    const byte Map32Tag = 0xD5;
    const byte ShapeDefTag = 0xD6;
    const byte KeyRefTag = 0xD8;
    const byte StrRefTag = 0xD9;

    sealed class EncodeState
    {
        internal readonly Dictionary<string, ulong> KeyIds = new();
        internal readonly Dictionary<string, ulong> StrIds = new();
        internal readonly Dictionary<string, ulong> ShapeIds = new();
        internal ulong NextKeyId;
        internal ulong NextStrId;
        internal ulong NextShapeId;
    }

    sealed class DecodeState
    {
        internal readonly List<string> Keys = new();
        internal readonly List<string> Strings = new();
        internal readonly List<List<string>?> Shapes = new();
    }

    internal static byte[] Encode(Value value)
    {
        var buffer = new List<byte>();
        EncodeValue(value, buffer, new EncodeState());
        return buffer.ToArray();
    }

    internal static Value Decode(byte[] data)
    {
        var reader = Wire.NewReader(data);
        var state = new DecodeState();
        var value = DecodeValue(reader, state);
        if (!reader.IsEof())
            throw Errors.InvalidData("trailing bytes in v2 decode");
        return value;
    }

    static void EncodeValue(Value value, List<byte> buffer, EncodeState state)
    {
        switch (value.Kind)
        {
            case ValueKind.Null:
                buffer.Add(NullTag);
                break;
            case ValueKind.Bool:
                buffer.Add(value.Bool ? TrueTag : FalseTag);
                break;
            case ValueKind.I64:
                EncodeI64(value.I64, buffer);
                break;
            case ValueKind.U64:
                EncodeU64(value.U64, buffer);
                break;
            case ValueKind.F64:
                buffer.Add(F64Tag);
                Wire.AppendF64Le(buffer, value.F64);
                break;
            case ValueKind.String:
                if (state.StrIds.TryGetValue(value.Str, out var strRef))
                {
                    buffer.Add(StrRefTag);
                    EncodeVaruintToList(strRef, buffer);
                }
                else
                {
                    EncodeStringLiteral(value.Str, buffer);
                    state.StrIds[value.Str] = state.NextStrId++;
                }
                break;
            case ValueKind.Binary:
                EncodeBinary(value.Bin, buffer);
                break;
            case ValueKind.Array:
                EncodeArray(value.Arr, buffer, state);
                break;
            case ValueKind.Map:
                EncodeMap(value.Map, buffer, state);
                break;
            default:
                throw Errors.InvalidData("unsupported value kind");
        }
    }

    static void EncodeArray(List<Value> values, List<byte> buffer, EncodeState state)
    {
        var shapeKeys = DetectShapeKeys(values);
        if (shapeKeys != null)
        {
            var sk = ShapeKey(shapeKeys);
            if (!state.ShapeIds.TryGetValue(sk, out var shapeId))
            {
                shapeId = state.NextShapeId++;
                state.ShapeIds[sk] = shapeId;
            }
            WriteArrayHeader(values.Count, buffer);
            buffer.Add(ShapeDefTag);
            EncodeVaruintToList(shapeId, buffer);
            EncodeVaruintToList((ulong)shapeKeys.Count, buffer);
            foreach (var key in shapeKeys)
                EncodeKey(key, buffer, state);
            foreach (var row in values)
            {
                if (row.Kind != ValueKind.Map)
                    throw Errors.InvalidData("shape array row must be map");
                foreach (var field in row.Map)
                    EncodeValue(field.Value, buffer, state);
            }
            return;
        }
        WriteArrayHeader(values.Count, buffer);
        foreach (var v in values)
            EncodeValue(v, buffer, state);
    }

    static void EncodeMap(List<MapEntry> entries, List<byte> buffer, EncodeState state)
    {
        WriteMapHeader(entries.Count, buffer);
        foreach (var entry in entries)
        {
            EncodeKey(entry.Key, buffer, state);
            EncodeValue(entry.Value, buffer, state);
        }
    }

    static void EncodeKey(string key, List<byte> buffer, EncodeState state)
    {
        if (state.KeyIds.TryGetValue(key, out var refId))
        {
            buffer.Add(KeyRefTag);
            EncodeVaruintToList(refId, buffer);
            return;
        }
        EncodeStringLiteral(key, buffer);
        state.KeyIds[key] = state.NextKeyId++;
    }

    static void EncodeStringLiteral(string value, List<byte> buffer)
    {
        var raw = Encoding.UTF8.GetBytes(value);
        var length = raw.Length;
        if (length <= 31)
            buffer.Add((byte)(0x80 | length));
        else if (length <= 0xFF)
        {
            buffer.Add(Str8Tag);
            buffer.Add((byte)length);
        }
        else if (length <= 0xFFFF)
        {
            buffer.Add(Str16Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
        }
        else
        {
            buffer.Add(Str32Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
            buffer.Add((byte)((length >> 16) & 0xFF));
            buffer.Add((byte)((length >> 24) & 0xFF));
        }
        buffer.AddRange(raw);
    }

    static void EncodeBinary(byte[] value, List<byte> buffer)
    {
        var length = value.Length;
        if (length <= 0xFF)
        {
            buffer.Add(Bin8Tag);
            buffer.Add((byte)length);
        }
        else if (length <= 0xFFFF)
        {
            buffer.Add(Bin16Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
        }
        else
        {
            buffer.Add(Bin32Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
            buffer.Add((byte)((length >> 16) & 0xFF));
            buffer.Add((byte)((length >> 24) & 0xFF));
        }
        buffer.AddRange(value);
    }

    static void EncodeU64(ulong value, List<byte> buffer)
    {
        if (value <= 127)
            buffer.Add((byte)value);
        else if (value <= 0xFF)
        {
            buffer.Add(U8Tag);
            buffer.Add((byte)value);
        }
        else if (value <= 0xFFFF)
        {
            buffer.Add(U16Tag);
            buffer.Add((byte)(value & 0xFF));
            buffer.Add((byte)((value >> 8) & 0xFF));
        }
        else if (value <= 0xFFFFFFFF)
        {
            buffer.Add(U32Tag);
            buffer.Add((byte)(value & 0xFF));
            buffer.Add((byte)((value >> 8) & 0xFF));
            buffer.Add((byte)((value >> 16) & 0xFF));
            buffer.Add((byte)((value >> 24) & 0xFF));
        }
        else
        {
            buffer.Add(U64Tag);
            Wire.AppendU64Le(buffer, (long)value);
        }
    }

    static void EncodeI64(long value, List<byte> buffer)
    {
        if (value >= -32 && value <= -1)
            buffer.Add((byte)value);
        else if (value >= 0 && value <= 127)
            buffer.Add((byte)value);
        else if (value >= -128 && value <= 127)
        {
            buffer.Add(I8Tag);
            buffer.Add((byte)value);
        }
        else if (value >= -32768 && value <= 32767)
        {
            buffer.Add(I16Tag);
            buffer.Add((byte)(value & 0xFF));
            buffer.Add((byte)((value >> 8) & 0xFF));
        }
        else if (value >= int.MinValue && value <= int.MaxValue)
        {
            buffer.Add(I32Tag);
            buffer.Add((byte)(value & 0xFF));
            buffer.Add((byte)((value >> 8) & 0xFF));
            buffer.Add((byte)((value >> 16) & 0xFF));
            buffer.Add((byte)((value >> 24) & 0xFF));
        }
        else
        {
            buffer.Add(I64Tag);
            Wire.AppendU64Le(buffer, value);
        }
    }

    static void WriteArrayHeader(int length, List<byte> buffer)
    {
        if (length <= 15)
            buffer.Add((byte)(0xA0 | length));
        else if (length <= 0xFFFF)
        {
            buffer.Add(Array16Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
        }
        else
        {
            buffer.Add(Array32Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
            buffer.Add((byte)((length >> 16) & 0xFF));
            buffer.Add((byte)((length >> 24) & 0xFF));
        }
    }

    static void WriteMapHeader(int length, List<byte> buffer)
    {
        if (length <= 15)
            buffer.Add((byte)(0xB0 | length));
        else if (length <= 0xFFFF)
        {
            buffer.Add(Map16Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
        }
        else
        {
            buffer.Add(Map32Tag);
            buffer.Add((byte)(length & 0xFF));
            buffer.Add((byte)((length >> 8) & 0xFF));
            buffer.Add((byte)((length >> 16) & 0xFF));
            buffer.Add((byte)((length >> 24) & 0xFF));
        }
    }

    static List<string>? DetectShapeKeys(List<Value> values)
    {
        if (values.Count < 2)
            return null;
        if (values[0].Kind != ValueKind.Map || values[0].Map.Count == 0)
            return null;
        var keys = values[0].Map.Select(e => e.Key).ToList();
        for (var i = 1; i < values.Count; i++)
        {
            var value = values[i];
            if (value.Kind != ValueKind.Map || value.Map.Count != keys.Count)
                return null;
            for (var j = 0; j < keys.Count; j++)
            {
                if (value.Map[j].Key != keys[j])
                    return null;
            }
        }
        return keys;
    }

    static string ShapeKey(IReadOnlyList<string> keys) => string.Join("\0", keys);

    static Value DecodeValue(Wire.Reader reader, DecodeState state)
    {
        var tag = reader.ReadU8();
        return DecodeValueFromTag(reader, state, tag);
    }

    static Value DecodeValueFromTag(Wire.Reader reader, DecodeState state, byte tag)
    {
        if (tag <= 0x7F)
            return Value.OfU64(tag);
        if (tag is >= 0x80 and <= 0x9F)
        {
            var length = tag & 0x1F;
            var s = Wire.DecodeUtf8(reader.ReadExact(length));
            state.Strings.Add(s);
            return Value.OfString(s);
        }
        if (tag is >= 0xA0 and <= 0xAF)
            return DecodeArrayBody(reader, state, tag & 0x0F);
        if (tag is >= 0xB0 and <= 0xBF)
            return DecodeMapBody(reader, state, tag & 0x0F);
        if (tag >= 0xE0)
            return Value.OfI64(tag < 128 ? tag : tag - 256);
        return tag switch
        {
            NullTag => Value.OfNull(),
            FalseTag => Value.OfBool(false),
            TrueTag => Value.OfBool(true),
            F64Tag => Value.OfF64(Wire.ReadF64Le(reader)),
            U8Tag => Value.OfU64(reader.ReadU8()),
            U16Tag => DecodeU16(reader),
            U32Tag => DecodeU32(reader),
            U64Tag => Value.OfU64((ulong)Wire.ReadU64Le(reader)),
            I8Tag => DecodeI8(reader),
            I16Tag => Value.OfI64(BitConverter.ToInt16(reader.ReadExact(2), 0)),
            I32Tag => Value.OfI64(BitConverter.ToInt32(reader.ReadExact(4), 0)),
            I64Tag => Value.OfI64(BitConverter.ToInt64(reader.ReadExact(8), 0)),
            Bin8Tag => Value.OfBinary(reader.ReadExact(reader.ReadU8())),
            Bin16Tag => DecodeBinary16(reader),
            Bin32Tag => DecodeBinary32(reader),
            Str8Tag or Str16Tag or Str32Tag => DecodeStringTag(reader, state, tag),
            Array16Tag => DecodeArrayBody(reader, state, ReadU16(reader)),
            Array32Tag => DecodeArrayBody(reader, state, ReadU32(reader)),
            Map16Tag => DecodeMapBody(reader, state, ReadU16(reader)),
            Map32Tag => DecodeMapBody(reader, state, ReadU32(reader)),
            StrRefTag => DecodeStrRef(reader, state),
            _ => throw Errors.InvalidTag(tag),
        };
    }

    static Value DecodeU16(Wire.Reader reader)
    {
        var b = reader.ReadExact(2);
        return Value.OfU64((ulong)(b[0] | (b[1] << 8)));
    }

    static Value DecodeU32(Wire.Reader reader)
    {
        var b = reader.ReadExact(4);
        return Value.OfU64((ulong)(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)));
    }

    static Value DecodeI8(Wire.Reader reader)
    {
        var b = reader.ReadU8();
        return Value.OfI64(b < 128 ? b : b - 256);
    }

    static Value DecodeBinary16(Wire.Reader reader)
    {
        var b = reader.ReadExact(2);
        var n = b[0] | (b[1] << 8);
        return Value.OfBinary(reader.ReadExact(n));
    }

    static Value DecodeBinary32(Wire.Reader reader)
    {
        var b = reader.ReadExact(4);
        var n = b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
        return Value.OfBinary(reader.ReadExact(n));
    }

    static Value DecodeStringTag(Wire.Reader reader, DecodeState state, byte tag)
    {
        int length = tag switch
        {
            Str8Tag => reader.ReadU8(),
            Str16Tag => ReadU16(reader),
            Str32Tag => ReadU32(reader),
            _ => throw Errors.InvalidData("invalid string tag"),
        };
        var s = Wire.DecodeUtf8(reader.ReadExact(length));
        state.Strings.Add(s);
        return Value.OfString(s);
    }

    static Value DecodeStrRef(Wire.Reader reader, DecodeState state)
    {
        var refId = reader.ReadIndex();
        if (refId >= state.Strings.Count)
            throw Errors.InvalidData("unknown str_ref id");
        return Value.OfString(state.Strings[refId]);
    }

    static Value DecodeArrayBody(Wire.Reader reader, DecodeState state, int length)
    {
        using var depth = reader.EnterDepth();
        reader.ClaimOutput(length);
        if (length == 0)
            return Value.OfArray(Array.Empty<Value>());
        var firstTag = reader.ReadU8();
        if (firstTag == ShapeDefTag)
        {
            var shapeId = reader.ReadCount(65535);
            var keyCount = reader.ReadCount(256);
            var keys = new List<string>();
            for (var i = 0; i < keyCount; i++)
                keys.Add(DecodeKey(reader, state));
            while (state.Shapes.Count <= shapeId)
                state.Shapes.Add(null);
            state.Shapes[shapeId] = keys;
            var values = new List<Value>();
            for (var i = 0; i < length; i++)
            {
                reader.ClaimOutput(keys.Count);
                var row = keys.Select(key => Value.Entry(key, DecodeValue(reader, state))).ToList();
                values.Add(Value.OfMap(row));
            }
            return Value.OfArray(values);
        }
        var items = new Value[length];
        items[0] = DecodeValueFromTag(reader, state, firstTag);
        for (var i = 1; i < length; i++)
            items[i] = DecodeValue(reader, state);
        return Value.OfArray(items);
    }

    static Value DecodeMapBody(Wire.Reader reader, DecodeState state, int length)
    {
        using var depth = reader.EnterDepth();
        reader.ClaimOutput(length);
        var entries = new List<MapEntry>();
        for (var i = 0; i < length; i++)
            entries.Add(new MapEntry(DecodeKey(reader, state), DecodeValue(reader, state)));
        return Value.OfMap(entries);
    }

    static string DecodeKey(Wire.Reader reader, DecodeState state)
    {
        var tag = reader.ReadU8();
        if (tag == KeyRefTag)
        {
            var refId = reader.ReadIndex();
            if (refId >= state.Keys.Count)
                throw Errors.InvalidData("unknown key_ref id");
            return state.Keys[refId];
        }
        if (tag is >= 0x80 and <= 0x9F)
        {
            var length = tag & 0x1F;
            var key = Wire.DecodeUtf8(reader.ReadExact(length));
            state.Keys.Add(key);
            return key;
        }
        if (tag is Str8Tag or Str16Tag or Str32Tag)
        {
            var v = DecodeValueFromTag(reader, state, tag);
            if (v.Kind != ValueKind.String)
                throw Errors.InvalidData("expected string key");
            state.Keys.Add(v.Str);
            return v.Str;
        }
        throw Errors.InvalidData("map key must be key_ref or string");
    }

    static int ReadU16(Wire.Reader reader)
    {
        var b = reader.ReadExact(2);
        return b[0] | (b[1] << 8);
    }

    static int ReadU32(Wire.Reader reader)
    {
        var b = reader.ReadExact(4);
        return b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
    }

    static void EncodeVaruintToList(ulong value, List<byte> buffer)
    {
        var ms = new MemoryStream();
        Wire.EncodeVaruint((long)value, ms);
        buffer.AddRange(ms.ToArray());
    }
}
