# NAPS2 Design Previewer

Live design viewer for the NAPS2 redesign. Edit icons/colors in the real source,
hit **Refresh** — no build, no SDK, no installs. Pure Windows PowerShell.

## Run

```powershell
powershell -ExecutionPolicy Bypass -File previewer\preview.ps1
```

Headless check (no window opens):

```powershell
powershell -ExecutionPolicy Bypass -File previewer\preview.ps1 -SelfTest
```

## What it shows

- **Toolbar tab** — mock of the real main-window toolbar (order + dropdowns mirror
  `NAPS2.Lib/EtoForms/Ui/DesktopForm.cs` + `DesktopCommands.cs`). Icons load from
  `NAPS2.Lib/Icons/*.png` on disk. Dark toggle previews icons on dark background,
  HiDPI toggle prefers `*-hires.png`.
- **Icons tab** — searchable grid of all ~200 icons, straight from disk.
- **Palette tab** — light/dark swatches parsed from
  `NAPS2.Lib/EtoForms/ColorScheme.cs` (hex values + ternaries, no compile).

## Workflow

1. Run the script above (zero build — it just runs)
2. Edit any PNG in `NAPS2.Lib/Icons/` or a hex value in `ColorScheme.cs`
3. Hit **Refresh** in the previewer — changes appear instantly
4. For structural changes (new buttons, dialogs, layout), update the `$Toolbar`
   model at the top of `preview.ps1` to match

The portable-zip workflow still produces the full app for final checks.
