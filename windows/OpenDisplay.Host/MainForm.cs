using System.Diagnostics;
using System.Text.Json;
using Microsoft.Win32;
using OpenDisplay.Core;
using QRCoder;
namespace OpenDisplay.Host;

public sealed class MainForm : Form
{
    private readonly Settings settings;
    private readonly byte[] key;
    private readonly Action<string> copyText;
    private readonly Label pairingFeedback = new() { AutoSize = true, ForeColor = Color.FromArgb(28, 72, 128), MaximumSize = new(250, 0) };
    private readonly TableLayoutPanel advanced = new() { Dock = DockStyle.Fill, ColumnCount = 1, AutoScroll = true, Padding = new(0, 0, 24, 0), RowCount = 0, Visible = false };
    private readonly ComboBox displays = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly TextBox wifi = new() { Dock = DockStyle.Fill, PlaceholderText = "Automatic discovery (or iPad IP address)" };
    private readonly CheckBox mirror = new() { Text = "Mirror an existing screen for testing", AutoSize = true };
    private readonly ComboBox side = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 140 };
    private readonly ComboBox frameRate = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 140 };
    private readonly Label status = new() { Text = "Ready to pair", AutoSize = true, MaximumSize = new(560, 0), ForeColor = Color.FromArgb(28, 72, 128) };
    private readonly Label statistics = new() { AutoSize = true, ForeColor = Color.DimGray };
    private readonly Button start = new() { Text = "Start connecting", AutoSize = true, MinimumSize = new(160, 42) };
    private readonly Button identify = new() { Text = "Show position arrows", AutoSize = true, Enabled = false, MinimumSize = new(160, 42) };
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };
    private CancellationTokenSource? stop;
    private Task? running;
    private ConnectionManager? manager;
    private bool exiting, refreshing;
    private long lastBytes;

    public MainForm(Settings settings, Action<string>? copyText = null)
    {
        this.settings = settings; key = settings.GetKey();
        this.copyText = copyText ?? Clipboard.SetText;
        Text = "OpenDisplay"; Icon = AppIcon.Window; Font = new Font("Segoe UI", 10); AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new(960, 690); MinimumSize = new(870, 700); StartPosition = FormStartPosition.CenterScreen; BackColor = Color.FromArgb(247, 248, 250);
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(32), ColumnCount = 2, RowCount = 3 };
        root.ColumnStyles.Add(new(SizeType.Percent, 64)); root.ColumnStyles.Add(new(SizeType.Percent, 36));
        root.RowStyles.Add(new(SizeType.Absolute, 90)); root.RowStyles.Add(new(SizeType.Percent, 100)); root.RowStyles.Add(new(SizeType.Absolute, 58)); Controls.Add(root);
        var heading = new Label { Text = "Your iPad. More room.", Font = new Font("Segoe UI", 25, FontStyle.Bold), AutoSize = true, Padding = new(0, 0, 0, 12) };
        root.Controls.Add(heading, 0, 0); root.SetColumnSpan(heading, 2);
        var left = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 5, Padding = new(0, 0, 24, 0) };
        for (int i = 0; i < 4; i++) left.RowStyles.Add(new(SizeType.AutoSize));
        left.RowStyles.Add(new(SizeType.Percent, 100)); root.Controls.Add(left, 0, 1);
        left.Controls.Add(new Label { Text = "Plug in your iPad and open OpenDisplay.\nYour desktop connects and fits automatically.", AutoSize = true, MaximumSize = new(520, 0), Margin = new(0, 0, 0, 24) }, 0, 0);
        status.Margin = new(0, 0, 0, 12); left.Controls.Add(status, 0, 1);
        statistics.Margin = new(0, 0, 0, 18); left.Controls.Add(statistics, 0, 2);
        var advancedLink = Link("Advanced options", (_, _) => { advanced.Visible = !advanced.Visible; });
        left.Controls.Add(advancedLink, 0, 3); left.Controls.Add(advanced, 0, 4);
        var form = advanced;
        void Row(Control control, int height = 40) { int row = form.RowCount++; form.RowStyles.Add(new(SizeType.AutoSize)); control.MinimumSize = new(0, height); control.Margin = new(0, 6, 0, 10); form.Controls.Add(control, 0, row); }
        Row(new Label { Text = "Display to send", AutoSize = true, Font = new(Font, FontStyle.Bold) }, 29); Row(displays, 42);
        var displayActions = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = true, AutoSize = true };
        displayActions.Controls.Add(Link("Refresh displays", (_, _) => RefreshDisplays()));
        displayActions.Controls.Add(Link("Arrange in Windows", (_, _) => Open("ms-settings:display")));
        displayActions.Controls.Add(Link("Set up extra display", (_, _) => Open("https://github.com/VirtualDrivers/Virtual-Display-Driver/releases"))); Row(displayActions, 40);
        Row(mirror, 35);
        side.Items.AddRange(["right", "left", "top", "bottom"]); side.SelectedItem = settings.MirrorSide; if (side.SelectedIndex < 0) side.SelectedIndex = 0;
        var position = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true }; position.Controls.Add(new Label { Text = "iPad position (mirror test)", AutoSize = true, Padding = new(0, 6, 6, 0) }); position.Controls.Add(side); Row(position, 43);
        Row(new Label { Text = "Wi-Fi fallback", AutoSize = true, Font = new(Font, FontStyle.Bold) }, 30); Row(wifi, 42);
        frameRate.Items.AddRange([30, 60]); frameRate.SelectedItem = settings.Fps; if (frameRate.SelectedIndex < 0) frameRate.SelectedIndex = 0;
        var fps = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true }; fps.Controls.Add(new Label { Text = "Frame rate target", AutoSize = true, Padding = new(0, 6, 6, 0) }); fps.Controls.Add(frameRate); Row(fps, 46);
        var startup = new CheckBox { Text = "Open at Windows sign-in", AutoSize = true };
        using (var runKey = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) startup.Checked = runKey?.GetValue("OpenDisplay") is not null;
        startup.CheckedChanged += (_, _) => { using var runKey = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"); if (startup.Checked) runKey.SetValue("OpenDisplay", '"' + Environment.ProcessPath! + "\" --tray"); else runKey.DeleteValue("OpenDisplay", false); }; Row(startup, 32);
        var pairing = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new(16, 0, 0, 0) };
        root.Controls.Add(pairing, 1, 1);
        pairing.Controls.Add(new Label { Text = "Pair once", Font = new(Font, FontStyle.Bold), AutoSize = true });
        pairing.Controls.Add(new Label { Text = "Scan in OpenDisplay on your iPad.", MaximumSize = new(250, 0), AutoSize = true, Margin = new(3, 10, 3, 12) });
        string uri = "opendisplay://pair?v=1&key=" + SecureChannel.EncodeKey(key) + "&name=" + Uri.EscapeDataString(Environment.MachineName);
        using var data = QRCodeGenerator.GenerateQrCode(uri, QRCodeGenerator.ECCLevel.M); using var code = new PngByteQRCode(data); using var png = new MemoryStream(code.GetGraphic(5)); using var img = Image.FromStream(png);
        pairing.Controls.Add(new PictureBox { Image = new Bitmap(img), Width = 248, Height = 248, SizeMode = PictureBoxSizeMode.Zoom, AccessibleName = "Pairing QR code. Use Copy pairing key if you cannot scan." });
        var copy = new Button { Text = "Copy pairing key", AutoSize = true, MinimumSize = new(170, 40), Margin = new(3, 14, 3, 12) }; copy.Click += (_, _) => CopyPairingKey(); pairing.Controls.Add(copy); pairing.Controls.Add(pairingFeedback);
        pairing.Controls.Add(new Label { Text = "Pair once, then leave this app running. Open OpenDisplay on your iPad to connect automatically.\n\nUSB is tried first. For Wi-Fi, keep both devices on the same local network.", MaximumSize = new(250, 0), AutoSize = true });
        pairing.Resize += (_, _) => { int width = Math.Max(200, pairing.ClientSize.Width - 40); foreach (var label in pairing.Controls.OfType<Label>()) label.MaximumSize = new(width, 0); foreach (var picture in pairing.Controls.OfType<PictureBox>()) picture.Size = new(Math.Min(width, (int)(248 * DeviceDpi / 96.0)), Math.Min(width, (int)(248 * DeviceDpi / 96.0))); };
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill }; actions.Controls.Add(start); actions.Controls.Add(identify); root.Controls.Add(actions, 0, 2); root.SetColumnSpan(actions, 2);
        tray = new NotifyIcon { Icon = AppIcon.Tray, Text = "OpenDisplay", Visible = true, ContextMenuStrip = new() };
        tray.ContextMenuStrip.Items.Add("Open OpenDisplay", null, (_, _) => Restore()); tray.ContextMenuStrip.Items.Add("Quit", null, async (_, _) => { exiting = true; await StopAsync(); Close(); }); tray.DoubleClick += (_, _) => Restore();
        start.Click += async (_, _) => { if (stop is null) await StartAsync(); else await StopAsync(); };
        identify.Click += async (_, _) => { try { if (manager is not null) await manager.IdentifyAsync(stop?.Token ?? default); } catch (Exception e) { status.Text = e.Message; } };
        mirror.Checked = settings.Mirror; wifi.Text = settings.WifiAddress; side.Enabled = mirror.Checked;
        mirror.CheckedChanged += (_, _) => { side.Enabled = mirror.Checked && stop is null; RefreshDisplays(); };
        RefreshDisplays();
        timer.Tick += (_, _) => { if (manager is null) return; long b = Interlocked.Read(ref manager.BytesSent); statistics.Text = b > 0 ? $"{Math.Max(0, b - lastBytes) * 8 / 1_000_000.0:F1} Mbps sent · local connection" : ""; lastBytes = b; }; timer.Start();
        SystemEvents.DisplaySettingsChanged += DisplaysChanged;
        Shown += async (_, _) => { if (settings.AutoConnect) await StartAsync(); if (Environment.GetCommandLineArgs().Contains("--tray")) Hide(); };
        FormClosing += (_, e) => { if (!exiting) { e.Cancel = true; Hide(); tray.ShowBalloonTip(1800, "OpenDisplay is still running", "Use the tray menu to reopen or quit.", ToolTipIcon.Info); } };
        FormClosed += (_, _) => { SystemEvents.DisplaySettingsChanged -= DisplaysChanged; tray.Dispose(); timer.Dispose(); System.Security.Cryptography.CryptographicOperations.ZeroMemory(key); };
    }
    private void Restore() { Show(); WindowState = FormWindowState.Normal; Activate(); }
    private static LinkLabel Link(string text, EventHandler click) { var l = new LinkLabel { Text = text, AutoSize = true, Margin = new(0, 4, 18, 0), LinkColor = Color.FromArgb(20, 80, 170) }; l.Click += click; return l; }
    private static void Open(string target) { try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch (Exception e) { MessageBox.Show(e.Message, "Could not open"); } }
    private void RefreshDisplays()
    {
        if (refreshing || stop is not null) return; refreshing = true;
        string previous = (displays.SelectedItem as DisplaySource)?.DeviceName ?? settings.DisplayName;
        displays.Items.Clear();
        var list = DisplaySource.GetAll().Where(d => mirror.Checked || d.Virtual).ToList();
        displays.Items.AddRange(list.Cast<object>().ToArray());
        displays.SelectedItem = list.FirstOrDefault(d => d.DeviceName == previous) ?? list.FirstOrDefault();
        if (list.Count == 0) status.Text = "Set up the open-source extra display, choose Extend in Windows, then refresh. Mirror mode is available for a capture test.";
        else status.Text = "Ready · press Start connecting to wait for your iPad";
        refreshing = false;
    }
    private void DisplaysChanged(object? sender, EventArgs e)
    {
        if (IsDisposed || !IsHandleCreated) return;
        if (manager is not null && Environment.TickCount64 - Interlocked.Read(ref manager.LastAutomaticModeChange) < 2500) return;
        BeginInvoke(async () => { bool resume = stop is not null || settings.AutoConnect; if (stop is not null) await StopAsync(false); RefreshDisplays(); if (resume) await StartAsync(); });
    }
    private async Task StartAsync()
    {
        if (displays.SelectedItem is not DisplaySource source) { status.Text = "Waiting for the extra display. Open Advanced options to finish its one-time setup."; return; }
        if (stop is not null) return;
        try { VideoSender.FindFfmpeg(settings.FfmpegPath); } catch (Exception e) { status.Text = e.Message; return; }
        settings.DisplayName = source.DeviceName; settings.WifiAddress = wifi.Text.Trim(); settings.Mirror = mirror.Checked; settings.MirrorSide = side.Text; settings.Fps = (int)frameRate.SelectedItem!; settings.AutoConnect = true; settings.Save();
        stop = new(); manager = new(settings, source, key);
        manager.Status += text => UI(() => { status.Text = text; identify.Enabled = text.StartsWith("Connected"); });
        manager.Identify += (screen, edge) => UI(() => new EdgeArrow(screen.Bounds, edge).Show());
        manager.DeviceConnected += id => UI(() => { settings.LastDeviceId = id; settings.Save(); });
        SetConnectingControls();
        var token = stop.Token;
        running = Task.Run(async () => { try { await manager.RunAsync(token); } catch (Exception e) { UI(async () => await ConnectionFailedAsync(e)); } });
        await Task.CompletedTask;
    }
    private void UI(Action action) { if (!IsDisposed && IsHandleCreated) BeginInvoke(action); }
    private void CopyPairingKey()
    {
        try { copyText(SecureChannel.EncodeKey(key)); pairingFeedback.Text = "Copied. Paste into your iPad app."; }
        catch { pairingFeedback.Text = "Clipboard is busy. Try copying again."; }
    }
    private void SetConnectingControls()
    {
        displays.Enabled = wifi.Enabled = mirror.Enabled = side.Enabled = frameRate.Enabled = false;
        start.Text = "Stop connecting";
    }
    private async Task ConnectionFailedAsync(Exception error)
    {
        await StopAsync(); status.Text = "Stopped · " + error.Message;
    }
    internal async Task RenderStateChecksAsync(string folder)
    {
        if (settings.Persist) throw new InvalidOperationException("State checks require nonpersistent preview settings.");
        advanced.Visible = true;
        mirror.Checked = true; RefreshDisplays();
        if (displays.SelectedItem is null) throw new InvalidOperationException("A physical monitor is needed for the preview check.");
        CopyPairingKey();
        if (!status.Text.StartsWith("Ready") || !pairingFeedback.Text.StartsWith("Copied")) throw new InvalidOperationException("Copy feedback replaced the ready status.");
        Capture("host-ready-copied.png");
        stop = new(); running = Task.CompletedTask; SetConnectingControls(); identify.Enabled = true;
        await ConnectionFailedAsync(new IOException("Preview: capture process could not start. Check FFmpeg, then try again."));
        if (!displays.Enabled || !wifi.Enabled || !mirror.Enabled || !frameRate.Enabled || identify.Enabled || start.Text != "Start connecting" || !status.Text.StartsWith("Stopped ·")) throw new InvalidOperationException("Failure recovery did not restore controls.");
        Capture("host-stopped-error.png");
        void Capture(string filename)
        {
            PerformLayout(); Application.DoEvents();
            using var bitmap = new Bitmap(Width, Height); DrawToBitmap(bitmap, new Rectangle(Point.Empty, Size));
            bitmap.Save(Path.Combine(folder, filename));
        }
    }
    private async Task StopAsync(bool remember = true)
    {
        if (stop is null) return; var cancellation = stop; cancellation.Cancel();
        if (running is not null) await running; cancellation.Dispose(); stop = null; manager = null; running = null;
        if (remember) { settings.AutoConnect = false; settings.Save(); }
        displays.Enabled = wifi.Enabled = mirror.Enabled = frameRate.Enabled = true; side.Enabled = mirror.Checked; identify.Enabled = false; start.Text = "Start connecting"; status.Text = "Stopped"; statistics.Text = ""; RefreshDisplays();
    }
}
