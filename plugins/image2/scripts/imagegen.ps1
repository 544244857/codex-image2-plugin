<#
.SYNOPSIS
  通过「独立的图片中转站」生成图片，供 Codex / Codex++ 在对话中调用。

.DESCRIPTION
  与 Codex 的聊天链路完全解耦：
    - 聊天仍然走 ~/.codex/config.toml 里配置的 model_provider
    - 本脚本只读取你自己的图片站配置（默认 ~/.codex/image2.env）
  四种接口形态自动尝试（-Mode auto）：
    images        POST {BASE}/images/generations        （Images API，非流式）
    images-stream POST {BASE}/images/generations        （同上，stream=true，SSE 分片返回）
    responses     POST {BASE}/responses                 （Responses API + image_generation 工具）
    chat          POST {BASE}/chat/completions          （gemini-2.5-flash-image 这类在对话里回图的模型）

.PARAMETER Prompt
  图片提示词。

.PARAMETER PromptFile
  从文件读取提示词（UTF-8），避免命令行转义问题。

.PARAMETER Out
  指定输出文件路径（N=1 时生效）。默认写到 -OutDir。

.PARAMETER OutDir
  输出目录，默认当前项目下的 imagegen-output。

.PARAMETER Mode
  auto / images / images-stream / responses / chat，默认 auto。

.PARAMETER Model
  图片模型名，覆盖配置文件里的 MODEL。

.PARAMETER Size
  默认 1024x1024；横版 1536x1024；竖版 1024x1536；也可 auto。

.PARAMETER Quality
  low / medium / high / auto。不传则不发送该字段（兼容性最好）。

.PARAMETER N
  生成数量，默认 1。

.PARAMETER EnvFile
  配置文件路径，默认 %USERPROFILE%\.codex\image2.env。

.PARAMETER ListModels
  只查询 GET {BASE}/models，列出疑似生图模型（不产生费用）。

.PARAMETER Probe
  依次实测各接口形态，遇到第一个成功即停止。会真实产生一次生图调用。

.PARAMETER DryRun
  只打印解析出的配置和请求体，不发任何网络请求（不产生费用）。

.PARAMETER Force
  覆盖已存在的同名输出文件。默认不覆盖，改为追加 -v2 / -v3。

.PARAMETER KeepRaw
  保留原始响应文件并把路径打印出来，便于排错。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File imagegen.ps1 -ListModels

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File imagegen.ps1 -Prompt "极简蓝色闪电图标，纯白背景" -Size 1024x1024
#>
[CmdletBinding()]
param(
    [string]$Prompt,
    [string]$PromptFile,
    [string]$Out,
    [string]$OutDir,
    [ValidateSet('auto', 'images', 'images-stream', 'responses', 'chat')]
    [string]$Mode = 'auto',
    [string]$Model,
    [string]$Size = '1024x1024',
    [string]$Quality,
    [int]$N = 1,
    [string]$EnvFile,
    [int]$TimeoutSec = 300,
    [int]$PartialImages = 0,
    [string]$ResponseFormat,
    [switch]$ListModels,
    [switch]$Probe,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$KeepRaw
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- 工具函数

function Write-Info([string]$Message) { Write-Host $Message }

# 用户可见的错误：打印干净的一行提示后退出，不抛 PowerShell 堆栈
function Fail([string]$Message) {
    Write-Host ''
    Write-Host "[错误] $Message"
    exit 1
}

function Get-ConfigValue {
    param($Table, [string[]]$Keys)
    foreach ($k in $Keys) {
        if ($Table -and $Table.ContainsKey($k)) {
            $v = [string]$Table[$k]
            if ($v -and $v.Trim().Length -gt 0) { return $v.Trim() }
        }
    }
    return $null
}

function Get-FirstValue {
    param([object[]]$Values)
    foreach ($v in $Values) {
        if ($null -ne $v) {
            $s = [string]$v
            if ($s.Trim().Length -gt 0) { return $s.Trim() }
        }
    }
    return $null
}

function Read-EnvFile {
    param([string]$Path)
    $table = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $table }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding UTF8)) {
        $t = $line.Trim()
        if ($t.Length -eq 0) { continue }
        if ($t.StartsWith('#')) { continue }
        $idx = $t.IndexOf('=')
        if ($idx -lt 1) { continue }
        $key = $t.Substring(0, $idx).Trim()
        $val = $t.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $table[$key] = $val
    }
    return $table
}

