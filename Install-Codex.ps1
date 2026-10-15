[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    throw 'Codex CLI is required. Install it and ensure codex is on PATH, then run this installer again.'
}
& codex plugin marketplace add $PSScriptRoot
if ($LASTEXITCODE -ne 0) { throw 'Could not register the local image2 marketplace.' }
& codex plugin add image2@image2-local
if ($LASTEXITCODE -ne 0) { throw 'Could not install image2.' }
Write-Output 'image2 installed. Restart Codex or start a new chat to discover the skills.'
Write-Output 'Configure the image relay using plugins/image2/scripts/Configure.ps1, or ask Codex to configure image2.'
