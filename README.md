# palworld-mods

An Nx monorepo containing Palworld mods, their reproducible tooling, release
packages, research notes, and Codex automation.

## Projects

| Nx project | Type | Status |
| --- | --- | --- |
| `distinct-base-icons` | Paks | Development |
| `deep-salvage` | Lua (server) | Development |
| `scatterspam-capture` | Lua | 1.0.0 |
| `visible-fishing-salvage-spots` | Paks | 1.0.0 |
| `init-palworld-mod` | Codex skill | Reusable tooling |

## Getting started

Requirements: Node.js 20.19+ and, for asset-tool builds, .NET 8.

```powershell
npm install
npm run validate
npm run build
```

Explore project relationships with `npm run graph`. Run one target with:

```powershell
npx nx run scatterspam-capture:validate
npx nx run distinct-base-icons:build
```

Each mod's loader-ready payload lives in
`packages/<PackageName>/package/<PackageName>`. Release media and archives are
kept beside the relevant mod when available.

Machine-specific Palworld and tool locations are intentionally excluded.
Create ignored `mod-project.local.json` files when local overrides are needed.

## GitHub

The repository is ready to initialize and push:

```powershell
git init -b main
git add .
git commit -m "chore: initialize Palworld mods monorepo"
git remote add origin https://github.com/<owner>/palworld-mods.git
git push -u origin main
```

No CI/CD pipeline is configured yet.
