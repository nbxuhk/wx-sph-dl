# Certificate helper for wx-sph-dl: issues the local MITM CA and per-host leaf certs
# using Windows PKI (New-SelfSignedCertificate), so no openssl.exe is required.
# ASCII only: PowerShell 5.1 reads .ps1 files as ANSI.
#
# Why every state gets its OWN CA subject tag (CN=DSH Local MITM CA <8 hex>):
# when several CAs share one subject, Windows chain building can embed the WRONG
# parent certificate in an exported leaf PFX. The proxy then serves a chain that
# fails on the client with "self-signed certificate in certificate chain" - and it
# fails only sometimes, depending on store enumeration order. A unique subject makes
# the parent unambiguous, and Test-PfxChain below refuses to hand out a PFX whose
# embedded chain is not exactly {leaf + the CA this state owns}.
#
# Modes: check | ca | leaf | cleanup     Exit codes: 0 = ok, 1 = failed/refused
param(
  [Parameter(Mandatory=$true)][string]$Mode,
  [string]$State = '',
  [string]$HostName = ''
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($State)) { $State = Join-Path (Split-Path -Parent $PSScriptRoot) 'state' }
$SubjectBase = 'DSH Local MITM CA'
$CertDir = Join-Path $State 'certs'
$IndexFile = Join-Path $CertDir 'index.json'
$PassFile = Join-Path $CertDir 'pass.txt'
$TagFile = Join-Path $CertDir 'catag.txt'

function Write-TextNoBom([string]$Path, [string]$Text) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Read-TextNoBom([string]$Path) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $t = [System.IO.File]::ReadAllText($Path, $enc)
  if ($t.Length -gt 0 -and [int][char]$t[0] -eq 0xFEFF) { $t = $t.Substring(1) }
  return $t
}

function Get-Index {
  if (-not (Test-Path $IndexFile)) { return @() }
  try {
    $j = (Read-TextNoBom $IndexFile) | ConvertFrom-Json
    return @($j)
  } catch { return @() }
}

function Save-Index($Items) {
  New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
  Write-TextNoBom $IndexFile (($Items | ConvertTo-Json -Depth 5) -replace "`r?`n", ' ')
}

function Add-Index([string]$Kind, [string]$Thumb, [string]$File, [string]$Host_, [string]$CaThumb, [string]$Subject_) {
  $items = @(Get-Index | Where-Object { -not ($_.kind -eq $Kind -and $_.host -eq $Host_) })
  $items += [pscustomobject]@{ kind = $Kind; thumbprint = $Thumb; file = $File; host = $Host_; ca = $CaThumb; subject = $Subject_ }
  Save-Index $items
}

function Get-IndexEntry([string]$Kind, [string]$Host_) {
  foreach ($it in @(Get-Index)) {
    if ($it.kind -eq $Kind -and ([string]$it.host) -eq ([string]$Host_)) { return $it }
  }
  return $null
}

function Get-CertByThumb([string]$Thumb) {
  if ([string]::IsNullOrWhiteSpace($Thumb)) { return $null }
  return Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $Thumb } | Select-Object -First 1
}

# The CA that THIS state owns (by thumbprint recorded in index.json), never "any cert with our subject".
function Get-OwnedCa {
  $e = Get-IndexEntry 'ca' ''
  if (-not $e) { return $null }
  return Get-CertByThumb ([string]$e.thumbprint)
}

# Subject tag: stable per state directory, created with the first CA.
function Get-TagExisting {
  if (-not (Test-Path $TagFile)) { return '' }
  $t = (Read-TextNoBom $TagFile).Trim()
  if ($t -match '^[0-9a-f]{8}$') { return $t }
  return ''
}

