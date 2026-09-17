// screencap.cs - dev tool: capture a real window (by title substring) to a PNG.
// Built with csc so it can declare Per-Monitor-V2 awareness itself (PowerShell cannot:
// its manifest fixes DPI awareness at process start, which virtualizes window coordinates).
// Usage: screencap.exe "<title substring>" <out.png> [--pid N]
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class ScreenCap
{
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }
    private delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] private static extern IntPtr SetProcessDpiAwarenessContext(IntPtr v);
    [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();

    private static void MakeAware()
    {
        try { if (SetProcessDpiAwarenessContext(new IntPtr(-4)) != IntPtr.Zero) return; } catch { }
        try { if (SetProcessDpiAwareness(2) == 0) return; } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    private static int Main(string[] args)
    {
        MakeAware();
        if (args.Length < 2) { Console.WriteLine("usage: screencap.exe \"<title substring>\" <out.png> [--pid N] [--delay ms]"); return 1; }
        string title = args[0], outPath = args[1];
        int pid = 0, delay = 1500;
        for (int i = 2; i < args.Length - 1; i++)
        {
            if (args[i] == "--pid") pid = int.Parse(args[i + 1]);
            if (args[i] == "--delay") delay = int.Parse(args[i + 1]);
        }
        System.Threading.Thread.Sleep(delay);

        IntPtr target = IntPtr.Zero; int bestArea = 0;
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            if (pid != 0) { uint p; GetWindowThreadProcessId(h, out p); if (p != (uint)pid) return true; }
            var sb = new StringBuilder(512); GetWindowTextW(h, sb, 512);
            string t = sb.ToString();
            if (pid == 0 && (t.Length == 0 || t.IndexOf(title, StringComparison.OrdinalIgnoreCase) < 0)) return true;
            RECT r; if (!GetWindowRect(h, out r)) return true;
            int area = (r.Right - r.Left) * (r.Bottom - r.Top);
            if (area > bestArea) { bestArea = area; target = h; }
            return true;
        }, IntPtr.Zero);

        if (target == IntPtr.Zero) { Console.WriteLine("window not found: " + title); return 2; }
        ShowWindow(target, 5); SetForegroundWindow(target);
        System.Threading.Thread.Sleep(700);

        RECT rc; if (!GetWindowRect(target, out rc)) { Console.WriteLine("GetWindowRect failed"); return 3; }
        int w = rc.Right - rc.Left, h2 = rc.Bottom - rc.Top;
        using (var bmp = new Bitmap(w, h2))
        {
            using (var g = Graphics.FromImage(bmp)) g.CopyFromScreen(rc.Left, rc.Top, 0, 0, new Size(w, h2));
            string dir = Path.GetDirectoryName(outPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            bmp.Save(outPath, ImageFormat.Png);
        }
        Console.WriteLine("captured " + w + "x" + h2 + " -> " + outPath);
        return 0;
    }
}
