using System.Diagnostics;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

namespace OpenDisplay.Host;

public sealed class EdgeArrow : Form
{
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 15 };
    private readonly Stopwatch clock = new();
    private readonly Point anchor, outward;
    private readonly float scale;
    private readonly bool animate = AnimationsEnabled();
    private readonly Bitmap artwork;
    private nint memoryDc, bitmapHandle, previousBitmap;
    internal int PresentedFrames { get; private set; }
    internal int PresentationError { get; private set; }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x20 | 0x80 | 0x80000; return cp; }
    }

    public EdgeArrow(Rectangle screen, string edge)
    {
        FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true;
        StartPosition = FormStartPosition.Manual; AutoScaleMode = AutoScaleMode.None;
        AccessibleName = $"Your iPad is {edge}"; AccessibleRole = AccessibleRole.Graphic;
        var monitor = MonitorFromPoint(new(screen.X + screen.Width / 2, screen.Y + screen.Height / 2), 2);
        scale = GetScaleFactorForMonitor(monitor, out int percent) == 0 ? Math.Clamp(percent / 100f, 1, 4) : 1;
        artwork = CreateArtwork(edge, scale);
        Size = artwork.Size;
        int inset = (int)Math.Round(8 * scale);
        anchor = edge switch
        {
            "left" => new(screen.Left + inset, screen.Top + (screen.Height - Height) / 2),
            "right" => new(screen.Right - Width - inset, screen.Top + (screen.Height - Height) / 2),
            "top" => new(screen.Left + (screen.Width - Width) / 2, screen.Top + inset),
            _ => new(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - inset)
        };
        outward = edge switch { "left" => new(-1, 0), "right" => new(1, 0), "top" => new(0, -1), _ => new(0, 1) };
        Location = anchor;
        timer.Tick += (_, _) => { if (clock.Elapsed.TotalSeconds >= 3) Close(); else Present(clock.Elapsed.TotalSeconds); };
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        memoryDc = CreateCompatibleDC(0);
        bitmapHandle = artwork.GetHbitmap(Color.FromArgb(0));
        previousBitmap = SelectObject(memoryDc, bitmapHandle);
        clock.Restart(); Present(0); if (!IsDisposed) timer.Start();
    }

    private void Present(double seconds)
    {
        var motion = MotionAt(seconds, animate);
        var position = new Point(anchor.X + (int)Math.Round(outward.X * motion.Offset * scale), anchor.Y + (int)Math.Round(outward.Y * motion.Offset * scale));
        var origin = Point.Empty;
        var size = artwork.Size;
        var blend = new Blend { Operation = 0, Alpha = (byte)Math.Round(motion.Opacity * 255), Format = 1 };
        // A small cached surface moves/fades; alpha edges avoid color-key fringes.
        // The window never steals focus or pointer input.
        if (!UpdateLayeredWindow(Handle, 0, ref position, ref size, memoryDc, ref origin, 0, ref blend, 2)) { PresentationError = Marshal.GetLastWin32Error(); Close(); }
        else PresentedFrames++;
    }

    internal static (double Offset, double Opacity) MotionAt(double seconds, bool animate)
    {
        double enter = Math.Clamp(seconds / (animate ? .35 : .2), 0, 1);
        double exit = Math.Clamp((3 - seconds) / .2, 0, 1);
        double opacity = Math.Min(1 - Math.Pow(1 - enter, 3), exit);
        double nudge = 5 * (1 - Math.Cos(Math.PI * Math.Max(0, seconds - .35) / .7));
        return (animate ? 24 * Math.Pow(1 - enter, 3) + nudge + 10 * (1 - exit) : 0, opacity);
    }

    internal static Bitmap CreateArtwork(string edge, float scale)
    {
        var bitmap = new Bitmap((int)Math.Ceiling(128 * scale), (int)Math.Ceiling(128 * scale), PixelFormat.Format32bppPArgb);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.ScaleTransform(scale, scale);
        // Soft downward shadow, rendered once per indicator rather than per frame.
        for (int radius = 12; radius >= 1; radius--)
        {
            using var shadow = new SolidBrush(Color.FromArgb(radius > 9 ? 2 : 5, 0, 0, 0));
            g.FillEllipse(shadow, 16 - radius, 19 - radius, 96 + 2 * radius, 96 + 2 * radius);
        }
        using var blue = new SolidBrush(Color.FromArgb(0, 122, 255));
        g.FillEllipse(blue, 16, 16, 96, 96);
        g.TranslateTransform(64, 64);
        g.RotateTransform(edge switch { "right" => 0, "bottom" => 90, "left" => 180, _ => 270 });
        using var pen = new Pen(Color.White, 5) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        g.DrawLine(pen, -20, 0, 19, 0);
        g.DrawLines(pen, [new PointF(3, -16), new PointF(20, 0), new PointF(3, 16)]);
        return bitmap;
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            timer.Dispose();
            if (memoryDc != 0)
            {
                SelectObject(memoryDc, previousBitmap); DeleteObject(bitmapHandle); DeleteDC(memoryDc);
                memoryDc = bitmapHandle = previousBitmap = 0;
            }
            artwork.Dispose();
        }
        base.Dispose(disposing);
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)] private struct Blend { public byte Operation, Flags, Alpha, Format; }
    private static bool AnimationsEnabled() => SystemParametersInfo(0x1042, 0, out bool enabled, 0) && enabled;
    [DllImport("user32.dll")] private static extern bool SystemParametersInfo(uint action, uint parameter, [MarshalAs(UnmanagedType.Bool)] out bool value, uint flags);
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("shcore.dll")] private static extern int GetScaleFactorForMonitor(nint monitor, out int percent);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(nint window, nint targetDc, ref Point position, ref Size size, nint sourceDc, ref Point source, uint color, ref Blend blend, uint flags);
    [DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);
}
