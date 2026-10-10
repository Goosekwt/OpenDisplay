using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace OpenDisplay.Core;

public static class Discovery
{
    public const string Service = "_opendisplay._tcp.local";
    // A legacy unicast mDNS query: Bonjour replies directly to the ephemeral source port.
    public static async Task<List<IPAddress>> FindAsync(CancellationToken ct)
    {
        using var socket = new UdpClient(AddressFamily.InterNetwork);
        socket.Client.Bind(new IPEndPoint(IPAddress.Any, 0));
        var query = new List<byte>(new byte[12]); query[1] = 1; query[5] = 1;
        foreach (string part in Service.Split('.')) { query.Add((byte)part.Length); query.AddRange(Encoding.ASCII.GetBytes(part)); }
        query.AddRange([0, 0, 12, 0, 1]);
        await socket.SendAsync(query.ToArray(), new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353), ct);
        var found = new HashSet<IPAddress>();
        while (!ct.IsCancellationRequested)
        {
            UdpReceiveResult packet;
            try { packet = await socket.ReceiveAsync(ct); } catch (OperationCanceledException) { break; }
            if (AdvertisesReceiver(packet.Buffer)) found.Add(packet.RemoteEndPoint.Address);
        }
        return found.ToList();
    }

    public static bool AdvertisesReceiver(byte[] packet)
    {
        try
        {
            if (packet.Length < 12 || (packet[2] & 0x80) == 0) return false;
            int p = 12, q = U16(packet, 4), records = U16(packet, 6) + U16(packet, 8) + U16(packet, 10);
            if (q > 64 || records > 512) return false;
            for (int i = 0; i < q; i++) { Name(packet, ref p); p += 4; }
            for (int i = 0; i < records; i++)
            {
                string name = Name(packet, ref p); int type = U16(packet, p); int length = U16(packet, p + 8); p += 10;
                if (p + length > packet.Length) return false;
                if (type == 12 && name.Equals(Service, StringComparison.OrdinalIgnoreCase)) { int r = p; return Name(packet, ref r).EndsWith("." + Service, StringComparison.OrdinalIgnoreCase); }
                p += length;
            }
        }
        catch (Exception e) when (e is IndexOutOfRangeException or ArgumentException or IOException) { }
        return false;
    }

    private static int U16(byte[] b, int p) => BinaryPrimitives.ReadUInt16BigEndian(b.AsSpan(p, 2));
    private static string Name(byte[] b, ref int position)
    {
        int p = position, end = -1, hops = 0, total = 0; var labels = new List<string>();
        while (true)
        {
            if (++hops > 64 || p >= b.Length) throw new IOException("Invalid DNS name.");
            int n = b[p++];
            if ((n & 0xc0) == 0xc0) { if (end < 0) end = p + 1; p = ((n & 63) << 8) | b[p]; continue; }
            if (n == 0) break;
            if (n > 63 || p + n > b.Length || (total += n + 1) > 255) throw new IOException("Invalid DNS label.");
            labels.Add(Encoding.ASCII.GetString(b, p, n)); p += n;
        }
        position = end < 0 ? p : end; return string.Join('.', labels);
    }
}
