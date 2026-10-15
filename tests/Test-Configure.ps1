[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runRoot = Join-Path $projectRoot ('imagegen-output\settings-test-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($runRoot)
$fixturePath = Join-Path $runRoot 'image2.env'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($fixturePath, @('# retained comment','UNKNOWN_FIELD=keep-this','CHAT_MODEL=retained-chat','MODEL=old','MODEL=duplicate'), $utf8)
$portProbe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$testPort = $portProbe.LocalEndpoint.Port
$portProbe.Stop()
$readyPath = Join-Path $runRoot 'ready'
$listenerJob = Start-Job -ArgumentList $testPort,$readyPath -ScriptBlock {
    param($port,$ready)
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add('http://127.0.0.1:' + $port + '/')
    $listener.Start()
    [System.IO.File]::WriteAllText($ready, 'ready')
    try {
        $context = $listener.GetContext()
        if ($context.Request.Url.AbsolutePath -ne '/v1/models') { throw 'Unexpected route' }
        if ($context.Request.Headers['Authorization'] -ne 'Bearer offline-settings-key') { throw 'Unexpected test authorization' }
        $body = [System.Text.Encoding]::UTF8.GetBytes('{"data":[{"id":"offline-image-model"},{"id":"second-model"}]}')
        $context.Response.ContentType = 'application/json'
        $context.Response.ContentLength64 = $body.Length
        $context.Response.OutputStream.Write($body,0,$body.Length)
        $context.Response.Close()
    } finally { $listener.Close() }
}
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    while (-not (Test-Path -LiteralPath $readyPath)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Mock model-list server did not start.' }
        Start-Sleep -Milliseconds 100
    }
    $scriptPath = Join-Path $projectRoot 'plugins\image2\scripts\Configure.ps1'
    $source = [System.IO.File]::ReadAllText($scriptPath).Replace('[void]$form.ShowDialog()', '')
    . ([scriptblock]::Create($source)) -ConfigPath $fixturePath
    $form.Show()
    $baseUrl.Text = 'http://127.0.0.1:' + $testPort
    $apiKey.Text = 'offline-settings-key'
    if (-not $apiKey.UseSystemPasswordChar) { throw 'Key field is not masked.' }
    if ($autoAssets.Checked) { throw 'Asset generation must default to off.' }
    $test.PerformClick()
    if ($model.Items.Count -ne 2) { throw ('Model list failed: ' + $status.Text) }
    $model.Text = 'offline-image-model'
    $mode.SelectedItem = 'images'
    $autoAssets.Checked = $true
    $save.PerformClick()
    if ($status.Text -notlike 'Saved locally*') { throw ('Save failed: ' + $status.Text) }
    $saved = [System.IO.File]::ReadAllLines($fixturePath)
    foreach ($line in @('# retained comment','UNKNOWN_FIELD=keep-this','CHAT_MODEL=retained-chat','MODEL=offline-image-model','MODE=images','AUTO_GENERATE_ASSETS=true')) {
        if ($saved -notcontains $line) { throw ('Setting was not retained: ' + $line) }
    }
    if (@($saved | Where-Object { $_ -like 'MODEL=*' }).Count -ne 1) { throw 'Duplicate known settings were not removed.' }
    if (@(Get-ChildItem -LiteralPath $runRoot -Filter '*.tmp').Count -ne 0) { throw 'Temporary settings file left behind.' }
    $form.Refresh()
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height)))
    $bitmap.Save((Join-Path $runRoot 'settings.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $form.Close()
    Receive-Job -Job $listenerJob -Wait -ErrorAction Stop | Out-Null
    Write-Output ('PASS: masked key, default-off toggle, mock model list, save, retained settings, duplicate removal. Screenshot: ' + (Join-Path $runRoot 'settings.png'))
} finally {
    if ($form) { $form.Dispose() }
    Stop-Job -Job $listenerJob -ErrorAction SilentlyContinue
    Remove-Job -Job $listenerJob -Force -ErrorAction SilentlyContinue
}
