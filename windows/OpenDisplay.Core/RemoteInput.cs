using System.Text.Json;

namespace OpenDisplay.Core;

public abstract record RemoteInput
{
    public sealed record Pointer(double X, double Y, string Phase, int Button) : RemoteInput;
    public sealed record Wheel(int Dx, int Dy) : RemoteInput;
    public sealed record Key(int Code, bool Down) : RemoteInput;
    public sealed record Text(string Value) : RemoteInput;
    public sealed record ReleaseAll : RemoteInput;

    public static RemoteInput? Parse(ReadOnlyMemory<byte> payload)
    {
        if (payload.Length is 0 or > 4096) return null;
        try
        {
            using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String) return null;
            switch (kind.GetString())
            {
                case "pointer":
                    if (!Number(root, "x", out var x) || !Number(root, "y", out var y) || x < 0 || x > 1 || y < 0 || y > 1 ||
                        !Integer(root, "button", out var button) || button is < 0 or > 2 || !root.TryGetProperty("phase", out var phase) || phase.ValueKind != JsonValueKind.String) return null;
                    string? action = phase.GetString();
                    return action is "move" or "down" or "up" ? new Pointer(x, y, action, button) : null;
                case "wheel":
                    return Integer(root, "dx", out var dx) && Integer(root, "dy", out var dy) && dx is >= -1200 and <= 1200 && dy is >= -1200 and <= 1200 ? new Wheel(dx, dy) : null;
                case "key":
                    if (!Integer(root, "code", out var code) || HidKeyMap.VirtualKey(code) == 0 || !root.TryGetProperty("down", out var down) || down.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) return null;
                    return new Key(code, down.GetBoolean());
                case "text":
                    if (!root.TryGetProperty("text", out var text) || text.ValueKind != JsonValueKind.String) return null;
                    var value = text.GetString()!;
                    return value.Length is > 0 and <= 1024 && !value.Contains('\0') ? new Text(value) : null;
                case "releaseAll": return new ReleaseAll();
                default: return null;
            }
        }
        catch (JsonException) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    private static bool Number(JsonElement root, string name, out double result)
    {
        result = 0;
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out result) && double.IsFinite(result);
    }
    private static bool Integer(JsonElement root, string name, out int result)
    {
        result = 0;
        return root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out result);
    }
}

/// USB keyboard page 0x07 usages; unsupported media/system usages are ignored.
public static class HidKeyMap
{
    public static ushort VirtualKey(int code)
    {
        if (code is >= 4 and <= 29) return (ushort)(0x41 + code - 4);
        if (code is >= 30 and <= 38) return (ushort)(0x31 + code - 30);
        if (code is >= 58 and <= 69) return (ushort)(0x70 + code - 58);
        if (code is >= 89 and <= 97) return (ushort)(0x61 + code - 89);
        if (code is >= 104 and <= 115) return (ushort)(0x7C + code - 104);
        return code switch
        {
            39 => 0x30, 40 or 88 => 0x0D, 41 => 0x1B, 42 => 0x08, 43 => 0x09, 44 => 0x20,
            45 => 0xBD, 46 => 0xBB, 47 => 0xDB, 48 => 0xDD, 49 or 50 => 0xDC,
            51 => 0xBA, 52 => 0xDE, 53 => 0xC0, 54 => 0xBC, 55 => 0xBE, 56 => 0xBF,
            57 => 0x14, 70 => 0x2C, 71 => 0x91, 72 => 0x13, 73 => 0x2D, 74 => 0x24,
            75 => 0x21, 76 => 0x2E, 77 => 0x23, 78 => 0x22, 79 => 0x27, 80 => 0x25,
            81 => 0x28, 82 => 0x26, 83 => 0x90, 84 => 0x6F, 85 => 0x6A, 86 => 0x6D,
            87 => 0x6B, 98 => 0x60, 99 => 0x6E, 100 => 0xE2, 101 => 0x5D,
            224 => 0xA2, 225 => 0xA0, 226 => 0xA4, 227 => 0x5B,
            228 => 0xA3, 229 => 0xA1, 230 => 0xA5, 231 => 0x5C,
            _ => 0
        };
    }
    public static bool IsExtended(int code) => code is 70 or >= 73 and <= 84 or 88 or 101 or 227 or 228 or 230 or 231;

    public static (int X, int Y) AbsolutePoint(double x, double y, DisplayRect display, DisplayRect desktop)
    {
        if (desktop.Width < 2 || desktop.Height < 2 || display.Width < 1 || display.Height < 1) throw new ArgumentOutOfRangeException(nameof(desktop));
        double px = display.X + Math.Clamp(x, 0, 1) * (display.Width - 1), py = display.Y + Math.Clamp(y, 0, 1) * (display.Height - 1);
        return ((int)Math.Round(Math.Clamp((px - desktop.X) / (desktop.Width - 1), 0, 1) * 65535),
                (int)Math.Round(Math.Clamp((py - desktop.Y) / (desktop.Height - 1), 0, 1) * 65535));
    }
}