# 把非 ASCII 字符转成 \uXXXX，保证 JSON 以纯 ASCII 落盘，PS 5.1 下不会出现编码错乱
function ConvertTo-AsciiJson {
    param([string]$Text)
    return [regex]::Replace($Text, '[^\u0000-\u007F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function Normalize-BaseUrl {
    param([string]$Url)
    $u = $Url.Trim().TrimEnd('/')
    if ($u -notmatch '/v\d+$') { $u = "$u/v1" }
    return $u
}

function ConvertTo-ImageExt {
    param([string]$Kind)
    switch ($Kind.ToLower()) {
        'png' { return 'png' }
        'jpeg' { return 'jpg' }
        'jpg' { return 'jpg' }
        'webp' { return 'webp' }
        'gif' { return 'gif' }
        default { return 'png' }
    }
}

# 递归收集响应里所有可能的图片载荷（兼容 Images / Responses / Chat 三种形态）
function Add-ImageCandidate {
    param([string]$Key, $Value, $Acc)
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^data:image/([a-zA-Z0-9.+-]+);base64,(.+)$') {
            [void]$Acc.Add([pscustomobject]@{ Kind = 'b64'; B64 = $Matches[2]; Ext = (ConvertTo-ImageExt $Matches[1]) })
            return
        }
        if ($Key -match '^(b64_json|partial_image_b64|result|image_base64|b64|image)$' -and $s.Length -ge 64 -and $s -match '^[A-Za-z0-9+/=\r\n]+$') {
            [void]$Acc.Add([pscustomobject]@{ Kind = 'b64'; B64 = $s; Ext = 'png' })
            return
        }
        if ($Key -match '^(url|image_url|imageUrl)$' -and $s -match '^https?://') {
            [void]$Acc.Add([pscustomobject]@{ Kind = 'url'; Url = $s; Ext = $null })
            return
        }
        return
    }
    Get-JsonNodeImages -Node $Value -Acc $Acc
}

function Get-JsonNodeImages {
    param($Node, $Acc)
    if ($null -eq $Node) { return }
    if ($Node -is [string]) { return }
    if ($Node -is [bool] -or $Node -is [int] -or $Node -is [long] -or $Node -is [double] -or $Node -is [decimal]) { return }

    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($k in @($Node.Keys)) { Add-ImageCandidate -Key ([string]$k) -Value $Node[$k] -Acc $Acc }
        return
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) { Add-ImageCandidate -Key $p.Name -Value $p.Value -Acc $Acc }
        return
    }
    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { Get-JsonNodeImages -Node $item -Acc $Acc }
        return
    }
}

function Get-BodyImages {
    param([string]$Body)
    $acc = New-Object System.Collections.ArrayList
    if (-not $Body -or $Body.Trim().Length -eq 0) { return $acc }

    $text = $Body.Trim()

    # SSE（stream=true）响应：一行行 data: {...}
    if ($text -match '(?m)^\s*(data|event):') {
        foreach ($line in ($text -split "`n")) {
            $t = $line.Trim()
            if (-not $t.StartsWith('data:')) { continue }
            $payload = $t.Substring(5).Trim()
            if ($payload.Length -eq 0 -or $payload -eq '[DONE]') { continue }
            try { $obj = $payload | ConvertFrom-Json } catch { continue }
            Get-JsonNodeImages -Node $obj -Acc $acc
        }
        if ($acc.Count -gt 0) { return $acc }
    }

    try { $obj = $text | ConvertFrom-Json } catch { return $acc }
    Get-JsonNodeImages -Node $obj -Acc $acc
    return $acc
}

function Get-UniqueImages {
    param($Items)
    $seen = @{}
    $result = New-Object System.Collections.ArrayList
    foreach ($it in $Items) {
        $fingerprint = if ($it.Kind -eq 'b64') { $it.B64.Substring(0, [Math]::Min(96, $it.B64.Length)) } else { $it.Url }
        if ($seen.ContainsKey($fingerprint)) { continue }
        $seen[$fingerprint] = $true
        [void]$result.Add($it)
    }
    return $result
}

