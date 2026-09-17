# Install a portable GitHub CLI (no elevated rights needed, user scope) for publishing.
# ASCII only.
param(
  [string]$Tool = '',
  [string]$Dest = ''
)
$ErrorActionPreference = 'Stop'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if ($Dest -eq '') { $Dest = Join-Path $env:LOCALAPPDATA 'Programs\gh' }
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw 'node.exe not found' }

& $node (Join-Path $Tool 'build\download-gh.mjs') $Dest
if ($LASTEXITCODE -ne 0) { throw 'download failed' }

$zip = Get-ChildItem $Dest -Filter '*_windows_amd64.zip' | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $zip) { throw 'zip not found in ' + $Dest }
Write-Output ('extracting ' + $zip.Name)
Expand-Archive -Path $zip.FullName -DestinationPath $Dest -Force

$exe = Get-ChildItem $Dest -Recurse -Filter 'gh.exe' | Select-Object -First 1
if (-not $exe) { throw 'gh.exe not found after extract' }
Write-Output ('GH-EXE ' + $exe.FullName)
& $exe.FullName --version
Write-Output ('GH-INSTALL-OK ' + $exe.FullName)
