#nullable enable

using System.Text;

namespace Twilic.Core;

internal static class Wire
{
    internal static string DecodeUtf8(byte[] bytes)
    {
        try { return new UTF8Encoding(false, true).GetString(bytes); }
        catch (DecoderFallbackException) { throw Errors.Utf8Error(); }
    }

    internal static void EncodeVaruint(long value, MemoryStream sink)
    {
        if (Unsigned.Compare(value, 0x80L) < 0)
        {
            sink.WriteByte((byte)value);
            return;
        }
        for (; ; )
        {
            byte b = (byte)(value & 0x7F);
            value = (long)((ulong)value >> 7);
            if (value != 0L)
                b |= 0x80;
            sink.WriteByte(b);
            if (value == 0L)
                break;
        }
    }

    internal static long EncodeZigzag(long value) => (value << 1) ^ (value >> 63);

    internal static long DecodeZigzag(long value) =>
        (long)(((ulong)value >> 1) ^ (ulong)-(value & 1L));

    internal static void EncodeBytes(byte[] bytes, MemoryStream sink)
    {
        EncodeVaruint(bytes.Length, sink);
        sink.Write(bytes, 0, bytes.Length);
    }

    internal static void EncodeString(string value, MemoryStream sink) =>
        EncodeBytes(Encoding.UTF8.GetBytes(value), sink);

    internal static void EncodeBitmap(bool[] bits, MemoryStream sink)
    {
        EncodeVaruint(bits.Length, sink);
        byte current = 0;
        for (int i = 0; i < bits.Length; i++)
        {
            if (bits[i])
                current |= (byte)(1 << (i % 8));
            if (i % 8 == 7)
            {
                sink.WriteByte(current);
                current = 0;
            }
        }
        if (bits.Length % 8 != 0)
            sink.WriteByte(current);
    }

    internal sealed class Reader
    {
        readonly byte[] input;
        int offset;
        int depth;
        long budget;

        internal Reader(byte[] input) { this.input = input; budget = Math.Min(input.Length, 1024) * 1024L; }

        internal void ClaimOutput(long count)
        {
            if (count < 0 || count > (1 << 20)) throw Errors.InvalidData("decode count limit exceeded");
            if (count > budget / 8) throw Errors.InvalidData("decode output ratio exceeded");
            budget -= count * 8;
        }
        internal int ReadIndex(int maximum = int.MaxValue)
        {
            long n = ReadVaruint();
            if (n < 0 || n > maximum) throw Errors.InvalidData("decode count limit exceeded");
            return (int)n;
        }
        internal int ReadCount(int maximum = 1 << 20)
        {
            int n = ReadIndex(maximum);
            ClaimOutput(n);
            return n;
        }
        internal IDisposable EnterDepth()
        {
            if (depth >= 64) throw Errors.InvalidData("decode depth limit exceeded");
            depth++;
            return new DepthScope(this);
        }
        sealed class DepthScope(Reader reader) : IDisposable
        {
            public void Dispose() { reader.depth--; }
        }

        internal int Position() => offset;

        internal bool IsEof() => offset >= input.Length;

        internal byte ReadU8()
        {
            if (offset >= input.Length)
                throw Errors.UnexpectedEof();
            return input[offset++];
        }

        internal byte[] ReadExact(int n)
        {
            int end = offset + n;
            if (n < 0 || n > input.Length - offset)
                throw Errors.UnexpectedEof();
            var slice = new byte[n];
            Array.Copy(input, offset, slice, 0, n);
            offset = end;
            return slice;
        }

        internal long ReadVaruint()
        {
            int shift = 0;
            long result = 0L;
            for (; ; )
            {
                if (shift >= 64)
                    throw Errors.InvalidData("varuint too large");
                byte b = ReadU8();
                if (shift == 63 && (b & 0x7E) != 0) throw Errors.InvalidData("varuint too large");
                result |= (long)(b & 0x7F) << shift;
                if ((b & 0x80) == 0)
                    return result;
                shift += 7;
            }
        }

        internal long ReadI64Zigzag() => DecodeZigzag(ReadVaruint());

        internal byte[] ReadBytes()
        {
            long n = ReadVaruint();
            if (n < 0 || n > input.Length - offset) throw Errors.UnexpectedEof();
            return ReadExact((int)n);
        }

        internal string ReadString() => DecodeUtf8(ReadBytes());

        internal bool[] ReadBitmap()
        {
            long bitCount = ReadCount();
            int byteCount = (int)((bitCount + 7L) / 8L);
            var bytes = ReadExact(byteCount);
            var bits = new bool[(int)bitCount];
            for (int i = 0; i < (int)bitCount; i++)
                bits[i] = (((bytes[i / 8] & 0xFF) >> (i % 8)) & 1) == 1;
            return bits;
        }
    }

    internal static Reader NewReader(byte[] input) => new(input);

    internal static long ReadU64Le(Reader r)
    {
        var b = r.ReadExact(8);
        return ((long)b[0] & 0xFF)
            | (((long)b[1] & 0xFF) << 8)
            | (((long)b[2] & 0xFF) << 16)
            | (((long)b[3] & 0xFF) << 24)
            | (((long)b[4] & 0xFF) << 32)
            | (((long)b[5] & 0xFF) << 40)
            | (((long)b[6] & 0xFF) << 48)
            | (((long)b[7] & 0xFF) << 56);
    }

    internal static double ReadF64Le(Reader r) =>
        BitConverter.Int64BitsToDouble(ReadU64Le(r));

    internal static void AppendU64Le(MemoryStream sink, long v)
    {
        sink.WriteByte((byte)v);
        sink.WriteByte((byte)((ulong)v >> 8));
        sink.WriteByte((byte)((ulong)v >> 16));
        sink.WriteByte((byte)((ulong)v >> 24));
        sink.WriteByte((byte)((ulong)v >> 32));
        sink.WriteByte((byte)((ulong)v >> 40));
        sink.WriteByte((byte)((ulong)v >> 48));
        sink.WriteByte((byte)((ulong)v >> 56));
    }

    internal static void AppendF64Le(MemoryStream sink, double v) =>
        AppendU64Le(sink, BitConverter.DoubleToInt64Bits(v));

    internal static void AppendU64Le(List<byte> buffer, long v)
    {
        buffer.Add((byte)v);
        buffer.Add((byte)((ulong)v >> 8));
        buffer.Add((byte)((ulong)v >> 16));
        buffer.Add((byte)((ulong)v >> 24));
        buffer.Add((byte)((ulong)v >> 32));
        buffer.Add((byte)((ulong)v >> 40));
        buffer.Add((byte)((ulong)v >> 48));
        buffer.Add((byte)((ulong)v >> 56));
    }

    internal static void AppendF64Le(List<byte> buffer, double v) =>
        AppendU64Le(buffer, BitConverter.DoubleToInt64Bits(v));

    internal static class Unsigned
    {
        internal static int Compare(long a, long b) =>
            unchecked((ulong)a).CompareTo(unchecked((ulong)b));
    }
}