function Invoke-RelayJson {
    param([string]$Method, [string]$Url, [string]$JsonBody, [int]$TimeoutSec)
    $tmp = Join-Path $env:TEMP ('image2-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $respPath = Join-Path $tmp 'response.txt'
    $errPath = Join-Path $tmp 'curl.err'
    $curlArgs = @('-sS', '--max-time', "$TimeoutSec", '-X', $Method, $Url,
        '-H', 'Accept: application/json, text/event-stream')
    if ($JsonBody) {
        $payloadPath = Join-Path $tmp 'payload.json'
        Set-Content -LiteralPath $payloadPath -Value (ConvertTo-AsciiJson $JsonBody) -Encoding ASCII -NoNewline
        $curlArgs += @('-H', 'Content-Type: application/json', '--data-binary', "@$payloadPath")
    }
    if ($script:ApiKey) { $curlArgs += @('-H', "Authorization: Bearer $($script:ApiKey)") }
    $curlArgs += @('-o', $respPath, '-w', '%{http_code}')

    $statusText = ''
    $exit = 0
    # curl 把网络错误写到 stderr；在 $ErrorActionPreference='Stop' 下这会被 PowerShell
    # 当成终止性异常抛出（exit code 还会变成 -1），所以这里临时放宽再取真实退出码。
    $eapPrev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $statusText = (& curl.exe @curlArgs 2>$errPath | Out-String).Trim()
        $exit = $LASTEXITCODE
    }
    catch {
        $statusText = ''
        $exit = -1
    }
    finally {
        $ErrorActionPreference = $eapPrev
    }

    $body = ''
    if (Test-Path -LiteralPath $respPath) {
        $body = Get-Content -LiteralPath $respPath -Raw -Encoding UTF8
        if ($null -eq $body) { $body = '' }
    }
    $errText = ''
    if (Test-Path -LiteralPath $errPath) {
        $errText = (Get-Content -LiteralPath $errPath -Raw -Encoding UTF8)
        if ($null -eq $errText) { $errText = '' }
    }
    if ($null -eq $statusText) { $statusText = '' }

    $status = 0
    if ($statusText -match '^\d{3}$') { $status = [int]$statusText }

    return [pscustomobject]@{
        Status  = $status
        Body    = $body
        Stderr  = $errText
        Exit    = $exit
        TmpDir  = $tmp
        RawPath = $respPath
    }
}

function Show-ResponseHint {
    param($Response, [int]$Chars = 400)
    if ($Response.Status -gt 0) { Write-Info ("  HTTP {0}" -f $Response.Status) }
    elseif ($Response.Exit -ne 0) {
        $err = [string]$Response.Stderr
        if ($err -match 'curl:\s*\((\d+)\)\s*([^\r\n]*)') { $err = "curl: ($($Matches[1])) $($Matches[2])" }
        $hint = ''
        switch ($Response.Exit) {
            6 { $hint = '（域名解析不了：BASE_URL 写错了或该域名不通）' }
            7 { $hint = '（连不上：端口/网络/代理问题）' }
            28 { $hint = '（超时：生图慢或该站被墙，可试 -Mode images-stream）' }
            35 { $hint = '（TLS 握手失败：可能被中间设备拦截）' }
            60 { $hint = '（证书校验失败：该站证书有问题）' }
        }
        Write-Info ("  curl 退出码 {0}{1} {2}" -f $Response.Exit, $hint, $err.Trim())
    }
    $snippet = $Response.Body
    if ($snippet -and $snippet.Length -gt $Chars) { $snippet = $snippet.Substring(0, $Chars) + '...' }
    if ($snippet) { Write-Info ("  响应片段: " + ($snippet -replace '\s+', ' ')) }
}

