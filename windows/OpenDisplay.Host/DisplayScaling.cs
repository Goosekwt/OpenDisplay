using System.Runtime.InteropServices;

namespace OpenDisplay.Host;

internal static class DisplayScaling
{
    private static readonly int[] Percentages = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];

    public static int? GetPercent(string deviceName)
    {
        var source = FindSource(deviceName);
        if (source is null) return null;
        var scale = ReadScale(source.Value);
        if (scale is null) return null;
        int index = scale.Value.Current - scale.Value.Minimum;
        return index >= 0 && index < Percentages.Length ? Percentages[index] : null;
    }

    public static bool FitVirtualDisplay(DisplaySource display, int percent)
    {
        // Never change the physical/primary display or a cloned source. Re-check
        // the current topology rather than trusting an earlier selection.
        if (!display.Virtual || display.Primary) return false;
        var current = DisplaySource.GetAll().FirstOrDefault(d => d.DeviceName == display.DeviceName);
        if (current is not { Virtual: true, Primary: false }) return false;
        var source = FindSource(display.DeviceName);
        if (source is null) return false;
        var scale = ReadScale(source.Value);
        int target = Array.IndexOf(Percentages, percent);
        if (scale is null || target < 0) return false;
        int relative = target + scale.Value.Minimum;
        if (relative < scale.Value.Minimum || relative > scale.Value.Maximum) return false;
        if (relative == scale.Value.Current) return true;
        var request = new SetScale { Header = Header(-4, 24, source.Value), Relative = relative };
        return SetDeviceInfo(ref request) == 0 && GetPercent(display.DeviceName) == percent;
    }

    private static GetScale? ReadScale(Source source)
    {
        // These two DPI packets are undocumented Windows interfaces. Fail closed
        // on an unsupported layout/range; video must still work if they disappear.
        // Packet semantics: https://github.com/lihas/windows-DPI-scaling-sample
        if (Marshal.SizeOf<GetScale>() != 32 || Marshal.SizeOf<SetScale>() != 24) return null;
        var request = new GetScale { Header = Header(-3, 32, source) };
        if (GetDeviceInfo(ref request) != 0 || request.Minimum > 0 || request.Minimum < -11 ||
            request.Maximum < 0 || request.Maximum - request.Minimum >= Percentages.Length ||
            request.Current < request.Minimum || request.Current > request.Maximum) return null;
        return request;
    }

    private static DeviceHeader Header(int type, uint size, Source source) => new() { Type = type, Size = size, Adapter = source.Adapter, Id = source.Id };
    private static Source? FindSource(string deviceName)
    {
        const uint activePaths = 2;
        for (int attempt = 0; attempt < 3; attempt++)
        {
            if (GetDisplayConfigBufferSizes(activePaths, out uint pathCount, out uint modeCount) != 0 || pathCount > 128 || modeCount > 1024) return null;
            var paths = new DisplayPath[pathCount];
            var modes = new ModeInfo[modeCount];
            int result = QueryDisplayConfig(activePaths, ref pathCount, paths, ref modeCount, modes, 0);
            if (result == 122) continue; // topology changed while allocating
            if (result != 0) return null;
            foreach (var path in paths.Take((int)pathCount))
            {
                var name = new SourceName { Header = Header(1, 84, path.Source), Name = "" };
                if (GetDeviceInfo(ref name) != 0 || name.Name != deviceName) continue;
                if (paths.Take((int)pathCount).Count(p => p.Source.Adapter.Equals(path.Source.Adapter) && p.Source.Id == path.Source.Id) != 1) return null;
                return path.Source;
            }
            return null;
        }
        return null;
    }

    [StructLayout(LayoutKind.Sequential)] private struct Luid { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] private struct Source { public Luid Adapter; public uint Id, ModeIndex, Status; }
    [StructLayout(LayoutKind.Sequential)] private struct Target
    {
        public Luid Adapter;
        public uint Id, ModeIndex, Technology, Rotation, Scaling, RateNumerator, RateDenominator, Scanline;
        public int Available;
        public uint Status;
    }
    [StructLayout(LayoutKind.Sequential)] private struct DisplayPath { public Source Source; public Target Target; public uint Flags; }
    [StructLayout(LayoutKind.Sequential, Size = 64)] private struct ModeInfo { public uint Type, Id; public Luid Adapter; }
    [StructLayout(LayoutKind.Sequential)] private struct DeviceHeader { public int Type; public uint Size; public Luid Adapter; public uint Id; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct SourceName
    {
        public DeviceHeader Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Name;
    }
    [StructLayout(LayoutKind.Sequential)] private struct GetScale { public DeviceHeader Header; public int Minimum, Current, Maximum; }
    [StructLayout(LayoutKind.Sequential)] private struct SetScale { public DeviceHeader Header; public int Relative; }
    [DllImport("user32.dll")] private static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
    [DllImport("user32.dll")] private static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] DisplayPath[] pathData, ref uint modes, [Out] ModeInfo[] modeData, nint topology);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] private static extern int GetDeviceInfo(ref SourceName request);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")] private static extern int GetDeviceInfo(ref GetScale request);
    [DllImport("user32.dll", EntryPoint = "DisplayConfigSetDeviceInfo")] private static extern int SetDeviceInfo(ref SetScale request);
}
