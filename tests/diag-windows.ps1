# Dev diagnostic: list and screenshot every visible top-level window of the GUI process.
# ASCII only. Output: JSON manifest (UTF-8) + PNG per window.
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [string]$OutDir = '',
  [int]$Seconds = 8
)
$ErrorActionPreference = 'Stop'
if (-not $OutDir) { $OutDir = Join-Path $env:TEMP 'wx-sph-dl-win' }
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WinDiagDpi {
  [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  public static string MakeAware() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return "per-monitor-v2"; } catch { }
    try { if (SetProcessDpiAwareness(2) == 0) return "per-monitor"; } catch { }
    try { if (SetProcessDPIAware()) return "system"; } catch { }
    return "none";
  }
}
'@
# Must be Per-Monitor aware like the program under test, otherwise GetWindowRect and
# CopyFromScreen report virtualized (scaled-down) coordinates.
Write-Output ("measure dpi awareness: " + [WinDiagDpi]::MakeAware())

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WinDiag {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);

  public static List<string[]> List(uint want) {
    var res = new List<string[]>();
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != want) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r; GetWindowRect(h, out r);
      var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      res.Add(new string[] {
        h.ToString(),
        c.ToString(),
        t.ToString(),
        (r.Right - r.Left).ToString(),
        (r.Bottom - r.Top).ToString(),
        r.Left.ToString(), r.Top.ToString()
      });
      return true;
    }, IntPtr.Zero);
    return res;
  }
}
'@

$proc = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds $Seconds
if ($proc.HasExited) { throw ('exe exited early with code ' + $proc.ExitCode) }

$wins = [WinDiag]::List([uint32]$proc.Id)
$items = @()
$n = 0
foreach ($w in $wins) {
  $n++
  $rect = @{ left = [int]$w[5]; top = [int]$w[6]; width = [int]$w[3]; height = [int]$w[4] }
  $file = ''
  if ($rect.width -ge 200 -and $rect.height -ge 150) {
    $file = Join-Path $OutDir ("win-{0}.png" -f $n)
    try {
      $bmp = New-Object System.Drawing.Bitmap $rect.width, $rect.height
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen($rect.left, $rect.top, 0, 0, (New-Object System.Drawing.Size $rect.width, $rect.height))
      $g.Dispose(); $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    } catch { $file = 'capture-failed: ' + $_.Exception.Message }
  }
  $items += [pscustomobject]@{
    n = $n; hwnd = $w[0]; cls = $w[1]; title = $w[2]
    width = $rect.width; height = $rect.height; left = $rect.left; top = $rect.top; png = $file
  }
}
$json = $items | ConvertTo-Json -Depth 4
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'windows.json'), $json, $enc)
Write-Output ('windows: ' + $items.Count + '  manifest: ' + (Join-Path $OutDir 'windows.json'))

try { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 800 } catch { }
try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } } catch { }
