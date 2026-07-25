using UAssetAPI;
using UAssetAPI.Unversioned;

if (args.Length != 3)
{
    Console.Error.WriteLine(
        "Usage: ScatterspamCapture.AssetTool <input.json> <output.uasset> <mappings.usmap>");
    return 2;
}

var input = Path.GetFullPath(args[0]);
var output = Path.GetFullPath(args[1]);
var mappingsPath = Path.GetFullPath(args[2]);

if (!File.Exists(input) || !File.Exists(mappingsPath))
{
    Console.Error.WriteLine("The JSON input or mappings file does not exist.");
    return 3;
}

var asset = UAsset.DeserializeJson(File.ReadAllText(input));
asset.Mappings = new Usmap(mappingsPath);
Directory.CreateDirectory(Path.GetDirectoryName(output)!);
asset.Write(output);

Console.WriteLine($"Wrote {output}");
return 0;
