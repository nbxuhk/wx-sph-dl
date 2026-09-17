# Diagnose scenario B: does certs.ps1 -Mode ca really overwrite ca.crt when a stale
# ca.crt/ca.pfx pair already exists in the state dir?
# ASCII only.
$ErrorActionPreference = 'Continue'
$Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$PS = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$A = Join-Path $Tool 'diag-state-a'
$B = Join-Path $Tool 'diag-state-b'

foreach ($d in @($A, $B)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }

Write-Output '--- create state A (its CA stays in the store) ---'
& $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\certs.ps1') -Mode 'ca' -State $A
$idxA = Get-Content (Join-Path $A 'certs\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$thumbA = @($idxA)[0].thumbprint
Write-Output ('A thumb=' + $thumbA)

Write-Output '--- build state B carrying A''s stale pfx/crt/pass (no index, no catag) ---'
New-Item -ItemType Directory -Force -Path (Join-Path $B 'certs') | Out-Null
Copy-Item (Join-Path $A 'certs\ca.pfx') (Join-Path $B 'certs\ca.pfx') -Force
Copy-Item (Join-Path $A 'certs\ca.crt') (Join-Path $B 'certs\ca.crt') -Force
Copy-Item (Join-Path $A 'certs\pass.txt') (Join-Path $B 'certs\pass.txt') -Force
$crtBefore = Get-FileHash (Join-Path $B 'certs\ca.crt') -Algorithm SHA256
Write-Output ('B ca.crt sha256 before = ' + $crtBefore.Hash)
Write-Output ('B files before: ' + ((Get-ChildItem (Join-Path $B 'certs') | ForEach-Object { $_.Name }) -join ', '))

Write-Output '--- remove A''s CA from the store, then run ca in B ---'
Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $thumbA } | ForEach-Object {
  Remove-Item -Path ('Cert:\CurrentUser\My\' + $_.Thumbprint) -Force
}
& $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\certs.ps1') -Mode 'ca' -State $B
$crtAfter = Get-FileHash (Join-Path $B 'certs\ca.crt') -Algorithm SHA256
Write-Output ('B ca.crt sha256 after  = ' + $crtAfter.Hash)
Write-Output ('ca.crt changed = ' + ($crtBefore.Hash -ne $crtAfter.Hash))

Write-Output '--- B index.json ---'
if (Test-Path (Join-Path $B 'certs\index.json')) { Get-Content (Join-Path $B 'certs\index.json') -Raw -Encoding UTF8 } else { Write-Output '(missing)' }
Write-Output '--- B catag.txt ---'
if (Test-Path (Join-Path $B 'certs\catag.txt')) { Get-Content (Join-Path $B 'certs\catag.txt') -Raw -Encoding UTF8 } else { Write-Output '(missing)' }

Write-Output '--- compare: SHA1 of cert inside ca.crt vs the CA the state now owns ---'
$pem = [IO.File]::ReadAllText((Join-Path $B 'certs\ca.crt'))
$b64 = ($pem -replace '-----[A-Z ]+-----', '' -replace '\s', '')
$der = [Convert]::FromBase64String($b64)
$crtCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,$der)
Write-Output ('ca.crt thumb   = ' + $crtCert.Thumbprint + '  subject=' + $crtCert.Subject)
$idxB = Get-Content (Join-Path $B 'certs\index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$thumbB = @($idxB)[0].thumbprint
Write-Output ('index thumb    = ' + $thumbB)
$live = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $thumbB })
Write-Output ('live in My     = ' + $live.Count + $(if ($live.Count) { '  subject=' + $live[0].Subject } else { '' }))
Write-Output ('MATCH ca.crt vs index = ' + ($crtCert.Thumbprint -eq $thumbB))

Write-Output '--- cleanup ---'
foreach ($d in @($A, $B)) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
& $PS -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Tool 'ps\purge-certs.ps1')
Write-Output 'DIAG-B-DONE'
