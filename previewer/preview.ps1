#Requires -Version 5.1
<#
NAPS2 Design Previewer - zero-install, zero-compile live viewer.
Runs on built-in Windows PowerShell + .NET Framework WinForms. No SDK needed.

  Run GUI:   powershell -ExecutionPolicy Bypass -File previewer\preview.ps1
  Self-test: powershell -ExecutionPolicy Bypass -File previewer\preview.ps1 -SelfTest

Edit PNGs in NAPS2.Lib\Icons or hex values in ColorScheme.cs, hit Refresh.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- repo locations (walk up from this script until NAPS2.Lib is found) ---
$dir = $PSScriptRoot
while ($dir -and -not (Test-Path (Join-Path $dir 'NAPS2.Lib'))) { $dir = Split-Path $dir -Parent }
if (-not $dir) { Write-Error 'Could not find repo root (no NAPS2.Lib above script dir).'; exit 1 }
$RepoRoot = $dir
$IconsDir = Join-Path $RepoRoot 'NAPS2.Lib\Icons'
$ColorSchemePath = Join-Path $RepoRoot 'NAPS2.Lib\EtoForms\ColorScheme.cs'

# --- toolbar mirror (order + dropdowns from DesktopForm.cs / DesktopCommands.cs) ---
function Sep { return @{ Sep = $true } }
function Btn($text, $icon, $menu) { return @{ Text = $text; Icon = $icon; Menu = $menu } }
function MenuItem($text, $icon) { return @{ Text = $text; Icon = $icon } }

$Toolbar = @(
    (Btn 'Scan' 'control_play_blue' @((MenuItem 'New Profile...' 'add_small'), (MenuItem 'Batch Scan...' 'application_cascade_small'), (MenuItem 'Scanner Sharing...' 'wireless_small'))),
    (Btn 'Profiles' 'blueprints' $null),
    (Btn 'OCR' 'text' $null),
    (Btn 'Import' 'folder_picture' $null),
    (Sep),
    (Btn 'Save PDF' 'file_extension_pdf' @((MenuItem 'Save all as PDF' $null), (MenuItem 'Save selected as PDF' $null), (Sep), (MenuItem 'PDF settings...' $null))),
    (Btn 'Save Images' 'pictures' @((MenuItem 'Save all as images' $null), (MenuItem 'Save selected as images' $null), (Sep), (MenuItem 'Image settings...' $null))),
    (Btn 'Email PDF' 'email_attach' @((MenuItem 'Email all as PDF' $null), (MenuItem 'Email selected as PDF' $null), (Sep), (MenuItem 'Email settings...' $null), (MenuItem 'PDF settings...' $null))),
    (Btn 'Print' 'printer' $null),
    (Sep),
    (Btn 'Image' 'picture_edit' @((MenuItem 'View' 'zoom_small'), (Sep), (MenuItem 'Crop' 'transform_crop_small'), (MenuItem 'Brightness/Contrast' 'contrast_with_sun_small'), (MenuItem 'Hue/Saturation' 'color_management_small'), (MenuItem 'Black and White' 'contrast_high_small'), (MenuItem 'Sharpen' 'sharpen_small'), (MenuItem 'Document Correction' 'document_small'), (MenuItem 'Compress' 'spring_small'), (Sep), (MenuItem 'Split' 'split_small'), (MenuItem 'Combine' 'combine_small'), (Sep), (MenuItem 'Edit with...' 'pencil_small'), (Sep), (MenuItem 'Reset' $null))),
    (Btn 'Rotate' 'arrow_rotate_anticlockwise' @((MenuItem 'Rotate Left' 'arrow_rotate_anticlockwise_small'), (MenuItem 'Rotate Right' 'arrow_rotate_clockwise_small'), (MenuItem 'Flip' 'arrow_switch_small'), (MenuItem 'Deskew' $null), (MenuItem 'Custom Rotation...' $null))),
    (Btn 'Move Up' 'arrow_up_small' $null),
    (Btn 'Move Down' 'arrow_down_small' $null),
    (Btn 'Reorder' 'arrow_refresh' @((MenuItem 'Manual Duplex' 'column_double_small'), (Sep), (MenuItem 'Interleave' $null), (MenuItem 'Deinterleave' $null), (MenuItem 'Reverse All' $null), (MenuItem 'Reverse Selected' $null))),
    (Sep),
    (Btn 'Delete' 'cross' $null),
    (Btn 'Clear' 'broom' $null),
    (Sep),
    (Btn 'Language' 'world' $null),
    (Btn 'Settings' 'cog_small' $null),
    (Btn 'About' 'information_small' $null)
)

