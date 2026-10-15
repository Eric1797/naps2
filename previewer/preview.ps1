#Requires -Version 5.1
<#
NAPS2 Design Previewer - zero-install, zero-compile live viewer.
Runs on built-in Windows PowerShell + .NET Framework WinForms. No SDK needed.

  Run GUI:   powershell -ExecutionPolicy Bypass -File previewer\preview.ps1
  Self-test: powershell -ExecutionPolicy Bypass -File previewer\preview.ps1 -SelfTest

Edit PNGs in NAPS2.Lib\Icons or hex values in ColorScheme.cs, hit Refresh.
#>
param([switch]$SelfTest, [switch]$TestRefresh)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:ErrLog = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Temp\preview-err2.log'
function Log-Error($text) {
    try { [IO.File]::AppendAllText($script:ErrLog, "[$(Get-Date -Format 'HH:mm:ss')] $text`r`n") } catch {}
}
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    Log-Error $e.Exception.ToString()
    [System.Windows.Forms.MessageBox]::Show($e.Exception.Message, 'Previewer error') | Out-Null
})

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

$script:LoadedImages = New-Object Collections.ArrayList
$script:GridImages = New-Object Collections.ArrayList
# All loaders append here; Refresh swaps the bin so old images are only
# disposed AFTER the new controls replace them (never paint a dead image).
$script:ImageBin = $null
function Bin-Add($img) { if ($img -and $script:ImageBin -ne $null) { [void]$script:ImageBin.Add($img) } }
function Load-Image($path) {
    if (-not $path) { return $null }
    try {
        $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
        try {
            $ms = New-Object IO.MemoryStream
            try {
                $fs.CopyTo($ms); $ms.Position = 0
                $src = [System.Drawing.Image]::FromStream($ms)
                try {
                    # Deep-copy so the image is detached from the (soon closed) stream.
                    # Without this, Button painting can throw "Parameter is not valid".
                    $bmp = New-Object System.Drawing.Bitmap($src)
                } finally { $src.Dispose() }
            } finally { $ms.Dispose() }
        } finally { $fs.Dispose() }
    } catch {
        return $null
    }
    Bin-Add $bmp
    return $bmp
}

function Resize-Image($img, $size) {
    if ($img.Width -eq $size -and $img.Height -eq $size) { return $img }
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.DrawImage($img, 0, 0, $size, $size) } finally { $g.Dispose() }
    Bin-Add $bmp
    return $bmp
}

function Placeholder($size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Magenta)
        $g.DrawString('?', (New-Object System.Drawing.Font('Arial', $size * 0.7)), [System.Drawing.Brushes]::Black, 0, 0)
    } finally { $g.Dispose() }
    Bin-Add $bmp
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
    return [System.Drawing.Color]::FromArgb([Convert]::ToInt32($hex.Substring(0,2),16), [Convert]::ToInt32($hex.Substring(2,2),16), [Convert]::ToInt32($hex.Substring(4,2),16))
}

