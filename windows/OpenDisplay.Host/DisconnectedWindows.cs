using System.Runtime.InteropServices;
using OpenDisplay.Core;

namespace OpenDisplay.Host;

// Windows can minimize windows when a monitor disappears. Remember only the
// visible app windows on our display and move them before detaching, avoiding
// the shell's asynchronous minimize-on-disconnect policy.
internal sealed class DisconnectedWindows
{
    private readonly List<(nint Window, uint Process, Placement Placement)> windows = [];

    public static DisconnectedWindows Capture(DisplaySource display)
    {
        var result = new DisconnectedWindows();
        EnumWindows((window, _) =>
        {
            if (!IsWindowVisible(window) || IsIconic(window)) return true;
            long style = GetWindowLongPtr(window, -16).ToInt64(), extended = GetWindowLongPtr(window, -20).ToInt64();
            if ((style & 0x40000000) != 0 || (style & 0x00C00000) != 0x00C00000 || (extended & 0x80) != 0) return true;
            if (DwmGetWindowAttribute(window, 14, out int cloaked, sizeof(int)) == 0 && cloaked != 0) return true;
            var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (!GetMonitorInfo(MonitorFromWindow(window, 2), ref monitor) || monitor.Device != display.DeviceName) return true;
            var placement = new Placement { Length = Marshal.SizeOf<Placement>() };
            if (!GetWindowPlacement(window, ref placement)) return true;
            GetWindowThreadProcessId(window, out uint process);
            // Ordinary app placement coordinates are relative to the workspace.
            placement.Normal.Left -= monitor.Monitor.Left;
            placement.Normal.Right -= monitor.Monitor.Left;
            placement.Normal.Top -= monitor.Monitor.Top;
            placement.Normal.Bottom -= monitor.Monitor.Top;
            placement.Show = IsZoomed(window) ? 3u : 1u;
            result.windows.Add((window, process, placement));
            return true;
        }, 0);
        return result;
    }

    public void ReturnToPrimary()
    {
        var primary = DisplaySource.GetAll().FirstOrDefault(d => d.Primary && !d.Virtual);
        if (primary is null) return;
        var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(MonitorFromPoint(primary.Bounds.Location, 2), ref monitor)) return;
        // WINDOWPLACEMENT uses workspace coordinates, including the monitor origin.
        var area = new DisplayRect(monitor.Monitor.Left, monitor.Monitor.Top,
            monitor.Work.Right - monitor.Work.Left, monitor.Work.Bottom - monitor.Work.Top);
        foreach (var saved in windows)
        {
            GetWindowThreadProcessId(saved.Window, out uint process);
            if (process != saved.Process || !IsWindowVisible(saved.Window)) continue;
            var placement = saved.Placement;
            var normal = placement.Normal;
            var fitted = Geometry.FitWindow(new(area.X + normal.Left, area.Y + normal.Top,
                Math.Max(1, normal.Right - normal.Left), Math.Max(1, normal.Bottom - normal.Top)), area);
            placement.Normal = new() { Left = fitted.X, Top = fitted.Y, Right = fitted.X + fitted.Width, Bottom = fitted.Y + fitted.Height };
            placement.Flags = 4; // Do not block on another application's message loop.
            placement.Minimum = placement.Maximum = new Point(-1, -1);
            SetWindowPlacement(saved.Window, ref placement);
        }
    }

    private delegate bool Enumerate(nint window, nint parameter);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Placement { public int Length; public uint Flags, Show; public Point Minimum, Maximum; public NativeRect Normal; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(Enumerate callback, nint parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern bool IsZoomed(nint window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(Point point, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern bool GetWindowPlacement(nint window, ref Placement placement);
    [DllImport("user32.dll")] private static extern bool SetWindowPlacement(nint window, ref Placement placement);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out int value, int size);
}
