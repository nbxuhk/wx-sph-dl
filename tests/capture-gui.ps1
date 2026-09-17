# Dev helper: launch the GUI, capture its main window to a PNG, then close it.
# Usage: powershell -ExecutionPolicy Bypass -File tests\capture-gui.ps1 -Exe <path> [-Out <png>] [-Seconds 10] [-KeepOpen]
# Notes: MainWindowHandle is unreliable for this app, so we enumerate top-level windows ourselves.
# ASCII only.
param(
  [Parameter(Mandatory=$true)][string]$Exe,
  [string]$Out = '',
  [int]$Seconds = 10,
  [switch]$KeepOpen
)
$ErrorActionPreference = 'Stop'
if (-not $Out) { $Out = Join-Path $env:TEMP 'wx-sph-dl-gui.png' }

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WinCap {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);

  // biggest visible top-level window owned by pid (our main form)
  public static IntPtr FindMain(uint want) {
    IntPtr best = IntPtr.Zero; int bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr l) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != want) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r;
      if (!GetWindowRect(h, out r)) return true;
      int area = (r.Right - r.Left) * (r.Bottom - r.Top);
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
  public static string Title(IntPtr h) {
    var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512); return sb.ToString();
  }
}
'@

$proc = Start-Process -FilePath $Exe -PassThru
$hwnd = [IntPtr]::Zero
for ($i = 0; $i -lt ($Seconds * 4); $i++) {
  Start-Sleep -Milliseconds 250
  $proc.Refresh()
  if ($proc.HasExited) { throw ('exe exited early with code ' + $proc.ExitCode) }
  $h = [WinCap]::FindMain([uint32]$proc.Id)
  if ($h -ne [IntPtr]::Zero) { $hwnd = $h; break }
}
if ($hwnd -eq [IntPtr]::Zero) { throw 'no visible top-level window found' }
[WinCap]::ShowWindow($hwnd, 5) | Out-Null
[WinCap]::SetForegroundWindow($hwnd) | Out-Null
Start-Sleep -Milliseconds 1200

$title = [WinCap]::Title($hwnd)
$r = New-Object WinCap+RECT
if (-not [WinCap]::GetWindowRect($hwnd, [ref]$r)) { throw 'GetWindowRect failed' }
$w = $r.Right - $r.Left; $h2 = $r.Bottom - $r.Top
Write-Output ("hwnd={0} titleLen={1} rect={2}x{3} at {4},{5}" -f $hwnd, $title.Length, $w, $h2, $r.Left, $r.Top)

$bmp = New-Object System.Drawing.Bitmap $w, $h2
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size $w, $h2))
$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ("saved: " + $Out)

if (-not $KeepOpen) {
  try { $proc.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 1000 } catch { }
  try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force } } catch { }
  Write-Output 'closed'
} else {
  Write-Output ('left open, pid ' + $proc.Id)
}
