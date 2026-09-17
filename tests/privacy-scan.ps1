# Privacy scan for a public release: look for local/user-specific data in the files that
# would actually be committed. Generic patterns only, plus any -ExtraPatterns you pass in.
# ASCII only. Exit 0 = clean.
param(
  [string]$Tool = '',
  [string]$ExtraPatternsCsv = '',
  [switch]$IncludeIgnored
)
$ErrorActionPreference = 'Continue'
if ($Tool -eq '') { $Tool = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
# Extra patterns arrive as one ";;"-delimited string: "-File script.ps1 -ExtraPatterns a,b"
# does not bind arrays reliably (the elements can end up consumed as other parameters).
$extra = @()
if ($ExtraPatternsCsv -ne '') { $extra = @($ExtraPatternsCsv -split ';;' | Where-Object { $_ -ne '' }) }

$patterns = @(
  # absolute paths into a user profile / home directory
  '(?i)[A-Z]:\\Users\\[^\\\s"'']+',
  '(?i)/Users/[^/\s"'']+',
  '(?i)/home/[^/\s"'']+',
  # other absolute roots often used as scratch/dev dirs
  '(?i)[A-Z]:\\(DSH|dev|work|projects|src|repos)\b',
  # account-ish identifiers and mail addresses
  '(?i)[A-Za-z0-9._%+-]+@(gmail|outlook|hotmail|qq|163|126|foxmail)\.com',
  '(?i)noreply\.gitee\.com',
  '(?i)\bDESKTOP-[A-Z0-9]{4,}\b',
  '(?i)\bhermes\b',
  '(?i)\.dsh[\\/]',
  # machine-local network details
  '(?i)\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b',
  '(?i)\b192\.168\.\d{1,3}\.\d{1,3}\b',
  '(?i)\b172\.(1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3}\b',
  # live signed CDN values (parameter NAMES are fine, values are not)
  'encfilekey=[A-Za-z0-9%]',
  'token=[A-Za-z0-9%]',
  'sign=[A-Za-z0-9%]',
  'taskid=[0-9]{4,}'
) + $extra

$files = if ($IncludeIgnored) {
  Get-ChildItem $Tool -Recurse -File | Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object { $_.FullName.Substring($Tool.Length + 1) }
} else {
  & git -C $Tool ls-files
}
if (-not $files -or @($files).Count -eq 0) {
  # An empty file list means the scan proved nothing: fail loudly instead of reporting OK.
  Write-Output 'PRIVACY-SCAN-INVALID no files to scan (is this a git work tree?)'
  exit 2
}
$skipExt = @('.png', '.ico', '.zip', '.exe', '.dll', '.pfx', '.bin')
# This file contains the pattern literals themselves (e.g. '/Users/...'), which would
# otherwise match each other. It has no other content, so skipping it is safe.
$selfRel = ''
try { $selfRel = $PSCommandPath.Substring($Tool.Length).TrimStart('\', '/') } catch { }
$findings = 0
foreach ($f in $files) {
  if ($skipExt -contains [IO.Path]::GetExtension($f).ToLower()) { continue }
  if ($selfRel -ne '' -and ($f -replace '\\', '/') -eq ($selfRel -replace '\\', '/')) { continue }
  $full = Join-Path $Tool $f
  if (-not (Test-Path $full)) { continue }
  foreach ($p in $patterns) {
    foreach ($h in (Select-String -Path $full -Pattern $p -AllMatches -ErrorAction SilentlyContinue)) {
      $findings++
      Write-Output ($f + ':' + $h.LineNumber + '  [' + $p + ']  ' + $h.Line.Trim().Substring(0, [Math]::Min(100, $h.Line.Trim().Length)))
    }
  }
}
Write-Output ''
Write-Output ("scanned " + @($files).Count + " files, findings=" + $findings)
Write-Output ($(if ($findings -eq 0) { 'PRIVACY-SCAN-OK' } else { 'PRIVACY-SCAN-SUSPECT' }))
exit $(if ($findings -eq 0) { 0 } else { 1 })
