using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using OpenDisplay.Core;
namespace OpenDisplay.Host;

public sealed class ConnectionManager(Settings settings, DisplaySource source, byte[] key)
{
    public event Action<string>? Status;
    public event Action<DisplaySource, string>? Identify;
    public event Action<string>? DeviceConnected;
    public event Action<string, string>? TransportConnected;
    public bool WaitingForUsb { get; private set; }
    public long BytesSent;
    public long FramesEncoded;
    public VideoTransferMetrics TransferMetrics { get; } = new();
    public long InputEvents, ReceiverFrames = -1, ReceiverDrops = -1;
    public DisplaySource? ConnectedDisplay { get; private set; }
    public VideoEncoding Encoding { get; private set; }
    public long LastAutomaticModeChange;
    private SecureChannel? active;
    private string ipadEdge = "left";
    private DisplaySource? neighbor;
    private string computerEdge = "right";
    private bool establishedUsbSession;
    private bool usbPresent;

    public async Task RunAsync(CancellationToken ct)
    {
        string executable = VideoSender.FindFfmpeg(settings.FfmpegPath);
        Status?.Invoke("Preparing screen capture");
        var fallback = await VideoSender.SelectEncodingAsync(executable, ct);
        long retryDesktopCaptureAfter = 0;
        void DetachIdleDisplay()
        {
            if (settings.Mirror || !source.Active) return;
            if (AutomaticDisplay.DetachOwned(source)) source = source with { Active = false };
        }
        try
        {
        Status?.Invoke("Looking for your paired iPad · USB first");
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var link = await FindConnection(ct);
                if (link is null)
                {
                    DetachIdleDisplay();
                    WaitingForUsb = establishedUsbSession && !settings.ContinueOnWifiAfterUsb;
                    Status?.Invoke(usbPresent ? "iPad is plugged in · open OpenDisplay on your iPad" : WaitingForUsb
                        ? "Ready for your iPad · plug in the cable and open OpenDisplay"
                        : "Waiting for iPad · open OpenDisplay on your paired iPad");
                    await Task.Delay(WaitingForUsb ? 650 : 1200, ct); continue;
                }
                WaitingForUsb = false;
                using var socket = link.Value.Socket; using var channel = link.Value.Channel;
                using var session = CancellationTokenSource.CreateLinkedTokenSource(ct);
                active = channel;
                using (var helloDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    helloDeadline.CancelAfter(5000);
                    var hello = await channel.ReceiveAsync(helloDeadline.Token);
                    if (hello.Type != 1) throw new IOException("iPad did not confirm the display session.");
                    using var json = JsonDocument.Parse(hello.Payload);
                    var root = json.RootElement;
                    if (root.ValueKind != JsonValueKind.Object) throw new IOException("iPad sent an invalid display hello.");
                    if (!root.TryGetProperty("ready", out var ready) || ready.ValueKind != JsonValueKind.True) throw new IOException("iPad is not ready to receive video.");
                    if (root.TryGetProperty("deviceId", out var id) && id.ValueKind == JsonValueKind.String) DeviceConnected?.Invoke(id.GetString() ?? "");
                    bool wasInactive = !source.Active;
                    if (root.TryGetProperty("displayWidth", out var width) && width.ValueKind == JsonValueKind.Number && width.TryGetInt32(out int w) &&
                        root.TryGetProperty("displayHeight", out var height) && height.ValueKind == JsonValueKind.Number && height.TryGetInt32(out int h) && source.Virtual)
                    {
                        Interlocked.Exchange(ref LastAutomaticModeChange, Environment.TickCount64);
                        source = AutomaticDisplay.Fit(source, w, h, settings.Fps);
                        // Retina iPads use two native pixels per interface point.
                        // Keep full-resolution video while making desktop UI legible.
                        DisplayScaling.FitVirtualDisplay(source, settings.IpadScalePercent);
                    }
                    if (!source.Active)
                    {
                        source = AutomaticDisplay.Fit(source, source.Bounds.Width > 0 ? source.Bounds.Width : 1600,
                            source.Bounds.Height > 0 ? source.Bounds.Height : 1000, settings.Fps);
                        DisplayScaling.FitVirtualDisplay(source, settings.IpadScalePercent);
                    }
                    if (wasInactive)
                    {
                        // A fixed delay is unreliable while Windows is creating the output.
                        for (int attempt = 0; attempt < 10 && GraphicsOutput.Find(source.DeviceName) is null; attempt++)
                            await Task.Delay(150, ct);
                    }
                }
                var output = GraphicsOutput.Find(source.DeviceName);
                Encoding = Environment.TickCount64 >= retryDesktopCaptureAfter && output?.VendorId == 0x10de && VideoSender.OutputSize(source.Bounds, VideoEncoding.NvidiaDesktop) == source.Bounds.Size
                    ? VideoEncoding.NvidiaDesktop : fallback;
                var size = VideoSender.OutputSize(source.Bounds, Encoding);
                var all = DisplaySource.GetAll();
                neighbor = all.Where(d => d.DeviceName != source.DeviceName && !d.Virtual).OrderBy(d => Distance(d.Bounds, source.Bounds)).FirstOrDefault();
                if (settings.Mirror || neighbor is null)
                {
                    neighbor = source; computerEdge = settings.MirrorSide;
                    ipadEdge = computerEdge switch { "left" => "right", "right" => "left", "top" => "bottom", _ => "top" };
                }
                else (computerEdge, ipadEdge) = Geometry.Edges(neighbor.Rect, source.Rect);
                using (var helloDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    helloDeadline.CancelAfter(5000);
                    await channel.SendAsync(1, JsonSerializer.SerializeToUtf8Bytes(new { name = Environment.MachineName, width = size.Width, height = size.Height, fps = settings.Fps, transport = link.Value.Transport, ipadEdge, inputVersion = 1, receiverStatsVersion = 1 }), helloDeadline.Token);
                }
                Interlocked.Exchange(ref BytesSent, 0);
                Interlocked.Exchange(ref FramesEncoded, 0);
                TransferMetrics.Reset();
                Interlocked.Exchange(ref InputEvents, 0);
                Interlocked.Exchange(ref ReceiverFrames, -1); Interlocked.Exchange(ref ReceiverDrops, -1);
                using var input = new InputSession(source.Bounds);
                ConnectedDisplay = source;
                if (link.Value.Transport == "USB") establishedUsbSession = true;
                TransportConnected?.Invoke(link.Value.Transport, link.Value.Peer);
                Status?.Invoke($"Connected over {link.Value.Transport} · {size.Width} × {size.Height} · {settings.Fps} fps target");
                await IdentifyAsync(session.Token);
                long lastReply = Environment.TickCount64;
                async Task ReadLoop()
                {
                    while (true)
                    {
                        var message = await channel.ReceiveAsync(session.Token);
                        if (message.Type == 4)
                        {
                            Interlocked.Exchange(ref lastReply, Environment.TickCount64);
                            if (message.Payload.Length is > 0 and <= 1024 && message.Payload[0] == '{')
                            {
                                try
                                {
                                    using var stats = JsonDocument.Parse(message.Payload);
                                    var data = stats.RootElement;
                                    if (data.ValueKind == JsonValueKind.Object && data.TryGetProperty("enqueuedFrames", out var frames) && frames.ValueKind == JsonValueKind.Number && frames.TryGetInt64(out long accepted) && accepted >= 0 &&
                                        data.TryGetProperty("droppedFrames", out var dropped) && dropped.ValueKind == JsonValueKind.Number && dropped.TryGetInt64(out long skipped) && skipped >= 0)
                                    { Interlocked.Exchange(ref ReceiverFrames, accepted); Interlocked.Exchange(ref ReceiverDrops, skipped); }
                                }
                                catch (JsonException) { }
                            }
                        }
                        else if (message.Type == 5 && RemoteInput.Parse(message.Payload) is { } command)
                        {
                            input.Apply(command); Interlocked.Exchange(ref InputEvents, input.EventsApplied);
                        }
                        else if (message.Type == 6) throw new IOException("iPad reported a decoding or connection error.");
                    }
                }
                async Task Heartbeat()
                {
                    while (true)
                    {
                        await Task.Delay(2000, session.Token);
                        if (Environment.TickCount64 - Interlocked.Read(ref lastReply) > 8000) throw new IOException("iPad stopped responding.");
                        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(session.Token); deadline.CancelAfter(3000);
                        await channel.SendAsync(4, BitConverter.GetBytes(Environment.TickCount64), deadline.Token);
                    }
                }
                var tasks = new[] { ReadLoop(), Heartbeat(), VideoSender.RunAsync(executable, source.Bounds, settings.Fps, Encoding, output, channel, b => Interlocked.Add(ref BytesSent, b), f => Interlocked.Exchange(ref FramesEncoded, f), session.Token, TransferMetrics) };
                var ended = await Task.WhenAny(tasks);
                session.Cancel(); socket.Close();
                try { await Task.WhenAll(tasks); } catch { }
                await ended;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or System.Security.Cryptography.CryptographicException or JsonException)
            {
                if (e is VideoCaptureException && Encoding != VideoEncoding.Software)
                {
                    if (Encoding == VideoEncoding.NvidiaDesktop) retryDesktopCaptureAfter = Environment.TickCount64 + 30_000;
                    else fallback = VideoEncoding.Software;
                    Status?.Invoke("Retrying with compatible capture · " + e.Message);
                }
                else Status?.Invoke(e is EndOfStreamException or SocketException
                    ? "Connection interrupted · reconnecting automatically"
                    : "Reconnecting · " + e.Message);
                try { await Task.Delay(e is VideoCaptureException ? 1800 : 750, ct); } catch (OperationCanceledException) { break; }
            }
            finally { active = null; ConnectedDisplay = null; }
        }
        }
        finally
        {
            ConnectedDisplay = null;
            try { DetachIdleDisplay(); }
            catch (IOException e) { Status?.Invoke("Could not disconnect the iPad display · " + e.Message); }
        }
    }

    public async Task IdentifyAsync(CancellationToken ct)
    {
        var channel = active; if (channel is null || neighbor is null) return;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(3000);
        await channel.SendAsync(3, JsonSerializer.SerializeToUtf8Bytes(new { edge = ipadEdge, seconds = 3 }), deadline.Token);
        Identify?.Invoke(neighbor, computerEdge);
    }

    private async Task<(TcpClient Socket, SecureChannel Channel, string Transport, string Peer)?> FindConnection(CancellationToken ct)
    {
        List<UsbDevice> devices = [];
        try { using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(1500); devices = await UsbMux.ListAsync(timeout.Token); }
        catch (Exception e) when (e is IOException or SocketException or OperationCanceledException) { }
        usbPresent = devices.Count > 0;
        foreach (var device in devices.OrderByDescending(d => d.Serial == settings.PreferredDevice))
        {
            var result = await Attempt(t => UsbMux.ConnectAsync(device.Id, 42150, t), "USB", ct);
            if (result is { } usb) return (usb.Socket, usb.Channel, usb.Transport, device.Serial);
        }
        // Unplugging a USB session should return the desktop, rather than
        // immediately recreating the second screen through discovery.
        if (establishedUsbSession && !settings.ContinueOnWifiAfterUsb) return null;
        // Try a known address immediately instead of paying the discovery timeout first.
        var tried = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        async Task<(TcpClient Socket, SecureChannel Channel, string Transport, string Peer)?> Wifi(string address)
        {
            address = address.Trim();
            if (address.Length == 0 || !tried.Add(address)) return null;
            var result = await Attempt(async t => { var tcp = new TcpClient { NoDelay = true }; try { await tcp.ConnectAsync(address, 42150, t); return tcp; } catch { tcp.Dispose(); throw; } }, "Wi-Fi", ct);
            return result is { } wifi ? (wifi.Socket, wifi.Channel, wifi.Transport, address) : null;
        }
        foreach (var address in new[] { settings.WifiAddress, settings.LastWifiAddress })
            if (await Wifi(address) is { } known) return known;
        var addresses = new List<string>();
        using (var discovery = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            discovery.CancelAfter(1800);
            try { addresses.AddRange((await Discovery.FindAsync(discovery.Token)).Select(a => a.ToString())); }
            catch (Exception e) when (e is SocketException or OperationCanceledException) { }
        }
        foreach (var address in addresses.Distinct())
        {
            var result = await Wifi(address);
            if (result is not null) return result;
        }
        return null;
    }
    private async Task<(TcpClient Socket, SecureChannel Channel, string Transport)?> Attempt(Func<CancellationToken, Task<TcpClient>> connect, string transport, CancellationToken ct)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(4000);
        TcpClient? socket = null;
        try { socket = await connect(timeout.Token); var channel = await SecureChannel.ConnectAsync(socket.GetStream(), key, timeout.Token); return (socket, channel, transport); }
        catch (Exception e) when (e is IOException or SocketException or OperationCanceledException or System.Security.Cryptography.CryptographicException)
        {
            socket?.Dispose();
            if (e is System.Security.Cryptography.CryptographicException) Status?.Invoke("Pairing does not match · scan this PC's QR code in the iPad app");
            return null;
        }
    }
    private static long Distance(Rectangle a, Rectangle b)
    {
        long dx = (long)a.X + a.Width / 2 - b.X - b.Width / 2, dy = (long)a.Y + a.Height / 2 - b.Y - b.Height / 2;
        return dx * dx + dy * dy;
    }
}
