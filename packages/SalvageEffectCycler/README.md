# Salvage Effect Cycler

Development-only UE4SS Lua tool for comparing Palworld's built-in Niagara
systems on active fishing salvage spots.

The tool changes only loaded Niagara components. It does not modify game
archives, loot, spawn behavior, interaction logic, or saves.

## In-game commands

Open the UE console and use:

- `salvagefx next` — apply the next candidate.
- `salvagefx prev` — apply the previous candidate.
- `salvagefx set <index-or-name>` — select a candidate.
- `salvagefx apply` — reapply the current candidate to loaded spots.
- `salvagefx list` — print every candidate and its index.
- `salvagefx status` — show the selection and loaded-component count.
- `salvagefx scale <number>` — change `User.Scale` and reapply.
- `salvagefx rate <number>` — change `User.Rate` and reapply.
- `salvagefx tune <scale> <rate>` — change both tuning values.
- `salvagefx help` — print the command summary.

Hotkeys are also registered for quick comparisons:

- `Ctrl+Page Down` — next candidate.
- `Ctrl+Page Up` — previous candidate.

Stand near one or more loaded Rank 1 or Rank 2 fishing salvage spots before
using the command. Newly streamed spots require `salvagefx apply`, or another
next/previous operation.

## Limitations

- Only Niagara systems already cooked into Palworld can be selected.
- Candidate systems may rely on actor-specific parameters, scale, orientation,
  or attachments. A successful swap does not guarantee an effect is suitable.
- Development defaults are `User.Scale = 0.12` and `User.Rate = 0.35`.
- The runtime `UNiagaraComponent:SetAsset` call is protected by diagnostics
  because its UE4SS reflection availability must be confirmed against the
  installed Palworld/UE4SS revision.
- This is a local visual inspection tool, not a production gameplay mod.