# --- disk loaders (no locks, so PNGs stay editable while preview runs) ---
function Get-IconFile($name, [switch]$Hires) {
    $stem = $name -replace '_small$', '-small'
    if ($Hires) { $c = Join-Path $IconsDir ($stem + '-hires.png'); if (Test-Path $c) { return $c }; return $null }
    foreach ($c in @((Join-Path $IconsDir ($stem + '.png')), (Join-Path $IconsDir ($name + '.png')))) {
        if (Test-Path $c) { return $c }
    }
    return $null
}

$script:LoadedImages = @()
function Load-Image($path) {
    if (-not $path) { return $null }
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $ms = New-Object IO.MemoryStream
        try { $fs.CopyTo($ms); $ms.Position = 0; $img = [Drawing.Image]::FromStream($ms) }
        finally { $ms.Dispose() }
    } finally { $fs.Dispose() }
    $script:LoadedImages += $img
    return $img
}

function Resize-Image($img, $size) {
    if ($img.Width -eq $size -and $img.Height -eq $size) { return $img }
    $bmp = New-Object Drawing.Bitmap($size, $size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try { $g.DrawImage($img, 0, 0, $size, $size) } finally { $g.Dispose() }
    $script:LoadedImages += $bmp
    return $bmp
}

function Placeholder($size) {
    $bmp = New-Object Drawing.Bitmap($size, $size)
    $g = [Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([Drawing.Color]::Magenta)
        $g.DrawString('?', (New-Object Drawing.Font('Arial', $size * 0.7)), [Drawing.Brushes]::Black, 0, 0)
    } finally { $g.Dispose() }
    $script:LoadedImages += $bmp
    return $bmp
}

function Icon-For($name, $size, $useHires) {
    $img = $null
    if ($useHires) { $p = Get-IconFile $name -Hires; if ($p) { $img = Load-Image $p } }
    if (-not $img) { $p = Get-IconFile $name; if ($p) { $img = Load-Image $p } }
    if (-not $img) { return Placeholder $size }
    return (Resize-Image $img $size)
}

# --- ColorScheme.cs parser (hex fields + DarkMode ternaries) ---
function Parse-Colors {
    $warnings = @(); $swatches = @()
    try { $fs = [IO.File]::Open($ColorSchemePath, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs); $text = $sr.ReadToEnd() }
    catch { return @{ Swatches = @(); Warnings = @("Could not read ColorScheme.cs: $_") } }
    finally { if ($sr) { $sr.Dispose() }; if ($fs) { $fs.Dispose() } }
    $named = @{ 'Colors.White' = 'FFFFFF'; 'Colors.Black' = '000000' }
    foreach ($m in [regex]::Matches($text, 'Color\s+(\w+)\s*=\s*Color\.FromRgb\(0x([0-9a-fA-F]{6})\)')) { $named[$m.Groups[1].Value] = $m.Groups[2].Value }
    foreach ($m in [regex]::Matches($text, 'public\s+Color\s+(\w+)\s*=>\s*DarkMode\s*\?\s*(.+?)\s*:\s*(.+?);')) {
        $d = Eval-Color $m.Groups[2].Value $named; $l = Eval-Color $m.Groups[3].Value $named
        if ($d -and $l) { $swatches += @{ Name = $m.Groups[1].Value; Light = $l; Dark = $d } }
        else { $warnings += "Could not parse expression for $($m.Groups[1].Value)" }
    }
    return @{ Swatches = $swatches; Warnings = $warnings }
}
function Eval-Color($expr, $named) {
    $expr = $expr.Trim()
    $m = [regex]::Match($expr, 'Color\.FromRgb\(0x([0-9a-fA-F]{6})\)')
    if ($m.Success) { return $m.Groups[1].Value }
    if ($named.ContainsKey($expr)) { return $named[$expr] }
    return $null
}
function Hex-ToColor($hex) {
    return [Drawing.Color]::FromArgb([Convert]::ToInt32($hex.Substring(0,2),16), [Convert]::ToInt32($hex.Substring(2,2),16), [Convert]::ToInt32($hex.Substring(4,2),16))
}

function Toolbar-IconNames {
    $set = @{}
    foreach ($b in $Toolbar) {
        if ($b.ContainsKey('Sep')) { continue }
        $set[$b.Icon] = $true
        foreach ($m in ($b.Menu | Where-Object { $_ -and -not $_.ContainsKey('Sep') })) { if ($m.Icon) { $set[$m.Icon] = $true } }
    }
    return @($set.Keys | Sort-Object)
}

# --- headless self-test ---
if ($SelfTest) {
    Write-Output "RepoRoot: $RepoRoot"
    $files = @(Get-ChildItem $IconsDir -Filter *.png)
    Write-Output "IconFiles: $($files.Count)"
    $missing = @(); $hashes = @()
    foreach ($n in (Toolbar-IconNames)) {
        $p = Get-IconFile $n
        if (-not $p) { $missing += $n } else { $hashes += (Get-FileHash $p -Algorithm SHA256).Hash }
    }
    Write-Output "ToolbarIcons: $((Toolbar-IconNames).Count) referenced, $($missing.Count) missing"
    foreach ($m in $missing) { Write-Output "  MISSING: $m" }
    $joined = $hashes -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($joined))).Replace('-','')
    Write-Output "ToolbarHash: $hash"
    $pal = Parse-Colors
    Write-Output "PaletteSwatches: $($pal.Swatches.Count)"
    foreach ($w in $pal.Warnings) { Write-Output "  WARN: $w" }
    $fail = $missing.Count + $(if ($pal.Swatches.Count -eq 0) { 1 } else { 0 })
    if ($fail -eq 0) { Write-Output 'SELFTEST: PASS'; exit 0 } else { Write-Output "SELFTEST: $fail FAILURES"; exit 1 }
}

