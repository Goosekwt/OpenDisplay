using System.Drawing.Drawing2D;
namespace OpenDisplay.Host;

public sealed class EdgeArrow : Form
{
    private readonly string edge;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 100 };
    private int ticks;
    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams { get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x20 | 0x80; return cp; } }
    public EdgeArrow(Rectangle screen, string edge)
    {
        this.edge = edge; FormBorderStyle = FormBorderStyle.None; ShowInTaskbar = false; TopMost = true; StartPosition = FormStartPosition.Manual;
        BackColor = Color.Magenta; TransparencyKey = Color.Magenta; DoubleBuffered = true;
        Size = new(152, 92);
        Location = edge switch
        {
            "left" => new(screen.Left + 14, screen.Top + (screen.Height - Height) / 2),
            "right" => new(screen.Right - Width - 14, screen.Top + (screen.Height - Height) / 2),
            "top" => new(screen.Left + (screen.Width - Width) / 2, screen.Top + 14),
            _ => new(screen.Left + (screen.Width - Width) / 2, screen.Bottom - Height - 14)
        };
        timer.Tick += (_, _) => { ticks++; if (ticks >= 25) Opacity = Math.Max(0, (30 - ticks) / 5.0); if (ticks >= 30) Close(); };
        Shown += (_, _) => timer.Start(); FormClosed += (_, _) => timer.Dispose();
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var back = new SolidBrush(Color.FromArgb(20, 93, 215));
        e.Graphics.FillRoundedRectangle(back, new Rectangle(0, 0, Width - 1, Height - 1), new Size(18, 18));
        e.Graphics.TranslateTransform(Width / 2f, 34);
        e.Graphics.RotateTransform(edge switch { "right" => 0, "bottom" => 90, "left" => 180, _ => 270 });
        using var pen = new Pen(Color.White, 4) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        e.Graphics.DrawLine(pen, -23, 0, 21, 0); e.Graphics.DrawLines(pen, [new(6, -15), new(22, 0), new(6, 15)]);
        e.Graphics.ResetTransform();
        TextRenderer.DrawText(e.Graphics, "iPad this way", SystemFonts.MessageBoxFont, new Rectangle(0, 62, Width, 24), Color.White, TextFormatFlags.HorizontalCenter);
    }
}
