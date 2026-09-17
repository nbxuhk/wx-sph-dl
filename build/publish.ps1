# Publish this project to GitHub (public) and attach release assets.
# Requires the GitHub CLI (build\install-gh.ps1) to be authenticated: gh auth status.
#
# Note: ErrorActionPreference stays 'Continue' on purpose. In PowerShell 5.1 a native
# command that writes to stderr raises a terminating error when the preference is 'Stop'
# (e.g. `gh repo view <missing repo>` would abort the script instead of returning a code),
# so every external call is checked via $LASTEXITCODE instead.
# ASCII only.
param(
  [string]$Tool = '',
  [Parameter(Mandatory = $true)][string]$Repo,          # e.g. <owner>/<name>
  [string]$Tag = '',
  [string]$Version = '1.1.0',
  [switch]$SkipPush
)
$ErrorActionPreference = 'Continue'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if ($Tag -eq '') { $Tag = 'v' + $Version }

function Fail([string]$Message) { Write-Output ('PUBLISH-FAIL ' + $Message); exit 1 }

$gh = Join-Path $env:LOCALAPPDATA 'Programs\gh\bin\gh.exe'
if (-not (Test-Path $gh)) { $gh = (Get-Command gh -ErrorAction SilentlyContinue).Source }
if (-not $gh) { Fail 'gh.exe not found: run build\install-gh.ps1 first' }

& $gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Fail 'gh is not authenticated (gh auth status)' }

# ---- 1. portable release artifact (re-zipped from the current build output) ----
$portDir = Join-Path $Tool 'dist\wx-sph-dl-portable'
if (-not (Test-Path $portDir)) { Fail ('portable build missing: ' + $portDir + ' (run build.ps1 -Portable)') }
$zip = Join-Path $Tool ('dist\wx-sph-dl-portable-' + $Version + '.zip')
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $portDir '*') -DestinationPath $zip -Force
Write-Output ('artifact: ' + $zip + '  (' + [math]::Round((Get-Item $zip).Length / 1MB, 1) + ' MB)')

# ---- 2. single-file exe ----
$exe = Join-Path $Tool 'dist\wx-sph-dl.exe'
if (-not (Test-Path $exe)) { Fail ('single-file build missing: ' + $exe) }
Write-Output ('artifact: ' + $exe + '  (' + [math]::Round((Get-Item $exe).Length / 1MB, 1) + ' MB)')

# ---- 3. repository ----
& $gh repo view $Repo *> $null
$exists = ($LASTEXITCODE -eq 0)
if ($exists) {
  Write-Output ('repo exists: ' + $Repo)
} else {
  Write-Output ('creating public repo: ' + $Repo)
  & $gh repo create $Repo --public --description 'WeChat Channels (shipin hao) video downloader: local MITM + in-memory keystream recovery, with a portable Windows GUI'
  if ($LASTEXITCODE -ne 0) { Fail 'gh repo create failed' }
}

# ---- 4. remote + push (SSH: no token in the remote URL) ----
$remote = 'git@github.com:' + $Repo + '.git'
$existing = (& git -C $Tool remote get-url origin 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $existing) {
  & git -C $Tool remote add origin $remote
} elseif ($existing -ne $remote) {
  & git -C $Tool remote set-url origin $remote
}
if ($SkipPush) {
  Write-Output 'SkipPush: not pushing'
} else {
  Write-Output ('pushing main -> ' + $remote)
  & git -C $Tool push -u origin main
  if ($LASTEXITCODE -ne 0) { Fail 'git push failed' }
}

# ---- 5. release with assets ----
if (-not $SkipPush) {
  $notes = Join-Path $Tool 'docs\CHANGELOG.md'
  Write-Output ('creating release ' + $Tag)
  & $gh release create $Tag --repo $Repo --title $Tag --notes-file $notes $exe $zip
  if ($LASTEXITCODE -ne 0) { Fail ('gh release create failed (does tag ' + $Tag + ' already exist?)') }
  & $gh release view $Tag --repo $Repo
}
Write-Output 'PUBLISH-OK'
# Exit explicitly: callers must be able to trust the status code (a native command writing
# to stderr must not turn a successful publish into a failure).
exit 0
