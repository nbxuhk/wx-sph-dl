# Sync the tool sources into the installed skill directory, then verify by hash.
# The skill is a copy (skill_manage only writes SKILL.md), so keep it byte-identical.
# ASCII only.
param(
  [string]$Tool = '',
  [string]$Skill = ''
)
$ErrorActionPreference = 'Stop'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
if ($Skill -eq '') { $Skill = Join-Path $env:USERPROFILE '.agents\skills\wechat-channels-download' }

$files = @(
  'sph.mjs', 'proxy.mjs', 'records.mjs', 'README.md',
  'ps\win.ps1', 'ps\certs.ps1', 'ps\purge-certs.ps1',
  'build\build.ps1', 'build\sync-skill.ps1', 'gui\WxSphDl.cs', 'gui\icon.ico',
  'tests\mitm-selftest.mjs', 'tests\setup-gate-tests.mjs',
  'tests\cert-collision-tests.ps1', 'tests\parse-check.ps1', 'tests\privacy-scan.ps1',
  'tests\proxy-restore-tests.ps1', 'tests\orphan-proxy-tests.ps1', 'tests\foreign-listener.mjs',
  'tests\fixtures\foreign-proxy\proxy.mjs',
  'tests\remove-root-ca.ps1', 'tests\probe-certs.ps1',
  'tests\diag-ca-overwrite.ps1', 'tests\diag-windows.ps1',
  'tests\capture-gui.ps1', 'tests\screencap.cs'
)

foreach ($f in $files) {
  $src = Join-Path $Tool $f
  if (-not (Test-Path $src)) { throw ('source missing: ' + $src) }
  $dst = Join-Path $Skill ('scripts\' + $f)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item $src $dst -Force
}

$mismatch = 0
foreach ($f in $files) {
  $a = (Get-FileHash (Join-Path $Tool $f) -Algorithm SHA256).Hash
  $b = (Get-FileHash (Join-Path $Skill ('scripts\' + $f)) -Algorithm SHA256).Hash
  if ($a -ne $b) { $mismatch++; Write-Output ('MISMATCH ' + $f) }
}
Write-Output ('synced ' + $files.Count + ' files, mismatches=' + $mismatch)
Write-Output ($(if ($mismatch -eq 0) { 'SKILL-SYNC-OK' } else { 'SKILL-SYNC-FAIL' }))
exit $(if ($mismatch -eq 0) { 0 } else { 1 })
