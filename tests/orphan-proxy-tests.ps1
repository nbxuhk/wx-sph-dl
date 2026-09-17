# Verify cleanup stops an ORPHAN proxy (running with no pid file, holding 127.0.0.1:18080)
# ONLY when ownership is proven, and refuses everything else.
#
# Cases:
#   1 our proxy, no pid file, recorded at start   -> stopped (ORPHAN-STOPPED)
#   2 foreign same-basename proxy.mjs, same port  -> REFUSED (no record, non-canonical path)
#   3 our proxy but its record file is missing    -> REFUSED (legacy/unknown; fail closed)
#   4 unrelated listener (different basename)     -> REFUSED
#
# ASCII only. Exit 0 = ORPHAN-KILL-OK.
param(
  [string]$Tool = ''
)
$ErrorActionPreference = 'Continue'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'node' }
$failures = 0
function Chk([string]$Label, [bool]$Ok, [string]$Detail = '') {
  Write-Output (($(if ($Ok) { 'OK   ' } else { 'FAIL ' })) + $Label + $(if ($Detail) { '  -- ' + $Detail } else { '' }))
  if (-not $Ok) { $script:failures++ }
}
function Port-Busy([int]$Port) {
  return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}
function Wait-Busy([int]$Port, [int]$Tries = 40) {
  foreach ($i in 1..$Tries) { if (Port-Busy $Port) { return $true }; Start-Sleep -Milliseconds 250 }
  return $false
}
function Wait-Free([int]$Port, [int]$Tries = 40) {
  foreach ($i in 1..$Tries) { if (-not (Port-Busy $Port)) { return $true }; Start-Sleep -Milliseconds 250 }
  return $false
}
function Run-Cleanup {
  return (& $node (Join-Path $Tool 'sph.mjs') cleanup 2>&1 | Out-String)
}
function OrphanLine([string]$Text) {
  return (($Text -split "`n" | Where-Object { $_ -match 'ORPHAN-' }) -join ' / ').Trim()
}

# state dirs live under a throwaway base so nothing touches the repo; the machine-global
# records dir is redirected per case with WXSPH_RECORDS (the child proxy inherits it)
$base1 = Join-Path $Tool 'state-orphan1'
$base2 = Join-Path $Tool 'state-orphan2'
$base3 = Join-Path $Tool 'state-orphan3'
foreach ($b in @($base1, $base2, $base3)) { if (Test-Path $b) { Remove-Item $b -Recurse -Force } }
$env:WXSPH_RECORDS = Join-Path $base1 'records'
$procs = @()

