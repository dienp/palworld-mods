namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class LiveGuidTests
{
    [TestMethod]
    public void ConvertsSavedUuidToUnrealGuidWords()
    {
        var result = PalworldService.ToLiveGuid(
            "c36f68c1-49d7-9305-d0b9-19906fb47761"
        );

        Assert.AreEqual(
            "C36F68C1-49D79305-D0B91990-6FB47761",
            result
        );
    }

    [TestMethod]
    public void PreservesExistingLiveGuidShape()
    {
        var result = PalworldService.ToLiveGuid(
            "C36F68C1-49D79305-D0B91990-6FB47761"
        );

        Assert.AreEqual(
            "C36F68C1-49D79305-D0B91990-6FB47761",
            result
        );
    }
}
