using Twilic;
using Twilic.Core;

namespace Twilic.Tests;

public class V2WireTest
{
    [Fact]
    public void RoundTripNull()
    {
        var input = Twilic.NewNull();
        Assert.True(Twilic.Equal(input, Twilic.Decode(Twilic.Encode(input))));
    }

    [Fact]
    public void RoundTripBool()
    {
        Assert.True(Twilic.Equal(Twilic.NewBool(true), Twilic.Decode(Twilic.Encode(Twilic.NewBool(true)))));
        Assert.True(Twilic.Equal(Twilic.NewBool(false), Twilic.Decode(Twilic.Encode(Twilic.NewBool(false)))));
    }

    [Fact]
    public void RoundTripI64AndU64()
    {
        var i64 = Twilic.NewI64(-42);
        var u64 = Twilic.NewU64(ulong.MaxValue / 2);
        Assert.True(Twilic.Equal(i64, Twilic.Decode(Twilic.Encode(i64))));
        Assert.True(Twilic.Equal(u64, Twilic.Decode(Twilic.Encode(u64))));
    }

    [Fact]
    public void RoundTripNestedMap()
    {
        var inner = Twilic.NewMap(Twilic.Entry("x", Twilic.NewString("inner")));
        var outer = Twilic.NewMap(
            Twilic.Entry("id", Twilic.NewU64(42)),
            Twilic.Entry("nested", inner));
        Assert.True(Twilic.Equal(outer, Twilic.Decode(Twilic.Encode(outer))));
    }

    [Fact]
    public void RoundTripArray()
    {
        var input = Twilic.NewArray(new[] { Twilic.NewString("a"), Twilic.NewString("b"), Twilic.NewString("c") });
        Assert.True(Twilic.Equal(input, Twilic.Decode(Twilic.Encode(input))));
    }

    [Fact]
    public void EncodeBatchRoundTrip()
    {
        var values = new[]
        {
            Twilic.NewMap(Twilic.Entry("n", Twilic.NewU64(1))),
            Twilic.NewMap(Twilic.Entry("n", Twilic.NewU64(2))),
        };
        var encoded = Twilic.EncodeBatch(values);
        var decoded = Twilic.Decode(encoded);
        Assert.Equal(ValueKind.Array, decoded.Kind);
        Assert.Equal(2, decoded.Arr.Count);
    }

    [Fact]
    public void SessionEncoderDelegatesToWireProfile()
    {
        var enc = new SessionEncoder();
        var value = Twilic.NewString("session");
        var bytes = enc.Encode(value);
        Assert.True(Twilic.Equal(value, Twilic.Decode(bytes)));
    }
}
