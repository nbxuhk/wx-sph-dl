# Build wx-sph-dl desktop edition (no install; target machine needs no Node).
#   .\build.ps1                 single-file exe (embeds node.exe + scripts)
#   .\build.ps1 -Portable       portable folder (exe + runtime\node.exe + scripts\)
#   .\build.ps1 -SkipSelftest   skip the post-build self test
# ASCII only (PowerShell 5.1 reads .ps1 as ANSI)
param(
  [switch]$Portable,
  [switch]$SkipSelftest,
  [string]$OutDir = '',
  [string]$NodeExe = ''
)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot          # tools\wx-sph-dl
if (-not $OutDir) { $OutDir = Join-Path $Root 'dist' }
if (-not $NodeExe) {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if (-not $cmd) { throw 'node.exe not found (needed as the embedded runtime)' }
  $NodeExe = $cmd.Source
}
$Csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $Csc)) { throw "csc.exe not found: $Csc" }

$ScriptFiles = @(
  @{ name = 'sph.mjs';           path = (Join-Path $Root 'sph.mjs') },
  @{ name = 'proxy.mjs';         path = (Join-Path $Root 'proxy.mjs') },
  @{ name = 'records.mjs';       path = (Join-Path $Root 'records.mjs') },
  @{ name = 'mitm-selftest.mjs'; path = (Join-Path $Root 'tests\mitm-selftest.mjs') },
  @{ name = 'win.ps1';           path = (Join-Path $Root 'ps\win.ps1') },
  @{ name = 'certs.ps1';         path = (Join-Path $Root 'ps\certs.ps1') },
  @{ name = 'purge-certs.ps1';   path = (Join-Path $Root 'ps\purge-certs.ps1') }
)
foreach ($s in $ScriptFiles) { if (-not (Test-Path $s.path)) { throw ("missing source: " + $s.path) } }
if (-not (Test-Path (Join-Path $Root 'gui\WxSphDl.cs'))) { throw 'missing gui\WxSphDl.cs' }

Write-Output ('build mode : ' + $(if ($Portable) { 'portable folder' } else { 'single exe' }))
Write-Output ('node       : ' + $NodeExe + '  (' + [math]::Round((Get-Item $NodeExe).Length / 1MB, 1) + ' MB)')

# best-effort icon generation (failure does not break the build)
# Rounded blue tile + white download arrow, matching AppIcon.Create() in the GUI.
$icon = Join-Path $Root 'gui\icon.ico'
try {
  Add-Type -AssemblyName System.Drawing
  $size = 256
  $bmp = New-Object System.Drawing.Bitmap $size, $size
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.Clear([System.Drawing.Color]::Transparent)

  $pad = [int]($size * 0.03); $rad = [int]($size * 0.22)
  $rect = New-Object System.Drawing.Rectangle $pad, $pad, ($size - 2 * $pad), ($size - 2 * $pad)
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $rad * 2
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc(($rect.Right - $d), $rect.Y, $d, $d, 270, 90)
  $path.AddArc(($rect.Right - $d), ($rect.Bottom - $d), $d, $d, 0, 90)
  $path.AddArc($rect.X, ($rect.Bottom - $d), $d, $d, 90, 90)
  $path.CloseFigure()
  $c1 = [System.Drawing.Color]::FromArgb(255, 74, 139, 240)
  $c2 = [System.Drawing.Color]::FromArgb(255, 36, 86, 187)
  $lg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, $c1, $c2, 60.0
  $g.FillPath($lg, $path)

  $white = [System.Drawing.Color]::White
  $pen = New-Object System.Drawing.Pen $white, ($size * 0.075)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $cx = $size / 2.0
  $g.DrawLine($pen, $cx, ($size * 0.24), $cx, ($size * 0.58))
  $g.DrawLine($pen, $cx, ($size * 0.58), ($cx - $size * 0.15), ($size * 0.43))
  $g.DrawLine($pen, $cx, ($size * 0.58), ($cx + $size * 0.15), ($size * 0.43))
  $pen2 = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(210, 255, 255, 255)), ($size * 0.075)
  $pen2.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen2.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($pen2, ($size * 0.30), ($size * 0.74), ($size * 0.70), ($size * 0.74))

  $g.Dispose()
  $hicon = $bmp.GetHicon()
  $ico = [System.Drawing.Icon]::FromHandle($hicon)
  $fs = [System.IO.File]::Create($icon)
  $ico.Save($fs)
  $fs.Close()
  $bmp.Dispose()
  Write-Output ('icon       : generated ' + $icon)
} catch { Write-Output ('icon       : skipped (' + $_.Exception.Message + ')') }

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$exePath = if ($Portable) { Join-Path (Join-Path $OutDir 'wx-sph-dl-portable') 'wx-sph-dl.exe' } else { Join-Path $OutDir 'wx-sph-dl.exe' }
# clean only this mode's product, so both artifacts can coexist
if ($Portable) {
  $portDir = Split-Path -Parent $exePath
  if (Test-Path $portDir) { Remove-Item $portDir -Recurse -Force }
} elseif (Test-Path $exePath) {
  Remove-Item $exePath -Force
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $exePath) | Out-Null

