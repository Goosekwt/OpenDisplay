using System.Runtime.InteropServices;
using OpenDisplay.Core;
namespace OpenDisplay.Host;

public sealed record DisplaySource(string DeviceName, string Label, Rectangle Bounds, bool Primary, bool Virtual)
{
    public override string ToString() => $"{Label} · {Bounds.Width} × {Bounds.Height}{(Primary ? " · primary" : "")}";
    public DisplayRect Rect => new(Bounds.X, Bounds.Y, Bounds.Width, Bounds.Height);
    public static List<DisplaySource> GetAll() => Screen.AllScreens.Select(s =>
    {
        string label = s.DeviceName;
        for (uint i = 0; i < 32; i++)
        {
            var d = new DisplayDevice { Size = Marshal.SizeOf<DisplayDevice>() };
            if (!EnumDisplayDevices(null, i, ref d, 0)) break;
            if (d.Name == s.DeviceName) { label = d.Description + " (" + s.DeviceName.Replace("\\\\.\\", "") + ")"; break; }
        }
        bool virtualDisplay = label.Contains("Virtual Display", StringComparison.OrdinalIgnoreCase) || label.Contains("IddSample", StringComparison.OrdinalIgnoreCase);
        return new DisplaySource(s.DeviceName, label, AutomaticDisplay.GetCurrentBounds(s.DeviceName), s.Primary, virtualDisplay);
    }).ToList();
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct DisplayDevice
    {
        public int Size;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint State;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Id;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Key;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool EnumDisplayDevices(string? name, uint number, ref DisplayDevice device, uint flags);
}