# --- GUI ---
$script:Dark = $false; $script:Hires = $false

$form = New-Object Forms.Form
$form.Text = 'NAPS2 Design Previewer (edit PNGs/CS, hit Refresh - no build)'
$form.Width = 1100; $form.Height = 750

$top = New-Object Forms.ToolStrip
$top.Dock = 'Top'; $top.GripStyle = 'Hidden'
$btnRefresh = New-Object Forms.ToolStripButton('Refresh')
$btnDark = New-Object Forms.ToolStripButton('Dark: off'); $btnDark.CheckOnClick = $true
$btnHires = New-Object Forms.ToolStripButton('HiDPI: off'); $btnHires.CheckOnClick = $true
$top.Items.Add($btnRefresh) | Out-Null
$top.Items.Add((New-Object Forms.ToolStripSeparator)) | Out-Null
$top.Items.Add($btnDark) | Out-Null
$top.Items.Add($btnHires) | Out-Null

$tabs = New-Object Forms.TabControl
$tabs.Dock = 'Fill'

# Toolbar tab
$tabToolbar = New-Object Forms.TabPage('Toolbar')
$mockBar = New-Object Forms.ToolStrip
$mockBar.Dock = 'Top'; $mockBar.GripStyle = 'Hidden'
$pageArea = New-Object Forms.Panel
$pageArea.Dock = 'Fill'; $pageArea.BackColor = 'White'
$tabToolbar.Controls.Add($pageArea); $tabToolbar.Controls.Add($mockBar)