try {
  # ---- case 1: our own proxy, no pid file, with its start record ----
  $log = Join-Path $env:TEMP 'orphan-proxy.log'
  $p1 = Start-Process -FilePath $node -ArgumentList @(
    (Join-Path $Tool 'proxy.mjs'), '--port', '18080', '--state', (Join-Path $base1 'state')
  ) -PassThru -NoNewWindow -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
  $procs += $p1
  Chk 'case1 our proxy is listening on 18080' (Wait-Busy 18080) ('pid=' + $p1.Id)
  $recFile = Join-Path $base1 'records\proxy-registry.json'
  Chk 'case1 start record written in the machine-global records dir' (Test-Path $recFile) $recFile
  Chk 'case1 no pid file' (-not (Test-Path (Join-Path $base1 'state\proxy.pid')))
  $out1 = Run-Cleanup
  Chk 'case1 orphan stopped and port released' (Wait-Free 18080) (OrphanLine $out1)
  Chk 'case1 reported ORPHAN-STOPPED' ($out1 -match 'ORPHAN-STOPPED') (OrphanLine $out1)

  # ---- case 2: another project's proxy.mjs on the same port ----
  $foreign = Join-Path $Tool 'tests\fixtures\foreign-proxy\proxy.mjs'
  $p2 = Start-Process -FilePath $node -ArgumentList @($foreign, '--port', '18080') -PassThru -NoNewWindow
  $procs += $p2
  Chk 'case2 foreign same-basename proxy is listening' (Wait-Busy 18080) ('pid=' + $p2.Id)
  $out2 = Run-Cleanup
  Start-Sleep -Milliseconds 800
  Chk 'case2 cleanup REFUSED to kill it' ($out2 -match 'ORPHAN-REFUSED') (OrphanLine $out2)
  Chk 'case2 foreign process still alive' (-not $p2.HasExited) ('alive=' + (-not $p2.HasExited))
  try { Stop-Process -Id $p2.Id -Force -ErrorAction SilentlyContinue } catch { }
  $null = Wait-Free 18080

  # ---- case 3: our proxy, but its record file is gone (legacy / unknown) ----
  $p3 = Start-Process -FilePath $node -ArgumentList @(
    (Join-Path $Tool 'proxy.mjs'), '--port', '18080', '--state', (Join-Path $base3 'state')
  ) -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $env:TEMP 'orphan3.log') -RedirectStandardError (Join-Path $env:TEMP 'orphan3.err')
  $procs += $p3
  Chk 'case3 our proxy is listening on 18080' (Wait-Busy 18080) ('pid=' + $p3.Id)
  # the registry is machine-global, so remove the record itself (not a per-base file)
  Remove-Item (Join-Path $env:WXSPH_RECORDS 'proxy-registry.json') -Force -ErrorAction SilentlyContinue
  Chk 'case3 start record removed' (-not (Test-Path (Join-Path $env:WXSPH_RECORDS 'proxy-registry.json')))
  $out3 = Run-Cleanup
  Start-Sleep -Milliseconds 800
  Chk 'case3 refused without a start record (fail closed)' ($out3 -match 'ORPHAN-REFUSED') (OrphanLine $out3)
  Chk 'case3 process still alive' (-not $p3.HasExited)
  try { Stop-Process -Id $p3.Id -Force -ErrorAction SilentlyContinue } catch { }
  $null = Wait-Free 18080

  # ---- case 4: unrelated listener with a different basename ----
  $p4 = Start-Process -FilePath $node -ArgumentList @(
    (Join-Path $Tool 'tests\foreign-listener.mjs'), '18080', '30'
  ) -PassThru -NoNewWindow
  $procs += $p4
  Chk 'case4 unrelated listener is listening' (Wait-Busy 18080) ('pid=' + $p4.Id)
  $out4 = Run-Cleanup
  Start-Sleep -Milliseconds 800
  Chk 'case4 refused a foreign listener' ($out4 -match 'ORPHAN-REFUSED') (OrphanLine $out4)
  Chk 'case4 listener still alive' (-not $p4.HasExited)
  try { Stop-Process -Id $p4.Id -Force -ErrorAction SilentlyContinue } catch { }
}
finally {
  foreach ($p in $procs) { try { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force } } catch { } }
  foreach ($b in @($base1, $base2, $base3)) {
    $certDir = Join-Path $b 'state\certs'
    if (Test-Path $certDir) { & $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\certs.ps1') -Mode cleanup -State (Join-Path $b 'state') | Out-Null }
    if (Test-Path $b) { Remove-Item $b -Recurse -Force }
  }
}
& $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\purge-certs.ps1') | Out-Null
if (Wait-Busy 18080 4) { 'port 18080 still busy at exit' }
$left = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like '*DSH Local MITM CA*' -or $_.Issuer -like '*DSH Local MITM CA*' }).Count
Chk 'no tool certs left in My' ($left -eq 0) ('left=' + $left)

Write-Output ''
Write-Output ($(if ($failures -eq 0) { 'ORPHAN-KILL-OK' } else { 'ORPHAN-KILL-FAIL (' + $failures + ')' }))
exit $(if ($failures -eq 0) { 0 } else { 1 })