function Toolbar-IconNames {
    $set = @{}
    foreach ($b in $Toolbar) {
        if ($b.ContainsKey('Sep')) { continue }
        $set[$b.Icon] = $true
        foreach ($m in ($b.Menu | Where-Object { $_ -and -not $_.ContainsKey('Sep') })) { if ($m.Icon) { $set[$m.Icon] = $true } }
    }
    foreach ($extra in @('control_play_blue_small', 'pencil_small', 'add_small', 'scanner-96', 'application_side_list_small', 'zoom_in_small', 'zoom_out_small')) { $set[$extra] = $true }
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

$form = New-Object System.Windows.Forms.Form
$form.Text = 'NAPS2 Design Previewer (edit PNGs/CS, hit Refresh - no build)'
$form.Width = 1100; $form.Height = 750

$top = New-Object System.Windows.Forms.ToolStrip
$top.Dock = 'Top'; $top.GripStyle = 'Hidden'
$btnRefresh = New-Object System.Windows.Forms.ToolStripButton('Refresh')
$btnDark = New-Object System.Windows.Forms.ToolStripButton('Dark: off'); $btnDark.CheckOnClick = $true
$btnHires = New-Object System.Windows.Forms.ToolStripButton('HiDPI: off'); $btnHires.CheckOnClick = $true
$top.Items.Add($btnRefresh) | Out-Null
$top.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$top.Items.Add($btnDark) | Out-Null
$top.Items.Add($btnHires) | Out-Null

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'

# Main-window tab (mirrors WinFormsDesktopForm: main toolbar, profiles toolbar,
# sidebar with profile/device/scan settings, thumbnail area, zoom controls)
$tabToolbar = New-Object System.Windows.Forms.TabPage('Main Window')
$mockBar = New-Object System.Windows.Forms.ToolStrip
$mockBar.Dock = 'Top'; $mockBar.GripStyle = 'Hidden'
$profilesBar = New-Object System.Windows.Forms.ToolStrip
$profilesBar.Dock = 'Top'; $profilesBar.GripStyle = 'Hidden'
$sepLine = New-Object System.Windows.Forms.Panel
$sepLine.Dock = 'Top'; $sepLine.Height = 1
$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = 'Fill'; $split.SplitterDistance = 235; $split.FixedPanel = 'Panel1'; $split.SplitterWidth = 4
$sidebarScroll = New-Object System.Windows.Forms.Panel
$sidebarScroll.Dock = 'Fill'; $sidebarScroll.AutoScroll = $true; $sidebarScroll.Padding = '10,8,10,8'
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = 'Fill'
$thumbFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$thumbFlow.Dock = 'Fill'; $thumbFlow.AutoScroll = $true; $thumbFlow.Padding = New-Object System.Windows.Forms.Padding(12)
$bottomBar = New-Object System.Windows.Forms.Panel
$bottomBar.Dock = 'Bottom'; $bottomBar.Height = 32
$script:SampleProfiles = @('G3070 series', 'Test Profile')
$script:SelectedThumb = 0
$script:ZoomLevels = @(50, 100, 150, 200); $script:ZoomIdx = 1
$script:Swatches = @()
$split.Panel1.Controls.Add($sidebarScroll)
$contentPanel.Controls.Add($thumbFlow)
$contentPanel.Controls.Add($bottomBar)
$split.Panel2.Controls.Add($contentPanel)
$tabToolbar.Controls.Add($split)
$tabToolbar.Controls.Add($sepLine)
$tabToolbar.Controls.Add($profilesBar)
$tabToolbar.Controls.Add($mockBar)

# Icons tab
$tabIcons = New-Object System.Windows.Forms.TabPage('Icons')
$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Dock = 'Top'
$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = 'Search:'; $searchLabel.Dock = 'Top'; $searchLabel.Height = 18
$iconFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$iconFlow.Dock = 'Fill'; $iconFlow.AutoScroll = $true
$tabIcons.Controls.Add($iconFlow); $tabIcons.Controls.Add($searchBox); $tabIcons.Controls.Add($searchLabel)

# Palette tab
$tabPalette = New-Object System.Windows.Forms.TabPage('Palette')
$palFlow = New-Object System.Windows.Forms.FlowLayoutPanel
$palFlow.Dock = 'Fill'; $palFlow.AutoScroll = $true; $palFlow.FlowDirection = 'TopDown'; $palFlow.WrapContents = $false
$tabPalette.Controls.Add($palFlow)

$tabs.TabPages.Add($tabToolbar) | Out-Null
$tabs.TabPages.Add($tabIcons) | Out-Null
$tabs.TabPages.Add($tabPalette) | Out-Null

$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Spring = $true
$status.Items.Add($statusLabel) | Out-Null

function Refresh-Toolbar {
    $mockBar.Items.Clear()
    $size = if ($script:Hires) { 32 } else { 16 }
    $mockBar.ImageScalingSize = New-Object System.Drawing.Size($size, $size)
    $mockBar.BackColor = if ($script:Dark) { Hex-ToColor '262626' } else { [System.Drawing.SystemColors]::Control }
    $mockBar.ForeColor = if ($script:Dark) { [System.Drawing.Color]::White } else { [System.Drawing.SystemColors]::ControlText }
    $missing = New-Object Collections.ArrayList
    foreach ($b in $Toolbar) {
        if ($b.ContainsKey('Sep')) { $mockBar.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null; continue }
        if (-not (Get-IconFile $b.Icon)) { [void]$missing.Add($b.Icon) }
        $img = Icon-For $b.Icon $size $script:Hires
        if ($b.Menu) {
            $drop = New-Object System.Windows.Forms.ToolStripDropDownButton($b.Text, $img)
            $drop.TextImageRelation = 'ImageAboveText'; $drop.ForeColor = $mockBar.ForeColor
            foreach ($m in $b.Menu) {
                if ($m.ContainsKey('Sep')) { $drop.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null; continue }
                $MenuItem = $null
                if ($m.Icon) { if (-not (Get-IconFile $m.Icon)) { [void]$missing.Add($m.Icon) }; $MenuItem = Icon-For $m.Icon 16 $false }
                $drop.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripMenuItem($m.Text, $MenuItem))) | Out-Null
            }
            $mockBar.Items.Add($drop) | Out-Null
        } else {
            $btn = New-Object System.Windows.Forms.ToolStripButton($b.Text, $img)
            $btn.TextImageRelation = 'ImageAboveText'; $btn.ForeColor = $mockBar.ForeColor
            $mockBar.Items.Add($btn) | Out-Null
        }
    }
    Refresh-WindowChrome $missing
}

