using System.Runtime.InteropServices;

namespace OpenDisplay.Host;

public sealed record GraphicsOutput(int AdapterIndex, int OutputIndex, string DeviceName, uint VendorId)
{
    public static GraphicsOutput? Find(string deviceName) => GetAll().FirstOrDefault(o => o.DeviceName == deviceName);

    // DXGI indices must be resolved by display name after each mode change. The
    // virtual display can belong to a different GPU from the primary monitor.
    public static List<GraphicsOutput> GetAll()
    {
        var result = new List<GraphicsOutput>();
        var iid = new Guid("7b7166ec-21c7-44ae-b21a-c9ae321ae369");
        if (CreateDXGIFactory(ref iid, out nint factory) < 0) return result;
        try
        {
            for (uint a = 0; a < 32; a++)
            {
                if (Method<Enumerate>(factory, 7)(factory, a, out nint adapter) < 0) break;
                try
                {
                    if (Method<DescribeAdapter>(adapter, 8)(adapter, out var description) < 0) continue;
                    for (uint o = 0; o < 32; o++)
                    {
                        if (Method<Enumerate>(adapter, 7)(adapter, o, out nint output) < 0) break;
                        try
                        {
                            if (Method<DescribeOutput>(output, 7)(output, out var d) >= 0 && d.Attached != 0)
                                result.Add(new((int)a, (int)o, d.DeviceName, description.VendorId));
                        }
                        finally { Marshal.Release(output); }
                    }
                }
                finally { Marshal.Release(adapter); }
            }
        }
        finally { Marshal.Release(factory); }
        return result;
    }

    private static T Method<T>(nint obj, int slot) where T : Delegate =>
        Marshal.GetDelegateForFunctionPointer<T>(Marshal.ReadIntPtr(Marshal.ReadIntPtr(obj), slot * nint.Size));
    [DllImport("dxgi.dll")] private static extern int CreateDXGIFactory(ref Guid iid, out nint factory);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int Enumerate(nint self, uint index, out nint item);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int DescribeOutput(nint self, out OutputDescription description);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)] private delegate int DescribeAdapter(nint self, out AdapterDescription description);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct OutputDescription
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        public int Left, Top, Right, Bottom, Attached, Rotation;
        public nint Monitor;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct AdapterDescription
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        public uint VendorId, DeviceId, SubsystemId, Revision;
        public nuint DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
        public uint LuidLow;
        public int LuidHigh;
    }
}
