using System.Text;

namespace PalworldMcpServer;

internal static class LiveBridgeProtocol
{
    public const string Header = "PALWORLD_COMPANION_BRIDGE/1";

    public static string Encode(IEnumerable<KeyValuePair<string, string?>> fields)
    {
        var output = new StringBuilder(Header).AppendLine();
        foreach (var field in fields.OrderBy(field => field.Key, StringComparer.Ordinal))
        {
            ValidateKey(field.Key);
            output
                .Append(field.Key)
                .Append('=')
                .Append(Uri.EscapeDataString(field.Value ?? string.Empty))
                .AppendLine();
        }
        return output.ToString();
    }

    public static IReadOnlyDictionary<string, string> Decode(string payload)
    {
        using var reader = new StringReader(payload);
        if (!string.Equals(reader.ReadLine()?.Trim(), Header, StringComparison.Ordinal))
        {
            throw new InvalidDataException("Unsupported live-bridge protocol header.");
        }

        var fields = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string? line;
        while ((line = reader.ReadLine()) != null)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            var separator = line.IndexOf('=');
            if (separator <= 0)
            {
                throw new InvalidDataException("Malformed live-bridge field.");
            }

            var key = line[..separator];
            ValidateKey(key);
            fields[key] = Uri.UnescapeDataString(line[(separator + 1)..]);
        }
        return fields;
    }

    private static void ValidateKey(string key)
    {
        if (
            string.IsNullOrWhiteSpace(key) ||
            key.Any(character =>
                !(character is >= 'a' and <= 'z') &&
                !(character is >= '0' and <= '9') &&
                character != '_'
            )
        )
        {
            throw new InvalidDataException($"Invalid live-bridge field name '{key}'.");
        }
    }
}
