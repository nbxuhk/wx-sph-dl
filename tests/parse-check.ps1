# Parse-check every PowerShell script in the tool (no execution).
# ASCII only.
param([string]$Tool = '')
$ErrorActionPreference = 'Continue'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$bad = 0
Get-ChildItem $Tool -Recurse -Filter *.ps1 | ForEach-Object {
  $errs = $null
  $null = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
  if ($errs -and $errs.Count) {
    $bad++
    Write-Output ('PARSE-ERR ' + $_.Name)
    $errs | ForEach-Object { Write-Output ('   ' + $_.Message) }
  } else {
    Write-Output ('PARSE-OK  ' + $_.Name)
  }
}
Write-Output ($(if ($bad -eq 0) { 'PS-PARSE-OK' } else { 'PS-PARSE-FAIL (' + $bad + ')' }))
exit $(if ($bad -eq 0) { 0 } else { 1 })
