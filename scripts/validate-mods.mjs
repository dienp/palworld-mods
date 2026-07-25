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
if (!existsSync(join(payloadRoot, info.Thumbnail))) {
  throw new Error(`${packageName}: thumbnail '${info.Thumbnail}' is missing`);
}

const expectedType = modProject.ModType === 'Lua' ? 'Lua' : 'Paks';
if (!info.InstallRule.some((rule) => rule.Type === expectedType)) {
  throw new Error(`${packageName}: Info.json has no ${expectedType} install rule`);
}

if (expectedType === 'Lua') {
  const source = readFileSync(join(payloadRoot, 'Scripts', 'main.lua'), 'utf8');
  for (const flag of ['debug_enabled', 'debug_notifications', 'debug_console']) {
    if (!source.includes(flag)) {
      console.warn(`${packageName}: consider retaining '${flag}' diagnostics`);
    }
  }
}

console.log(`Validated ${packageName} ${info.Version} (${expectedType})`);
