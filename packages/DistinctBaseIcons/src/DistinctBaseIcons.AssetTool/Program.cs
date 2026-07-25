using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;
using System.Text.Json;
using System.Text.Json.Nodes;

if (args.Length != 3 || (args[0] != "tojson" && args[0] != "patch" && args[0] != "patchwhite" && args[0] != "patchtexture" && args[0] != "patchmaterial"))
{
    Console.Error.WriteLine("Usage: DistinctBaseIcons.AssetTool <tojson|patch|patchwhite|patchtexture|patchmaterial> <input.uasset> <output>");
    return 2;
}

var input = Path.GetFullPath(args[1]);
var output = Path.GetFullPath(args[2]);
var repositoryRoot = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
var mappingsPath = Path.Combine(repositoryRoot, "tools", "Mappings.usmap");

if (!File.Exists(input))
{
    Console.Error.WriteLine($"Asset not found: {input}");
    return 3;
}

if (!File.Exists(mappingsPath))
{
    Console.Error.WriteLine($"Mappings not found: {mappingsPath}");
    return 4;
}

var mappings = new Usmap(mappingsPath);
var asset = new UAsset(input, EngineVersion.VER_UE5_1, mappings);
Directory.CreateDirectory(Path.GetDirectoryName(output)!);
var json = JsonNode.Parse(asset.SerializeJson())!;

