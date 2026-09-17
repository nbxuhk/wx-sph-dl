// wx-sph-dl 桌面版（WinForms，单窗口，自绘 UI；用 csc 编译，无 designer / 无第三方依赖）
// 编译: csc /target:winexe /codepage:65001 /resource:node.exe,node.exe ... gui\WxSphDl.cs
// 运行: wx-sph-dl.exe [--selftest] [--screenshot <png>] [--outdir <dir>]
//
// 约束与要点：
//   · 目标框架 .NET Framework 4.0（csc 默认）→ 只能 C# 5 语法；Process.Kill(bool) 不可用。
//   · 布局用显式 LayoutAll()，不依赖 Anchor/自动缩放：WinForms 的 AutoScale 会与自绘控件
//     相互覆盖（实测卡片宽度被还原成默认值）。改为 AutoScaleMode.None + 自己按 DPI 缩放数字，
//     字体仍用 Point（GDI+ 会按 DPI 自动放大），二者比例因此保持一致。
//   · 所有自绘控件用不透明背景色（WinForms 控件默认不支持 Color.Transparent）。
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace WxSphDl
{
    // ---------------- 主题与 DPI 缩放 ----------------
    internal static class Theme
    {
        public const string Family = "Microsoft YaHei UI";
        public static float Scale = 1f;              // 由 Program.Main 在 DPI 感知后设置
        public static int S(int v) { return (int)Math.Round(v * Scale); }
        public static float SF(float v) { return v * Scale; }

        public static readonly Color Bg = Color.FromArgb(0xF4, 0xF6, 0xF9);
        public static readonly Color CardBg = Color.White;
        public static readonly Color Border = Color.FromArgb(0xE2, 0xE6, 0xEC);
        public static readonly Color Accent = Color.FromArgb(0x2F, 0x6F, 0xED);
        public static readonly Color AccentHover = Color.FromArgb(0x2A, 0x63, 0xD4);
        public static readonly Color AccentDown = Color.FromArgb(0x24, 0x56, 0xBB);
        public static readonly Color Text = Color.FromArgb(0x1F, 0x24, 0x30);
        public static readonly Color SubText = Color.FromArgb(0x6B, 0x72, 0x80);
        public static readonly Color Muted = Color.FromArgb(0x9A, 0xA0, 0xA6);
        public static readonly Color Success = Color.FromArgb(0x16, 0xA3, 0x4A);
        public static readonly Color Warning = Color.FromArgb(0xD9, 0x77, 0x06);
        public static readonly Color Danger = Color.FromArgb(0xDC, 0x26, 0x26);
        public static readonly Color GhostBg = Color.FromArgb(0xF1, 0xF3, 0xF7);
        public static readonly Color GhostHover = Color.FromArgb(0xE6, 0xEA, 0xF2);
        public static readonly Color ConsoleBg = Color.FromArgb(0x0F, 0x17, 0x2A);
        public static readonly Color ConsoleFg = Color.FromArgb(0xD6, 0xE2, 0xF0);

        public static Font F(float pt, FontStyle style) { return new Font(Family, pt, style, GraphicsUnit.Point); }
        public static Font Body() { return F(9.5f, FontStyle.Regular); }
        public static Font Bold() { return F(9.5f, FontStyle.Bold); }
        public static Font Small() { return F(8.5f, FontStyle.Regular); }
        public static Font Title() { return F(15f, FontStyle.Bold); }
        public static Font Mono() { return F(9.5f, FontStyle.Regular); }

        public static GraphicsPath Round(Rectangle r, int radius)
        {
            var p = new GraphicsPath();
            int d = radius * 2;
            if (d <= 0 || r.Width <= d || r.Height <= d) { p.AddRectangle(r); return p; }
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }

    internal static class Native
    {
        [DllImport("user32.dll")] private static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] private static extern IntPtr SetProcessDpiAwarenessContext(IntPtr value);
        private static readonly IntPtr PER_MONITOR_AWARE_V2 = new IntPtr(-4);

        public static void EnableDpiAwareness()
        {
            try { if (SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) != IntPtr.Zero) return; } catch { }
            try { SetProcessDPIAware(); } catch { }
        }
        public static float DetectScale()
        {
            try
            {
                using (var g = Graphics.FromHwnd(IntPtr.Zero)) { return g.DpiX / 96f; }
            }
            catch { return 1f; }
        }
    }

    // ---------------- 运行时引导（内嵌资源解包） ----------------
    internal static class Bootstrap
    {
        public const string Version = "1.1.0";

        public static string ExeDir { get { return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); } }
        public static bool IsGreen { get { return File.Exists(Path.Combine(ExeDir, "runtime", "node.exe")); } }
        public static string BaseDir
        {
            get
            {
                if (IsGreen) return ExeDir;
                return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "wx-sph-dl");
            }
        }
        public static string NodeExe { get { return Path.Combine(BaseDir, "runtime", "node.exe"); } }
        public static string ScriptsDir { get { return Path.Combine(BaseDir, "scripts"); } }
        public static string StateDir { get { return Path.Combine(BaseDir, "state"); } }
        public static string LogDir { get { return Path.Combine(BaseDir, "logs"); } }
        public static string OutDir { get { return Path.Combine(BaseDir, "output"); } }

        private static readonly string[] Scripts = { "sph.mjs", "proxy.mjs", "records.mjs", "mitm-selftest.mjs" };
        private static readonly string[] PsScripts = { "win.ps1", "certs.ps1", "purge-certs.ps1" };

        public static void EnsureRuntime(Action<string> log)
        {
            Directory.CreateDirectory(BaseDir);
            Directory.CreateDirectory(ScriptsDir);
            Directory.CreateDirectory(Path.Combine(ScriptsDir, "ps"));
            Directory.CreateDirectory(StateDir);
            Directory.CreateDirectory(LogDir);
            Directory.CreateDirectory(OutDir);

            // 绿色模式：文件已在 exe 同目录，直接用（便携版没有内嵌资源，不能去解包）
            if (IsGreen)
            {
                var missing = new System.Collections.Generic.List<string>();
                foreach (var s in AllScripts())
                {
                    string rel = s.IndexOf("ps" + Path.DirectorySeparatorChar) == 0 ? Path.Combine("scripts", s) : Path.Combine("scripts", s);
                    if (!File.Exists(Path.Combine(BaseDir, rel))) missing.Add(rel);
                }
                if (missing.Count == 0) return;
                throw new InvalidOperationException("绿色模式缺少文件：" + string.Join("、", missing.ToArray())
                    + "\n请重新运行 build.ps1 -Portable 生成完整目录。");
            }

            var stampFile = Path.Combine(BaseDir, "version.stamp");
            // The stamp must change whenever the EMBEDDED FILES change, not just when the
            // version string does: with a constant-only stamp, a rebuilt exe kept running
            // whatever scripts it had extracted the first time (silently stale JS/PS1).
            var want = Version + "|" + Assembly.GetExecutingAssembly().GetName().Version + "|" + ResourceFingerprint();
            bool upToDate = File.Exists(stampFile) && File.ReadAllText(stampFile).Trim() == want;
            bool needNode = !File.Exists(NodeExe);
            bool needScripts = false;
            var expected = new System.Collections.Generic.List<string>();
            foreach (var s in Scripts) expected.Add(Path.Combine(ScriptsDir, s));
            foreach (var s in PsScripts) expected.Add(Path.Combine(ScriptsDir, "ps", s));
            foreach (var p in expected) { if (!File.Exists(p)) { needScripts = true; break; } }

            if (!upToDate || needNode || needScripts)
            {
                var asm = Assembly.GetExecutingAssembly();
                if (needNode)
                {
                    if (log != null) log("正在解包内置 Node 运行时…");
                    Extract(asm, "node.exe", NodeExe);
                }
                if (!upToDate && !needNode && log != null) log("内置脚本有更新，正在刷新…");
                foreach (var s in Scripts) Extract(asm, s, Path.Combine(ScriptsDir, s));
                foreach (var s in PsScripts) Extract(asm, s, Path.Combine(ScriptsDir, "ps", s));
                File.WriteAllText(stampFile, want);
            }
        }

        // SHA-256 over every embedded script resource (node.exe is summarised by length),
        // so any change in the shipped scripts forces a re-extract on the next launch.
        private static string ResourceFingerprint()
        {
            var asm = Assembly.GetExecutingAssembly();
            var sb = new StringBuilder();
            using (var sha = SHA256.Create())
            {
                foreach (var s in AllScripts())
                {
                    string resName = s.Replace("\\", "/");
                    int slash = resName.LastIndexOf('/');
                    if (slash >= 0) resName = resName.Substring(slash + 1);
                    using (var stream = asm.GetManifestResourceStream(resName))
                    {
                        if (stream == null) { sb.Append(resName).Append(":missing;"); continue; }
                        sb.Append(resName).Append(':').Append(Convert.ToBase64String(sha.ComputeHash(stream))).Append(';');
                    }
                }
                using (var node = asm.GetManifestResourceStream("node.exe"))
                {
                    sb.Append("node.exe:").Append(node == null ? "none" : node.Length.ToString());
                }
            }
            return sb.ToString();
        }

        private static string[] AllScripts()
        {
            var list = new System.Collections.Generic.List<string>();
            list.AddRange(Scripts);
            foreach (var s in PsScripts) list.Add(Path.Combine("ps", s));
            return list.ToArray();
        }

        private static void Extract(Assembly asm, string resName, string dest)
        {
            using (var input = asm.GetManifestResourceStream(resName))
            {
                if (input == null) throw new InvalidOperationException("缺失内嵌资源: " + resName);
                string dir = Path.GetDirectoryName(dest);
                if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
                using (var output = File.Create(dest)) input.CopyTo(output);
            }
        }
    }

    // ---------------- 自绘控件 ----------------
    internal sealed class Card : Panel
    {
        public string Title = "";
        public Card()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Font = Theme.Body();
        }
        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            using (var p = Theme.Round(new Rectangle(0, 0, Width, Height), Theme.S(10))) { Region = new Region(p); }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.Round(r, Theme.S(10)))
            {
                using (var b = new SolidBrush(Theme.CardBg)) g.FillPath(b, path);
                using (var pen = new Pen(Theme.Border)) g.DrawPath(pen, path);
            }
            if (!string.IsNullOrEmpty(Title))
            {
                using (var f = Theme.Bold())
                using (var b = new SolidBrush(Theme.Text))
                    g.DrawString(Title, f, b, Theme.S(16), Theme.S(12));
            }
        }
    }

    internal sealed class FlatBtn : Button
    {
        public bool Primary = false;
        public bool Danger = false;
        private bool _hover, _down;
        public FlatBtn()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            FlatStyle = FlatStyle.Flat;
            FlatAppearance.BorderSize = 0;
            BackColor = Color.Transparent;   // 需要本控件自身绘制圆角，角落要透出父容器
            Font = Theme.Body();
            Cursor = Cursors.Hand;
            Height = Theme.S(32);
        }
        protected override void OnMouseEnter(EventArgs e) { _hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { _hover = false; _down = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs e) { _down = true; Invalidate(); base.OnMouseDown(e); }
        protected override void OnMouseUp(MouseEventArgs e) { _down = false; Invalidate(); base.OnMouseUp(e); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            Color fill, fg;
            if (!Enabled) { fill = Color.FromArgb(0xEE, 0xF0, 0xF4); fg = Theme.Muted; }
            else if (Primary) { fill = _down ? Theme.AccentDown : (_hover ? Theme.AccentHover : Theme.Accent); fg = Color.White; }
            else if (Danger) { fill = _down ? Color.FromArgb(0xB9, 0x1C, 0x1C) : (_hover ? Color.FromArgb(0xE8, 0x3B, 0x3B) : Color.FromArgb(0xFE, 0xF2, 0xF2)); fg = (_hover || _down) ? Color.White : Theme.Danger; }
            else { fill = _hover || _down ? Theme.GhostHover : Theme.GhostBg; fg = Theme.Text; }
            using (var path = Theme.Round(r, Theme.S(8)))
            {
                using (var b = new SolidBrush(fill)) g.FillPath(b, path);
                if (!Primary && Enabled && !(Danger && (_hover || _down)))
                {
                    using (var pen = new Pen(Theme.Border)) g.DrawPath(pen, path);
                }
            }
            TextRenderer.DrawText(g, Text, Font, r, fg,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
            // 自绘后必须自己给键盘焦点提示（可访问性）
            if (Focused && Enabled)
            {
                var inner = new Rectangle(r.X + Theme.S(2), r.Y + Theme.S(2), r.Width - Theme.S(4), r.Height - Theme.S(4));
                using (var path2 = Theme.Round(inner, Theme.S(6)))
                using (var pen = new Pen(Color.FromArgb(150, Theme.Accent), Theme.SF(1.4f)))
                    g.DrawPath(pen, path2);
            }
        }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }
    }

    // 五步进度条：圆圈 + 连接线
    internal sealed class StepBar : Control
    {
        private readonly string[] _names;
        private readonly string[] _state;
        public StepBar(string[] names)
        {
            _names = names;
            _state = new string[names.Length];
            for (int i = 0; i < _state.Length; i++) _state[i] = "idle";
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.CardBg;
            Font = Theme.Body();
            Height = Theme.S(56);
        }
        public void SetState(int idx, string state)
        {
            if (idx < 0 || idx >= _state.Length) return;
            _state[idx] = state;
            if (InvokeRequired) { BeginInvoke(new Action(Invalidate)); return; }
            Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            int n = _names.Length;
            if (n == 0 || Width < Theme.S(60)) return;
            int r = Theme.S(15), cy = Theme.S(20);
            float slot = (float)Width / n;
            for (int i = 0; i < n; i++)
            {
                float cx = slot * i + slot / 2f;
                Color ring = Theme.Muted, fill = Color.White, fg = Theme.SubText;
                string mark = (i + 1).ToString();
                if (_state[i] == "run") { ring = Theme.Accent; fill = Color.FromArgb(0xE8, 0xF0, 0xFE); fg = Theme.Accent; mark = "…"; }
                else if (_state[i] == "ok") { ring = Theme.Success; fill = Theme.Success; fg = Color.White; mark = "✓"; }
                else if (_state[i] == "fail") { ring = Theme.Danger; fill = Theme.Danger; fg = Color.White; mark = "✕"; }
                if (i < n - 1)
                {
                    using (var pen = new Pen(Color.FromArgb(0xDD, 0xE2, 0xEA), Theme.SF(2f)))
                        g.DrawLine(pen, cx + r / 2f + Theme.S(4), cy, cx + slot - r / 2f - Theme.S(4), cy);
                }
                var circle = new Rectangle((int)(cx - r / 2f), cy - r / 2, r, r);
                using (var b = new SolidBrush(fill)) g.FillEllipse(b, circle);
                using (var pen = new Pen(ring, Theme.SF(2f))) g.DrawEllipse(pen, circle);
                using (var f = Theme.Small())
                using (var b = new SolidBrush(fg))
                {
                    var sz = g.MeasureString(mark, f);
                    g.DrawString(mark, f, b, cx - sz.Width / 2f, cy - sz.Height / 2f);
                }
                using (var f = Theme.Small())
                using (var b = new SolidBrush(_state[i] == "idle" ? Theme.SubText : ring))
                {
                    var sz = g.MeasureString(_names[i], f);
                    g.DrawString(_names[i], f, b, cx - sz.Width / 2f, cy + r / 2f + Theme.S(4));
                }
            }
        }
    }

    // 提示条：左侧色条 + 圆形图标 + 文本
    internal sealed class Banner : Control
    {
        public enum Kind { Info, Warn, Ok }
        private Kind _kind = Kind.Info;
        private string _text = "";
        public Kind Style { get { return _kind; } set { _kind = value; Invalidate(); } }
        public string Body { get { return _text; } set { _text = value; Invalidate(); } }
        public Banner()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Font = Theme.Body();
            Height = Theme.S(50);
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            Color accent = _kind == Kind.Warn ? Theme.Warning : (_kind == Kind.Ok ? Theme.Success : Theme.Accent);
            Color bg = _kind == Kind.Warn ? Color.FromArgb(0xFF, 0xFA, 0xEB)
                     : (_kind == Kind.Ok ? Color.FromArgb(0xF0, 0xFB, 0xF4) : Color.FromArgb(0xEF, 0xF5, 0xFE));
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.Round(r, Theme.S(8)))
            {
                using (var b = new SolidBrush(bg)) g.FillPath(b, path);
                using (var pen = new Pen(Color.FromArgb(40, accent))) g.DrawPath(pen, path);
            }
            using (var b = new SolidBrush(accent)) g.FillRectangle(b, 0, Theme.S(8), Theme.S(4), Height - Theme.S(16));
            var ic = new Rectangle(Theme.S(16), Height / 2 - Theme.S(9), Theme.S(18), Theme.S(18));
            using (var b = new SolidBrush(accent)) g.FillEllipse(b, ic);
            string glyph = _kind == Kind.Warn ? "!" : (_kind == Kind.Ok ? "✓" : "i");
            using (var f = Theme.F(9f, FontStyle.Bold))
            using (var b = new SolidBrush(Color.White))
            {
                var sz = g.MeasureString(glyph, f);
                g.DrawString(glyph, f, b, ic.X + ic.Width / 2f - sz.Width / 2f, ic.Y + ic.Height / 2f - sz.Height / 2f);
            }
            var tr = new Rectangle(Theme.S(44), 0, Math.Max(Theme.S(10), Width - Theme.S(56)), Height);
            TextRenderer.DrawText(g, _text, Font, tr, Theme.Text,
                TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak | TextFormatFlags.NoPadding);
        }
    }

    // 状态胶囊
    internal sealed class Pill : Control
    {
        private string _text = "";
        private Color _color = Theme.Muted;
        public Pill()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
            Font = Theme.Small();
            Height = Theme.S(24);
        }
        public void SetText(string text, Color color)
        {
            _text = text; _color = color;
            if (InvokeRequired) { BeginInvoke(new Action(Invalidate)); return; }
            Invalidate();
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.ClearTypeGridFit;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.Round(r, Height / 2))
            {
                using (var b = new SolidBrush(Color.FromArgb(28, _color))) g.FillPath(b, path);
                using (var pen = new Pen(Color.FromArgb(90, _color))) g.DrawPath(pen, path);
            }
            TextRenderer.DrawText(g, _text, Font, r, _color,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
    }

    // 带占位提示的输入框
    internal sealed class HintBox : TextBox
    {
        private const int EM_SETCUEBANNER = 0x1501;
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, string lParam);
        private string _hint = "";
        public string Hint
        {
            get { return _hint; }
            set { _hint = value; if (IsHandleCreated) SendMessage(Handle, EM_SETCUEBANNER, (IntPtr)1, _hint); }
        }
        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            SendMessage(Handle, EM_SETCUEBANNER, (IntPtr)1, _hint);
        }
    }

    // 圆角输入外壳（内含无边框 TextBox）
    internal sealed class InputShell : Control
    {
        public readonly HintBox Box = new HintBox();
        public InputShell()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Color.White;
            Box.BorderStyle = BorderStyle.None;
            Box.Font = Theme.F(10.5f, FontStyle.Regular);
            Box.ForeColor = Theme.Text;
            Box.BackColor = Color.White;
            Controls.Add(Box);
            Height = Theme.S(38);
        }
        protected override void OnResize(EventArgs e)
        {
            base.OnResize(e);
            Box.SetBounds(Theme.S(12), (Height - Box.PreferredHeight) / 2, Math.Max(Theme.S(10), Width - Theme.S(24)), Box.PreferredHeight);
            using (var p = Theme.Round(new Rectangle(0, 0, Width, Height), Theme.S(8))) { Region = new Region(p); }
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.Round(r, Theme.S(8)))
            {
                using (var b = new SolidBrush(Color.White)) g.FillPath(b, path);
                using (var pen = new Pen(Box.Focused ? Theme.Accent : Theme.Border, Box.Focused ? Theme.SF(1.6f) : Theme.SF(1f))) g.DrawPath(pen, path);
            }
        }
    }

    // ---------------- 主窗口 ----------------
    internal sealed class MainForm : Form
    {
        private readonly InputShell _link = new InputShell();
        private readonly RichTextBox _log = new RichTextBox();
        private readonly StepBar _steps;
        private readonly Banner _banner = new Banner();
        private readonly Pill _pill = new Pill();
        private readonly Label _statusLeft = new Label();
        private readonly Label _statusRight = new Label();
        private readonly NumericUpDown _minutes = new NumericUpDown();
        private readonly Label _lblMin = new Label();
        private readonly Label _lblUnit = new Label();
        private readonly FlatBtn _btnPaste = new FlatBtn();
        private readonly FlatBtn _btnOpen = new FlatBtn();
        private readonly FlatBtn _btnDoctor = new FlatBtn();
        private readonly FlatBtn _btnSetup = new FlatBtn();
        private readonly FlatBtn _btnKey = new FlatBtn();
        private readonly FlatBtn _btnDecrypt = new FlatBtn();
        private readonly FlatBtn _btnClean = new FlatBtn();
        private readonly FlatBtn _btnStop = new FlatBtn();
        private readonly FlatBtn _btnUrgent = new FlatBtn();
        private readonly FlatBtn _btnClear = new FlatBtn();
        private readonly FlatBtn _btnSaveLog = new FlatBtn();
        private readonly FlatBtn _btnFolder = new FlatBtn();
        private readonly Timer _timer = new Timer();
        private readonly Panel _head = new Panel();
        private readonly Panel _body = new Panel();
        private readonly Panel _status = new Panel();
        private readonly Card _c1 = new Card();
        private readonly Card _c2 = new Card();
        private readonly Card _c3 = new Card();
        private readonly Card _c4 = new Card();
        private Process _current;
        private string _logFile;
        private readonly string _outDir;

        private static readonly string[] StepNames = { "环境检查", "安装抓包", "抓取取密钥", "下载解密", "清理还原" };

        public MainForm(string outDir)
        {
            _outDir = outDir;
            Text = "微信视频号下载器";
            BackColor = Theme.Bg;
            Font = Theme.Body();
            AutoScaleMode = AutoScaleMode.None;               // 自己按 DPI 缩放（见文件头说明）
            ClientSize = new Size(Theme.S(1020), Theme.S(720));
            MinimumSize = new Size(Theme.S(880), Theme.S(620));
            StartPosition = FormStartPosition.CenterScreen;
            DoubleBuffered = true;
            _steps = new StepBar(StepNames);
            try { Icon = AppIcon.Create(); } catch { }

            BuildHeader();
            BuildStatusBar();
            BuildCards();
            Controls.Add(_body);
            Controls.Add(_head);
            Controls.Add(_status);
            Resize += delegate { LayoutAll(); };
            Shown += delegate { LayoutAll(); };

            _timer.Interval = 4000;
            _timer.Tick += delegate { RefreshStatus(); };
            Load += delegate { OnLoaded(); };
        }

        protected override CreateParams CreateParams
        {
            get { var cp = base.CreateParams; cp.ClassStyle |= 0x20000; return cp; }   // CS_DROPSHADOW
        }

        // ---------------- 构建 ----------------
        private void BuildHeader()
        {
            _head.BackColor = Theme.Bg;
            var logo = new LogoBox();
            var title = new Label { Text = "微信视频号下载器", Font = Theme.Title(), ForeColor = Theme.Text, BackColor = Color.Transparent, AutoSize = false };
            var sub = new Label { Text = "把视频号分享链接背后的原始视频文件下载到本地（非录屏、非转码）", Font = Theme.Small(), ForeColor = Theme.SubText, BackColor = Color.Transparent, AutoSize = false };
            _btnUrgent.Text = "紧急还原";
            _btnUrgent.Danger = true;
            _btnUrgent.Click += delegate { DoEmergencyRestore(); };
            _head.Controls.AddRange(new Control[] { logo, title, sub, _btnUrgent, _pill });
            _head.Tag = new object[] { logo, title, sub };
        }

        private void BuildStatusBar()
        {
            _status.BackColor = Color.White;
            _status.Paint += delegate(object s, PaintEventArgs e)
            {
                using (var pen = new Pen(Theme.Border)) e.Graphics.DrawLine(pen, 0, 0, _status.Width, 0);
            };
            _statusLeft.Text = "就绪";
            _statusLeft.Font = Theme.Small();
            _statusLeft.ForeColor = Theme.SubText;
            _statusLeft.AutoSize = false;
            _statusLeft.BackColor = Color.Transparent;
            _statusRight.Font = Theme.Small();
            _statusRight.ForeColor = Theme.Muted;
            _statusRight.TextAlign = ContentAlignment.MiddleRight;
            _statusRight.AutoSize = false;
            _statusRight.BackColor = Color.Transparent;
            _status.Controls.AddRange(new Control[] { _statusLeft, _statusRight });
        }

        private void BuildCards()
        {
            _body.BackColor = Theme.Bg;

            // 卡片 1：链接
            _c1.Title = "视频号分享链接";
            _link.Box.Hint = "粘贴形如 https://weixin.qq.com/sph/xxxx 的分享链接";
            _link.Box.Text = "https://weixin.qq.com/sph/";
            _btnPaste.Text = "粘贴";
            _btnPaste.Click += delegate { if (Clipboard.ContainsText()) _link.Box.Text = Clipboard.GetText().Trim(); };
            _btnOpen.Text = "在微信中打开";
            _btnOpen.Click += delegate { OpenWeixinLink(_link.Box.Text.Trim()); };
            _c1.Controls.AddRange(new Control[] { _link, _btnPaste, _btnOpen });

            // 卡片 2：进度
            _c2.Title = "执行进度";
            _lblMin.Text = "取密钥时长";
            _lblMin.Font = Theme.Small();
            _lblMin.ForeColor = Theme.SubText;
            _lblMin.AutoSize = false;
            _lblMin.BackColor = Theme.CardBg;
            _minutes.Minimum = 1; _minutes.Maximum = 60; _minutes.Value = 20;
            _minutes.Font = Theme.Body();
            _minutes.BorderStyle = BorderStyle.FixedSingle;
            _lblUnit.Text = "分钟";
            _lblUnit.Font = Theme.Small();
            _lblUnit.ForeColor = Theme.SubText;
            _lblUnit.AutoSize = false;
            _lblUnit.BackColor = Theme.CardBg;
            _c2.Controls.AddRange(new Control[] { _steps, _lblMin, _minutes, _lblUnit });

            // 卡片 3：操作
            _c3.Title = "操作";
            _btnDoctor.Text = "① 环境检查"; _btnDoctor.Click += delegate { RunStepAsync(0, "doctor"); };
            _btnSetup.Text = "② 安装抓包"; _btnSetup.Primary = true; _btnSetup.Click += delegate { DoSetup(); };
            _btnKey.Text = "③ 抓取 + 取密钥"; _btnKey.Primary = true; _btnKey.Click += delegate { DoWatchAndKey(); };
            _btnDecrypt.Text = "④ 下载解密"; _btnDecrypt.Primary = true; _btnDecrypt.Click += delegate { RunStepAsync(3, "decrypt"); };
            _btnClean.Text = "⑤ 清理还原"; _btnClean.Click += delegate { DoCleanup(); };
            _btnStop.Text = "停止"; _btnStop.Enabled = false; _btnStop.Click += delegate { StopCurrent(); };
            _c3.Controls.AddRange(new Control[] { _btnDoctor, _btnSetup, _btnKey, _btnDecrypt, _btnClean, _btnStop });

            // 提示条
            // 卡片 4：日志
            _c4.Title = "运行日志";
            _btnClear.Text = "清空"; _btnClear.Click += delegate { _log.Clear(); };
            _btnSaveLog.Text = "保存日志"; _btnSaveLog.Click += delegate { SaveLog(); };
            _btnFolder.Text = "打开输出目录";
            _btnFolder.Click += delegate { if (!Directory.Exists(_outDir)) Directory.CreateDirectory(_outDir); Process.Start("explorer.exe", _outDir); };
            _log.Multiline = true; _log.ReadOnly = true; _log.WordWrap = false; _log.BorderStyle = BorderStyle.None;
            _log.BackColor = Theme.ConsoleBg; _log.ForeColor = Theme.ConsoleFg; _log.Font = Theme.Mono();
            _log.ScrollBars = RichTextBoxScrollBars.Both; _log.DetectUrls = false;
            _c4.Controls.AddRange(new Control[] { _log, _btnClear, _btnSaveLog, _btnFolder });

            _body.Controls.AddRange(new Control[] { _c1, _c2, _c3, _banner, _c4 });
        }

        // ---------------- 显式布局（唯一真源） ----------------
        private void LayoutAll()
        {
            int W = ClientSize.Width, H = ClientSize.Height;
            _head.SetBounds(0, 0, W, Theme.S(74));
            _status.SetBounds(0, H - Theme.S(30), W, Theme.S(30));
            _body.SetBounds(0, Theme.S(74), W, Math.Max(Theme.S(100), H - Theme.S(74) - Theme.S(30)));

            var hdr = (object[])_head.Tag;
            var logo = (Control)hdr[0];
            var title = (Label)hdr[1];
            var sub = (Label)hdr[2];
            logo.SetBounds(Theme.S(20), Theme.S(17), Theme.S(40), Theme.S(40));
            title.SetBounds(Theme.S(72), Theme.S(13), Theme.S(420), Theme.S(30));
            sub.SetBounds(Theme.S(74), Theme.S(43), Theme.S(520), Theme.S(20));
            _pill.SetBounds(W - Theme.S(262), Theme.S(24), Theme.S(240), Theme.S(26));
            _btnUrgent.SetBounds(_pill.Left - Theme.S(122), Theme.S(21), Theme.S(112), Theme.S(30));

            int padX = Theme.S(18);
            int cw = Math.Max(Theme.S(200), W - padX * 2);
            _c1.SetBounds(padX, Theme.S(8), cw, Theme.S(92));
            _c2.SetBounds(padX, Theme.S(108), cw, Theme.S(118));
            _c3.SetBounds(padX, Theme.S(236), cw, Theme.S(92));
            _banner.SetBounds(padX, Theme.S(336), cw, Theme.S(52));
            _c4.SetBounds(padX, Theme.S(396), cw, Math.Max(Theme.S(140), _body.Height - Theme.S(400)));

            // 卡片 1 内部
            int bx = _c1.Width;
            _btnOpen.SetBounds(bx - Theme.S(134), Theme.S(43), Theme.S(118), Theme.S(32));
            _btnPaste.SetBounds(_btnOpen.Left - Theme.S(84), Theme.S(43), Theme.S(76), Theme.S(32));
            _link.SetBounds(Theme.S(16), Theme.S(40), Math.Max(Theme.S(120), _btnPaste.Left - Theme.S(24)), Theme.S(38));

            // 卡片 2 内部
            _lblUnit.SetBounds(_c2.Width - Theme.S(56), Theme.S(46), Theme.S(40), Theme.S(20));
            _minutes.SetBounds(_lblUnit.Left - Theme.S(62), Theme.S(44), Theme.S(56), Theme.S(24));
            _lblMin.SetBounds(_minutes.Left - Theme.S(84), Theme.S(46), Theme.S(80), Theme.S(20));
            _steps.SetBounds(Theme.S(16), Theme.S(38), Math.Max(Theme.S(200), _lblMin.Left - Theme.S(32)), Theme.S(60));

            // 卡片 3 内部
            int by = Theme.S(40), bh = Theme.S(34);
            _btnDoctor.SetBounds(Theme.S(16), by, Theme.S(108), bh);
            _btnSetup.SetBounds(Theme.S(132), by, Theme.S(108), bh);
            _btnKey.SetBounds(Theme.S(248), by, Theme.S(150), bh);
            _btnDecrypt.SetBounds(Theme.S(406), by, Theme.S(108), bh);
            _btnClean.SetBounds(Theme.S(522), by, Theme.S(108), bh);
            _btnStop.SetBounds(Theme.S(638), by, Theme.S(76), bh);

            // 卡片 4 内部
            _btnFolder.SetBounds(_c4.Width - Theme.S(128), Theme.S(8), Theme.S(112), Theme.S(28));
            _btnSaveLog.SetBounds(_btnFolder.Left - Theme.S(92), Theme.S(8), Theme.S(84), Theme.S(28));
            _btnClear.SetBounds(_btnSaveLog.Left - Theme.S(70), Theme.S(8), Theme.S(62), Theme.S(28));
            _log.SetBounds(Theme.S(16), Theme.S(40), Math.Max(Theme.S(120), _c4.Width - Theme.S(32)), Math.Max(Theme.S(60), _c4.Height - Theme.S(56)));

            // 状态栏
            _statusLeft.SetBounds(Theme.S(18), Theme.S(6), Math.Max(Theme.S(100), W / 2 - Theme.S(30)), Theme.S(18));
            _statusRight.SetBounds(W / 2, Theme.S(6), Math.Max(Theme.S(100), W / 2 - Theme.S(20)), Theme.S(18));
        }

        private void OnLoaded()
        {
            try
            {
                Bootstrap.EnsureRuntime(AppendLog);
                if (!Directory.Exists(Bootstrap.LogDir)) Directory.CreateDirectory(Bootstrap.LogDir);
                _logFile = Path.Combine(Bootstrap.LogDir, "gui-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
                AppendLog("运行时目录: " + Bootstrap.BaseDir);
                AppendLog("输出目录: " + _outDir);
                try
                {
                    using (var g = CreateGraphics())
                        AppendLog(string.Format("显示: DPI={0:0} 缩放={1:0}%  客户区={2}x{3}",
                            g.DpiX, g.DpiX / 96f * 100f, ClientSize.Width, ClientSize.Height));
                }
                catch { }
                AppendLog("提示: 先点【环境检查】；安装抓包后需完全重启微信，并在微信里播放视频。");
                RefreshStatus();
                _timer.Start();
                SetBanner(Banner.Kind.Info, "第 1 步：点击【环境检查】确认本机可用（PKI / certutil / 注册表 / 微信进程）。");
                LayoutAll();
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "初始化失败: " + ex.Message, "错误", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        // ---------------- 日志/状态 ----------------
        private void AppendLog(string line)
        {
            if (line == null) return;
            if (InvokeRequired) { BeginInvoke(new Action<string>(AppendLog), line); return; }
            _log.AppendText(line + Environment.NewLine);
            _log.SelectionStart = _log.TextLength; _log.ScrollToCaret();
            try { if (_logFile != null) File.AppendAllText(_logFile, line + Environment.NewLine); } catch { }
        }

        private void SetStatus(string s)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(SetStatus), s); return; }
            _statusLeft.Text = s;
        }

        private void SetBanner(Banner.Kind kind, string text)
        {
            if (InvokeRequired) { BeginInvoke(new Action<Banner.Kind, string>(SetBanner), kind, text); return; }
            _banner.Style = kind;
            _banner.Body = text;
        }

        private void RefreshStatus()
        {
            try
            {
                var vids = Path.Combine(Bootstrap.StateDir, "videos.jsonl");
                int n = 0;
                if (File.Exists(vids)) n = File.ReadAllLines(vids).Length;
                bool running = false;
                var pidf = Path.Combine(Bootstrap.StateDir, "proxy.pid");
                if (File.Exists(pidf))
                {
                    // pid 存活不够（PID 会被系统回收）：还要确认代理端口真的在监听
                    try { int pid = int.Parse(File.ReadAllText(pidf).Trim()); Process.GetProcessById(pid); running = PortListening(18080); }
                    catch { running = false; }
                }
                bool hasKey = File.Exists(Path.Combine(Bootstrap.StateDir, "keys", "keystream.bin"));
                string text = running ? (hasKey ? "抓包中 · 密钥流已就绪" : "抓包中 · 已捕获 " + n + " 条取流")
                                      : (n > 0 ? "已停止 · 历史捕获 " + n + " 条" : "抓包未启动");
                _pill.SetText(text, running ? (hasKey ? Theme.Success : Theme.Accent) : Theme.Muted);
                SetStatus(string.Format("取流 {0} 条　·　{1}　·　输出目录 {2}", n, hasKey ? "密钥流已取到" : "尚未取到密钥流", _outDir));
            }
            catch { }
        }

        private static bool PortListening(int port)
        {
            try
            {
                using (var c = new System.Net.Sockets.TcpClient())
                {
                    var ar = c.BeginConnect("127.0.0.1", port, null, null);
                    bool ok = ar.AsyncWaitHandle.WaitOne(300);
                    if (ok && c.Connected) { c.EndConnect(ar); return true; }
                    return false;
                }
            }
            catch { return false; }
        }

        private void OpenWeixinLink(string url)
        {
            if (string.IsNullOrWhiteSpace(url)) { MessageBox.Show(this, "请先粘贴视频号链接", "提示"); return; }
            try
            {
                var exe = @"D:\Weixin\Weixin.exe";
                if (File.Exists(exe)) Process.Start(exe, "\"" + url + "\"");
                else Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
            }
            catch (Exception ex) { MessageBox.Show(this, "打开失败: " + ex.Message, "错误"); }
        }

        // ---------------- 命令执行 ----------------
        private async Task<int> RunCliAsync(string args, string stepName)
        {
            var psi = new ProcessStartInfo
            {
                FileName = Bootstrap.NodeExe,
                Arguments = "\"" + Path.Combine(Bootstrap.ScriptsDir, "sph.mjs") + "\" " + args
                            + " --state \"" + Bootstrap.StateDir + "\" --outdir \"" + _outDir + "\"",
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
                CreateNoWindow = true,
                WorkingDirectory = Bootstrap.ScriptsDir,
            };
            AppendLog("$ sph.mjs " + args);
            var tcs = new TaskCompletionSource<int>();
            var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
            proc.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) AppendLog(e.Data); };
            proc.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) AppendLog("! " + e.Data); };
            proc.Exited += delegate { try { tcs.TrySetResult(proc.ExitCode); } catch { tcs.TrySetResult(-1); } };
            _current = proc;
            _btnStop.Enabled = true;
            proc.Start();
            proc.BeginOutputReadLine(); proc.BeginErrorReadLine();
            int code = await tcs.Task;
            _btnStop.Enabled = false; _current = null;
            AppendLog("── " + stepName + " 结束（exit " + code + "）");
            RefreshStatus();
            return code;
        }

        private void StopCurrent()
        {
            var p = _current;
            if (p == null) return;
            try
            {
                p.Kill();
                AppendLog("已请求停止当前步骤（后台扫描器可用【⑤ 清理还原】收尾）");
                SetBanner(Banner.Kind.Warn, "已请求停止。若扫描器仍在跑，点【⑤ 清理还原】收尾。");
            }
            catch { }
        }

        private async void RunStepAsync(int stepIdx, string cli)
        {
            _steps.SetState(stepIdx, "run");
            int code = await RunCliAsync(cli, StepNames[stepIdx]);
            _steps.SetState(stepIdx, code == 0 ? "ok" : "fail");
            if (code != 0) MessageBox.Show(this, StepNames[stepIdx] + " 失败（exit " + code + "），详见日志。", "失败", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private async void DoSetup()
        {
            if (MessageBox.Show(this,
                "即将执行：\n\n· 写入 PAC 并启动本地 MITM\n· 把临时 CA 装入【当前用户\\受信任的根】\n· 把系统代理指向本地 PAC\n\n" +
                "其余流量仍走你原来的代理（setup 会先备份并校验，任何异常都会中止且不改动网络）。\n\n继续？",
                "确认安装抓包", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
            _steps.SetState(1, "run");
            int code = await RunCliAsync("setup", "setup");
            _steps.SetState(1, code == 0 ? "ok" : "fail");
            if (code != 0) { MessageBox.Show(this, "安装失败，详见日志。", "失败"); return; }
            SetBanner(Banner.Kind.Warn, "接下来：1) 完全退出微信（托盘退出）并重开；2) 在微信里打开链接并持续播放 30 秒以上；3) 回到本窗口点【③ 抓取 + 取密钥】。");
        }

        private async void DoWatchAndKey()
        {
            _steps.SetState(2, "run");
            int c1 = await RunCliAsync("watch", "watch");
            if (c1 != 0)
            {
                _steps.SetState(2, "fail");
                SetBanner(Banner.Kind.Warn, "还没抓到取流地址：确认微信已重启、链接已在微信里打开并正在播放。");
                MessageBox.Show(this, "抓取失败：还没有抓到取流地址。\n请确认：微信已完全重启、已在微信里打开视频号并播放。", "抓取失败");
                return;
            }
            SetBanner(Banner.Kind.Info, "正在扫描内存取密钥流 —— 请保持微信里的视频持续播放，不要关闭窗口…");
            int c2 = await RunCliAsync("key --minutes " + ((int)_minutes.Value), "key");
            _steps.SetState(2, c2 == 0 ? "ok" : "fail");
            if (c2 == 0) SetBanner(Banner.Kind.Ok, "密钥流已取到 ✅ 现在点【④ 下载解密】即可导出原始视频。");
            else
            {
                SetBanner(Banner.Kind.Warn, "取密钥失败：最常见原因是扫描与播放没有重叠 —— 保持播放 30 秒以上后重试。");
                MessageBox.Show(this, "取密钥失败。\n最常见原因：扫描与播放没有重叠 —— 请保持播放 30 秒以上后重试。", "取密钥失败");
            }
        }

        private async void DoCleanup()
        {
            if (MessageBox.Show(this,
                "即将执行：\n\n· 停止代理与后台扫描器\n· 还原系统代理设置（还原到你原来的值）\n· 移除临时 CA\n\n" +
                "删除根证书时 Windows 会弹安全确认框，请点【是】。\n\n继续？",
                "确认清理", MessageBoxButtons.OKCancel, MessageBoxIcon.Question) != DialogResult.OK) return;
            _steps.SetState(4, "run");
            int code = await RunCliAsync("cleanup", "cleanup");
            _steps.SetState(4, code == 0 ? "ok" : "fail");
            SetBanner(Banner.Kind.Ok, "已清理。如证书确认框没点，请手动删：certmgr.msc → 受信任的根证书颁发机构 → DSH Local MITM CA。");
        }

        private async void DoEmergencyRestore()
        {
            if (MessageBox.Show(this, "紧急还原：停止后台扫描器、把系统代理恢复为备份值、并尝试删除临时 CA。\n\n继续？",
                "紧急还原", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
            _steps.SetState(4, "run");
            await RunCliAsync("stopscans", "stopscans");
            int code = await RunCliAsync("cleanup", "cleanup");
            _steps.SetState(4, code == 0 ? "ok" : "fail");
            SetBanner(Banner.Kind.Ok, "已执行还原。请确认状态胶囊与系统代理设置均已恢复。");
        }

        private void SaveLog()
        {
            try
            {
                var dlg = new SaveFileDialog { FileName = "wx-sph-dl-log.txt", Filter = "文本文件|*.txt" };
                if (dlg.ShowDialog(this) == DialogResult.OK) File.WriteAllText(dlg.FileName, _log.Text);
            }
            catch { }
        }
    }

    // 应用图标（运行时绘制，与构建时嵌入的 .ico 同风格）
    internal static class AppIcon
    {
        public static Icon Create()
        {
            int S = Theme.S(64);
            using (var bmp = new Bitmap(S, S))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    using (var path = Theme.Round(new Rectangle(Theme.S(2), Theme.S(2), S - Theme.S(4), S - Theme.S(4)), Theme.S(14)))
                    using (var lg = new LinearGradientBrush(new Rectangle(0, 0, S, S), Color.FromArgb(0x4A, 0x8B, 0xF0), Color.FromArgb(0x24, 0x56, 0xBB), 60f))
                        g.FillPath(lg, path);
                    using (var pen = new Pen(Color.White, Theme.SF(5f)))
                    {
                        pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                        float cx = S / 2f;
                        g.DrawLine(pen, cx, S * 0.24f, cx, S * 0.58f);
                        g.DrawLine(pen, cx, S * 0.58f, cx - S * 0.15f, S * 0.43f);
                        g.DrawLine(pen, cx, S * 0.58f, cx + S * 0.15f, S * 0.43f);
                    }
                    using (var pen = new Pen(Color.FromArgb(200, Color.White), Theme.SF(5f)))
                    {
                        pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                        g.DrawLine(pen, S * 0.30f, S * 0.74f, S * 0.70f, S * 0.74f);
                    }
                }
                IntPtr h = bmp.GetHicon();
                return Icon.FromHandle(h);
            }
        }
    }

    internal sealed class LogoBox : Control
    {
        public LogoBox()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            BackColor = Theme.Bg;
        }
        protected override void OnPaint(PaintEventArgs e)
        {
            var g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            var r = new Rectangle(0, 0, Width - 1, Height - 1);
            using (var path = Theme.Round(r, Theme.S(10)))
            using (var lg = new LinearGradientBrush(r, Color.FromArgb(0x4A, 0x8B, 0xF0), Color.FromArgb(0x24, 0x56, 0xBB), 60f))
                g.FillPath(lg, path);
            float cx = Width / 2f, cy = Height * 0.40f;
            using (var pen = new Pen(Color.White, Theme.SF(3.6f)))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                g.DrawLine(pen, cx, Height * 0.24f, cx, cy);
                g.DrawLine(pen, cx, cy, cx - Width * 0.16f, cy - Height * 0.16f);
                g.DrawLine(pen, cx, cy, cx + Width * 0.16f, cy - Height * 0.16f);
            }
            using (var pen = new Pen(Color.FromArgb(210, Color.White), Theme.SF(3.6f)))
            {
                pen.StartCap = LineCap.Round; pen.EndCap = LineCap.Round;
                g.DrawLine(pen, Width * 0.28f, Height * 0.74f, Width * 0.72f, Height * 0.74f);
            }
        }
    }

    // ---------------- 入口 ----------------
    internal static class Program
    {
        [STAThread]
        private static int Main(string[] args)
        {
            Native.EnableDpiAwareness();
            Theme.Scale = Native.DetectScale();
            bool selftest = Array.IndexOf(args, "--selftest") >= 0;
            string outDir = null, shot = null;
            for (int i = 0; i < args.Length - 1; i++)
            {
                if (args[i] == "--outdir") outDir = args[i + 1];
                if (args[i] == "--screenshot") shot = args[i + 1];
            }

            if (selftest) return SelfTest();

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            if (outDir == null) outDir = Bootstrap.OutDir;
            try
            {
                var form = new MainForm(outDir);
                if (shot != null)
                {
                    form.Shown += delegate
                    {
                        var t = new Timer();
                        t.Interval = 2500;
                        t.Tick += delegate
                        {
                            t.Stop();
                            try
                            {
                                using (var bmp = new Bitmap(form.ClientSize.Width, form.ClientSize.Height))
                                {
                                    form.DrawToBitmap(bmp, new Rectangle(0, 0, bmp.Width, bmp.Height));
                                    string dir = Path.GetDirectoryName(shot);
                                    if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
                                    bmp.Save(shot, System.Drawing.Imaging.ImageFormat.Png);
                                }
                            }
                            catch (Exception ex) { try { File.WriteAllText(shot + ".error.txt", ex.ToString()); } catch { } }
                            form.Close();
                        };
                        t.Start();
                    };
                }
                Application.Run(form);
                return 0;
            }
            catch (Exception ex)
            {
                string path = Path.Combine(Path.GetTempPath(), "wx-sph-dl-ui-error.txt");
                try { File.WriteAllText(path, DateTime.Now.ToString("s") + Environment.NewLine + ex.ToString()); } catch { }
                try { MessageBox.Show("界面启动失败：\n\n" + ex.Message + "\n\n详细信息已写入：\n" + path, "wx-sph-dl 错误", MessageBoxButtons.OK, MessageBoxIcon.Error); } catch { }
                return 2;
            }
        }

        private static int SelfTest()
        {
            var sb = new StringBuilder();
            int failures = 0;
            Action<string, bool> chk = delegate(string label, bool ok) { sb.AppendLine((ok ? "✅ " : "✗ ") + label); if (!ok) failures++; };
            try
            {
                Bootstrap.EnsureRuntime(delegate(string s) { sb.AppendLine("· " + s); });
                chk("解包 runtime: node.exe 存在", File.Exists(Bootstrap.NodeExe));
                foreach (var f in new[] { "sph.mjs", "proxy.mjs" })
                    chk("解包脚本: " + f, File.Exists(Path.Combine(Bootstrap.ScriptsDir, f)));
                foreach (var f in new[] { "win.ps1", "certs.ps1", "purge-certs.ps1" })
                    chk("解包脚本: ps/" + f, File.Exists(Path.Combine(Bootstrap.ScriptsDir, "ps", f)));

                Action<string, string> run = delegate(string tag, string cmdArgs)
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = Bootstrap.NodeExe,
                        Arguments = "\"" + Path.Combine(Bootstrap.ScriptsDir, "sph.mjs") + "\" " + cmdArgs
                                    + " --state \"" + Bootstrap.StateDir + "\" --outdir \"" + Bootstrap.OutDir + "\"",
                        UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
                        StandardOutputEncoding = Encoding.UTF8, CreateNoWindow = true, WorkingDirectory = Bootstrap.ScriptsDir,
                    };
                    var p = Process.Start(psi);
                    string outp = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                    p.WaitForExit(180000);
                    sb.AppendLine("--- " + tag + " (exit " + p.ExitCode + ")");
                    sb.AppendLine(outp.Trim());
                    chk(tag + " 退出码 0", p.ExitCode == 0);
                };

                run("doctor", "doctor");
                run("setup --dry-run", "setup --dry-run");

                var psi2 = new ProcessStartInfo
                {
                    FileName = Bootstrap.NodeExe,
                    Arguments = "\"" + Path.Combine(Bootstrap.ScriptsDir, "mitm-selftest.mjs") + "\" --state \""
                                + Path.Combine(Bootstrap.StateDir, "selftest") + "\" --port 18098",
                    UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = Encoding.UTF8, CreateNoWindow = true, WorkingDirectory = Bootstrap.ScriptsDir,
                };
                var p2 = Process.Start(psi2);
                string o2 = p2.StandardOutput.ReadToEnd() + p2.StandardError.ReadToEnd();
                p2.WaitForExit(180000);
                sb.AppendLine("--- mitm-selftest (exit " + p2.ExitCode + ")");
                sb.AppendLine(o2.Trim());
                chk("MITM 证书链自检通过", p2.ExitCode == 0);
            }
            catch (Exception ex)
            {
                sb.AppendLine("✗ 异常: " + ex);
                failures++;
            }

            sb.AppendLine(failures == 0 ? "\nEXE-SELFTEST-OK" : "\nEXE-SELFTEST-FAIL");
            string text = sb.ToString();
            try
            {
                Directory.CreateDirectory(Bootstrap.LogDir);
                File.WriteAllText(Path.Combine(Bootstrap.LogDir, "selftest-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log"), text);
            }
            catch { }
            try { AttachConsole(-1); Console.Out.Write(text); } catch { }
            return failures == 0 ? 0 : 1;
        }

        [DllImport("kernel32.dll")]
        private static extern bool AttachConsole(int dwProcessId);
    }
}
