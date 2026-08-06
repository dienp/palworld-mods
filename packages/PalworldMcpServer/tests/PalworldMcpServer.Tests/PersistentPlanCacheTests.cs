namespace PalworldMcpServer.Tests;

[TestClass]
public sealed class PersistentPlanCacheTests
{
    [TestMethod]
    public void CacheSurvivesProcessEquivalentReopen()
    {
        WithTemporaryCache((path, directory) =>
        {
            using (var first = new PersistentPlanCache<string, string>(true, path, 16))
            {
                first.Set("sek", "worker-plan");
            }

            using var second = new PersistentPlanCache<string, string>(true, path, 16);
            Assert.IsTrue(second.TryGet("sek", out var value));
            Assert.AreEqual("worker-plan", value);
            Assert.AreEqual(1, second.Statistics().Hits);
        });
    }

    [TestMethod]
    public void CacheEvictsLeastRecentlyUsedPersistentEntry()
    {
        WithTemporaryCache((path, directory) =>
        {
            using var cache = new PersistentPlanCache<string, string>(true, path, 16);
            for (var index = 0; index < 16; index++)
            {
                cache.Set($"key-{index}", $"value-{index}");
            }
            Assert.IsTrue(cache.TryGet("key-0", out _));

            cache.Set("key-16", "value-16");

            Assert.IsTrue(cache.TryGet("key-0", out _));
            Assert.IsFalse(cache.TryGet("key-1", out _));
            Assert.AreEqual(1, cache.Statistics().Evictions);
        });
    }

    [TestMethod]
    public void InvalidationClearsPersistentEntries()
    {
        WithTemporaryCache((path, directory) =>
        {
            using var cache = new PersistentPlanCache<string, string>(true, path, 16);
            cache.Set("sek", "worker-plan");

            cache.Invalidate();

            Assert.AreEqual(0, cache.Statistics().Entries);
            Assert.IsFalse(cache.TryGet("sek", out _));
            Assert.AreEqual(1, cache.Statistics().Invalidations);
        });
    }

    private static void WithTemporaryCache(Action<string, string> test)
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"palworld-mcp-cache-test-{Guid.NewGuid():N}"
        );
        Directory.CreateDirectory(directory);
        try
        {
            test(Path.Combine(directory, "plans.sqlite3"), directory);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
