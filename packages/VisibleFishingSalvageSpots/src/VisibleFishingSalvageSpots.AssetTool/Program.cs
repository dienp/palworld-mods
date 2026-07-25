using System.Text.Json.Nodes;
using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

if (args.Length < 4)
{
    Console.Error.WriteLine(
        "Usage: VisibleFishingSalvageSpots.AssetTool <inspect|material|clone-niagara|patch-actor> <input.uasset> <output> <mappings.usmap>");
    return 2;
}

var mode = args[0];
var input = Path.GetFullPath(args[1]);
var output = Path.GetFullPath(args[2]);
var mappingsPath = Path.GetFullPath(args[3]);

if (!File.Exists(input) || !File.Exists(mappingsPath))
{
    Console.Error.WriteLine("The input asset or mappings file does not exist.");
    return 3;
}

var mappings = new Usmap(mappingsPath);
var asset = new UAsset(input, EngineVersion.VER_UE5_1, mappings);
var json = JsonNode.Parse(asset.SerializeJson())!;

if (mode == "inspect")
{
    Directory.CreateDirectory(Path.GetDirectoryName(output)!);
    File.WriteAllText(output, json.ToJsonString());
    Console.WriteLine($"Wrote {output}.");
    return 0;
}
else if (mode == "material")
{
    var data = json["Exports"]?[0]?["Data"] as JsonArray;
    var scalars = data?
        .OfType<JsonObject>()
        .SingleOrDefault(property => property["Name"]?.GetValue<string>() == "ScalarParameterValues")?["Value"]
        as JsonArray;

    if (scalars is null || scalars.Count == 0)
    {
        Console.Error.WriteLine("No scalar-parameter template was found; refusing to write.");
        return 4;
    }

    var template = scalars[0]!.DeepClone() as JsonObject;
    if (template is null)
    {
        Console.Error.WriteLine("The scalar-parameter template is invalid; refusing to write.");
        return 5;
    }

    scalars.Clear();
    AddScalar(scalars, template, "Base Color Intensity", 2.0);
    AddScalar(scalars, template, "Base Emissive Intensity", 8.0);

    if (json["NameMap"] is JsonArray names)
    {
        AddName(names, "Base Color Intensity");
        AddName(names, "Base Emissive Intensity");
    }
}
else if (mode == "clone-niagara")
{
    var renamed = ReplaceStrings(
        json,
        "NS_RareKingFishGlow",
        "NS_SalvageSpotGlow_Red");
    var materialPaths = ReplaceStrings(
        json,
        "/Game/Pal/Effect/Material_Instances/Particle_basic_color/MI_Ray",
        "/Game/Pal/Effect/Material_Instances/Particle_basic_color/MI_SalvageRay_Red");
    var materialNames = ReplaceStrings(json, "MI_Ray", "MI_SalvageRay_Red");
    if (renamed == 0 || materialPaths == 0 || materialNames == 0)
    {
        Console.Error.WriteLine(
            $"Expected Niagara and ray-material identifiers; Niagara {renamed}, paths {materialPaths}, names {materialNames}.");
        return 6;
    }
    Console.WriteLine(
        $"Renamed {renamed} Niagara identifiers and repointed {materialPaths + materialNames} ray-material identifiers.");
}
else if (mode == "clone-ray")
{
    var renamed = ReplaceStrings(json, "MI_Ray", "MI_SalvageRay_Red");
    var recolored = RecolorAllLinearColorsRed(json);
    if (renamed == 0 || recolored == 0)
    {
        Console.Error.WriteLine(
            $"Expected ray identifiers and linear colors; renamed {renamed}, recolored {recolored}.");
        return 9;
    }
    Console.WriteLine($"Renamed {renamed} ray identifiers and recolored {recolored} linear colors.");
}
else if (mode == "patch-actor")
{
    var paths = ReplaceStrings(
        json,
        "/Game/Pal/Effect/Common/Glow/NS_SingleStar",
        "/Game/Pal/Effect/Common/Glow/NS_ItemPickupTower_Glow");
    var names = ReplaceStrings(json, "NS_SingleStar", "NS_ItemPickupTower_Glow");
    if (paths == 0 || names == 0)
    {
        Console.Error.WriteLine(
            $"Expected the salvage actor's NS_SingleStar reference; paths {paths}, names {names}.");
        return 7;
    }

    if (args.Length < 5 || !File.Exists(args[4]))
    {
        Console.Error.WriteLine("patch-actor requires the original pickup-tower system as argument 5.");
        return 10;
    }

    var effectAsset = new UAsset(
        Path.GetFullPath(args[4]),
        EngineVersion.VER_UE5_1,
        mappings);
    var effectJson = JsonNode.Parse(effectAsset.SerializeJson())!;
    var exposedParameters = FindProperty(effectJson, "ExposedParameters") as JsonObject;
    if (exposedParameters is null)
    {
        Console.Error.WriteLine("The pickup-tower system has no exposed-parameter store.");
        return 11;
    }

    var overrideTemplate = exposedParameters.DeepClone() as JsonObject
        ?? throw new InvalidOperationException("Unable to clone exposed parameters.");
    overrideTemplate["Name"] = "OverrideParameters";
    SetPickupTowerParameters(overrideTemplate, 0.25f);

    var replacedStores = ReplaceNonEmptyOverrideStores(json, overrideTemplate);
    if (replacedStores == 0)
    {
        Console.Error.WriteLine("No populated Niagara override store was found in the salvage actor.");
        return 12;
    }

    if (json["NameMap"] is JsonArray actorNames)
    {
        AddName(actorNames, "User.BaseColor");
        AddName(actorNames, "User.LightColor");
        AddName(actorNames, "User.Rate");
        AddName(actorNames, "LinearColor");
        AddName(actorNames, "NS_ItemPickupTower_Glow");
        AddName(actorNames, "/Game/Pal/Effect/Common/Glow/NS_ItemPickupTower_Glow");
    }

    Console.WriteLine(
        $"Repointed {paths} system paths and {names} Niagara identifiers; replaced {replacedStores} parameter store(s) at scale 0.25.");
}
else
{
    Console.Error.WriteLine($"Unknown mode: {mode}");
    return 8;
}

