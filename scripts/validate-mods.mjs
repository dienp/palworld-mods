import { existsSync, readFileSync } from 'node:fs';
import { basename, join, resolve } from 'node:path';

const projectRoot = resolve(process.argv[2] ?? '.');
const modProjectPath = join(projectRoot, 'mod-project.json');

if (!existsSync(modProjectPath)) {
  throw new Error(`Missing ${modProjectPath}`);
}

const readJson = (path) =>
  JSON.parse(readFileSync(path, 'utf8').replace(/^\uFEFF/, ''));

const modProject = readJson(modProjectPath);
const packageName = modProject.PackageName;
const payloadRoot = join(projectRoot, 'package', packageName);
const infoPath = join(payloadRoot, 'Info.json');

for (const [key, value] of Object.entries({
  ModName: modProject.ModName,
  PackageName: packageName,
  ModType: modProject.ModType
})) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${basename(projectRoot)}: ${key} must be a non-empty string`);
  }
}

if (!/^[A-Za-z0-9]+$/.test(packageName)) {
  throw new Error(`${packageName}: PackageName must be alphanumeric`);
}
if (!existsSync(infoPath)) {
  throw new Error(`${packageName}: missing package/${packageName}/Info.json`);
}

const info = readJson(infoPath);
if (info.PackageName !== packageName) {
  throw new Error(`${packageName}: Info.json PackageName does not match mod-project.json`);
}
if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(info.Version)) {
  throw new Error(`${packageName}: invalid semantic Version '${info.Version}'`);
}
if (!Array.isArray(info.InstallRule) || info.InstallRule.length === 0) {
  throw new Error(`${packageName}: Info.json requires at least one InstallRule`);
}
const thumbnailPath = join(payloadRoot, info.Thumbnail);
if (!existsSync(thumbnailPath)) {
  throw new Error(`${packageName}: thumbnail '${info.Thumbnail}' is missing`);
}
const thumbnail = readFileSync(thumbnailPath);
if (thumbnail.length < 24) {
  throw new Error(`${packageName}: thumbnail must be a valid PNG of at least 24 bytes`);
}
const pngSignature = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
if (!thumbnail.subarray(0, 8).equals(pngSignature)) {
  throw new Error(`${packageName}: thumbnail must be a PNG`);
}
if (thumbnail.length >= 1024 * 1024) {
  throw new Error(
    `${packageName}: thumbnail is ${thumbnail.length} bytes; ` +
    'Steam Workshop previews must be strictly below 1 MiB'
  );
}
const thumbnailWidth = thumbnail.readUInt32BE(16);
const thumbnailHeight = thumbnail.readUInt32BE(20);
if (thumbnailWidth !== thumbnailHeight) {
  console.warn(
    `${packageName}: prefer a square Workshop thumbnail; got ` +
    `${thumbnailWidth}x${thumbnailHeight}`
  );
}

const expectedType = modProject.ModType === 'Lua' ? 'Lua' : 'Paks';
if (!info.InstallRule.some((rule) => rule.Type === expectedType)) {
  throw new Error(`${packageName}: Info.json has no ${expectedType} install rule`);
}

if (expectedType === 'Lua') {
  const luaEntryPoint = join(payloadRoot, 'Scripts', 'main.lua');
  if (!existsSync(luaEntryPoint)) {
    throw new Error(
      `${packageName}: Lua entry point must be package/${packageName}/Scripts/main.lua`
    );
  }

  const luaRules = info.InstallRule.filter((rule) => rule.Type === 'Lua');
  if (!luaRules.some((rule) =>
    Array.isArray(rule.Targets) && rule.Targets.includes('.')
  )) {
    throw new Error(
      `${packageName}: Lua InstallRule must target '.' to preserve Scripts/main.lua`
    );
  }

  const source = readFileSync(luaEntryPoint, 'utf8');
  for (const flag of ['debug_enabled', 'debug_notifications', 'debug_console']) {
    if (!source.includes(flag)) {
      console.warn(`${packageName}: consider retaining '${flag}' diagnostics`);
    }
  }

  const luaLines = source.split('\n');

  // A later `name = function(...)` silently overwrites an earlier
  // `local function name(...)` in the same chunk. That shadowing kept four
  // dead Raid Manager entry points alive in this file, so reject any
  // top-level name that is defined more than once.
  const definitions = new Map();
  luaLines.forEach((line, index) => {
    const match =
      line.match(/^(?:local\s+)?function\s+([A-Za-z_]\w*)\s*\(/) ??
      line.match(/^(?:local\s+)?([A-Za-z_]\w*)\s*=\s*function\s*\(/);
    if (!match) {
      return;
    }
    const [, name] = match;
    if (!definitions.has(name)) {
      definitions.set(name, []);
    }
    definitions.get(name).push(index + 1);
  });

  const shadowed = [...definitions]
    .filter(([, at]) => at.length > 1)
    .map(([name, at]) => `${name} (lines ${at.join(', ')})`);
  if (shadowed.length > 0) {
    throw new Error(
      `${packageName}: duplicate top-level function definitions shadow ` +
      `earlier ones: ${shadowed.join('; ')}`
    );
  }

  // Unreferenced top-level locals cannot be reached from a command, a hook, or
  // the UE4SS console, so they are dead weight rather than diagnostics. This
  // is a warning by default so an unrelated mod's backlog cannot block a
  // release, and an error for packages that have already been cleaned.
  const unreferenced = [...definitions]
    .filter(([name, at]) => {
      if (!/^local\s/.test(luaLines[at[0] - 1])) {
        return false;
      }
      const uses = luaLines.filter(
        (line, index) =>
          index !== at[0] - 1 &&
          new RegExp(`\\b${name}\\b`).test(line)
      );
      return uses.length === 0;
    })
    .map(([name, at]) => `${name} (line ${at[0]})`);
  if (unreferenced.length > 0) {
    const message =
      `${packageName}: unreferenced local functions: ${unreferenced.join('; ')}`;
    if (modProject.RejectUnreferencedLuaFunctions === true) {
      throw new Error(message);
    }
    console.warn(message);
  }
}

console.log(`Validated ${packageName} ${info.Version} (${expectedType})`);
