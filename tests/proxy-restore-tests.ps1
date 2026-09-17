# Regression for proxy restoration (the gap the setup gate tests never covered:
# they only ever run --dry-run or abort, so restoreproxy was never exercised).
#
# Cases:
#   A  backup carries the user's OWN PAC        -> restoreproxy writes it back verbatim
#   B  backup carries an empty AutoConfigURL    -> restoreproxy REMOVES the value
#   C  backup carries a proxy-only config       -> all four fields match the backup
#   D  dropownpac with a RECORDED endpoint      -> removed (setpac records what it installs)
#   E  dropownpac with a foreign PAC            -> left untouched (KEEP)
#   F  dropownpac with a loopback PAC on another port / another path -> KEEP (not ours!)
#   G  saveproxy while a RECORDED pac is set    -> recorded as empty + WARN (never captured
#                                                 as "the user's original")
#   H  saveproxy with a foreign PAC             -> recorded verbatim (no normalization)
#
# Ownership must come from <base>/records/pac-endpoints.json, never from a URL shape:
# http://127.0.0.1:8080/proxy.pac may be the user's own local PAC server.
#
# The live registry is snapshotted first and restored exactly at the end.
# ASCII only. Exit 0 = PROXY-RESTORE-OK.
param(
  [string]$Tool = ''
)
$ErrorActionPreference = 'Continue'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$win = Join-Path $Tool 'ps\win.ps1'
# base dir holds state/; records live in the machine-global dir, redirected here via
# WXSPH_RECORDS so the test stays isolated and touches nothing outside the repo
$Base = Join-Path $Tool 'state-proxytest'
$State = Join-Path $Base 'state'
$Records = Join-Path $Base 'records'
$env:WXSPH_RECORDS = $Records
$failures = 0

function Chk([string]$Label, [bool]$Ok, [string]$Detail = '') {
  Write-Output (($(if ($Ok) { 'OK   ' } else { 'FAIL ' })) + $Label + $(if ($Detail) { '  -- ' + $Detail } else { '' }))
  if (-not $Ok) { $script:failures++ }
}
function Run-Win([string]$Mode, [string[]]$Extra = @()) {
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $win, '-Mode', $Mode, '-State', $State) + $Extra
  $r = & $PS @a 2>&1
  return @{ exit = $LASTEXITCODE; out = ($r -join "`n").Trim() }
}
function Get-Proxy {
  $p = Get-ItemProperty $reg
  $names = @($p.PSObject.Properties.Name)
  return [pscustomobject]@{
    ProxyEnable   = [int]$p.ProxyEnable
    ProxyServer   = [string]$p.ProxyServer
    ProxyOverride = [string]$p.ProxyOverride
    AutoConfigURL = $(if ($names -contains 'AutoConfigURL') { [string]$p.AutoConfigURL } else { $null })
    HasAutoConfig = ($names -contains 'AutoConfigURL')
  }
}
function Set-Proxy($v) {
  Set-ItemProperty $reg -Name ProxyEnable -Value ([int]$v.ProxyEnable) -Type DWord
  Set-ItemProperty $reg -Name ProxyServer -Value ([string]$v.ProxyServer) -Type String
  Set-ItemProperty $reg -Name ProxyOverride -Value ([string]$v.ProxyOverride) -Type String
  if ($v.HasAutoConfig) { Set-ItemProperty $reg -Name AutoConfigURL -Value ([string]$v.AutoConfigURL) -Type String }
  else { Remove-ItemProperty $reg -Name AutoConfigURL -ErrorAction SilentlyContinue }
}
function Write-Backup($obj) {
  New-Item -ItemType Directory -Force -Path $State | Out-Null
  $enc = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText((Join-Path $State 'original-proxy.json'), ($obj | ConvertTo-Json), $enc)
}
function Same($a, $b) {
  return ($a.ProxyEnable -eq $b.ProxyEnable) -and ($a.ProxyServer -eq $b.ProxyServer) -and
         ($a.ProxyOverride -eq $b.ProxyOverride) -and ($a.HasAutoConfig -eq $b.HasAutoConfig) -and
         ((-not $a.HasAutoConfig) -or ($a.AutoConfigURL -eq $b.AutoConfigURL))
}
function Show($v) {
  if ($null -eq $v) { return '(absent)' }
  return ('{Enable=' + $v.ProxyEnable + ' Server=' + $v.ProxyServer + ' AutoConfigURL=' + $(if ($v.HasAutoConfig) { "'" + $v.AutoConfigURL + "'" } else { '(absent)' }) + '}')
}

$original = Get-Proxy
Write-Output ('baseline: ' + (Show $original))
$recordedPac = 'http://127.0.0.1:18080/proxy.pac'
$foreignPac = 'http://pac.corp.example:8080/proxy.pac'
$otherLocalPac = 'http://127.0.0.1:8080/proxy.pac'
$loopbackNoPort = 'http://localhost/proxy.pac'
$samePortOtherPath = 'http://127.0.0.1:18080/other.pac'
if (Test-Path $Base) { Remove-Item $Base -Recurse -Force }

