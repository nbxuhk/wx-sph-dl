# Publish this project to GitHub (public) and attach release assets.
# Requires the GitHub CLI (build\install-gh.ps1) to be authenticated: gh auth status.
# ASCII only.
param(
  [string]$Tool = '',
  [Parameter(Mandatory = $true)][string]$Repo,          # e.g. nbxuhk/wx-sph-dl
  [string]$Tag = '',
  [string]$Version = '1.1.0',
  [switch]$SkipPush
)
$ErrorActionPreference = 'Stop'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if ($Tag -eq '') { $Tag = 'v' + $Version }

$gh = Join-Path $env:LOCALAPPDATA 'Programs\gh\bin\gh.exe'
if (-not (Test-Path $gh)) { $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source }
if (-not $gh) { throw 'gh.exe not found: run build\install-gh.ps1 first' }
& $gh auth status | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated' }

# ---- 1. portable release artifact (re-zipped from the current build output) ----
$portDir = Join-Path $Tool 'dist\wx-sph-dl-portable'
if (-not (Test-Path $portDir)) { throw ('portable build missing: ' + $portDir + ' (run build.ps1 -Portable)') }
$zip = Join-Path $Tool ('dist\wx-sph-dl-portable-' + $Version + '.zip')
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $portDir '*') -DestinationPath $zip -Force
Write-Output ('artifact: ' + $zip + '  (' + [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MB)')

# ---- 2. single-file exe ----
$exe = Join-Path $Tool 'dist\wx-sph-dl.exe'
if (-not (Test-Path $exe)) { throw ('single-file build missing: ' + $exe) }
Write-Output ('artifact: ' + $exe + '  (' + [math]::Round((Get-Item $exe).Length / 1MB, 1) + ' MB)')

# ---- 3. repository ----
$exists = $true
& $gh repo view $Repo 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { $exists = $false }
if ($exists) {
  Write-Output ('repo exists: ' + $Repo)
} else {
  Write-Output ('creating public repo: ' + $Repo)
  & $gh repo create $Repo --public --description 'WeChat Channels (视频号) video downloader: local MITM + in-memory keystream recovery, plus a portable Windows GUI'
  if ($LASTEXITCODE -ne 0) { throw 'gh repo create failed' }
}

# ---- 4. remote + push (SSH: no token in the remote URL) ----
$remote = 'git@github.com:' + $Repo + '.git'
$existing = (& git -C $Tool remote get-url origin 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $existing) {
  & git -C $Tool remote add origin $remote
} elseif ($existing -ne $remote) {
  & git -C $Tool remote set-url origin $remote
}
if (-not $SkipPush) {
  Write-Output ('pushing main -> ' + $remote)
  & git -C $Tool push -u origin main
  if ($LASTEXITCODE -ne 0) { throw 'git push failed' }
} else {
  Write-Output 'SkipPush: not pushing'
}

# ---- 5. release with assets ----
if (-not $SkipPush) {
  $notes = Join-Path $Tool 'docs\CHANGELOG.md'
  Write-Output ('creating release ' + $Tag)
  & $gh release create $Tag --repo $Repo --title $Tag --notes-file $notes $exe $zip
  if ($LASTEXITCODE -ne 0) { throw 'gh release create failed (does the tag already exist?)' }
  & $gh release view $Tag --repo $Repo
}
Write-Output 'PUBLISH-OK'
