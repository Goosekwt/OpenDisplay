using System.Runtime.InteropServices;
using OpenDisplay.Core;

namespace OpenDisplay.Host;

internal static class AutomaticDisplay
{
    public static DisplaySource Fit(DisplaySource source, int width, int height, int fps)
    {
        if (!source.Virtual) return source;
        var supported = GetModes(source.DeviceName);
        var selected = DisplayModeSelector.Select(supported, width, height, fps);
        var current = CreateMode();
        if (selected is null || !EnumDisplaySettings(source.DeviceName, -1, ref current)) return source;
        var physical = DisplaySource.GetAll().Where(d => !d.Virtual).ToList();
        bool touches = physical.Any(d => Touches(d.Bounds, new Rectangle(current.X, current.Y, (int)current.Width, (int)current.Height)));
        bool reposition = !touches && physical.Count > 0;
        if (current.Width != selected.Width || current.Height != selected.Height || current.Frequency != selected.RefreshRate || reposition)
        {
            var next = current;
            next.Fields = 0x00080000 | 0x00100000 | 0x00400000;
            next.Width = (uint)selected.Width; next.Height = (uint)selected.Height; next.Frequency = (uint)selected.RefreshRate;
            if (reposition)
            {
                var neighbor = physical.FirstOrDefault(d => d.Primary) ?? physical[0];
                next.Fields |= 0x20; next.X = neighbor.Bounds.Right; next.Y = neighbor.Bounds.Top;
            }
            if (ChangeDisplaySettingsEx(source.DeviceName, ref next, IntPtr.Zero, 2, IntPtr.Zero) == 0 &&
                ChangeDisplaySettingsEx(source.DeviceName, ref next, IntPtr.Zero, 0, IntPtr.Zero) == 0)
                current = next;
        }
        return source with { Bounds = new Rectangle(current.X, current.Y, (int)current.Width, (int)current.Height) };
    }

    public static List<DisplayMode> GetModes(string deviceName)
    {
        var supported = new List<DisplayMode>();
        for (int i = 0; i < 4096; i++)
        {
            var mode = CreateMode();
            if (!EnumDisplaySettings(deviceName, i, ref mode)) break;
            supported.Add(new((int)mode.Width, (int)mode.Height, (int)mode.Frequency));
        }
        return supported;
    }

    private static bool Touches(Rectangle a, Rectangle b) =>
        ((a.Right == b.Left || a.Left == b.Right) && Math.Min(a.Bottom, b.Bottom) > Math.Max(a.Top, b.Top)) ||
        ((a.Bottom == b.Top || a.Top == b.Bottom) && Math.Min(a.Right, b.Right) > Math.Max(a.Left, b.Left));

    private static DevMode CreateMode() => new() { Size = (ushort)Marshal.SizeOf<DevMode>(), DeviceName = "", FormName = "" };
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DevMode
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public ushort SpecVersion, DriverVersion, Size, DriverExtra;
        public uint Fields;
        public int X, Y;
        public uint Orientation, FixedOutput;
        public short Color, Duplex, YResolution, TTOption, Collate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FormName;
        public ushort LogPixels;
        public uint BitsPerPixel, Width, Height, DisplayFlags, Frequency, ICMMethod, ICMIntent, MediaType, DitherType, Reserved1, Reserved2, PanningWidth, PanningHeight;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool EnumDisplaySettings(string device, int mode, ref DevMode data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int ChangeDisplaySettingsEx(string device, ref DevMode data, IntPtr hwnd, uint flags, IntPtr param);
}
