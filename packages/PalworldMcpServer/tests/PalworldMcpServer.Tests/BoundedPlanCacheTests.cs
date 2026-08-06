namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class BoundedPlanCacheTests
{
    [TestMethod]
    public void CacheTracksHitsAndMisses()
    {
        var cache = new BoundedPlanCache<string, string>(2);
        cache.Set("sek", "plan");

        Assert.IsTrue(cache.TryGet("sek", out var value));
        Assert.AreEqual("plan", value);
        Assert.IsFalse(cache.TryGet("missing", out _));

        var statistics = cache.Statistics();
        Assert.AreEqual(1, statistics.Hits);
        Assert.AreEqual(1, statistics.Misses);
        Assert.AreEqual(1, statistics.Entries);
    }

    [TestMethod]
    public void CacheEvictsLeastRecentlyUsedEntry()
    {
        var cache = new BoundedPlanCache<string, string>(2);
        cache.Set("first", "1");
        cache.Set("second", "2");
        Assert.IsTrue(cache.TryGet("first", out _));

        cache.Set("third", "3");

        Assert.IsFalse(cache.TryGet("second", out _));
        Assert.IsTrue(cache.TryGet("first", out _));
        Assert.IsTrue(cache.TryGet("third", out _));
        Assert.AreEqual(1, cache.Statistics().Evictions);
    }

    [TestMethod]
    public void InvalidationClearsEntriesAndRecordsReason()
    {
        var cache = new BoundedPlanCache<string, string>(2);
        cache.Set("sek", "plan");

        cache.Invalidate("save_modified");

        var statistics = cache.Statistics();
        Assert.AreEqual(0, statistics.Entries);
        Assert.AreEqual(1, statistics.Invalidations);
        Assert.AreEqual("save_modified", statistics.LastInvalidationReason);
        Assert.IsNotNull(statistics.LastInvalidatedAtUtc);
    }
}
