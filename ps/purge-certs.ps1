# Maintenance helper: remove every cert this tool created (CA + leaves) from the user's
# My and intermediate-CA stores. Use after an interrupted run, or when several
# "DSH Local MITM CA" certs have accumulated and a leaf could be signed by a stale CA.
# The trusted-root copy cannot be removed here (the cert provider refuses to touch the
# user Root store); run "node sph.mjs cleanup" for that, which uses CryptoAPI and asks
# Windows to confirm. ASCII only.
param(
  [switch]$WhatIf,
  [string]$State = ''
)
$ErrorActionPreference = 'Continue'
$Subject = 'DSH Local MITM CA'

function Get-Mine([string]$Store) {
  return @(Get-ChildItem ('Cert:\CurrentUser\' + $Store) -ErrorAction SilentlyContinue | Where-Object {
    $_.Subject -like ('*' + $Subject + '*') -or $_.Issuer -like ('*' + $Subject + '*')
  })
}

$mine = Get-Mine 'My'
$inter = Get-Mine 'CA'
$root = Get-Mine 'Root'

Write-Output ('found: My=' + $mine.Count + ' CA=' + $inter.Count + ' Root=' + $root.Count)
foreach ($p in @(@{ n = 'My'; c = $mine }, @{ n = 'CA'; c = $inter })) {
  foreach ($c in $p.c) {
    Write-Output ('  [' + $p.n + '] ' + $c.Subject + '  ' + $c.Thumbprint + '  (issuer: ' + $c.Issuer + ')')
  }
}
foreach ($c in $root) {
  Write-Output ('  [Root-trusted] ' + $c.Subject + '  ' + $c.Thumbprint + '  <- needs "node sph.mjs cleanup" (CryptoAPI + confirm dialog)')
}

if (-not $WhatIf) {
  foreach ($c in $mine) { Remove-Item -Path ('Cert:\CurrentUser\My\' + $c.Thumbprint) -Force -ErrorAction SilentlyContinue }
  foreach ($c in $inter) { Remove-Item -Path ('Cert:\CurrentUser\CA\' + $c.Thumbprint) -Force -ErrorAction SilentlyContinue }
  if ($State -ne '') {
    Remove-Item (Join-Path $State 'certs\*.pfx') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $State 'certs\index.json') -Force -ErrorAction SilentlyContinue
  }
  $leftMy = (Get-Mine 'My').Count
  $leftCa = (Get-Mine 'CA').Count
  $leftRoot = (Get-Mine 'Root').Count
  Write-Output ('removed: My=' + ($mine.Count - $leftMy) + ' CA=' + ($inter.Count - $leftCa))
  Write-Output ('remaining: My=' + $leftMy + ' CA=' + $leftCa + ' Root=' + $leftRoot)
}