function Pal($name, $fallbackLight, $fallbackDark) {
    $s = $script:Swatches | Where-Object { $_.Name -eq $name } | Select-Object -First 1
    if ($s) { if ($script:Dark) { return (Hex-ToColor $s.Dark) } else { return (Hex-ToColor $s.Light) } }
    if ($script:Dark) { return $fallbackDark } else { return $fallbackLight }
}

function Refresh-WindowChrome($missing) {
    $fore = Pal 'ForegroundColor' 'Black' 'White'
    $back = Pal 'BackgroundColor' 'White' '262626'
    $sep = Pal 'SeparatorColor' 'DDDDDD' '606060'
    $hlBack = Pal 'HighlightBackgroundColor' 'CCE8FF' '28445B'
    $hlBorder = Pal 'HighlightBorderColor' '60A0E8' '0078D4'

    # Profiles toolbar (16px, icon before text, like UpdateProfilesToolbar)
    $profilesBar.Items.Clear()
    $profilesBar.ImageScalingSize = New-Object System.Drawing.Size(16, 16)
    $profilesBar.BackColor = $mockBar.BackColor; $profilesBar.ForeColor = $mockBar.ForeColor
    foreach ($p in $script:SampleProfiles) {
        if (-not (Get-IconFile 'control_play_blue_small')) { $missing.Add('control_play_blue_small') }
        $item = New-Object System.Windows.Forms.ToolStripButton($p, (Icon-For 'control_play_blue_small' 16 $false))
        $item.TextImageRelation = 'ImageBeforeText'; $item.ForeColor = $mockBar.ForeColor
        $profilesBar.Items.Add($item) | Out-Null
    }
    $sepLine.BackColor = $sep
    $split.BackColor = $sep
    $sidebarScroll.BackColor = $back
    $contentPanel.BackColor = $back
    $thumbFlow.BackColor = $back
    $bottomBar.BackColor = $back

    # Sidebar (mirrors Sidebar.CreateView: profile row, device, 4 dropdowns, Scan)
    $sidebarScroll.Controls.Clear()
    $addSide = {
        param($c, $h)
        $c.Dock = 'Top'; if ($h) { $c.Height = $h }; $sidebarScroll.Controls.Add($c)
    }
    $profileRow = New-Object System.Windows.Forms.Panel; $profileRow.Height = 28
    $lblProfile = New-Object System.Windows.Forms.Label
    $lblProfile.Text = 'Profile:'; $lblProfile.Dock = 'Fill'; $lblProfile.TextAlign = 'MiddleLeft'; $lblProfile.ForeColor = $fore
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Image = Icon-For 'pencil_small' 16 $false; $btnEdit.Width = 32; $btnEdit.Dock = 'Right'; $btnEdit.FlatStyle = 'Flat'
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Image = Icon-For 'add_small' 16 $false; $btnNew.Width = 32; $btnNew.Dock = 'Right'; $btnNew.FlatStyle = 'Flat'
    foreach ($n in @('pencil_small', 'add_small')) { if (-not (Get-IconFile $n)) { $missing.Add($n) } }
    $profileRow.Controls.Add($lblProfile); $profileRow.Controls.Add($btnNew); $profileRow.Controls.Add($btnEdit)
    (& $addSide $profileRow 28)
    $script:ProfileCombo = New-Object System.Windows.Forms.ComboBox
    $script:ProfileCombo.DropDownStyle = 'DropDownList'
    foreach ($p in $script:SampleProfiles) { $script:ProfileCombo.Items.Add($p) | Out-Null }
    $script:ProfileCombo.SelectedIndex = 0
    $script:ProfileCombo.BackColor = $back; $script:ProfileCombo.ForeColor = $fore
    $script:ProfileCombo.Add_SelectedIndexChanged({ $form.Text = "NAPS2 - $($script:ProfileCombo.SelectedItem) (design preview)" })
    (& $addSide $script:ProfileCombo 26)
    $sp1 = New-Object System.Windows.Forms.Panel; (& $addSide $sp1 10)
    $deviceRow = New-Object System.Windows.Forms.Panel; $deviceRow.Height = 44
    $devIcon = New-Object System.Windows.Forms.PictureBox
    $devIcon.Image = Icon-For 'scanner-96' 32 $false; $devIcon.Size = New-Object System.Drawing.Size(36, 36)
    $devIcon.SizeMode = 'CenterImage'; $devIcon.Dock = 'Left'
    if (-not (Get-IconFile 'scanner-96')) { $missing.Add('scanner-96') }
    $devLabel = New-Object System.Windows.Forms.Label
    $devLabel.Text = "G3070 series`nWIA"; $devLabel.Dock = 'Fill'; $devLabel.TextAlign = 'MiddleLeft'; $devLabel.ForeColor = $fore
    $deviceRow.Controls.Add($devLabel); $deviceRow.Controls.Add($devIcon)
    (& $addSide $deviceRow 44)
    $sp2 = New-Object System.Windows.Forms.Panel; (& $addSide $sp2 10)
    $fields = @(
        @{ Label = 'Paper source:'; Items = @('Glass', 'Feeder', 'Duplex') },
        @{ Label = 'Page size:'; Items = @('Letter', 'A4', 'Legal') },
        @{ Label = 'Resolution:'; Items = @('100 DPI', '200 DPI', '300 DPI', '600 DPI') },
        @{ Label = 'Bit depth:'; Items = @('24-bit Color', '8-bit Grayscale', '1-bit Black & White') }
    )
    foreach ($f in $fields) {
        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'
        foreach ($i in $f.Items) { $cb.Items.Add($i) | Out-Null }
        $cb.SelectedIndex = 0; $cb.BackColor = $back; $cb.ForeColor = $fore
        $lb = New-Object System.Windows.Forms.Label
        $lb.Text = $f.Label; $lb.Height = 18; $lb.TextAlign = 'BottomLeft'; $lb.ForeColor = $fore
        (& $addSide $cb 26); (& $addSide $lb 18)
        $sp = New-Object System.Windows.Forms.Panel; (& $addSide $sp 6)
    }
    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = 'Scan'; $btnScan.Height = 36; $btnScan.Dock = 'Bottom'
    $btnScan.Image = Icon-For 'control_play_blue_small' 16 $false; $btnScan.ImageAlign = 'MiddleLeft'; $btnScan.TextAlign = 'MiddleCenter'
    $btnScan.Font = New-Object System.Drawing.Font($btnScan.Font, [System.Drawing.FontStyle]::Bold)
    $btnScan.BackColor = $back; $btnScan.ForeColor = $fore
    $sidebarScroll.Controls.Add($btnScan)

    # Thumbnails (4 sample pages, click to select, palette highlight)
    $thumbFlow.Controls.Clear()
    $zoom = $script:ZoomLevels[$script:ZoomIdx]
    $tw = [int](110 * $zoom / 100); $th = [int](150 * $zoom / 100)
    for ($i = 0; $i -lt 4; $i++) {
        $cell = New-Object System.Windows.Forms.Panel
        $cell.Width = $tw + 20; $cell.Height = $th + 44; $cell.Margin = New-Object System.Windows.Forms.Padding(8)
        $page = New-Object System.Windows.Forms.Panel
        $page.Size = New-Object System.Drawing.Size($tw, $th); $page.Location = New-Object System.Drawing.Point(10, 6)
        $page.BackColor = 'White'; $page.BorderStyle = 'FixedSingle'
        $pg = New-Object System.Windows.Forms.Label
        $pg.Text = "Page $($i + 1) sample"; $pg.Dock = 'Fill'; $pg.TextAlign = 'MiddleCenter'; $pg.ForeColor = 'Gray'
        $page.Controls.Add($pg)
        $cap = New-Object System.Windows.Forms.Label
        $cap.Text = "Page $($i + 1)"; $cap.Dock = 'Bottom'; $cap.Height = 30; $cap.TextAlign = 'TopCenter'; $cap.ForeColor = $fore
        $cell.Controls.Add($cap); $cell.Controls.Add($page)
        if ($i -eq $script:SelectedThumb) { $cell.BackColor = $hlBack; $page.BorderStyle = 'FixedSingle' }
        else { $cell.BackColor = $back }
        $idx = $i
        $cell.Add_Click({ $script:SelectedThumb = $idx; Refresh-Thumbs }.GetNewClosure())
        $cell.Cursor = 'Hand'
        $thumbFlow.Controls.Add($cell) | Out-Null
    }

    # Bottom bar (sidebar toggle + zoom, mirrors GetControlButtons)
    $bottomBar.Controls.Clear()
    $btnSide = New-Object System.Windows.Forms.Button
    $btnSide.Image = Icon-For 'application_side_list_small' 16 $false; $btnSide.Width = 40; $btnSide.Dock = 'Left'; $btnSide.FlatStyle = 'Flat'
    if (-not (Get-IconFile 'application_side_list_small')) { [void]$missing.Add('application_side_list_small') }
    $btnSide.Add_Click({ $split.Panel1Collapsed = -not $split.Panel1Collapsed })
    $zoomIn = New-Object System.Windows.Forms.Button
    $zoomIn.Image = Icon-For 'zoom_in_small' 16 $false; $zoomIn.Width = 36; $zoomIn.Dock = 'Right'; $zoomIn.FlatStyle = 'Flat'
    $zoomLabel = New-Object System.Windows.Forms.Label
    $zoomLabel.Text = "$zoom%"; $zoomLabel.Width = 52; $zoomLabel.Dock = 'Right'; $zoomLabel.TextAlign = 'MiddleCenter'; $zoomLabel.ForeColor = $fore
    $zoomOut = New-Object System.Windows.Forms.Button
    $zoomOut.Image = Icon-For 'zoom_out_small' 16 $false; $zoomOut.Width = 36; $zoomOut.Dock = 'Right'; $zoomOut.FlatStyle = 'Flat'
    foreach ($n in @('zoom_in_small', 'zoom_out_small')) { if (-not (Get-IconFile $n)) { $missing.Add($n) } }
    $zoomIn.Add_Click({ $script:ZoomIdx = [Math]::Min(3, $script:ZoomIdx + 1); Refresh-Thumbs })
    $zoomOut.Add_Click({ $script:ZoomIdx = [Math]::Max(0, $script:ZoomIdx - 1); Refresh-Thumbs })
    $bottomBar.Controls.Add($btnSide); $bottomBar.Controls.Add($zoomIn); $bottomBar.Controls.Add($zoomLabel); $bottomBar.Controls.Add($zoomOut)

    $form.Text = "NAPS2 - $($script:SampleProfiles[0]) (design preview)"
    if ($missing.Count -gt 0) {
        $statusLabel.Text += " | Missing icons: " + (($missing | Sort-Object -Unique) -join ', ')
    }
}