try {
  # ---- A: user's own PAC must be written back verbatim ----
  Write-Backup @{ ProxyEnable = 1; ProxyServer = '127.0.0.1:1080'; ProxyOverride = '<local>'; AutoConfigURL = $foreignPac }
  $r = Run-Win 'restoreproxy'
  $got = Get-Proxy
  Chk 'A restoreproxy succeeds' ($r.exit -eq 0)
  Chk 'A non-empty PAC restored VERBATIM' ($got.AutoConfigURL -eq $foreignPac -and $got.HasAutoConfig) (Show $got)

  # ---- B: empty AutoConfigURL in the backup means "remove the value" ----
  Write-Backup @{ ProxyEnable = 0; ProxyServer = ''; ProxyOverride = '<local>'; AutoConfigURL = '' }
  $r = Run-Win 'restoreproxy'
  $got = Get-Proxy
  Chk 'B restoreproxy succeeds' ($r.exit -eq 0)
  Chk 'B empty PAC removes the value (not an empty string)' (-not $got.HasAutoConfig) (Show $got)

  # ---- C: proxy-only config round-trips all four fields ----
  Write-Backup @{ ProxyEnable = 1; ProxyServer = '127.0.0.1:1080'; ProxyOverride = '<local>;localhost'; AutoConfigURL = '' }
  $r = Run-Win 'restoreproxy'
  $want = [pscustomobject]@{ ProxyEnable = 1; ProxyServer = '127.0.0.1:1080'; ProxyOverride = '<local>;localhost'; AutoConfigURL = $null; HasAutoConfig = $false }
  Chk 'C proxy-only backup restored exactly' (Same (Get-Proxy) $want) (Show (Get-Proxy))

  # ---- D: setpac records the endpoint, then dropownpac removes exactly that one ----
  $r = Run-Win 'setpac' @('-PacUrl', $recordedPac)
  $recFile = Join-Path $Records 'pac-endpoints.json'
  Chk 'D setpac succeeds' ($r.exit -eq 0) $r.out
  Chk 'D setpac records the endpoint in the machine-global dir' (Test-Path $recFile) $recFile
  Chk 'D registry now points at the recorded PAC' ((Get-Proxy).AutoConfigURL -eq $recordedPac)
  $r = Run-Win 'dropownpac'
  $got = Get-Proxy
  Chk 'D dropownpac reports DROPPED' ($r.out -match '^DROPPED') $r.out
  Chk 'D recorded PAC is gone' (-not $got.HasAutoConfig) (Show $got)

  # ---- E: a foreign PAC (no record) must be left alone ----
  Set-ItemProperty $reg -Name AutoConfigURL -Value $foreignPac -Type String
  $r = Run-Win 'dropownpac'
  $got = Get-Proxy
  Chk 'E dropownpac reports KEEP' ($r.out -match '^KEEP') $r.out
  Chk 'E foreign PAC untouched' ($got.HasAutoConfig -and $got.AutoConfigURL -eq $foreignPac) (Show $got)

  # ---- F: loopback PACs that we never installed must NOT be treated as ours ----
  foreach ($u in @($otherLocalPac, $loopbackNoPort, $samePortOtherPath)) {
    Set-ItemProperty $reg -Name AutoConfigURL -Value $u -Type String
    $r = Run-Win 'dropownpac'
    $got = Get-Proxy
    Chk ("F KEEP loopback PAC we never recorded: " + $u) ($r.out -match '^KEEP' -and $got.HasAutoConfig -and $got.AutoConfigURL -eq $u) ($r.out)
  }

  # ---- G: saveproxy must NOT record a PAC endpoint we installed as the user's original ----
  $r = Run-Win 'setpac' @('-PacUrl', $recordedPac)
  Set-ItemProperty $reg -Name ProxyEnable -Value 1 -Type DWord
  $r = Run-Win 'saveproxy'
  $b = Get-Content (Join-Path $State 'original-proxy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Chk 'G saveproxy succeeds' ($r.exit -eq 0 -and $r.out -match '^SAVED') $r.out
  Chk 'G recorded own PAC stored as empty' ([string]$b.AutoConfigURL -eq '')
  Chk 'G normalization is announced' ($r.out -match 'WARN normalized')

  # ---- H: a foreign PAC is preserved verbatim by saveproxy ----
  Set-ItemProperty $reg -Name AutoConfigURL -Value $foreignPac -Type String
  $r = Run-Win 'saveproxy'
  $b = Get-Content (Join-Path $State 'original-proxy.json') -Raw -Encoding UTF8 | ConvertFrom-Json
  Chk 'H foreign PAC preserved verbatim' ([string]$b.AutoConfigURL -eq $foreignPac) ([string]$b.AutoConfigURL)
  Chk 'H no normalization warning' (-not ($r.out -match 'WARN normalized'))
}
finally {
  # Always put the live registry back exactly as found.
  Set-Proxy $original
  if (Test-Path $Base) { Remove-Item $Base -Recurse -Force }
}
$final = Get-Proxy
Chk 'registry restored to the baseline snapshot' (Same $final $original) ((Show $original) + ' -> ' + (Show $final))

Write-Output ''
Write-Output ($(if ($failures -eq 0) { 'PROXY-RESTORE-OK' } else { 'PROXY-RESTORE-FAIL (' + $failures + ')' }))
exit $(if ($failures -eq 0) { 0 } else { 1 })
