using Microsoft.Data.Sqlite;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace PalworldMcpServer;

internal sealed record PersistentPlanCacheStatistics(
    bool Enabled,
    int Entries,
    int Capacity,
    long Hits,
    long Misses,
    long Evictions,
    long Invalidations,
    string? InitializationError
);

internal sealed class PersistentPlanCache<TKey, TValue> : IDisposable
    where TKey : notnull
{
    private const int SchemaVersion = 1;
    private readonly object sync = new();
    private readonly int capacity;
    private readonly SqliteConnection? connection;
    private long hits;
    private long misses;
    private long evictions;
    private long invalidations;
    private string? initializationError;

    public PersistentPlanCache(bool enabled, string? configuredPath, int requestedCapacity)
    {
        capacity = Math.Clamp(requestedCapacity, 16, 4096);
        if (!enabled)
        {
            return;
        }

        SqliteConnection? candidate = null;
        try
        {
            var cachePath = ResolvePath(configuredPath);
            Directory.CreateDirectory(Path.GetDirectoryName(cachePath)!);
            candidate = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = cachePath,
                Mode = SqliteOpenMode.ReadWriteCreate,
                Cache = SqliteCacheMode.Shared,
                Pooling = false
            }.ToString());
            candidate.Open();

            using var command = candidate.CreateCommand();
            command.CommandText = $"""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;
                PRAGMA temp_store=MEMORY;
                CREATE TABLE IF NOT EXISTS plan_cache (
                    cache_key TEXT PRIMARY KEY,
                    response_json TEXT NOT NULL,
                    created_utc TEXT NOT NULL,
                    accessed_utc TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS ix_plan_cache_accessed
                    ON plan_cache(accessed_utc);
                PRAGMA user_version={SchemaVersion};
                """;
            command.ExecuteNonQuery();
            connection = candidate;
        }
        catch (Exception error)
        {
            candidate?.Dispose();
            initializationError = error.Message;
        }
    }

    public bool TryGet(TKey key, out TValue? value)
    {
        lock (sync)
        {
            if (connection == null)
            {
                misses++;
                value = default;
                return false;
            }

            var cacheKey = StableKey(key);
            using var select = connection.CreateCommand();
            select.CommandText = "SELECT response_json FROM plan_cache WHERE cache_key = $key;";
            select.Parameters.AddWithValue("$key", cacheKey);
            var json = select.ExecuteScalar() as string;
            if (json == null)
            {
                misses++;
                value = default;
                return false;
            }

            try
            {
                value = JsonSerializer.Deserialize<TValue>(json);
            }
            catch (JsonException)
            {
                DeleteNoLock(cacheKey);
                misses++;
                value = default;
                return false;
            }
            if (value == null)
            {
                DeleteNoLock(cacheKey);
                misses++;
                return false;
            }

            using var touch = connection.CreateCommand();
            touch.CommandText = "UPDATE plan_cache SET accessed_utc = $now WHERE cache_key = $key;";
            touch.Parameters.AddWithValue("$now", DateTime.UtcNow.ToString("O"));
            touch.Parameters.AddWithValue("$key", cacheKey);
            touch.ExecuteNonQuery();
            hits++;
            return true;
        }
    }

    public void Set(TKey key, TValue value)
    {
        lock (sync)
        {
            if (connection == null)
            {
                return;
            }

            var now = DateTime.UtcNow.ToString("O");
            using var upsert = connection.CreateCommand();
            upsert.CommandText = """
                INSERT INTO plan_cache(cache_key, response_json, created_utc, accessed_utc)
                VALUES($key, $json, $now, $now)
                ON CONFLICT(cache_key) DO UPDATE SET
                    response_json = excluded.response_json,
                    accessed_utc = excluded.accessed_utc;
                """;
            upsert.Parameters.AddWithValue("$key", StableKey(key));
            upsert.Parameters.AddWithValue("$json", JsonSerializer.Serialize(value));
            upsert.Parameters.AddWithValue("$now", now);
            upsert.ExecuteNonQuery();

            var excess = CountNoLock() - capacity;
            if (excess <= 0)
            {
                return;
            }

            using var evict = connection.CreateCommand();
            evict.CommandText = """
                DELETE FROM plan_cache
                WHERE cache_key IN (
                    SELECT cache_key FROM plan_cache
                    ORDER BY accessed_utc ASC
                    LIMIT $excess
                );
                """;
            evict.Parameters.AddWithValue("$excess", excess);
            evictions += evict.ExecuteNonQuery();
        }
    }

    public void Invalidate()
    {
        lock (sync)
        {
            if (connection != null)
            {
                using var command = connection.CreateCommand();
                command.CommandText = "DELETE FROM plan_cache;";
                command.ExecuteNonQuery();
            }
            invalidations++;
        }
    }

    public PersistentPlanCacheStatistics Statistics()
    {
        lock (sync)
        {
            return new(
                Enabled: connection != null,
                Entries: CountNoLock(),
                Capacity: capacity,
                Hits: hits,
                Misses: misses,
                Evictions: evictions,
                Invalidations: invalidations,
                InitializationError: initializationError
            );
        }
    }

    public void Dispose()
    {
        lock (sync)
        {
            connection?.Dispose();
        }
    }

    private int CountNoLock()
    {
        if (connection == null)
        {
            return 0;
        }

        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM plan_cache;";
        return Convert.ToInt32(command.ExecuteScalar());
    }

    private void DeleteNoLock(string cacheKey)
    {
        using var command = connection!.CreateCommand();
        command.CommandText = "DELETE FROM plan_cache WHERE cache_key = $key;";
        command.Parameters.AddWithValue("$key", cacheKey);
        command.ExecuteNonQuery();
    }

    private static string StableKey(TKey key)
    {
        var payload = $"{SchemaVersion}|{JsonSerializer.Serialize(key)}";
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(payload)));
    }

    private static string ResolvePath(string? configuredPath)
    {
        if (!string.IsNullOrWhiteSpace(configuredPath))
        {
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(configuredPath));
        }

        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "PalworldMcpServer",
            $"plan-cache-v{SchemaVersion}.sqlite3"
        );
    }
}
