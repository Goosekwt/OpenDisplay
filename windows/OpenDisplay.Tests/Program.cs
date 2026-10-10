using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using OpenDisplay.Core;

int passed = 0;
void Check(bool value, string message) { if (!value) throw new Exception("FAILED: " + message); Console.WriteLine("PASS " + message); passed++; }
async Task Reject(Func<Task> action, string message) { try { await action(); } catch (Exception e) when (e is IOException or CryptographicException or OperationCanceledException) { Check(true, message); return; } throw new Exception("FAILED: accepted " + message); }

if (args.Contains("--usb"))
{
    using var usbTimeout = new CancellationTokenSource(5000);
    var devices = await UsbMux.ListAsync(usbTimeout.Token);
    Console.WriteLine($"USB service reachable; {devices.Count} USB Apple device(s).");
    return;
}

var key = Enumerable.Range(0, 32).Select(i => (byte)i).ToArray();
var modes = new[] { new DisplayMode(1920, 1080, 60), new DisplayMode(1600, 1200, 30), new DisplayMode(2420, 1668, 30), new DisplayMode(2420, 1668, 60), new DisplayMode(1668, 2420, 30) };
Check(DisplayModeSelector.Select(modes, 2420, 1668, 30) == modes[2], "automatic sizing chooses native iPad dimensions and target rate");
Check(DisplayModeSelector.Select(modes, 1668, 2420, 30) == modes[4], "automatic sizing follows portrait orientation");
Check(DisplayModeSelector.Select(modes, 2048, 1536, 30) == modes[1], "unsupported native resolution selects matching shape without distortion");
Check(DisplayModeSelector.Select(modes, 0, 1668, 30) is null && DisplayModeSelector.Select(modes, 99999, 1200, 30) is null, "invalid peer dimensions cannot select a display mode");
var salt = Enumerable.Range(32, 64).Select(i => (byte)i).ToArray();
Check(!SecureChannel.Derive(key, salt, "client").SequenceEqual(SecureChannel.Derive(key, salt, "server")), "directional keys are different");
Console.WriteLine("HKDF client fixture: " + Convert.ToHexString(SecureChannel.Derive(key, salt, "client")).ToLowerInvariant());
Check(Convert.ToHexString(SecureChannel.Derive(key, salt, "client")).Equals("2f5e4e0a9459deef95a7e703080d1594fcfa2ed872277d55b8b7759e279ffc9c", StringComparison.OrdinalIgnoreCase), "HKDF matches independent cross-platform fixture");
using (var fakeServer = new MemoryStream(new byte[104]))
{
    fakeServer.Position = 36; fakeServer.Write("OPA1"u8); fakeServer.Position = 0;
    await Reject(async () => { using var channel = await SecureChannel.ConnectAsync(fakeServer, key, default); }, "unauthenticated peer cannot establish a session");
}

async Task<(TcpClient ClientSocket, TcpClient ServerSocket, SecureChannel Client, SecureChannel Server, RecordingStream Wire)> Pair(bool fragmented = false)
{
    using var timeout = new CancellationTokenSource(5000);
    var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
    try
    {
        var a = new TcpClient { NoDelay = true }; var connect = a.ConnectAsync((IPEndPoint)listener.LocalEndpoint, timeout.Token);
        var b = await listener.AcceptTcpClientAsync(timeout.Token); await connect; b.NoDelay = true;
        var wire = new RecordingStream(a.GetStream(), fragmented);
        var server = SecureChannel.AcceptAsync(new RecordingStream(b.GetStream(), fragmented), key, timeout.Token);
        var client = await SecureChannel.ConnectAsync(wire, key, timeout.Token);
        var receiver = await server; wire.Records.Clear(); return (a, b, client, receiver, wire);
    }
    finally { listener.Stop(); }
}
async Task Session(Func<SecureChannel, SecureChannel, RecordingStream, CancellationToken, Task> test, bool fragmented = false)
{
    var pair = await Pair(fragmented);
    using var a = pair.ClientSocket; using var b = pair.ServerSocket; using var client = pair.Client; using var server = pair.Server; using var timeout = new CancellationTokenSource(5000);
    await test(client, server, pair.Wire, timeout.Token);
}