function Get-SafePath {
    param([string]$Path, [switch]$Force)
    if ($Force -or -not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = Split-Path -Parent $Path
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [System.IO.Path]::GetExtension($Path)
    for ($i = 2; $i -lt 100; $i++) {
        $candidate = Join-Path $dir ("{0}-v{1}{2}" -f $base, $i, $ext)
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    return $Path
}

function Save-ImageItems {
    param($Items, [string]$TargetPath, [string]$TargetDir, [string]$ModelName, [switch]$Force)
    $saved = New-Object System.Collections.ArrayList
    $stamp = [datetime]::Now.ToString('yyyyMMdd-HHmmss')
    $dir = $TargetDir
    if (-not $dir -and $TargetPath) { $dir = Split-Path -Parent $TargetPath }
    if (-not $dir) { $dir = (Get-Location).Path }
    try { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    catch {
        Fail "输出目录无法写入: $dir`n原因: $($_.Exception.Message)`n如果是 Codex 沙箱阻止的，请改用一个位于当前项目里的目录，或在 ~/.codex/config.toml 里加：`n  [sandbox_workspace_write]`n  writable_roots = [`"$dir`"]"
    }

    $index = 0
    foreach ($it in $Items) {
        $index++
        $ext = if ($it.Ext) { $it.Ext } else { 'png' }
        if ($TargetPath -and $Items.Count -eq 1) {
            $path = $TargetPath
            $parent = Split-Path -Parent $path
            if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        }
        else {
            $safeModel = ($ModelName -replace '[^A-Za-z0-9._-]', '-')
            if (-not $safeModel) { $safeModel = 'image' }
            $path = Join-Path $dir ("{0}-{1}-{2:00}.{3}" -f $safeModel, $stamp, $index, $ext)
        }
        $path = Get-SafePath -Path $path -Force:$Force

        if ($it.Kind -eq 'b64') {
            $bytes = [Convert]::FromBase64String($it.B64)
            try { [System.IO.File]::WriteAllBytes($path, $bytes) }
            catch { Fail "图片写入失败: $path`n原因: $($_.Exception.Message)" }
            [void]$saved.Add($path)
        }
        else {
            $dl = Invoke-RelayJson -Method 'GET' -Url $it.Url -JsonBody $null -TimeoutSec $script:Timeout
            if ($dl.Status -ge 200 -and $dl.Status -lt 300 -and (Test-Path -LiteralPath $dl.RawPath)) {
                if (-not $it.Ext) {
                    $urlPath = ([uri]$it.Url).AbsolutePath
                    $urlExt = [System.IO.Path]::GetExtension($urlPath).TrimStart('.').ToLower()
                    if ($urlExt -in @('png', 'jpg', 'jpeg', 'webp', 'gif')) {
                        $ext = ConvertTo-ImageExt $urlExt
                        $path = [System.IO.Path]::ChangeExtension($path, $ext)
                    }
                }
                Copy-Item -LiteralPath $dl.RawPath -Destination $path -Force
                [void]$saved.Add($path)
            }
            else {
                Write-Info ("  警告: 图片 URL 下载失败 ($($it.Url))")
                Show-ResponseHint -Response $dl
            }
        }
    }
    return $saved
}

# ---------------------------------------------------------------- 读取配置

if (-not $EnvFile -or $EnvFile.Trim().Length -eq 0) {
    if ($env:IMAGEGEN_ENV_FILE) { $EnvFile = $env:IMAGEGEN_ENV_FILE }
    else { $EnvFile = Join-Path $env:USERPROFILE '.codex\image2.env' }
}
if (-not (Test-Path -LiteralPath $EnvFile)) {
    if ($ListModels -or $Probe -or $DryRun) {
        Write-Info "提示: 配置文件不存在 → $EnvFile"
    }
    else {
        Fail "找不到配置文件: $EnvFile`n先复制模板并填入你自己的图片站信息：`n  Copy-Item '$PSScriptRoot\..\image2.env.example' '$EnvFile'`n  notepad '$EnvFile'"
    }
}
$cfg = Read-EnvFile -Path $EnvFile

$cfgBase = Get-FirstValue @($env:IMAGEGEN_BASE_URL, (Get-ConfigValue $cfg @('BASE_URL', 'URL')))
if (-not $cfgBase) {
    if ($DryRun) { $cfgBase = '(未设置: 请在配置文件里写 BASE_URL=...)' }
    else {
        Fail "缺少 BASE_URL。请在 $EnvFile 里写：`n  BASE_URL=https://你的图片站域名/v1`n（这是图片站地址，不要用聊天中转站的地址）"
    }
}
$baseUrl = Normalize-BaseUrl $cfgBase
$script:ApiKey = Get-FirstValue @($env:IMAGEGEN_API_KEY, (Get-ConfigValue $cfg @('API_KEY', 'KEY')))

$model = Get-FirstValue @($Model, $env:IMAGEGEN_MODEL, (Get-ConfigValue $cfg @('MODEL')), 'gpt-image-1')
$chatModel = Get-FirstValue @($env:IMAGEGEN_CHAT_MODEL, (Get-ConfigValue $cfg @('CHAT_MODEL')))
$responsesModel = Get-FirstValue @($env:IMAGEGEN_RESPONSES_MODEL, (Get-ConfigValue $cfg @('RESPONSES_MODEL')), $chatModel, 'gpt-5.1')
$configuredMode = Get-FirstValue @($env:IMAGEGEN_MODE, (Get-ConfigValue $cfg @('MODE')))
if ($Mode -eq 'auto' -and $configuredMode) { $Mode = $configuredMode.ToLower() }
if (-not $OutDir -or $OutDir.Trim().Length -eq 0) {
    # 默认写到当前工作目录下的 imagegen-output：
    # Codex 的 workspace-write 沙箱只允许写工作区内部，写 C:\Users\...\Pictures 会被拒绝。
    $defaultOut = Join-Path (Get-Location).Path 'imagegen-output'
    $OutDir = Get-FirstValue @($env:IMAGEGEN_OUT_DIR, (Get-ConfigValue $cfg @('OUT_DIR')), $defaultOut)
}
$script:Timeout = $TimeoutSec

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile)) { Fail "找不到提示词文件: $PromptFile" }
    $Prompt = (Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8).Trim()
}

