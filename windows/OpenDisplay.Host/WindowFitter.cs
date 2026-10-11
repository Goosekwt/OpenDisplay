using System.Runtime.InteropServices;
using OpenDisplay.Core;

namespace OpenDisplay.Host;

/// Fits regular app windows after a move or layout settles on the connected iPad.
/// Hooks and timer are owned by the host UI thread; nothing moves during a drag.
public sealed class WindowFitter : IDisposable
{
    private readonly WinEvent callback;
    private readonly nint moveHook, locationHook;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 200 };
    private DisplaySource? target;
    private nint moving;
    private readonly Dictionary<nint, long> pending = [];
    private readonly Dictionary<nint, (DisplayRect Actual, DisplayRect Requested)> attempts = [];

    public WindowFitter()
    {
        callback = OnEvent;
        moveHook = SetWinEventHook(10, 11, 0, callback, 0, 0, 2);
        locationHook = SetWinEventHook(0x800B, 0x800B, 0, callback, 0, 0, 2);
        timer.Tick += (_, _) =>
        {
            if (moving != 0) return;
            foreach (var window in pending.Where(p => Environment.TickCount64 - p.Value >= 200).Select(p => p.Key).Take(16).ToArray())
            { pending.Remove(window); Fit(window); }
        };
        timer.Start();
    }
    public void SetTarget(DisplaySource? display)
    {
        display = display is { Virtual: true, Primary: false } ? display : null;
        if (target == display) return;
        target = display;
        attempts.Clear(); pending.Clear(); moving = 0;
        if (target is not null) EnumWindows((window, _) => { Fit(window); return true; }, 0);
    }
    private void OnEvent(nint hook, uint kind, nint window, int objectId, int childId, uint thread, uint time)
    {
        if (target is null || window == 0) return;
        if (kind == 10) { moving = window; attempts.Remove(window); return; }
        if (kind == 11) { moving = 0; Queue(window); return; }
        if (objectId == 0 && childId == 0 && moving == 0) Queue(window);
    }
    private void Queue(nint window)
    {
        if (pending.Count >= 64 && !pending.ContainsKey(window)) return;
        pending[window] = Environment.TickCount64;
    }
    private void Fit(nint window)
    {
        if (target is null || !IsWindowVisible(window) || IsIconic(window) || IsZoomed(window)) return;
        GetWindowThreadProcessId(window, out uint process);
        if (process == Environment.ProcessId) return;
        long style = GetWindowLongPtr(window, -16).ToInt64();
        if ((style & 0x40000000) != 0 || (style & 0x00C00000) != 0x00C00000 || (style & 0x00040000) == 0) return;
        var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(MonitorFromWindow(window, 2), ref monitor) || monitor.Device != target.DeviceName || !GetWindowRect(window, out var rect)) return;
        var before = new DisplayRect(rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top);
        if (before.Width <= 0 || before.Height <= 0) return;
        var work = monitor.Work;
        var after = Geometry.FitWindow(before, new(work.Left, work.Top, work.Right - work.Left, work.Bottom - work.Top));
        if (after == before) { attempts.Remove(window); return; }
        // Some applications enforce a minimum size larger than this display.
        // Do not fight that constraint in a location-change feedback loop.
        if (attempts.TryGetValue(window, out var previous) && previous == (before, after)) return;
        SetWindowPos(window, 0, after.X, after.Y, after.Width, after.Height, 0x0004 | 0x0010 | 0x0200);
        if (GetWindowRect(window, out var actual))
        {
            if (attempts.Count >= 256) attempts.Clear();
            attempts[window] = (new(actual.Left, actual.Top, actual.Right - actual.Left, actual.Bottom - actual.Top), after);
        }
    }
    public void Dispose() { timer.Dispose(); if (moveHook != 0) UnhookWinEvent(moveHook); if (locationHook != 0) UnhookWinEvent(locationHook); }
    private delegate void WinEvent(nint hook, uint kind, nint window, int objectId, int childId, uint thread, uint time);
    private delegate bool Enumerate(nint window, nint parameter);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Device; }
    [DllImport("user32.dll")] private static extern nint SetWinEventHook(uint min, uint max, nint module, WinEvent callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(nint hook);
    [DllImport("user32.dll")] private static extern bool EnumWindows(Enumerate callback, nint parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool IsIconic(nint window);
    [DllImport("user32.dll")] private static extern bool IsZoomed(nint window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll")] private static extern nint MonitorFromWindow(nint window, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(nint monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}
