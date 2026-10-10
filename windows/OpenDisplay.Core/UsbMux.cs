using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace OpenDisplay.Core;

public record UsbDevice(int Id, string Serial, string Connection);

public static class UsbMux
{
    public static async Task<List<UsbDevice>> ListAsync(CancellationToken ct)
    {
        using var socket = new TcpClient(); await socket.ConnectAsync("127.0.0.1", 27015, ct);
        var reply = await Request(socket.GetStream(), "ListDevices", [], ct);
        var devices = new List<UsbDevice>();
        var array = Value(reply.Root!.Element("dict")!, "DeviceList");
        foreach (var d in array?.Elements("dict") ?? [])
        {
            var props = Value(d, "Properties"); if (props is null) continue;
            if (!int.TryParse(Value(d, "DeviceID")?.Value ?? Value(props, "DeviceID")?.Value, out var id)) continue;
            devices.Add(new(id, Value(props, "SerialNumber")?.Value ?? "", Value(props, "ConnectionType")?.Value ?? ""));
        }
        return devices.Where(d => d.Connection == "USB").ToList();
    }

    public static async Task<TcpClient> ConnectAsync(int deviceId, ushort port, CancellationToken ct)
    {
        var socket = new TcpClient { NoDelay = true };
        try
        {
            await socket.ConnectAsync("127.0.0.1", 27015, ct);
            ushort networkPort = BinaryPrimitives.ReverseEndianness(port);
            var reply = await Request(socket.GetStream(), "Connect", [new("DeviceID", deviceId), new("PortNumber", networkPort)], ct);
            var result = Value(reply.Root!.Element("dict")!, "Number")?.Value;
            if (result != "0") throw new IOException($"iPad app is not listening over USB (usbmux {result ?? "unknown"}).");
            return socket;
        }
        catch { socket.Dispose(); throw; }
    }

    private static XElement? Value(XElement dict, string name) => dict.Elements("key").FirstOrDefault(k => k.Value == name)?.ElementsAfterSelf().FirstOrDefault();

    private static async Task<XDocument> Request(Stream stream, string message, KeyValuePair<string, int>[] extras, CancellationToken ct)
    {
        var dict = new XElement("dict", new XElement("key", "MessageType"), new XElement("string", message), new XElement("key", "ClientVersionString"), new XElement("string", "OpenDisplay/0.1"), new XElement("key", "ProgName"), new XElement("string", "OpenDisplay"), new XElement("key", "kLibUSBMuxVersion"), new XElement("integer", 3));
        foreach (var e in extras) dict.Add(new XElement("key", e.Key), new XElement("integer", e.Value));
        var xml = Encoding.UTF8.GetBytes(new XDocument(new XDeclaration("1.0", "UTF-8", null), new XElement("plist", new XAttribute("version", "1.0"), dict)).ToString());
        var header = new byte[16];
        BinaryPrimitives.WriteUInt32LittleEndian(header, (uint)xml.Length + 16);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(4), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(8), 8);
        BinaryPrimitives.WriteUInt32LittleEndian(header.AsSpan(12), 1);
        await stream.WriteAsync(header, ct); await stream.WriteAsync(xml, ct);
        await stream.ReadExactlyAsync(header, ct);
        var size = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (size < 16 || size > 1_048_576 || BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8)) != 8) throw new IOException("Unsupported usbmux response.");
        var body = new byte[(int)size - 16]; await stream.ReadExactlyAsync(body, ct);
        using var reader = XmlReader.Create(new MemoryStream(body), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null });
        return XDocument.Load(reader);
    }
}
