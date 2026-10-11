using System.Text.Json;
namespace OpenDisplay.Host;
internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--scale-check"))
        {
            var display = DisplaySource.GetAll().Single(d => d.Virtual && !d.Primary);
            var before = DisplaySource.GetAll().Select(d => new { d.DeviceName, percent = DisplayScaling.GetPercent(d.DeviceName) }).ToArray();
            bool changed = DisplayScaling.FitVirtualDisplay(display, int.Parse(args[1]));
            var after = DisplaySource.GetAll().Select(d => new { d.DeviceName, percent = DisplayScaling.GetPercent(d.DeviceName) }).ToArray();
            File.WriteAllText(args[2], JsonSerializer.Serialize(new { changed, before, after }));
            return;
        }
        if (args.Contains("--arrow-check"))
        {
            using var arrow = new EdgeArrow(DisplaySource.GetAll().First(d => d.Primary).Bounds, "left");
            Application.Run(arrow);
            File.WriteAllText(args[1], JsonSerializer.Serialize(new { arrow.PresentedFrames, arrow.PresentationError, arrow.IsDisposed }));
            return;
        }
        if (args.Contains("--arrow-preview"))
        {
            string folder = args.ElementAtOrDefault(1) ?? "."; Directory.CreateDirectory(folder);
            foreach (var edge in new[] { "left", "right", "top", "bottom" })
            {
                using var art = EdgeArrow.CreateArtwork(edge, 2);
                art.Save(Path.Combine(folder, $"arrow-{edge}.png"));
            }
            return;
        }
        if (args.Contains("--fit-check"))
        {
            var source = DisplaySource.GetAll().First(d => d.Virtual);
            var fitted = AutomaticDisplay.Fit(source, int.Parse(args[1]), int.Parse(args[2]), 30);
            File.WriteAllText(args[3], JsonSerializer.Serialize(new { before = source, after = fitted }, new JsonSerializerOptions { WriteIndented = true }));
            return;
        }
        if (args.Contains("--render-test"))
        {
            string folder = args.ElementAtOrDefault(1) ?? "."; Directory.CreateDirectory(folder);
            var preview = new Settings { Persist = false, AutoConnect = false, ProtectedKey = Convert.ToBase64String(System.Security.Cryptography.ProtectedData.Protect(new byte[32], null, System.Security.Cryptography.DataProtectionScope.CurrentUser)) };
            using var form = new MainForm(preview, _ => { }) { ShowInTaskbar = false, Opacity = 0 };
            form.Show(); Application.DoEvents();
            foreach (var size in new[] { new Size(960, 690), new Size(1100, 800) })
            {
                double scale = form.DeviceDpi / 96.0;
                form.ClientSize = new Size((int)(size.Width * scale), (int)(size.Height * scale)); form.PerformLayout(); Application.DoEvents();
                using var bitmap = new Bitmap(form.Width, form.Height); form.DrawToBitmap(bitmap, new Rectangle(Point.Empty, form.Size));
                bitmap.Save(Path.Combine(folder, $"host-{size.Width}.png"));
            }
            form.RenderStateChecksAsync(folder).GetAwaiter().GetResult();
            return;
        }
        if (args.Contains("--diagnose"))
        {
            var result = new { dpiMode = Application.HighDpiMode.ToString(), displays = DisplaySource.GetAll(), scaling = DisplaySource.GetAll().Select(d => new { d.DeviceName, percent = DisplayScaling.GetPercent(d.DeviceName), currentMode = AutomaticDisplay.GetCurrentMode(d.DeviceName) }), graphicsOutputs = GraphicsOutput.GetAll(), modes = DisplaySource.GetAll().Where(d => d.Virtual).Select(d => new { d.DeviceName, modes = AutomaticDisplay.GetModes(d.DeviceName) }), ffmpeg = VideoSender.FindFfmpeg("") };
            File.WriteAllText(args.ElementAtOrDefault(1) ?? "diagnostics.json", JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true })); return;
        }
        using var mutex = new Mutex(true, "Local\\OpenDisplay.Host", out bool first);
        if (!first) { MessageBox.Show("OpenDisplay is already running. Open it from the Windows tray.", "OpenDisplay"); return; }
        try { Application.Run(new MainForm(Settings.Load())); }
        catch (Exception e) { MessageBox.Show(e.Message, "OpenDisplay could not start", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }
}