# Icons tab
$tabIcons = New-Object Forms.TabPage('Icons')
$searchBox = New-Object Forms.TextBox
$searchBox.Dock = 'Top'
$searchLabel = New-Object Forms.Label
$searchLabel.Text = 'Search:'; $searchLabel.Dock = 'Top'; $searchLabel.Height = 18
$iconFlow = New-Object Forms.FlowLayoutPanel
$iconFlow.Dock = 'Fill'; $iconFlow.AutoScroll = $true
$tabIcons.Controls.Add($iconFlow); $tabIcons.Controls.Add($searchBox); $tabIcons.Controls.Add($searchLabel)

# Palette tab
$tabPalette = New-Object Forms.TabPage('Palette')
$palFlow = New-Object Forms.FlowLayoutPanel
$palFlow.Dock = 'Fill'; $palFlow.AutoScroll = $true; $palFlow.FlowDirection = 'TopDown'; $palFlow.WrapContents = $false
$tabPalette.Controls.Add($palFlow)

$tabs.TabPages.Add($tabToolbar) | Out-Null
$tabs.TabPages.Add($tabIcons) | Out-Null
$tabs.TabPages.Add($tabPalette) | Out-Null

$status = New-Object Forms.StatusStrip
$statusLabel = New-Object Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$status.Items.Add($statusLabel) | Out-Null

function Refresh-Toolbar {
    $mockBar.Items.Clear()
    $size = if ($script:Hires) { 32 } else { 16 }
    $mockBar.ImageScalingSize = New-Object Drawing.Size($size, $size)
    $mockBar.BackColor = if ($script:Dark) { Hex-ToColor '262626' } else { [Drawing.SystemColors]::Control }
    $mockBar.ForeColor = if ($script:Dark) { [Drawing.Color]::White } else { [Drawing.SystemColors]::ControlText }
    $missing = @()
    foreach ($b in $Toolbar) {
        if ($b.ContainsKey('Sep')) { $mockBar.Items.Add((New-Object Forms.ToolStripSeparator)) | Out-Null; continue }
        if (-not (Get-IconFile $b.Icon)) { $missing += $b.Icon }
        $img = Icon-For $b.Icon $size $script:Hires
        if ($b.Menu) {
            $drop = New-Object Forms.ToolStripDropDownButton($b.Text, $img)
            $drop.TextImageRelation = 'ImageAboveText'; $drop.ForeColor = $mockBar.ForeColor
            foreach ($m in $b.Menu) {
                if ($m.ContainsKey('Sep')) { $drop.DropDownItems.Add((New-Object Forms.ToolStripSeparator)) | Out-Null; continue }
                $MenuItem = $null
                if ($m.Icon) { if (-not (Get-IconFile $m.Icon)) { $missing += $m.Icon }; $MenuItem = Icon-For $m.Icon 16 $false }
                $drop.DropDownItems.Add((New-Object Forms.ToolStripMenuItem($m.Text, $MenuItem))) | Out-Null
            }
            $mockBar.Items.Add($drop) | Out-Null
        } else {
            $btn = New-Object Forms.ToolStripButton($b.Text, $img)
            $btn.TextImageRelation = 'ImageAboveText'; $btn.ForeColor = $mockBar.ForeColor
            $mockBar.Items.Add($btn) | Out-Null
        }
    }
    $pageArea.BackColor = if ($script:Dark) { Hex-ToColor '262626' } else { [Drawing.Color]::White }
    $pageArea.Controls.Clear()
    $hint = New-Object Forms.Label
    $hint.Dock = 'Fill'; $hint.TextAlign = 'MiddleCenter'
    $hint.ForeColor = if ($script:Dark) { [Drawing.Color]::White } else { [Drawing.Color]::Black }
    $t = "Thumbnail area (placeholder)`n`nEdit PNGs in NAPS2.Lib\Icons or colors in ColorScheme.cs,`nthen hit Refresh - no rebuild needed."
    if ($missing.Count -gt 0) { $t += "`n`nMissing icons: " + (($missing | Sort-Object -Unique) -join ', ') }
    $hint.Text = $t
    $pageArea.Controls.Add($hint)
}