if (-not $script:ApiKey -and -not $DryRun) {
    Fail "缺少 API_KEY。请在 $EnvFile 里写 API_KEY=...，或设置环境变量 IMAGEGEN_API_KEY。"
}

# ---------------------------------------------------------------- 反查模型列表

if ($ListModels) {
    Write-Info "GET $baseUrl/models  (配置文件: $EnvFile)"
    $r = Invoke-RelayJson -Method 'GET' -Url "$baseUrl/models" -JsonBody $null -TimeoutSec $TimeoutSec
    if ($r.Status -lt 200 -or $r.Status -ge 300) {
        Write-Info "查询失败。"
        Show-ResponseHint -Response $r
        exit 1
    }
    try { $models = ($r.Body | ConvertFrom-Json).data } catch { $models = $null }
    if (-not $models) {
        Show-ResponseHint -Response $r
        exit 1
    }
    $ids = @($models | ForEach-Object { $_.id })
    Write-Info ("共 {0} 个模型。疑似生图模型：" -f $ids.Count)
    $imageIds = $ids | Where-Object { $_ -match '(?i)image|dall|flux|seedream|sd[-_]?[0-9]|stable|midjourney|mj|kolors|hunyuan|qwen-image|grok.*image|imagen|nano-banana|banana|ideogram|recraft|gpt-4o-image|glm-image|cogview|kling|doubao.*seed' }
    if ($imageIds) { $imageIds | Sort-Object -Unique | ForEach-Object { Write-Info "  $_" } }
    else {
        Write-Info "  （没有匹配到明显的生图模型名，可把全部模型名复制出来人工确认）"
        $ids | Sort-Object -Unique | Select-Object -First 60 | ForEach-Object { Write-Info "  $_" }
    }
    if ($r.TmpDir -and -not $KeepRaw) { Remove-Item -LiteralPath $r.TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

# ---------------------------------------------------------------- 组装请求

function New-ImagesPayload {
    param([string]$ModelName, [string]$PromptText, [string]$SizeValue, [string]$QualityValue, [int]$Count, [bool]$Stream)
    $body = [ordered]@{
        model  = $ModelName
        prompt = $PromptText
        n      = $Count
        size   = $SizeValue
    }
    if ($QualityValue) { $body['quality'] = $QualityValue }
    if ($Stream) {
        $body['stream'] = $true
        if ($PartialImages -gt 0) { $body['partial_images'] = $PartialImages }
    }
    $rf = $ResponseFormat
    if (-not $rf -and $ModelName -match '(?i)^dall-e') { $rf = 'b64_json' }
    if ($rf) { $body['response_format'] = $rf }
    return ($body | ConvertTo-Json -Depth 8 -Compress)
}

function New-ResponsesPayload {
    param([string]$ModelName, [string]$PromptText, [string]$SizeValue, [string]$QualityValue)
    $tool = [ordered]@{ type = 'image_generation'; action = 'generate'; size = $SizeValue }
    if ($QualityValue) { $tool['quality'] = $QualityValue }
    $body = [ordered]@{
        model       = $ModelName
        input       = $PromptText
        tools       = @($tool)
        tool_choice = @{ type = 'image_generation' }
        stream      = $true
    }
    return ($body | ConvertTo-Json -Depth 8 -Compress)
}

function New-ChatPayload {
    param([string]$ModelName, [string]$PromptText)
    $body = [ordered]@{
        model    = $ModelName
        messages = @(@{ role = 'user'; content = $PromptText })
        stream   = $false
    }
    return ($body | ConvertTo-Json -Depth 8 -Compress)
}

$plan = @()
if ($Mode -eq 'auto') {
    $plan = @('images', 'images-stream')
    if ($responsesModel) { $plan += 'responses' }
    if ($chatModel) { $plan += 'chat' }
}
else { $plan = @($Mode) }
if ($PartialImages -le 0) { $PartialImages = 1 }

# ---------------------------------------------------------------- DryRun

if ($DryRun) {
    Write-Info "配置文件   : $EnvFile"
    Write-Info "BASE_URL   : $baseUrl"
    Write-Info "API_KEY    : $(if ($script:ApiKey) { '(已读取，内容隐藏)' } else { '(未设置)' })"
    Write-Info "MODEL      : $model"
    Write-Info "CHAT_MODEL : $(if ($chatModel) { $chatModel } else { '(未设置，chat 模式会跳过)' })"
    Write-Info "RESP_MODEL : $responsesModel"
    Write-Info "OUT_DIR    : $OutDir"
    Write-Info "计划模式   : $($plan -join ' -> ')"
    foreach ($m in $plan) {
        $json = switch ($m) {
            'images' { New-ImagesPayload -ModelName $model -PromptText $Prompt -SizeValue $Size -QualityValue $Quality -Count $N -Stream $false }
            'images-stream' { New-ImagesPayload -ModelName $model -PromptText $Prompt -SizeValue $Size -QualityValue $Quality -Count $N -Stream $true }
            'responses' { New-ResponsesPayload -ModelName $responsesModel -PromptText $Prompt -SizeValue $Size -QualityValue $Quality }
            'chat' { New-ChatPayload -ModelName $chatModel -PromptText $Prompt }
        }
        Write-Info ""
        $endpoint = switch ($m) {
            'images' { "$baseUrl/images/generations" }
            'images-stream' { "$baseUrl/images/generations" }
            'responses' { "$baseUrl/responses" }
            'chat' { "$baseUrl/chat/completions" }
        }
        Write-Info "[$m] POST $endpoint"
        Write-Info $json
    }
    exit 0
}

if (-not $Prompt -or $Prompt.Trim().Length -eq 0) {
    Fail '缺少提示词。用 -Prompt "..." 或 -PromptFile <文件> 传入。'
}

# ---------------------------------------------------------------- 正式调用

$attemptModes = $plan
if ($Probe) {
    Write-Info "== 先查可用模型 =="
    $r0 = Invoke-RelayJson -Method 'GET' -Url "$baseUrl/models" -JsonBody $null -TimeoutSec $TimeoutSec
    if ($r0.Status -ge 200 -and $r0.Status -lt 300) {
        try {
            $ids = @((($r0.Body | ConvertFrom-Json).data) | ForEach-Object { $_.id })
            $imageIds = $ids | Where-Object { $_ -match '(?i)image|dall|flux|seedream|banana|imagen|qwen-image|cogview|glm-image|kolors|ideogram' }
            Write-Info ("  模型总数 {0}；疑似生图模型: {1}" -f $ids.Count, (($imageIds | Sort-Object -Unique) -join ', '))
        }
        catch { Write-Info "  /models 返回无法解析（不影响生图）" }
    }
    else {
        Write-Info "  GET /models 不可用（部分中转站关闭了该接口，不影响生图）"
        Show-ResponseHint -Response $r0 -Chars 200
    }
    if (-not $KeepRaw -and $r0.TmpDir) { Remove-Item -LiteralPath $r0.TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    Write-Info ""
    Write-Info "== 依次实测各接口形态（每次失败最多产生 1 次调用）=="
}

$saved = $null
$usedMode = $null
$keepTmp = @()

foreach ($m in $attemptModes) {
    if ($m -eq 'chat' -and -not $chatModel) { continue }
    Write-Info "-> 尝试模式: $m"

    switch ($m) {
        'images' {
            $url = "$baseUrl/images/generations"
            $json = New-ImagesPayload -ModelName $model -PromptText $Prompt -SizeValue $Size -QualityValue $Quality -Count $N -Stream $false
        }
        'images-stream' {
            $url = "$baseUrl/images/generations"
            $json = New-ImagesPayload -ModelName $model -PromptText $Prompt -SizeValue $Size -QualityValue $Quality -Count $N -Stream $true
        }
        'responses' {
            $url = "$baseUrl/responses"
            $json = New-ResponsesPayload -ModelName $responsesModel -PromptText $Prompt -SizeValue $Size -QualityValue $Quality
        }
        'chat' {
            $url = "$baseUrl/chat/completions"
            $json = New-ChatPayload -ModelName $chatModel -PromptText $Prompt
        }
    }

    if ($m -eq 'images-stream' -and $PartialImages -le 0) { $PartialImages = 1 }

    $r = Invoke-RelayJson -Method 'POST' -Url $url -JsonBody $json -TimeoutSec $TimeoutSec
    $items = @(Get-BodyImages -Body $r.Body)
    $items = @(Get-UniqueImages -Items $items)

    if ($items.Count -eq 0) {
        Show-ResponseHint -Response $r
        if ($KeepRaw -and $r.TmpDir) { $keepTmp += $r.TmpDir }
        elseif ($r.TmpDir) { Remove-Item -LiteralPath $r.TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
        continue
    }

    if ($items.Count -gt $N) { $items = @($items | Select-Object -Last $N) }
    Write-Info ("  收到 {0} 张图片，开始保存" -f $items.Count)
    $saved = Save-ImageItems -Items $items -TargetPath $Out -TargetDir $OutDir -ModelName $model -Force:$Force
    $usedMode = $m
    if ($KeepRaw -and $r.TmpDir) { $keepTmp += $r.TmpDir }
    elseif ($r.TmpDir) { Remove-Item -LiteralPath $r.TmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    break
}

if (-not $saved -or $saved.Count -eq 0) {
    Write-Info ""
    Write-Info "全部模式都失败了，请按下面顺序排查："
    Write-Info "  1. $EnvFile 里的 BASE_URL 是否写到 /v1 为止（例: https://your-relay.com/v1）"
    Write-Info "  2. API_KEY 是否是该图片站的 key（聊天 key 和图片 key 是分开的）"
    Write-Info "  3. MODEL 名是否该站真实存在：用 -ListModels 查"
    Write-Info "  4. 该站是否支持 /images/generations；不支持就试 -Mode responses 或 -Mode chat -Model <对话生图模型>"
    Write-Info "  5. 加 -KeepRaw 保留原始响应，或加 -DryRun 检查请求体"
    exit 1
}

Write-Info ""
Write-Info "成功（模式: $usedMode）"
foreach ($p in $saved) {
    $full = (Resolve-Path -LiteralPath $p).Path
    Write-Info "SAVED: $full"
    Write-Info ("PREVIEW: " + ($full -replace '\\', '/'))
}
if ($keepTmp.Count -gt 0) { Write-Info ("原始响应: " + ($keepTmp -join ', ')) }
exit 0