Directory.CreateDirectory(Path.GetDirectoryName(output)!);
var patched = UAsset.DeserializeJson(json.ToJsonString());
patched.Mappings = mappings;
patched.Write(output);
Console.WriteLine($"Wrote {output}.");
return 0;

static void AddScalar(JsonArray scalars, JsonObject template, string name, double value)
{
    var entry = template.DeepClone() as JsonObject
        ?? throw new InvalidOperationException("Unable to clone scalar parameter.");
    var values = entry["Value"] as JsonArray
        ?? throw new InvalidOperationException("Scalar parameter has no value array.");
    var info = values
        .OfType<JsonObject>()
        .Single(item => item["Name"]?.GetValue<string>() == "ParameterInfo");
    var infoValues = info["Value"] as JsonArray
        ?? throw new InvalidOperationException("Parameter info has no value array.");
    var nameProperty = infoValues
        .OfType<JsonObject>()
        .Single(item => item["Name"]?.GetValue<string>() == "Name");
    var valueProperty = values
        .OfType<JsonObject>()
        .Single(item => item["Name"]?.GetValue<string>() == "ParameterValue");

    nameProperty["Value"] = name;
    valueProperty["Value"] = value;
    valueProperty["IsZero"] = false;
    scalars.Add(entry);
}

static void AddName(JsonArray names, string name)
{
    if (!names.Any(item => item?.GetValue<string>() == name))
    {
        names.Add(name);
    }
}

static int ReplaceStrings(JsonNode node, string source, string target)
{
    var changed = 0;
    if (node is JsonObject obj)
    {
        foreach (var pair in obj.ToArray())
        {
            if (pair.Value is JsonValue value &&
                value.TryGetValue<string>(out var text) &&
                text.Contains(source, StringComparison.Ordinal))
            {
                obj[pair.Key] = text.Replace(source, target, StringComparison.Ordinal);
                changed++;
            }
            else if (pair.Value is not null)
            {
                changed += ReplaceStrings(pair.Value, source, target);
            }
        }
    }
    else if (node is JsonArray array)
    {
        for (var index = 0; index < array.Count; index++)
        {
            if (array[index] is JsonValue value &&
                value.TryGetValue<string>(out var text) &&
                text.Contains(source, StringComparison.Ordinal))
            {
                array[index] = text.Replace(source, target, StringComparison.Ordinal);
                changed++;
            }
            else if (array[index] is not null)
            {
                changed += ReplaceStrings(array[index]!, source, target);
            }
        }
    }
    return changed;
}

