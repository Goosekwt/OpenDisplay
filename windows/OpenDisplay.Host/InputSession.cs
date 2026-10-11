using System.Runtime.InteropServices;
using OpenDisplay.Core;

namespace OpenDisplay.Host;

/// Owned by one authenticated connection. Never logs keystrokes or text.
public sealed class InputSession(Rectangle bounds) : IDisposable
{
    private readonly HashSet<int> keys = [], buttons = [];
    public long EventsApplied { get; private set; }
    public void Apply(RemoteInput input)
    {
        switch (input)
        {
            case RemoteInput.Pointer pointer:
                var desktop = new DisplayRect(GetSystemMetrics(76), GetSystemMetrics(77), GetSystemMetrics(78), GetSystemMetrics(79));
                if (desktop.Width < 2 || desktop.Height < 2) return;
                var point = HidKeyMap.AbsolutePoint(pointer.X, pointer.Y, new(bounds.X, bounds.Y, bounds.Width, bounds.Height), desktop);
                uint flags = 0x8000 | 0x4000 | 0x0001; // Absolute virtual-desktop move, in physical pixels.
                if (pointer.Phase == "down") { if (buttons.Add(pointer.Button)) flags |= ButtonFlag(pointer.Button, false); }
                if (pointer.Phase == "up") { if (buttons.Remove(pointer.Button)) flags |= ButtonFlag(pointer.Button, true); }
                Send(Mouse(flags, point.X, point.Y)); break;
            case RemoteInput.Wheel wheel:
                if (wheel.Dy != 0) Send(Mouse(0x0800, data: unchecked((uint)wheel.Dy)));
                if (wheel.Dx != 0) Send(Mouse(0x1000, data: unchecked((uint)wheel.Dx)));
                break;
            case RemoteInput.Key key:
                if (key.Down) keys.Add(key.Code);
                else if (!keys.Remove(key.Code)) return;
                Send(Keyboard(key.Code, !key.Down)); break;
            case RemoteInput.Text text:
                var batch = new NativeInput[text.Value.Length * 2];
                for (int i = 0; i < text.Value.Length; i++)
                {
                    batch[i * 2] = new() { Type = 1, Union = new() { Keyboard = new() { Scan = text.Value[i], Flags = 4 } } };
                    batch[i * 2 + 1] = new() { Type = 1, Union = new() { Keyboard = new() { Scan = text.Value[i], Flags = 6 } } };
                }
                SendInput((uint)batch.Length, batch, Marshal.SizeOf<NativeInput>()); break;
            case RemoteInput.ReleaseAll: ReleaseAll(); break;
        }
        EventsApplied++;
    }
    public void ReleaseAll()
    {
        foreach (int key in keys) Send(Keyboard(key, true));
        foreach (int button in buttons) Send(Mouse(ButtonFlag(button, true)));
        keys.Clear(); buttons.Clear();
    }
    public void Dispose() => ReleaseAll();
    private static uint ButtonFlag(int button, bool up) => (button, up) switch { (0, false) => 2, (0, true) => 4, (1, false) => 8, (1, true) => 16, (2, false) => 32, _ => 64 };
    private static NativeInput Mouse(uint flags, int x = 0, int y = 0, uint data = 0) => new() { Union = new() { Mouse = new() { X = x, Y = y, Data = data, Flags = flags } } };
    private static NativeInput Keyboard(int code, bool up) => new() { Type = 1, Union = new() { Keyboard = new() { Key = HidKeyMap.VirtualKey(code), Flags = (up ? 2u : 0) | (HidKeyMap.IsExtended(code) ? 1u : 0) } } };
    private static void Send(NativeInput input) => SendInput(1, [input], Marshal.SizeOf<NativeInput>());
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, [In] NativeInput[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] private struct NativeInput { public uint Type; public InputUnion Union; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion { [FieldOffset(0)] public MouseInput Mouse; [FieldOffset(0)] public KeyInput Keyboard; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput { public int X, Y; public uint Data, Flags, Time; public nuint Extra; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyInput { public ushort Key, Scan; public uint Flags, Time; public nuint Extra; }
}
