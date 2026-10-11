using System.Runtime.InteropServices;
using OpenDisplay.Core;

namespace OpenDisplay.Host;

internal static class AutomaticDisplay
{
    // Display modes and capture coordinates must share physical pixels, regardless
    // of the independent scaling percentages Windows uses for each monitor.
    public static Rectangle GetCurrentBounds(string deviceName)
    {
        var mode = CreateMode();
        if (!EnumDisplaySettings(deviceName, -1, ref mode))
            throw new IOException("Could not read the current display size. Refresh displays and try again.");
        return new Rectangle(mode.X, mode.Y, (int)mode.Width, (int)mode.Height);
    }
    public static DisplayMode? GetCurrentMode(string deviceName)
    {
        var mode = CreateMode();
        return EnumDisplaySettings(deviceName, -1, ref mode) ? new((int)mode.Width, (int)mode.Height, (int)mode.Frequency) : null;
    }

    public static DisplaySource Fit(DisplaySource source, int width, int height, int fps)
    {
        if (!source.Virtual) return source;
        var supported = GetModes(source.DeviceName);
        var selected = DisplayModeSelector.Select(supported, width, height, fps);
        var current = CreateMode();
        if (selected is null || !EnumDisplaySettings(source.DeviceName, -1, ref current)) return source;
        var physical = DisplaySource.GetAll().Where(d => !d.Virtual).OrderByDescending(d => d.Primary).Select(d => d.Rect).ToList();
        var placement = Geometry.ResizeAttached(new(current.X, current.Y, (int)current.Width, (int)current.Height), selected.Width, selected.Height, physical);
        bool reposition = current.X != placement.X || current.Y != placement.Y;
        if (current.Width != selected.Width || current.Height != selected.Height || current.Frequency != selected.RefreshRate || reposition)
        {
            var next = current;
            next.Fields = 0x00080000 | 0x00100000 | 0x00400000;
            next.Width = (uint)selected.Width; next.Height = (uint)selected.Height; next.Frequency = (uint)selected.RefreshRate;
            if (reposition)
            {
                next.Fields |= 0x20; next.X = placement.X; next.Y = placement.Y;
            }
            int result = ChangeDisplaySettingsEx(source.DeviceName, ref next, IntPtr.Zero, 2, IntPtr.Zero);
            if (result == 0) result = ChangeDisplaySettingsEx(source.DeviceName, ref next, IntPtr.Zero, 0, IntPtr.Zero);
            if (result != 0) throw new IOException($"Windows could not fit the extra display (code {result}).");
        }
        return source with { Bounds = GetCurrentBounds(source.DeviceName) };
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