function Get-TagEnsured {
  $t = Get-TagExisting
  if ($t -ne '') { return $t }
  New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
  $bytes = New-Object byte[] 4
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $t = (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
  Write-TextNoBom $TagFile $t
  return $t
}

# Verify an exported PFX holds exactly two certs: the CA this state owns + one leaf.
# Anything else (missing parent, a foreign same-subject parent, or extra certs) is
# rejected, because the proxy would otherwise serve a chain clients cannot validate.
function Test-PfxChain([string]$PfxPath, $Ca) {
  try {
    if (-not (Test-Path $PfxPath)) { return $false }
    if (-not (Test-Path $PassFile)) { return $false }
    $pass = (Read-TextNoBom $PassFile).Trim()
    $coll = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    $coll.Import([System.IO.File]::ReadAllBytes($PfxPath), $pass, $flags)
    $caCount = @($coll | Where-Object { $_.Thumbprint -eq $Ca.Thumbprint }).Count
    $otherCount = @($coll | Where-Object { $_.Thumbprint -ne $Ca.Thumbprint }).Count
    return ($caCount -eq 1 -and $otherCount -eq 1)
  } catch {
    return $false
  }
}

try {
  switch ($Mode) {

    'check' {
      $cmd = Get-Command New-SelfSignedCertificate -ErrorAction SilentlyContinue
      if (-not $cmd) { Write-Output 'CERTCHECK-FAIL New-SelfSignedCertificate not available (PKI module missing)'; exit 1 }
      if (-not $cmd.Parameters.ContainsKey('Signer')) { Write-Output 'CERTCHECK-FAIL -Signer not supported'; exit 1 }
      $canWriteMy = $true
      try { Get-ChildItem Cert:\CurrentUser\My -ErrorAction Stop | Out-Null } catch { $canWriteMy = $false }
      if (-not $canWriteMy) { Write-Output 'CERTCHECK-FAIL Cert:\CurrentUser\My not accessible'; exit 1 }
      Write-Output 'CERTCHECK-OK'
    }

    'ca' {
      New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
      $pfx = Join-Path $CertDir 'ca.pfx'
      $crt = Join-Path $CertDir 'ca.crt'
      # Reuse ONLY if this state's own CA (thumbprint in index.json) is still in the store.
      $owned = Get-OwnedCa
      if ((Test-Path $pfx) -and (Test-Path $crt) -and $owned) {
        Write-Output ('CA-EXISTS thumb=' + $owned.Thumbprint + ' subject=' + $owned.Subject + ' file=' + $pfx)
        exit 0
      }
      # Half state (own CA without its PFX key) is unusable: drop the cert so it cannot
      # linger as a same-subject decoy for later leaf exports.
      if ($owned -and -not (Test-Path $pfx)) {
        Remove-Item -Path ('Cert:\CurrentUser\My\' + $owned.Thumbprint) -Force -ErrorAction SilentlyContinue
      }
      # Never leave a stale ca.pfx/ca.crt next to a freshly created CA: a leftover PEM is
      # exactly what made clients trust a CA the proxy no longer served.
      Remove-Item $pfx -Force -ErrorAction SilentlyContinue
      Remove-Item $crt -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path $PassFile)) {
        $bytes = New-Object byte[] 24
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        Write-TextNoBom $PassFile (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
      }
      $pass = (Read-TextNoBom $PassFile).Trim()
      $sec = ConvertTo-SecureString -String $pass -AsPlainText -Force
      $tag = Get-TagEnsured
      $Subject = $SubjectBase + ' ' + $tag

      $ext = @(
        '2.5.29.19={critical}{text}ca=1',
        '2.5.29.37={text}1.3.6.1.5.5.7.3.1'
      )
      $ca = New-SelfSignedCertificate -Subject ('CN=' + $Subject) `
        -KeyUsage CertSign, CRLSign, DigitalSignature -KeyUsageProperty Sign `
        -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 -TextExtension $ext -NotAfter (Get-Date).AddYears(5) `
        -CertStoreLocation Cert:\CurrentUser\My
      if (-not $ca) { throw 'certificate creation returned nothing' }

      Export-PfxCertificate -Cert $ca -FilePath $pfx -Password $sec | Out-Null
      # Write the PEM ourselves instead of shelling out to "certutil -encode": that helper
      # REFUSES to overwrite an existing file and exits non-zero, which silently kept a
      # stale CA PEM in place. Then read it back and prove it is the CA we just created.
      $b64 = [Convert]::ToBase64String($ca.RawData)
      $lines = @()
      for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $lines += $b64.Substring($i, [Math]::Min(64, $b64.Length - $i))
      }
      $pem = "-----BEGIN CERTIFICATE-----`r`n" + ($lines -join "`r`n") + "`r`n-----END CERTIFICATE-----`r`n"
      Write-TextNoBom $crt $pem
      $backB64 = ((Read-TextNoBom $crt) -replace '-----[A-Z ]+-----', '') -replace '\s', ''
      $back = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (,([Convert]::FromBase64String($backB64)))
      if ($back.Thumbprint -ne $ca.Thumbprint) {
        throw ('ca.crt self-check failed: file=' + $back.Thumbprint + ' expected=' + $ca.Thumbprint)
      }
      Add-Index 'ca' $ca.Thumbprint $pfx '' $ca.Thumbprint $ca.Subject
      Write-Output ('CA-OK thumb=' + $ca.Thumbprint + ' subject=' + $ca.Subject + ' verified=1 pfx=' + $pfx + ' pem=' + $crt)
    }

    'leaf' {
      if ([string]::IsNullOrWhiteSpace($HostName)) { Write-Output 'LEAF-FAIL -HostName required'; exit 1 }
      New-Item -ItemType Directory -Force -Path $CertDir | Out-Null
      $safe = ($HostName -replace '[^A-Za-z0-9._-]', '_')
      $pfx = Join-Path $CertDir ('leaf-' + $safe + '.pfx')
      # Must be signed by the CA THIS state owns; never "any cert with our subject"
      $ca = Get-OwnedCa
      if (-not $ca) { Write-Output 'LEAF-FAIL no CA owned by this state in Cert:\CurrentUser\My (run -Mode ca first)'; exit 1 }
      $prev = Get-IndexEntry 'leaf' $HostName
      if ((Test-Path $pfx) -and $prev -and ([string]$prev.ca) -eq $ca.Thumbprint -and (Test-PfxChain $pfx $ca)) {
        Write-Output ('LEAF-EXISTS host=' + $HostName + ' file=' + $pfx + ' ca=' + $ca.Thumbprint)
        exit 0
      }
      if (Test-Path $pfx) { Remove-Item $pfx -Force -ErrorAction SilentlyContinue }
      if (-not (Test-Path $PassFile)) { Write-Output 'LEAF-FAIL pass.txt missing'; exit 1 }
      $pass = (Read-TextNoBom $PassFile).Trim()
      $sec = ConvertTo-SecureString -String $pass -AsPlainText -Force

      $leaf = New-SelfSignedCertificate -DnsName $HostName -Signer $ca `
        -KeyExportPolicy Exportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA `
        -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2) `
        -CertStoreLocation Cert:\CurrentUser\My
      if (-not $leaf) { throw 'leaf creation returned nothing' }
      Export-PfxCertificate -Cert $leaf -FilePath $pfx -Password $sec | Out-Null

      if (-not (Test-PfxChain $pfx $ca)) {
        Remove-Item $pfx -Force -ErrorAction SilentlyContinue
        Remove-Item -Path ('Cert:\CurrentUser\My\' + $leaf.Thumbprint) -Force -ErrorAction SilentlyContinue
        Write-Output ('LEAF-FAIL exported chain is not exactly {leaf + owned CA ' + $ca.Subject + '}; refusing to serve an ambiguous chain')
        exit 1
      }
      Add-Index 'leaf' $leaf.Thumbprint $pfx $HostName $ca.Thumbprint $leaf.Subject
      Write-Output ('LEAF-OK host=' + $HostName + ' thumb=' + $leaf.Thumbprint + ' ca=' + $ca.Thumbprint + ' file=' + $pfx)
    }

    'cleanup' {
      $items = @(Get-Index)
      $targets = New-Object System.Collections.Generic.List[string]
      foreach ($it in $items) { if ($it.thumbprint) { $targets.Add([string]$it.thumbprint) } }
      # Also sweep this state's OWN subject tag across My and the intermediate store,
      # so orphans survive neither a lost index.json nor a Windows chain-engine cache copy.
      $tag = Get-TagExisting
      if ($tag -ne '') {
        $pat = '*' + $SubjectBase + ' ' + $tag + '*'
        foreach ($store in @('My', 'CA')) {
          Get-ChildItem ('Cert:\CurrentUser\' + $store) -ErrorAction SilentlyContinue | Where-Object {
            $_.Subject -like $pat -or $_.Issuer -like $pat
          } | ForEach-Object { $targets.Add([string]$_.Thumbprint) }
        }
      }
      $removed = 0
      foreach ($t in ($targets | Select-Object -Unique)) {
        if (Get-CertByThumb $t) {
          Remove-Item -Path ('Cert:\CurrentUser\My\' + $t) -Force -ErrorAction SilentlyContinue
          $removed++
        }
        Remove-Item -Path ('Cert:\CurrentUser\CA\' + $t) -Force -ErrorAction SilentlyContinue
      }
      Remove-Item (Join-Path $CertDir '*.pfx') -Force -ErrorAction SilentlyContinue
      Remove-Item $IndexFile -Force -ErrorAction SilentlyContinue
      Write-Output ('CERTS-CLEANED removed=' + $removed + ' tag=' + ($tag -replace '^$', 'none'))
    }

    default { Write-Output ('unknown mode: ' + $Mode); exit 1 }
  }
  exit 0
} catch {
  Write-Output ('CERTS-FAIL ' + $_.Exception.Message)
  exit 1
}