function Refresh-Thumbs {
    $fore = Pal 'ForegroundColor' 'Black' 'White'
    $back = Pal 'BackgroundColor' 'White' '262626'
    $hlBack = Pal 'HighlightBackgroundColor' 'CCE8FF' '28445B'
    $zoom = $script:ZoomLevels[$script:ZoomIdx]
    $tw = [int](110 * $zoom / 100); $th = [int](150 * $zoom / 100)
    $i = 0
    foreach ($cell in $thumbFlow.Controls) {
        $cell.Width = $tw + 20; $cell.Height = $th + 44
        $cell.BackColor = if ($i -eq $script:SelectedThumb) { $hlBack } else { $back }
        foreach ($c in $cell.Controls) {
            if ($c -is [System.Windows.Forms.Panel]) { $c.Size = New-Object System.Drawing.Size($tw, $th) }
            if ($c -is [System.Windows.Forms.Label]) { $c.ForeColor = $fore }
        }
        $i++
    }
    foreach ($c in $bottomBar.Controls) {
        if ($c -is [System.Windows.Forms.Label]) { $c.Text = "$zoom%"; $c.ForeColor = $fore }
    }
}

function Refresh-Icons {
    $oldGrid = $script:GridImages
    $script:GridImages = New-Object Collections.ArrayList
    $prevBin = $script:ImageBin
    $script:ImageBin = $script:GridImages
    try {
        $iconFlow.SuspendLayout()
        $iconFlow.Controls.Clear()
    $filter = $searchBox.Text.Trim()
    $bg = if ($script:Dark) { Hex-ToColor '262626' } else { [System.Drawing.Color]::White }
    foreach ($f in (Get-ChildItem $IconsDir -Filter *.png | Sort-Object Name)) {
        if ($filter -and $f.Name -notlike "*$filter*") { continue }
        $img = Load-Image $f.FullName
        $box = New-Object System.Windows.Forms.PictureBox
        $box.Image = $img; $box.Size = New-Object System.Drawing.Size(40, 40)
        $box.SizeMode = 'CenterImage'; $box.BackColor = $bg; $box.BorderStyle = 'FixedSingle'
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $f.Name; $label.Width = 120; $label.Height = 28; $label.TextAlign = 'TopCenter'
        $cell = New-Object System.Windows.Forms.FlowLayoutPanel
        $cell.FlowDirection = 'TopDown'; $cell.WrapContents = $false; $cell.Width = 128; $cell.Height = 76
        $cell.Controls.Add($box) | Out-Null; $cell.Controls.Add($label) | Out-Null
        $iconFlow.Controls.Add($cell) | Out-Null
    }
    $iconFlow.ResumeLayout()
    } finally {
        $script:ImageBin = $prevBin
        foreach ($img in $oldGrid) { try { $img.Dispose() } catch {} }
    }
}

