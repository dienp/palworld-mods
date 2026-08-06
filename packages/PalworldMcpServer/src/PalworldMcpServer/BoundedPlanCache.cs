namespace PalworldMcpServer;

internal sealed record PlanCacheStatistics(
    int Entries,
    int Capacity,
    long Hits,
    long Misses,
    long Evictions,
    long Invalidations,
    string? LastInvalidationReason,
    DateTime? LastInvalidatedAtUtc
);

internal sealed class BoundedPlanCache<TKey, TValue>(int capacity)
    where TKey : notnull
{
    private sealed record CacheEntry(TKey Key, TValue Value);

    private readonly object sync = new();
    private readonly Dictionary<TKey, LinkedListNode<CacheEntry>> entries = [];
    private readonly LinkedList<CacheEntry> recency = [];
    private long hits;
    private long misses;
    private long evictions;
    private long invalidations;
    private string? lastInvalidationReason;
    private DateTime? lastInvalidatedAtUtc;

    public bool TryGet(TKey key, out TValue? value)
    {
        lock (sync)
        {
            if (!entries.TryGetValue(key, out var node))
            {
                misses++;
                value = default;
                return false;
            }

            recency.Remove(node);
            recency.AddFirst(node);
            hits++;
            value = node.Value.Value;
            return true;
        }
    }

    public void Set(TKey key, TValue value)
    {
        lock (sync)
        {
            if (entries.TryGetValue(key, out var existing))
            {
                existing.Value = new CacheEntry(key, value);
                recency.Remove(existing);
                recency.AddFirst(existing);
                return;
            }

            var node = recency.AddFirst(new CacheEntry(key, value));
            entries.Add(key, node);

            if (entries.Count <= capacity)
            {
                return;
            }

            var oldest = recency.Last!;
            recency.RemoveLast();
            entries.Remove(oldest.Value.Key);
            evictions++;
        }
    }

    public void Invalidate(string reason)
    {
        lock (sync)
        {
            entries.Clear();
            recency.Clear();
            invalidations++;
            lastInvalidationReason = reason;
            lastInvalidatedAtUtc = DateTime.UtcNow;
        }
    }

    public PlanCacheStatistics Statistics()
    {
        lock (sync)
        {
            return new(
                Entries: entries.Count,
                Capacity: capacity,
                Hits: hits,
                Misses: misses,
                Evictions: evictions,
                Invalidations: invalidations,
                LastInvalidationReason: lastInvalidationReason,
                LastInvalidatedAtUtc: lastInvalidatedAtUtc
            );
        }
    }
}
