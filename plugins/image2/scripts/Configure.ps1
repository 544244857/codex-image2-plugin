[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE '.codex\image2.env')
)

$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'The image2 configuration window requires Windows.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Read-Image2Config([string]$Path) {
    $values = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }
            $index = $trimmed.IndexOf('=')
            if ($index -gt 0) { $values[$trimmed.Substring(0, $index).Trim()] = $trimmed.Substring($index + 1).Trim().Trim('"').Trim("'") }
        }
    }
    return $values
}

function Add-ConfigRow($Table, [int]$Row, [string]$Label, $Control) {
    $caption = New-Object System.Windows.Forms.Label
    $caption.Text = $Label
    $caption.Anchor = 'Left'
    $caption.AutoSize = $true
    $caption.Margin = New-Object System.Windows.Forms.Padding(8, 8, 8, 4)
    $Control.Dock = 'Fill'
    $Control.Margin = New-Object System.Windows.Forms.Padding(4, 4, 8, 4)
    $Table.Controls.Add($caption, 0, $Row)
    $Table.Controls.Add($Control, 1, $Row)
}

$config = Read-Image2Config $ConfigPath
$form = New-Object System.Windows.Forms.Form
$form.Text = 'image2 Settings'
$form.StartPosition = 'CenterScreen'
$form.ClientSize = New-Object System.Drawing.Size(680, 395)
$form.MinimumSize = New-Object System.Drawing.Size(680, 395)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'
$layout.Padding = New-Object System.Windows.Forms.Padding(12)
$layout.ColumnCount = 2
$layout.RowCount = 8
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
for ($i = 0; $i -lt 7; $i++) { [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38))) }
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))

$baseUrl = New-Object System.Windows.Forms.TextBox
$baseUrl.Text = [string]$config['BASE_URL']
$apiKey = New-Object System.Windows.Forms.TextBox
$apiKey.UseSystemPasswordChar = $true
$apiKey.Text = [string]$config['API_KEY']
$model = New-Object System.Windows.Forms.ComboBox
$model.DropDownStyle = 'DropDown'
$model.Text = if ($config['MODEL']) { [string]$config['MODEL'] } else { 'gpt-image-1' }
$mode = New-Object System.Windows.Forms.ComboBox
$mode.DropDownStyle = 'DropDownList'
[void]$mode.Items.AddRange([object[]]@('auto', 'images', 'images-stream', 'responses', 'chat'))
$mode.SelectedItem = if ($config['MODE'] -and $mode.Items.Contains([string]$config['MODE'])) { [string]$config['MODE'] } else { 'auto' }
$outDir = New-Object System.Windows.Forms.TextBox
$outDir.Text = [string]$config['OUT_DIR']
$autoAssets = New-Object System.Windows.Forms.CheckBox
$autoAssets.Text = 'Allow generated visual assets in software projects'
$autoAssets.Checked = ([string]$config['AUTO_GENERATE_ASSETS'] -eq 'true')
$status = New-Object System.Windows.Forms.Label
$status.AutoSize = $true
$status.Anchor = 'Left'

Add-ConfigRow $layout 0 'Image relay URL' $baseUrl
Add-ConfigRow $layout 1 'API key' $apiKey
Add-ConfigRow $layout 2 'Image model' $model
Add-ConfigRow $layout 3 'API mode' $mode
Add-ConfigRow $layout 4 'Output directory' $outDir
Add-ConfigRow $layout 5 'Asset generation' $autoAssets
Add-ConfigRow $layout 6 'Status' $status

$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock = 'Fill'
$buttons.FlowDirection = 'RightToLeft'
$buttons.WrapContents = $false
$save = New-Object System.Windows.Forms.Button
$save.Text = 'Save'
$save.Width = 100
$cancel = New-Object System.Windows.Forms.Button
$cancel.Text = 'Close'
$cancel.Width = 100
$test = New-Object System.Windows.Forms.Button
$test.Text = 'Test connection'
$test.Width = 130
[void]$buttons.Controls.Add($save)
[void]$buttons.Controls.Add($cancel)
[void]$buttons.Controls.Add($test)
$layout.Controls.Add($buttons, 1, 7)
$form.Controls.Add($layout)
$form.AcceptButton = $save
$form.CancelButton = $cancel

$test.Add_Click({
    $status.Text = 'Checking model list...'
    $form.Refresh()
    try {
        $url = $baseUrl.Text.Trim().TrimEnd('/')
        if (-not $url) { throw 'Image relay URL is required.' }
        if ($url -notmatch '/v\d+$') { $url += '/v1' }
        $headers = @{ Authorization = 'Bearer ' + $apiKey.Text.Trim() }
        $response = Invoke-RestMethod -Method Get -Uri ($url + '/models') -Headers $headers -TimeoutSec 20
        $ids = @($response.data | ForEach-Object { $_.id } | Where-Object { $_ })
        if ($ids.Count -eq 0) { throw 'The endpoint returned no model IDs.' }
        $model.Items.Clear()
        foreach ($id in $ids) { [void]$model.Items.Add([string]$id) }
        $status.Text = 'Connected. ' + $ids.Count + ' model(s) found.'
    }
    catch {
        $status.Text = 'Connection failed: ' + $_.Exception.Message
    }
})

$save.Add_Click({
    try {
        if (-not $baseUrl.Text.Trim()) { throw 'Image relay URL is required.' }
        if (-not $apiKey.Text.Trim()) { throw 'API key is required.' }
        if (-not $model.Text.Trim()) { throw 'Image model is required.' }
        $updates = [ordered]@{
            BASE_URL = $baseUrl.Text.Trim()
            API_KEY = $apiKey.Text.Trim()
            MODEL = $model.Text.Trim()
            MODE = [string]$mode.SelectedItem
            OUT_DIR = $outDir.Text.Trim()
            AUTO_GENERATE_ASSETS = if ($autoAssets.Checked) { 'true' } else { 'false' }
        }
        $existingLines = @()
        if (Test-Path -LiteralPath $ConfigPath) { $existingLines = @([System.IO.File]::ReadAllLines($ConfigPath)) }
        $written = @{}
        $lines = New-Object System.Collections.Generic.List[string]
        foreach ($line in $existingLines) {
            $trimmed = $line.Trim()
            $index = $trimmed.IndexOf('=')
            if ($index -gt 0) {
                $key = $trimmed.Substring(0, $index).Trim()
                if ($updates.Contains($key)) {
                    if (-not $written.ContainsKey($key)) {
                        $lines.Add($key + '=' + [string]$updates[$key])
                        $written[$key] = $true
                    }
                    continue
                }
            }
            $lines.Add($line)
        }
        foreach ($key in $updates.Keys) { if (-not $written.ContainsKey($key)) { $lines.Add($key + '=' + [string]$updates[$key]) } }
        $directory = Split-Path -Parent $ConfigPath
        if ($directory) { [void][System.IO.Directory]::CreateDirectory($directory) }
        $tempPath = $ConfigPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [System.IO.File]::WriteAllLines($tempPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $ConfigPath) { [System.IO.File]::Replace($tempPath, $ConfigPath, [NullString]::Value) }
        else { [System.IO.File]::Move($tempPath, $ConfigPath) }
        $status.Text = 'Saved locally. Keep this file private.'
    }
    catch {
        $status.Text = 'Save failed: ' + $_.Exception.Message
    }
})

$cancel.Add_Click({ $form.Close() })
[void]$form.ShowDialog()