function Refresh-Palette {
    $palFlow.SuspendLayout()
    $palFlow.Controls.Clear()
    $pal = Parse-Colors
    foreach ($s in $pal.Swatches) {
        $row = New-Object System.Windows.Forms.FlowLayoutPanel
        $row.FlowDirection = 'LeftToRight'; $row.WrapContents = $false; $row.Height = 34; $row.Width = 620
        $name = New-Object System.Windows.Forms.Label
        $name.Text = $s.Name; $name.Width = 220; $name.TextAlign = 'MiddleLeft'
        $row.Controls.Add($name) | Out-Null
        foreach ($mode in @(@{ N = 'Light'; H = $s.Light }, @{ N = 'Dark'; H = $s.Dark })) {
            $c = Hex-ToColor $mode.H
            $p = New-Object System.Windows.Forms.Panel
            $p.BackColor = $c; $p.Width = 170; $p.Height = 28; $p.BorderStyle = 'FixedSingle'
            $l = New-Object System.Windows.Forms.Label
            $l.Text = "$($mode.N) #$($mode.H)"; $l.Dock = 'Fill'; $l.TextAlign = 'MiddleCenter'; $l.BackColor = 'Transparent'
            $lum = $c.R * 0.299 + $c.G * 0.587 + $c.B * 0.114
            $l.ForeColor = if ($lum -gt 150) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
            $p.Controls.Add($l)
            $row.Controls.Add($p) | Out-Null
        }
        $palFlow.Controls.Add($row) | Out-Null
    }
    foreach ($w in $pal.Warnings) {
        $wl = New-Object System.Windows.Forms.Label; $wl.Text = $w; $wl.ForeColor = 'Red'; $wl.AutoSize = $true
        $palFlow.Controls.Add($wl) | Out-Null
    }
    $palFlow.ResumeLayout()
}