await Session(async (client, server, wire, ct) =>
{
    byte[] data = RandomNumberGenerator.GetBytes(250_000);
    var send = client.SendAsync(2, data, ct); var result = await server.ReceiveAsync(ct); await send;
    Check(result.Type == 2 && result.Payload.SequenceEqual(data), "encrypted video survives fragmented TCP reads and writes");
    await server.SendAsync(4, "heartbeat"u8.ToArray(), ct); var pong = await client.ReceiveAsync(ct);
    Check(pong.Type == 4 && pong.Payload.SequenceEqual("heartbeat"u8.ToArray()), "reverse heartbeat direction interoperates");
}, true);

await Session(async (client, server, wire, ct) =>
{
    var sends = Enumerable.Range(0, 30).Select(i => client.SendAsync(3, BitConverter.GetBytes(i), ct)).ToArray();
    var seen = new HashSet<int>(); for (int i = 0; i < 30; i++) seen.Add(BitConverter.ToInt32((await server.ReceiveAsync(ct)).Payload));
    await Task.WhenAll(sends); Check(seen.Count == 30, "concurrent video/control writers cannot interleave records");
});

await Session(async (client, server, wire, ct) =>
{
    await client.SendAsync(2, new byte[] { 1, 2, 3 }, ct); await server.ReceiveAsync(ct);
    await wire.Inner.WriteAsync(wire.Records[0], ct);
    await Reject(async () => { await server.ReceiveAsync(ct); }, "replayed encrypted record rejected");
});
await Session(async (client, server, wire, ct) =>
{
    byte[] broken = new byte[29]; BinaryPrimitives.WriteUInt32BigEndian(broken, 25);
    await wire.Inner.WriteAsync(broken, ct);
    await Reject(async () => { await server.ReceiveAsync(ct); }, "invalid authentication tag rejected");
});
await Session(async (client, server, wire, ct) =>
{
    byte[] huge = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(huge, uint.MaxValue); await wire.Inner.WriteAsync(huge, ct);
    await Reject(async () => { await server.ReceiveAsync(ct); }, "oversized record rejected before allocation");
});
await Session(async (client, server, wire, ct) =>
{
    byte[] shortRecord = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(shortRecord, 24); await wire.Inner.WriteAsync(shortRecord, ct);
    await Reject(async () => { await server.ReceiveAsync(ct); }, "undersized record rejected");
});

var r = new DisplayRect(0, 0, 1920, 1080);
Check(Geometry.Edges(r, new(1920, 0, 1600, 1200)) == ("right", "left"), "right-side iPad has matching inward-neighbor edge arrows");
Check(Geometry.Edges(r, new(-1600, 0, 1600, 1200)) == ("left", "right"), "left-side iPad arrows");
Check(Geometry.Edges(r, new(0, -1200, 1600, 1200)) == ("top", "bottom"), "upper iPad arrows");
Check(Geometry.Edges(r, new(0, 1080, 1600, 1200)) == ("bottom", "top"), "lower iPad arrows");
Check(!Discovery.AdvertisesReceiver([1, 2]), "truncated discovery packet rejected");
var cycle = new byte[30]; cycle[2] = 0x80; cycle[7] = 1; cycle[12] = 0xc0; cycle[13] = 12;
Check(!Discovery.AdvertisesReceiver(cycle), "cyclic DNS compression rejected without hanging");
Console.WriteLine($"{passed} checks passed.");

sealed class RecordingStream(Stream inner, bool fragmented) : Stream
{
    public Stream Inner => inner;
    public List<byte[]> Records { get; } = [];
    public override bool CanRead => true; public override bool CanWrite => true; public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException(); public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken ct = default)
    {
        Records.Add(buffer.ToArray());
        if (!fragmented) { await inner.WriteAsync(buffer, ct); return; }
        for (int i = 0; i < buffer.Length; i += 317) await inner.WriteAsync(buffer.Slice(i, Math.Min(317, buffer.Length - i)), ct);
    }
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default) => inner.ReadAsync(buffer[..Math.Min(buffer.Length, fragmented ? 137 : buffer.Length)], ct);
    public override void Flush() => inner.Flush(); public override int Read(byte[] b, int o, int n) => inner.Read(b, o, n); public override void Write(byte[] b, int o, int n) => inner.Write(b, o, n);
    public override long Seek(long o, SeekOrigin s) => throw new NotSupportedException(); public override void SetLength(long n) => throw new NotSupportedException();
    protected override void Dispose(bool disposing) { if (disposing) inner.Dispose(); base.Dispose(disposing); }
}
