# Tool selection and troubleshooting

## Decision table

| Need | Preferred tool | Mapping required |
| --- | --- | --- |
| PAK metadata, mount point, version | `repak info` | No |
| List or search internal paths | `repak list` | No |
| Read one exact raw entry | `repak get` | No |
| Compare entry content hashes | `repak hash-list` | No |
| Read cooked UObject properties | FModel or UAssetAPI | Usually yes |
| Preview mesh or texture | FModel | Usually yes |
| Preview cooked Niagara animation | Running game | N/A |

Use repak first because reading the PAK index is fast, deterministic, and does
not deserialize cooked UObject properties.

## repak

Repository convention:

`tools/repak/repak.exe`

The tested build is official `trumank/repak` v0.2.3:

- asset: `repak_cli-x86_64-pc-windows-msvc.zip`
- archive SHA-256:
  `6720d602144d75df477a99d5bedb6ea780997546afc335901d4937cafeaa73fa`
- release:
  `https://github.com/trumank/repak/releases/tag/v0.2.3`

Keep the executable ignored; do not commit it.

## Palworld paths

Typical Steam layout:

```text
<SteamLibrary>/steamapps/common/Palworld/
  Engine/
  Pal/
    Content/
      Paks/
        Pal-Windows.pak
```

Pass the PAK file to repak. Pass the game root containing `Engine` and `Pal` to
FModel's Directory Selector.

Unreal internal paths use:

```text
Pal/Content/.../Asset.uasset
```

Runtime object paths usually use:

```text
/Game/.../Asset.Asset
```

Convert `Pal/Content/` to `/Game/`, remove the extension, then append the asset
name after a dot.

## Mappings

Palworld uses unversioned cooked properties. repak does not need mappings to
list or extract raw entries, but FModel and UAssetAPI need a matching `.usmap`
to deserialize most assets.

Configure FModel:

1. Select `GAME_UE5_1`.
2. Set the game directory to the Palworld root.
3. Enable **Local Mapping File**.
4. Select the current `Mappings.usmap`.

Community mapping source used by the Palworld Modding documentation:

`https://github.com/PalworldModding/UsefulFiles/blob/master/Mappings.usmap`

Mappings can become stale after game updates. Empty data, missing properties,
or parser exceptions can indicate a revision mismatch.

## Encrypted archives

Run `repak info` before assuming encryption. Supply an AES key only when the
archive reports encryption and the user has a legitimate key for their
installed game. Never guess, publish, or commit keys.

## Extraction scope

For a cooked package, collect the `.uasset` and only existing same-basename
companions:

- `.uexp`
- `.ubulk`
- `.uptnl`

Use ignored `work/original` storage. Record SHA-256 hashes, then delete local
research extracts when no longer needed. Never add them to Git.