function Refresh-All {
    # Build the new UI first, dispose the old images after: controls on screen
    # still reference them until replaced, and painting a disposed image
    # throws "Parameter is not valid" (red X + error popup on toggle/refresh).
    $old = $script:LoadedImages
    $script:LoadedImages = New-Object Collections.ArrayList
    $script:ImageBin = $script:LoadedImages
    try {
        $script:Swatches = (Parse-Colors).Swatches
        Refresh-Toolbar
        Refresh-Icons
        Refresh-Palette
    } finally {
        foreach ($img in $old) { try { $img.Dispose() } catch {} }
    }
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

if ($TestRefresh) {
    # Headless refresh-cycle test: rebuilds + repaints repeatedly, exercising
    # the dark/hires paths. Catches "paint a disposed image" regressions.
    try {
        Refresh-All
        for ($k = 0; $k -lt 3; $k++) {
            [System.Windows.Forms.Application]::DoEvents()
            $shot = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            try { $form.DrawToBitmap($shot, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height))) }
            finally { $shot.Dispose() }
            Refresh-All
        }
        $script:Dark = $true; Refresh-All
        $script:Hires = $true; Refresh-All
        [System.Windows.Forms.Application]::DoEvents()
        $shot = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        try { $form.DrawToBitmap($shot, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height))) }
        finally { $shot.Dispose() }
        Write-Output 'REFRESHTEST: PASS'
        exit 0
    } catch {
        Write-Output ('REFRESHTEST: FAIL: ' + $_.Exception.Message)
        exit 1
    }
}
try {
    Refresh-All
} catch {
    Log-Error $_.Exception.ToString()
    [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Previewer startup error') | Out-Null
    exit 1
}
[void]$form.ShowDialog()
