# Remove every tool-owned cert from the user's trusted ROOT store.
# The PowerShell cert provider refuses to touch that store, so this goes through
# .NET X509Store / CryptoAPI, which makes Windows show a confirmation dialog per cert
# ("... do you want to DELETE ...?"). Someone must click Yes.
# ASCII only.
$ErrorActionPreference = 'Continue'
$Subject = 'DSH Local MITM CA'
$deadline = (Get-Date).AddMinutes(8)
$round = 0
while ((Get-Date) -lt $deadline) {
  $round++
  $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
  $store.Open('ReadWrite')
  $mine = @($store.Certificates | Where-Object { $_.Subject -like ('*' + $Subject + '*') })
  if ($mine.Count -eq 0) { $store.Close(); Write-Output ('ROOT-CA-CLEAN after ' + $round + ' rounds'); break }
  Write-Output ('round ' + $round + ': ' + $mine.Count + ' cert(s) to delete; waiting for the Windows confirmation dialog...')
  foreach ($c in $mine) {
    try { $store.Remove($c); Write-Output ('  requested delete: ' + $c.Thumbprint) }
    catch { Write-Output ('  delete failed: ' + $c.Thumbprint + ' ' + $_.Exception.Message) }
  }
  $left = @($store.Certificates | Where-Object { $_.Subject -like ('*' + $Subject + '*') })
  $store.Close()
  if ($left.Count -eq 0) { Write-Output 'ROOT-CA-CLEAN'; break }
  Start-Sleep -Seconds 5
}
$store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'CurrentUser')
$store.Open('ReadOnly')
$final = @($store.Certificates | Where-Object { $_.Subject -like ('*' + $Subject + '*') })
$store.Close()
Write-Output ('ROOT-REMAINING ' + $final.Count)
foreach ($c in $final) { Write-Output ('  still trusted: ' + $c.Thumbprint + ' ' + $c.Subject) }
Write-Output 'ROOT-DELETE-DONE'
