using Twilic;
using Twilic.Core;

namespace Twilic.Tests;

public class TwilicSmokeTest
{
    [Fact]
    public void RoundTripMap()
    {
        var input = global::Twilic.Twilic.NewMap(global::Twilic.Twilic.Entry("id", global::Twilic.Twilic.NewU64(42)));
        var encoded = global::Twilic.Twilic.Encode(input);
        var decoded = global::Twilic.Twilic.Decode(encoded);
        Assert.Equal(ValueKind.Map, decoded.Kind);
        Assert.Equal("id", decoded.Map[0].Key);
        Assert.Equal(42UL, decoded.Map[0].Value.U64);
    }

    [Fact]
    public void RoundTripString()
    {
        var input = global::Twilic.Twilic.NewString("alpha");
        var decoded = global::Twilic.Twilic.Decode(global::Twilic.Twilic.Encode(input));
        Assert.True(global::Twilic.Twilic.Equal(input, decoded));
    }
}
