namespace Twilic.Tests;
public class SecurityLimitsTest
{
    [Fact]
    public void NestedInputReturnsAnError()
    {
        byte[] bytes = Enumerable.Repeat((byte)0xa1, 70).Append((byte)0xc0).ToArray();
        Assert.ThrowsAny<Exception>(() => Twilic.Decode(bytes));
        Twilic.Decode(new byte[] { 0xa0 });
    }
    [Fact]
    public void OversizedLengthReturnsAnError()
    {
        Assert.ThrowsAny<Exception>(() => Twilic.Decode(new byte[] { 0xd3, 255, 255, 255, 255 }));
    }
}