$cscArgs = @('/nologo', '/target:winexe', '/platform:anycpu', '/codepage:65001', '/optimize+',
             ('/out:' + $exePath))
if (Test-Path $icon) { $cscArgs += ('/win32icon:' + $icon) }
$cscArgs += @('/reference:System.Windows.Forms.dll', '/reference:System.Drawing.dll')

if (-not $Portable) {
  $cscArgs += ('/resource:' + $NodeExe + ',node.exe')
}
foreach ($s in $ScriptFiles) { $cscArgs += ('/resource:' + $s.path + ',' + $s.name) }
$cscArgs += (Join-Path $Root 'gui\WxSphDl.cs')

Write-Output 'compiling...'
& $Csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw ('csc failed with exit ' + $LASTEXITCODE) }
if (-not (Test-Path $exePath)) { throw 'exe not produced' }

if ($Portable) {
  # portable folder: runtime + scripts next to the exe -> green mode, nothing written to AppData
  $baseDir = Split-Path -Parent $exePath
  New-Item -ItemType Directory -Force -Path (Join-Path $baseDir 'runtime') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $baseDir 'scripts\ps') | Out-Null
  Copy-Item $NodeExe (Join-Path $baseDir 'runtime\node.exe') -Force
  foreach ($s in $ScriptFiles) {
    $target = if ($s.name -like '*.ps1') { Join-Path $baseDir ('scripts\ps\' + $s.name) } else { Join-Path $baseDir ('scripts\' + $s.name) }
    Copy-Item $s.path $target -Force
  }
}

$size = [math]::Round((Get-Item $exePath).Length / 1MB, 1)
Write-Output ('produced   : ' + $exePath + '  (' + $size + ' MB)')

if (-not $SkipSelftest) {
  # The exe is /target:winexe: calling it with "& $exe --selftest" returns immediately and
  # leaves $LASTEXITCODE unset, which used to print "selftest exit: 0" and pass the build
  # even when the selftest had failed. Wait on the process and also require the
  # EXE-SELFTEST-OK marker in the log file the exe always writes.
  Write-Output 'running exe --selftest ...'
  $logDir = if ($Portable) { Join-Path (Split-Path -Parent $exePath) 'logs' } else { Join-Path $env:LOCALAPPDATA 'wx-sph-dl\logs' }
  $before = @()
  if (Test-Path $logDir) { $before = @(Get-ChildItem $logDir -Filter 'selftest-*.log' | ForEach-Object { $_.FullName }) }
  $outFile = Join-Path $env:TEMP 'wx-sph-dl-exe-selftest.out'
  Remove-Item $outFile -Force -ErrorAction SilentlyContinue
  $proc = Start-Process -FilePath $exePath -ArgumentList '--selftest' -Wait -PassThru -NoNewWindow `
    -RedirectStandardOutput $outFile -RedirectStandardError ($outFile + '.err')
  $exeText = ''
  foreach ($f in @($outFile, $outFile + '.err')) { if (Test-Path $f) { $exeText += (Get-Content $f -Raw -Encoding UTF8) } }
  if (Test-Path $logDir) {
    $fresh = @(Get-ChildItem $logDir -Filter 'selftest-*.log' | Where-Object { $before -notcontains $_.FullName } | Sort-Object LastWriteTime)
    if ($fresh.Count) { $exeText += (Get-Content $fresh[$fresh.Count - 1].FullName -Raw -Encoding UTF8) }
  }
  $exeOk = ($proc.ExitCode -eq 0) -and ($exeText -match 'EXE-SELFTEST-OK')
  Write-Output ('selftest exit: ' + $proc.ExitCode + '  marker=' + $(if ($exeText -match 'EXE-SELFTEST-OK') { 'EXE-SELFTEST-OK' } elseif ($exeText -match 'EXE-SELFTEST-FAIL') { 'EXE-SELFTEST-FAIL' } else { 'missing' }))
  if (-not $exeOk) {
    Write-Output ($exeText.Trim())
    throw ('exe --selftest failed (exit ' + $proc.ExitCode + '); see ' + $logDir)
  }
}
Write-Output 'BUILD-OK'