function Refresh-Icons {
    $iconFlow.SuspendLayout()
    $iconFlow.Controls.Clear()
    $filter = $searchBox.Text.Trim()
    $bg = if ($script:Dark) { Hex-ToColor '262626' } else { [Drawing.Color]::White }
    foreach ($f in (Get-ChildItem $IconsDir -Filter *.png | Sort-Object Name)) {
        if ($filter -and $f.Name -notlike "*$filter*") { continue }
        $img = Load-Image $f.FullName
        $box = New-Object Forms.PictureBox
        $box.Image = $img; $box.Size = New-Object Drawing.Size(40, 40)
        $box.SizeMode = 'CenterImage'; $box.BackColor = $bg; $box.BorderStyle = 'FixedSingle'
        $label = New-Object Forms.Label
        $label.Text = $f.Name; $label.Width = 120; $label.Height = 28; $label.TextAlign = 'TopCenter'
        $cell = New-Object Forms.FlowLayoutPanel
        $cell.FlowDirection = 'TopDown'; $cell.WrapContents = $false; $cell.Width = 128; $cell.Height = 76
        $cell.Controls.Add($box) | Out-Null; $cell.Controls.Add($label) | Out-Null
        $iconFlow.Controls.Add($cell) | Out-Null
    }
    $iconFlow.ResumeLayout()
}

function Refresh-Palette {
    $palFlow.SuspendLayout()
    $palFlow.Controls.Clear()
    $pal = Parse-Colors
    foreach ($s in $pal.Swatches) {
        $row = New-Object Forms.FlowLayoutPanel
        $row.FlowDirection = 'LeftToRight'; $row.WrapContents = $false; $row.Height = 34; $row.Width = 620
        $name = New-Object Forms.Label
        $name.Text = $s.Name; $name.Width = 220; $name.TextAlign = 'MiddleLeft'
        $row.Controls.Add($name) | Out-Null
        foreach ($mode in @(@{ N = 'Light'; H = $s.Light }, @{ N = 'Dark'; H = $s.Dark })) {
            $c = Hex-ToColor $mode.H
            $p = New-Object Forms.Panel
            $p.BackColor = $c; $p.Width = 170; $p.Height = 28; $p.BorderStyle = 'FixedSingle'
            $l = New-Object Forms.Label
            $l.Text = "$($mode.N) #$($mode.H)"; $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.BackColor = 'Transparent'
            $lum = $c.R * 0.299 + $c.G * 0.587 + $c.B * 0.114
            $l.ForeColor = if ($lum -gt 150) { [Drawing.Color]::Black } else { [Drawing.Color]::White }
            $p.Controls.Add($l)
            $row.Controls.Add($p) | Out-Null
        }
        $palFlow.Controls.Add($row) | Out-Null
    }
    foreach ($w in $pal.Warnings) {
        $wl = New-Object Forms.Label; $wl.Text = $w; $wl.ForeColor = 'Red'; $wl.AutoSize = $true
        $palFlow.Controls.Add($wl) | Out-Null
    }
    $palFlow.ResumeLayout()
}

function Refresh-All {
    foreach ($img in $script:LoadedImages) { try { $img.Dispose() } catch {} }
    $script:LoadedImages = @()
    Refresh-Toolbar
    Refresh-Icons
    Refresh-Palette
    $n = @(Get-ChildItem $IconsDir -Filter *.png).Count
    $statusLabel.Text = "Root: $RepoRoot | Icons: $n files | Refreshed: $(Get-Date -Format T) (no rebuild)"
}

$btnRefresh.Add_Click({ Refresh-All })
$btnDark.Add_Click({ $script:Dark = $btnDark.Checked; $btnDark.Text = if ($script:Dark) { 'Dark: on' } else { 'Dark: off' }; Refresh-All })
$btnHires.Add_Click({ $script:Hires = $btnHires.Checked; $btnHires.Text = if ($script:Hires) { 'HiDPI: on' } else { 'HiDPI: off' }; Refresh-All })
$searchBox.Add_TextChanged({ Refresh-Icons })

$form.Controls.Add($tabs)
$form.Controls.Add($top)
$form.Controls.Add($status)

Refresh-All
[void]$form.ShowDialog()
