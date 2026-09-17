# Regression test for the certificate-chain bug found 2026-09-17:
#   A stale CA with the SAME SUBJECT as the live one made Windows embed the wrong
#   parent in a leaf PFX, so the proxy served a chain that failed with
#   "self-signed certificate in certificate chain" - on the 2nd run, not the 1st.
#   A second trap: proxy.mjs used to trust a bare "ca.pfx exists" test, so a CA that
#   had been purged from the store still looked usable and every leaf after it failed.
#
# Scenario A: a decoy same-subject CA sits in My; two consecutive selftest runs on one
#             state dir must both pass.
# Scenario B: state holds ca.pfx/ca.crt but the CA is no longer in the store (purged)
#             and index.json is gone -> the run must regenerate instead of failing.
#
# ASCII only. Exit 0 = CERTS-REGRESSION-OK.
param(
  [string]$Tool = '',
  [int]$Port = 18096
)
$ErrorActionPreference = 'Continue'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'node' }

$State = Join-Path $Tool 'state-regression'
$Stale = Join-Path $Tool 'state-regression-stale'
$decoy = $null
$failures = 0
function Chk([string]$Label, [bool]$Ok) {
  Write-Output (($(if ($Ok) { 'OK   ' } else { 'FAIL ' })) + $Label)
  if (-not $Ok) { $script:failures++ }
}
function Run-Selftest([string]$Tag, [string[]]$Extra) {
  $log = Join-Path $env:TEMP ('certs-regression-' + $Tag + '.log')
  $err = Join-Path $env:TEMP ('certs-regression-' + $Tag + '.err')
  $a = @((Join-Path $Tool 'tests\mitm-selftest.mjs'), '--state', $State, '--port', "$Port") + $Extra
  $p = Start-Process -FilePath $node -ArgumentList $a -Wait -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError $err
  $text = (Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue) -join "`n"
  Write-Output ('--- selftest ' + $Tag + ' exit=' + $p.ExitCode)
  ($text -split "`n") | Where-Object { $_ -match 'SELFTEST|authorized|HTTP|self-signed|CA ' } | ForEach-Object { Write-Output ('    ' + $_.Trim()) }
  return @{ exit = $p.ExitCode; text = $text }
}

# --- cleanup any leftovers from a previous test run ---
foreach ($s in @($State, $Stale)) { if (Test-Path $s) { Remove-Item $s -Recurse -Force } }
Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
  Where-Object { $_.Subject -like '*DSH Local MITM CA*' -or $_.Issuer -like '*DSH Local MITM CA*' } |
  ForEach-Object { Remove-Item -Path ('Cert:\CurrentUser\My\' + $_.Thumbprint) -Force -ErrorAction SilentlyContinue }

# --- Scenario A: decoy same-subject CA in My ---
$decoy = New-SelfSignedCertificate -Subject 'CN=DSH Local MITM CA' `
  -KeyUsage CertSign, CRLSign -KeyUsageProperty Sign -KeyExportPolicy Exportable `
  -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA -HashAlgorithm SHA256 `
  -NotAfter (Get-Date).AddYears(1) -CertStoreLocation Cert:\CurrentUser\My
Chk ('decoy same-subject CA created: ' + $decoy.Thumbprint) ([bool]$decoy)

$r1 = Run-Selftest 'A-run1' @()
Chk 'A1 first run passes (decoy present)' ($r1.exit -eq 0 -and $r1.text -match 'SELFTEST-OK')
Chk 'A1 served chain is exactly leaf + our CA' ($r1.text -match 'CHAIN depth=2 .*chain-ok=True')

# Second run on the SAME state dir: this is what used to fail.
$r2 = Run-Selftest 'A-run2' @()
Chk 'A2 second run on same state passes' ($r2.exit -eq 0 -and $r2.text -match 'SELFTEST-OK')
Chk 'A2 served chain is exactly leaf + our CA' ($r2.text -match 'CHAIN depth=2 .*chain-ok=True')

# --- Scenario B: pfx present, own CA purged from the store, index.json gone ---
& $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\certs.ps1') -Mode 'ca' -State $Stale | Out-Null
$staleIndex = Get-Content (Join-Path $Stale 'certs\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$staleThumb = @($staleIndex)[0].thumbprint
Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $staleThumb } | ForEach-Object {
  Remove-Item -Path ('Cert:\CurrentUser\My\' + $_.Thumbprint) -Force -ErrorAction SilentlyContinue
}
$gone = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $staleThumb }).Count
Chk 'stale CA removed from store while its pfx survives' ($gone -eq 0)

if (Test-Path $State) { Remove-Item $State -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $State 'certs') | Out-Null
Copy-Item (Join-Path $Stale 'certs\ca.pfx') (Join-Path $State 'certs\ca.pfx') -Force
Copy-Item (Join-Path $Stale 'certs\ca.crt') (Join-Path $State 'certs\ca.crt') -Force
Copy-Item (Join-Path $Stale 'certs\pass.txt') (Join-Path $State 'certs\pass.txt') -Force
$r3 = Run-Selftest 'B' @('--keep-state')
Chk 'B regenerates the CA instead of reusing the purged one' ($r3.exit -eq 0 -and $r3.text -match 'SELFTEST-OK')

# --- cleanup ---
foreach ($s in @($State, $Stale)) { if (Test-Path $s) { Remove-Item $s -Recurse -Force } }
& $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\purge-certs.ps1') | Out-Null
if ($decoy) { Remove-Item -Path ('Cert:\CurrentUser\My\' + $decoy.Thumbprint) -Force -ErrorAction SilentlyContinue }
$left = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -like '*DSH Local MITM CA*' -or $_.Issuer -like '*DSH Local MITM CA*' }).Count
Chk 'no tool certs left in My after cleanup' ($left -eq 0)

Write-Output ''
Write-Output ($(if ($failures -eq 0) { 'CERTS-REGRESSION-OK' } else { 'CERTS-REGRESSION-FAIL (' + $failures + ')' }))
exit $(if ($failures -eq 0) { 0 } else { 1 })