if (args[0] == "patch" || args[0] == "patchwhite")
{
    var target = args[0] == "patchwhite"
        ? new[] { 1.0, 1.0, 1.0 }
        : new[] { 1.0, 0.3467040563550296, 0.011612245179743885 };
    var changed = PatchEnabledCampColor(json, target);
    if (changed != 9)
    {
        Console.Error.WriteLine($"Expected to change 9 RGB values, changed {changed}; refusing to write.");
        return 5;
    }

    var patchedAsset = UAsset.DeserializeJson(json.ToJsonString());
    patchedAsset.Mappings = mappings;
    patchedAsset.Write(output);
}
else if (args[0] == "patchtexture")
{
    var changed = PatchCampTexture(json);
    if (changed == 0)
    {
        Console.Error.WriteLine("No BC3 color endpoints were changed; refusing to write.");
        return 6;
    }

    var patchedAsset = UAsset.DeserializeJson(json.ToJsonString());
    patchedAsset.Mappings = mappings;
    patchedAsset.Write(output);
    Console.WriteLine($"Recolored {changed} BC3 color endpoints.");
}
else if (args[0] == "patchmaterial")
{
    var templatePath = Path.Combine(repositoryRoot, "work", "MI_UI_MapMarker_00.json");
    if (!File.Exists(templatePath))
    {
        Console.Error.WriteLine($"Material template JSON not found: {templatePath}");
        return 7;
    }

    var template = JsonNode.Parse(File.ReadAllText(templatePath))!;
    var changed = AddCampMaterialColors(json, template);
    if (changed != 2)
    {
        Console.Error.WriteLine($"Expected two material color overrides, created {changed}; refusing to write.");
        return 8;
    }

    var patchedAsset = UAsset.DeserializeJson(json.ToJsonString());
    patchedAsset.Mappings = mappings;
    patchedAsset.Write(output);
}
else
{
    File.WriteAllText(output, json.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
}

Console.WriteLine($"Wrote {output}");
return 0;

static int PatchEnabledCampColor(JsonNode node, double[] target)
{
    const double epsilon = 0.000001;
    var sources = new[]
    {
        // SetEnable.
        new[] { 0.15000000596046448, 0.905555009841919, 1.0 },
        // SetSameGuild and the Icon widget-template default.
        new[] { 0.149959996342659, 0.9046609997749329, 1.0 }
    };
    var changed = 0;
    foreach (var candidate in Walk(node).OfType<JsonObject>())
    {
        if (candidate["$type"]?.GetValue<string>() is not string type)
        {
            continue;
        }

        if (type.Contains("EX_StructConst", StringComparison.Ordinal) &&
            candidate["Value"] is JsonArray values && values.Count == 4)
        {
            var floats = values.OfType<JsonObject>().ToArray();
            if (floats.Length != 4)
            {
                continue;
            }

            var actual = floats.Take(3).Select(value => value["Value"]!.GetValue<double>()).ToArray();
            if (sources.Any(source =>
                    actual.Zip(source).All(pair => Math.Abs(pair.First - pair.Second) < epsilon)))
            {
                for (var i = 0; i < 3; i++)
                {
                    floats[i]["Value"] = target[i];
                }

                changed += 3;
            }
        }

        // The Icon image also has this teal baked into its widget-template default.
        // It is used before (and sometimes instead of) the SetEnable Blueprint path.
        if (type.Contains("FLinearColor", StringComparison.Ordinal) &&
            TryGetDouble(candidate["R"], out var red) &&
            TryGetDouble(candidate["G"], out var green) &&
            TryGetDouble(candidate["B"], out var blue))
        {
            var actual = new[] { red, green, blue };
            if (sources.Any(source =>
                    actual.Zip(source).All(pair => Math.Abs(pair.First - pair.Second) < epsilon)))
            {
                candidate["R"] = target[0];
                candidate["G"] = target[1];
                candidate["B"] = target[2];
                changed += 3;
            }
        }
    }

    return changed;
}

static bool TryGetDouble(JsonNode? node, out double value)
{
    value = 0;
    return node is JsonValue jsonValue && jsonValue.TryGetValue(out value);
}

static int PatchCampTexture(JsonNode root)
{
    var export = root["Exports"]?[0] as JsonObject;
    var encoded = export?["Extras"]?.GetValue<string>();
    if (encoded is null)
    {
        return 0;
    }

    var bytes = Convert.FromBase64String(encoded);

    // FTexturePlatformData followed by one inline 100x100 PF_DXT5 mip.
    // The two consecutive 10,000-byte fields are the bulk-data element count
    // and byte size; eight bytes of bulk metadata follow before the payload.
    var sizeMarker = FindConsecutiveInt32(bytes, 10_000);
    if (sizeMarker < 0)
    {
        return 0;
    }

    var payloadStart = sizeMarker + 12;
    const int payloadLength = 10_000;
    if (payloadStart + payloadLength > bytes.Length)
    {
        return 0;
    }

    var changed = 0;
    for (var block = payloadStart; block < payloadStart + payloadLength; block += 16)
    {
        // BC3: 8 bytes alpha, then a BC1 color block with two RGB565 endpoints.
        changed += RecolorRgb565(bytes, block + 8) ? 1 : 0;
        changed += RecolorRgb565(bytes, block + 10) ? 1 : 0;
    }

    export!["Extras"] = Convert.ToBase64String(bytes);
    return changed;
}

static int FindConsecutiveInt32(byte[] bytes, int value)
{
    for (var i = 0; i <= bytes.Length - 8; i++)
    {
        if (BitConverter.ToInt32(bytes, i) == value && BitConverter.ToInt32(bytes, i + 4) == value)
        {
            return i;
        }
    }

    return -1;
}

static bool RecolorRgb565(byte[] bytes, int offset)
{
    var source = BitConverter.ToUInt16(bytes, offset);
    var r = ((source >> 11) & 31) * 255.0 / 31.0;
    var g = ((source >> 5) & 63) * 255.0 / 63.0;
    var b = (source & 31) * 255.0 / 31.0;
    var luminance = Math.Clamp((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0, 0.0, 1.0);

    // #FF9F1C, scaled by source luminance to retain the original shading.
    var targetR = (int)Math.Round(255 * luminance);
    var targetG = (int)Math.Round(159 * luminance);
    var targetB = (int)Math.Round(28 * luminance);
    var target = (ushort)(((targetR * 31 / 255) << 11) |
                          ((targetG * 63 / 255) << 5) |
                          (targetB * 31 / 255));

    if (target == source)
    {
        return false;
    }

    bytes[offset] = (byte)(target & 0xFF);
    bytes[offset + 1] = (byte)(target >> 8);
    return true;
}

static int AddCampMaterialColors(JsonNode camp, JsonNode template)
{
    var campData = camp["Exports"]?[0]?["Data"] as JsonArray;
    var templateData = template["Exports"]?[0]?["Data"] as JsonArray;
    if (campData is null || templateData is null)
    {
        return 0;
    }

    var vectorProperty = templateData.OfType<JsonObject>()
        .SingleOrDefault(property => property["Name"]?.GetValue<string>() == "VectorParameterValues")?
        .DeepClone() as JsonObject;
    if (vectorProperty?["Value"] is not JsonArray entries || entries.Count != 2)
    {
        return 0;
    }

    var colors = new Dictionary<string, double[]>
    {
        // Dark burnt-orange border and bright #FF9F1C fill, in linear space.
        ["Color1"] = new[] { 0.18, 0.035, 0.002, 1.0 },
        ["Color2"] = new[] { 1.0, 0.3467040563550296, 0.011612245179743885, 1.0 }
    };

    var changed = 0;
    foreach (var entry in entries.OfType<JsonObject>())
    {
        var parameterName = Walk(entry).OfType<JsonObject>()
            .FirstOrDefault(value =>
                value["$type"]?.GetValue<string>()?.Contains("NamePropertyData", StringComparison.Ordinal) == true &&
                value["Name"]?.GetValue<string>() == "Name")?["Value"]?.GetValue<string>();
        var color = Walk(entry).OfType<JsonObject>()
            .FirstOrDefault(value => value["$type"]?.GetValue<string>()?.Contains("FLinearColor", StringComparison.Ordinal) == true);
        if (parameterName is null || color is null || !colors.TryGetValue(parameterName, out var target))
        {
            continue;
        }

        color["R"] = target[0];
        color["G"] = target[1];
        color["B"] = target[2];
        color["A"] = target[3];
        changed++;
    }

    if (changed != 2)
    {
        return changed;
    }

    var textureIndex = campData.Select((node, index) => (node, index))
        .First(pair => pair.node?["Name"]?.GetValue<string>() == "TextureParameterValues").index;
    campData.Insert(textureIndex, vectorProperty);

    if (camp["NameMap"] is JsonArray nameMap)
    {
        foreach (var name in new[] { "Color1", "Color2" })
        {
            if (!nameMap.Any(value => value?.GetValue<string>() == name))
            {
                nameMap.Add(name);
            }
        }
    }

    return changed;
}

static IEnumerable<JsonNode> Walk(JsonNode node)
{
    yield return node;

    if (node is JsonObject obj)
    {
        foreach (var child in obj.Select(pair => pair.Value).Where(value => value is not null))
        {
            foreach (var descendant in Walk(child!))
            {
                yield return descendant;
            }
        }
    }
    else if (node is JsonArray array)
    {
        foreach (var child in array.Where(value => value is not null))
        {
            foreach (var descendant in Walk(child!))
            {
                yield return descendant;
            }
        }
    }
}
