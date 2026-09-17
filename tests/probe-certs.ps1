# Probe: (a) can we enumerate all certs inside a PFX with .NET on this box,
# (b) what tool-owned certs actually remain in the user's stores.
# ASCII only.
$ErrorActionPreference = 'Continue'

Write-Output '--- .NET / PS version ---'
Write-Output ('PSVersion=' + $PSVersionTable.PSVersion.ToString())
Write-Output ('CLR=' + [System.Environment]::Version.ToString())

Write-Output '--- X509Certificate2Collection.Import overloads ---'
$t = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]
$t.GetMethods() | Where-Object { $_.Name -eq 'Import' } | ForEach-Object {
  Write-Output ('  Import(' + (($_.GetParameters() | ForEach-Object { $_.ParameterType.Name }) -join ', ') + ')')
}

Write-Output '--- leftover certs: subject or issuer mentions our CA name ---'
$pat = '*MITM CA*'
foreach ($store in @('My', 'Root', 'CA')) {
  $items = @(Get-ChildItem ('Cert:\CurrentUser\' + $store) -ErrorAction SilentlyContinue | Where-Object {
    $_.Subject -like $pat -or $_.Issuer -like $pat
  })
  Write-Output ('[' + $store + '] count=' + $items.Count)
  foreach ($c in $items) {
    Write-Output ('   thumb=' + $c.Thumbprint + ' notBefore=' + $c.NotBefore.ToString('s') + ' subject=' + $c.Subject + ' issuer=' + $c.Issuer)
  }
}

Write-Output '--- certs in My created in the last 3 days (any subject, to catch renamed leftovers) ---'
$cut = (Get-Date).AddDays(-3)
Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.NotBefore -gt $cut } | ForEach-Object {
  Write-Output ('   thumb=' + $_.Thumbprint + ' notBefore=' + $_.NotBefore.ToString('s') + ' subject=' + $_.Subject)
}
Write-Output 'PROBE-DONE'
