# Windows development toolchain

This repository does not vendor Unreal Engine, Wwise, Palworld Modding Kit
(PMK), Visual Studio, or game files. Install them outside the repository and
keep machine-specific paths in ignored `*.local.json` files.

The PMK prerequisites below follow the
[Palworld Modding Kit prerequisites](https://pwmodding.wiki/docs/developers/palworld-modding-kit/prerequisites)
guide (checked 2026-07-25).

## Repository tooling

Install:

- Node.js 20.19 or newer
- npm
- .NET SDK 8
- Git

Verify from a PowerShell session that does not load user profiles:

```powershell
node --version
npm.cmd --version
dotnet --list-sdks
git --version
```

Then initialize the repository:

```powershell
npm.cmd install
npm.cmd run validate
npm.cmd run build
```

Use `npm.cmd` instead of `npm` when PowerShell execution policy blocks the
`npm.ps1` shim.

## LogicMod and cooked-asset tooling

The Deep Salvage LogicMod bridge requires this pinned toolchain:

| Tool | Required version or selection |
| --- | --- |
| Palworld | Current Steam game installation |
| Unreal Engine | Any 5.1 release, including 5.1 or 5.1.1 |
| Visual Studio | Visual Studio 2022; Community is sufficient |
| MSVC toolset | `MSVC v143 - VS 2022 C++ x64/x86 Build Tools (v14.38-17.8)` |
| .NET runtime | .NET 6 x64 runtime |
| Wwise | 2021.1.11 |
| Palworld Modding Kit | PMK compatible with Unreal Engine 5.1 |

Do not substitute Visual Studio 2026: it is not compatible with Unreal Engine
5.1. In Visual Studio Installer, select both workloads shown by the PMK guide:

- **.NET desktop development**
- **Desktop development with C++**

Then open **Individual components**, search for the following exact component,
and make sure it is selected:

```text
MSVC v143 - VS 2022 C++ x64/x86 Build Tools (v14.38-17.8)
```

The C++ workload installs its supporting Windows SDK. The machine may also
have newer MSVC toolsets; do not remove them. PMK specifically needs v14.38
available alongside newer versions.

## Wwise installation

Install the current **Audiokinetic Launcher**, but use it to install the pinned
**Wwise 2021.1.11** authoring/SDK version. The Launcher version and Wwise
version are independent.

For Wwise 2021.1.11, include:

- Authoring
- SDK (C++)
- Microsoft > Windows > Visual Studio 2022

On the plugins page, select no optional plugins and start the installation.
After the SDK installation completes:

1. Open the Audiokinetic Launcher's **Unreal Engine** tab.
2. Select **Download...**.
3. Select **Offline Integration Files**.
4. Set **Integration Version** to `2021.1.11`.
5. Choose a memorable local directory and install the integration files.

Keep that directory: the subsequent PMK installation process needs it.

### PMK Wwise integration notes

The prerequisite guide stops after downloading the offline integration. During
the later PMK installation, PMK expects the resulting project plugin at:

```text
<PMK>\Plugins\Wwise
```

Follow the PMK installation guide for copying and configuring that plugin.
Keep all Wwise plugin and SDK files as local PMK dependencies; do not commit
them to this repository.

## Audiokinetic Launcher opens and immediately exits

On newer Windows 11 installations the Launcher can exit after playing only a
sound when the optional WMIC capability is absent. Confirm with:

```powershell
Test-Path "$env:WINDIR\System32\wbem\wmic.exe"
```

If it returns `False`, install WMIC from an elevated PowerShell or Terminal:

```powershell
dism.exe /Online /Add-Capability /CapabilityName:WMIC~~~~ /NoRestart
```

Let DISM finish; do not start a second servicing operation while it is still
running. Verify:

```powershell
& "$env:WINDIR\System32\wbem\wmic.exe" os get Caption,Version /value
```

The same capability can be installed through **Settings > System > Optional
features** by adding **WMIC**.

## Local layout

A practical local layout is:

```text
<workspace>\
  palworld-mods\    # this repository
  PMK\              # local Palworld Modding Kit
```

Example installed locations on a development machine:

```text
C:\Program Files\Epic Games\UE_5.1
C:\Program Files\Wwise Launcher
<workspace>\PMK
```

These are examples, not committed defaults. Record actual paths in the
relevant ignored `mod-project.local.json`.

## Verification checklist

Before building a LogicMod:

1. `UnrealEditor-Cmd.exe -version` starts successfully.
2. `dotnet --list-runtimes` includes a .NET 6 x64 runtime.
3. Visual Studio 2022 has both required workloads.
4. Visual Studio exposes the exact MSVC v14.38-17.8 component.
5. Wwise 2021.1.11 includes SDK (C++) and Windows/Visual Studio 2022.
6. The Wwise 2021.1.11 offline Unreal integration has been downloaded.
7. After PMK installation, PMK opens or compiles without a missing `Wwise` or
   `AkAudio` dependency.
8. Repository `validate` and `build` targets pass.

Do not copy installed tools, SDKs, PMK, extracted game assets, or cooked game
content into this repository.