static JsonNode? FindProperty(JsonNode node, string propertyName)
{
    if (node is JsonObject obj)
    {
        if (obj["Name"]?.GetValue<string>() == propertyName)
        {
            return obj;
        }

        foreach (var child in obj.Select(pair => pair.Value).Where(value => value is not null))
        {
            var found = FindProperty(child!, propertyName);
            if (found is not null)
            {
                return found;
            }
        }
    }
    else if (node is JsonArray array)
    {
        foreach (var child in array.Where(value => value is not null))
        {
            var found = FindProperty(child!, propertyName);
            if (found is not null)
            {
                return found;
            }
        }
    }

    return null;
}

static int ReplaceNonEmptyOverrideStores(JsonNode node, JsonObject template)
{
    var replaced = 0;
    if (node is JsonArray array)
    {
        for (var index = 0; index < array.Count; index++)
        {
            if (array[index] is JsonObject candidate &&
                candidate["Name"]?.GetValue<string>() == "OverrideParameters" &&
                candidate["Value"] is JsonArray values &&
                values.Count > 0)
            {
                array[index] = template.DeepClone();
                replaced++;
            }
            else if (array[index] is not null)
            {
                replaced += ReplaceNonEmptyOverrideStores(array[index]!, template);
            }
        }
    }
    else if (node is JsonObject obj)
    {
        foreach (var child in obj.Select(pair => pair.Value).Where(value => value is not null))
        {
            replaced += ReplaceNonEmptyOverrideStores(child!, template);
        }
    }
    return replaced;
}

static void SetPickupTowerParameters(JsonObject store, float scale)
{
    var parameterData = FindProperty(store, "ParameterData")?["Value"] as JsonArray
        ?? throw new InvalidOperationException("The parameter store has no byte data.");
    var bytes = new List<byte>();
    foreach (var value in new[]
    {
        1.0f, 0.0f, 0.04f, 1.0f,
        80.0f, 0.0f, 3.2f, 1.0f,
        1.0f, scale
    })
    {
        bytes.AddRange(BitConverter.GetBytes(value));
    }

    if (parameterData.Count != bytes.Count)
    {
        throw new InvalidOperationException(
            $"Expected {bytes.Count} parameter bytes but found {parameterData.Count}.");
    }

    for (var index = 0; index < bytes.Count; index++)
    {
        parameterData[index]!["Value"] = bytes[index];
    }
}

static int RecolorPurpleLinearColors(JsonNode node)
{
    var changed = 0;
    if (node is JsonObject obj)
    {
        var type = obj["$type"]?.GetValue<string>();
        if (type?.Contains("LinearColor", StringComparison.Ordinal) == true &&
            TryNumber(obj["R"], out var red) &&
            TryNumber(obj["G"], out var green) &&
            TryNumber(obj["B"], out var blue) &&
            blue > green * 1.35 &&
            red > green * 1.20 &&
            blue > 0.05)
        {
            var peak = Math.Max(red, blue);
            obj["R"] = peak;
            obj["G"] = peak * 0.01;
            obj["B"] = peak * 0.04;
            changed++;
        }

        foreach (var child in obj.Select(pair => pair.Value).Where(value => value is not null))
        {
            changed += RecolorPurpleLinearColors(child!);
        }
    }
    else if (node is JsonArray array)
    {
        foreach (var child in array.Where(value => value is not null))
        {
            changed += RecolorPurpleLinearColors(child!);
        }
    }
    return changed;
}

static int RecolorAllLinearColorsRed(JsonNode node)
{
    var changed = 0;
    if (node is JsonObject obj)
    {
        var type = obj["$type"]?.GetValue<string>();
        if (type?.Contains("FLinearColor", StringComparison.Ordinal) == true &&
            TryNumber(obj["R"], out var red) &&
            TryNumber(obj["G"], out var green) &&
            TryNumber(obj["B"], out var blue))
        {
            var peak = Math.Max(red, Math.Max(green, blue));
            obj["R"] = peak;
            obj["G"] = peak * 0.01;
            obj["B"] = peak * 0.04;
            changed++;
        }
        foreach (var child in obj.Select(pair => pair.Value).Where(value => value is not null))
        {
            changed += RecolorAllLinearColorsRed(child!);
        }
    }
    else if (node is JsonArray array)
    {
        foreach (var child in array.Where(value => value is not null))
        {
            changed += RecolorAllLinearColorsRed(child!);
        }
    }
    return changed;
}

static bool TryNumber(JsonNode? node, out double value)
{
    value = 0;
    return node is JsonValue json &&
        (json.TryGetValue(out value) ||
         (json.TryGetValue<string>(out var text) &&
          double.TryParse(text, System.Globalization.NumberStyles.Float,
              System.Globalization.CultureInfo.InvariantCulture, out value)));
}
