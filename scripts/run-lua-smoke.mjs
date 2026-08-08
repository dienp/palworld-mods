import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// Runs a mod's offline Lua smoke test. A standalone Lua interpreter is not part
// of the Windows modding toolchain, so a missing interpreter is a skip rather
// than a failure; the static validator still runs everywhere.
const projectRoot = resolve(process.argv[2] ?? '.');
const script = join(projectRoot, 'scripts', 'smoke.lua');
const entryPoint = join(
  projectRoot,
  'package',
  'PalworldCompanionBridge',
  'Scripts',
  'main.lua'
);

const interpreters = ['lua5.4', 'lua54', 'lua', 'luajit'];
const interpreter = interpreters.find(
  (candidate) => spawnSync(candidate, ['-v'], { stdio: 'ignore' }).status === 0
);

if (interpreter === undefined) {
  console.warn(
    'No Lua interpreter found; skipping the offline smoke test. ' +
    `Install one of: ${interpreters.join(', ')}.`
  );
  process.exit(0);
}

const mailbox = mkdtempSync(join(tmpdir(), 'pcb-smoke-'));
mkdirSync(join(mailbox, 'PalworldCompanionBridge'), { recursive: true });
try {
  const result = spawnSync(interpreter, [script, mailbox, entryPoint], {
    stdio: 'inherit'
  });
  process.exit(result.status ?? 1);
} finally {
  rmSync(mailbox, { force: true, recursive: true });
}
