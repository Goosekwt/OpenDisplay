using System.Runtime.InteropServices;
using OpenDisplay.Core;

namespace OpenDisplay.Host;

internal static class AutomaticDisplay
{
    public static long LastTopologyChange;
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

    public static Rectangle GetSavedBounds(string deviceName)
    {
        var mode = CreateMode();
        return EnumDisplaySettings(deviceName, -2, ref mode) ? new(mode.X, mode.Y, (int)mode.Width, (int)mode.Height) : Rectangle.Empty;
    }

    // Only the adapter installed by OpenDisplay may be detached automatically.
    // The receipt is written by the scoped driver installer, never inferred from a friendly name.
    public static bool Owns(DisplaySource display)
    {
        if (!display.Virtual || display.Primary) return false;
        try
        {
            string receipt = File.ReadAllText(@"C:\VirtualDisplayDriver\opendisplay-device.txt").Trim();
            return DisplayOwnership.Matches(receipt, display.AdapterId);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return false; }
    }

    public static bool DetachOwned(DisplaySource selected)
    {
        var displays = DisplaySource.GetAll();
        var current = displays.FirstOrDefault(d => d.DeviceName == selected.DeviceName);
        if (current is null) return false;
        if (!Owns(current) || !displays.Any(d => d.DeviceName != current.DeviceName && d.Primary && !d.Virtual) ||
            !DisplayScaling.HasIndependentSource(current.DeviceName)) return false;
        var mode = CreateMode();
        if (!EnumDisplaySettings(current.DeviceName, -1, ref mode)) return false;
        var windows = DisconnectedWindows.Capture(current);
        windows.ReturnToPrimary();
        Thread.Sleep(300); // Allow queued placements before Windows removes the monitor.
        // Detach with position and BOTH size fields present. No registry flag,
        // so the last connected size/placement stays available for reconnect.
        mode.Fields = 0x20 | 0x00080000 | 0x00100000;
        mode.X = mode.Y = 0; mode.Width = mode.Height = 0;
        Interlocked.Exchange(ref LastTopologyChange, Environment.TickCount64);
        int result = ChangeDisplaySettingsEx(current.DeviceName, ref mode, 0, 0, 0);
        if (result != 0) throw new IOException($"Windows could not disconnect the iPad display (code {result}).");
        if (DisplaySource.GetAll().Any(d => d.DeviceName == current.DeviceName))
            throw new IOException("Windows kept the iPad display active after the disconnect request.");
        return true;
    }

    public static DisplaySource Fit(DisplaySource source, int width, int height, int fps)
    {
        if (!source.Virtual) return source;
        source = DisplaySource.GetAll(true).FirstOrDefault(d => d.DeviceName == source.DeviceName && d.AdapterId == source.AdapterId)
            ?? throw new IOException("The selected display is no longer available.");
        var supported = GetModes(source.DeviceName);
        var selected = DisplayModeSelector.Select(supported, width, height, fps);
        var current = CreateMode();
        if (selected is null) return source;
        if (!source.Active || !EnumDisplaySettings(source.DeviceName, -1, ref current) || current.Width == 0 || current.Height == 0)
        {
            if (!Owns(source)) throw new IOException("The selected display is disconnected. Enable it in Windows display settings.");
            current = CreateMode();
            if (!EnumDisplaySettings(source.DeviceName, -2, ref current)) current = CreateMode();
            // Retain the last position but force a fresh activation of the saved monitor.
            current.Width = current.Height = 0;
        }
        var physical = DisplaySource.GetAll().Where(d => !d.Virtual).OrderByDescending(d => d.Primary).Select(d => d.Rect).ToList();
        var previous = current.Width == 0 || current.Height == 0 ? source.Rect : new(current.X, current.Y, (int)current.Width, (int)current.Height);
        var placement = Geometry.ResizeAttached(previous, selected.Width, selected.Height, physical);
        bool reposition = current.X != placement.X || current.Y != placement.Y;
        if (current.Width != selected.Width || current.Height != selected.Height || current.Frequency != selected.RefreshRate || reposition)
        {
            var next = current;
            next.Fields = 0x00080000 | 0x00100000 | 0x00400000;
            next.Width = (uint)selected.Width; next.Height = (uint)selected.Height; next.Frequency = (uint)selected.RefreshRate;
            if (reposition || current.Width == 0 || current.Height == 0)
            {
                next.Fields |= 0x20; next.X = placement.X; next.Y = placement.Y;
            }
            if (current.Width == 0 || current.Height == 0)
            {
                next.Fields |= 0x00040000;
                next.BitsPerPixel = 32;
            }
            Interlocked.Exchange(ref LastTopologyChange, Environment.TickCount64);
            bool attaching = current.Width == 0 || current.Height == 0;
            // CDS_TEST can reject an inactive source even when activation works.
            // Persist only this owned adapter's connected mode; detach is temporary.
            int result = attaching ? 0 : ChangeDisplaySettingsEx(source.DeviceName, ref next, IntPtr.Zero, 2, IntPtr.Zero);
            if (result == 0) result = ChangeDisplaySettingsEx(source.DeviceName, ref next, IntPtr.Zero, attaching ? 1u : 0u, IntPtr.Zero);
            if (result != 0) throw new IOException($"Windows could not fit the extra display (code {result}).");
        }
        return DisplaySource.GetAll().FirstOrDefault(d => d.DeviceName == source.DeviceName && d.AdapterId == source.AdapterId)
            ?? throw new IOException("Windows did not activate the iPad display.");
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
