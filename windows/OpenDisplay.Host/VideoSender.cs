using System.Diagnostics;
using OpenDisplay.Core;
namespace OpenDisplay.Host;

public static class VideoSender
{
    public static string FindFfmpeg(string configured)
    {
        if (!string.IsNullOrWhiteSpace(configured) && File.Exists(configured)) return configured;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            var path = Path.Combine(dir.Trim('"'), "ffmpeg.exe"); if (File.Exists(path)) return path;
        }
        throw new FileNotFoundException("FFmpeg was not found. Install FFmpeg, then restart OpenDisplay.");
    }
    public static Size OutputSize(Rectangle rect)
    {
        double scale = Math.Min(1, Math.Min(1920.0 / rect.Width, 1440.0 / rect.Height));
        return new(Math.Max(2, (int)(rect.Width * scale) & ~1), Math.Max(2, (int)(rect.Height * scale) & ~1));
    }
    public static ProcessStartInfo Arguments(string executable, Rectangle rect, int fps)
    {
        var size = OutputSize(rect);
        var psi = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        string[] args = ["-hide_banner", "-loglevel", "warning", "-f", "gdigrab", "-framerate", fps.ToString(), "-draw_mouse", "1", "-offset_x", rect.X.ToString(), "-offset_y", rect.Y.ToString(), "-video_size", $"{rect.Width}x{rect.Height}", "-i", "desktop", "-an", "-vf", $"scale={size.Width}:{size.Height}", "-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-crf", "22", "-pix_fmt", "yuv420p", "-g", fps.ToString(), "-bf", "0", "-x264-params", $"aud=1:repeat-headers=1:scenecut=0:keyint={fps}:min-keyint={fps}", "-flush_packets", "1", "-f", "h264", "pipe:1"];
        foreach (var arg in args) psi.ArgumentList.Add(arg);
        return psi;
    }
    public static async Task RunAsync(string executable, Rectangle rect, int fps, SecureChannel channel, Action<long> bytesSent, CancellationToken ct)
    {
        using var process = new Process { StartInfo = Arguments(executable, rect, fps), EnableRaisingEvents = true };
        string lastError = "";
        process.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) lastError = e.Data.Length > 500 ? e.Data[..500] : e.Data; };
        if (!process.Start()) throw new IOException("Could not start screen capture.");
        process.BeginErrorReadLine();
        using var stop = ct.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        try
        {
            var buffer = new byte[65536];
            while (true)
            {
                int count = await process.StandardOutput.BaseStream.ReadAsync(buffer, ct);
                if (count == 0) throw new IOException("Screen capture ended. " + lastError);
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(3));
                await channel.SendAsync(2, buffer.AsMemory(0, count), deadline.Token); bytesSent(count);
            }
        }
        finally { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
    }
}
