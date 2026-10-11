using System.Diagnostics;
using OpenDisplay.Core;
namespace OpenDisplay.Host;

public enum VideoEncoding { Software, AmdHardware, NvidiaDesktop }
public sealed class VideoCaptureException(string message) : IOException(message);

public sealed class VideoTransferMetrics
{
    public long ReadTicks, SendTicks, Chunks;
    public void Reset() { Interlocked.Exchange(ref ReadTicks, 0); Interlocked.Exchange(ref SendTicks, 0); Interlocked.Exchange(ref Chunks, 0); }
    public object Snapshot() => new { readSeconds = Interlocked.Read(ref ReadTicks) / (double)Stopwatch.Frequency, sendSeconds = Interlocked.Read(ref SendTicks) / (double)Stopwatch.Frequency, chunks = Interlocked.Read(ref Chunks) };
}

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
    public static async Task<VideoEncoding> SelectEncodingAsync(string executable, CancellationToken ct)
    {
        // Probe the encoder itself: being listed by FFmpeg does not mean a working
        // driver is installed. No desktop pixels are captured by this probe.
        var psi = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true };
        foreach (string arg in new[] { "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=black:s=1280x720:r=60", "-frames:v", "2", "-an", "-c:v", "h264_amf", "-usage", "ultralowlatency", "-f", "null", "-" }) psi.ArgumentList.Add(arg);
        using var process = new Process { StartInfo = psi };
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(5000);
        try
        {
            process.Start();
            var errors = process.StandardError.ReadToEndAsync(deadline.Token);
            await process.WaitForExitAsync(deadline.Token); await errors;
            return process.ExitCode == 0 ? VideoEncoding.AmdHardware : VideoEncoding.Software;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { return VideoEncoding.Software; }
        finally { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
    }
    public static Size OutputSize(Rectangle rect, VideoEncoding encoding = VideoEncoding.Software)
    {
        double scale = Math.Min(1, Math.Min((encoding != VideoEncoding.Software ? 3840.0 : 1920.0) / rect.Width, (encoding != VideoEncoding.Software ? 2880.0 : 1440.0) / rect.Height));
        return new(Math.Max(2, (int)(rect.Width * scale) & ~1), Math.Max(2, (int)(rect.Height * scale) & ~1));
    }
    public static ProcessStartInfo Arguments(string executable, Rectangle rect, int fps, VideoEncoding encoding = VideoEncoding.Software, GraphicsOutput? output = null)
    {
        var size = OutputSize(rect, encoding);
        var psi = new ProcessStartInfo(executable) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        foreach (var arg in new[] { "-hide_banner", "-loglevel", "warning", "-nostats", "-progress", "pipe:2", "-stats_period", "1" }) psi.ArgumentList.Add(arg);
        if (encoding == VideoEncoding.NvidiaDesktop)
        {
            if (output is null || size != rect.Size) throw new VideoCaptureException("The graphics capture target is unavailable.");
            foreach (var arg in new[] { "-init_hw_device", $"d3d11va=capture:{output.AdapterIndex}", "-filter_hw_device", "capture", "-filter_complex", $"ddagrab=output_idx={output.OutputIndex}:framerate={fps}:draw_mouse=1:dup_frames=1[out]", "-map", "[out]" }) psi.ArgumentList.Add(arg);
        }
        else
        {
            foreach (var arg in new[] { "-f", "gdigrab", "-framerate", fps.ToString(), "-draw_mouse", "1", "-offset_x", rect.X.ToString(), "-offset_y", rect.Y.ToString(), "-video_size", $"{rect.Width}x{rect.Height}", "-i", "desktop", "-vf", $"scale={size.Width}:{size.Height}" }) psi.ArgumentList.Add(arg);
        }
        // Do not manufacture frames to disguise slow capture, or burst duplicates
        // after a stall. Static desktop repeats are produced by ddagrab itself.
        foreach (var arg in new[] { "-an", "-fps_mode", "passthrough" }) psi.ArgumentList.Add(arg);
        string[] codec = encoding switch
        {
            VideoEncoding.NvidiaDesktop => ["-c:v", "h264_nvenc", "-preset", "p1", "-tune", "ull", "-rc", "cbr", "-b:v", "32M", "-maxrate", "32M", "-bufsize", "2M", "-g", fps.ToString(), "-bf", "0", "-zerolatency", "1", "-delay", "0", "-aud", "1"],
            VideoEncoding.AmdHardware => ["-c:v", "h264_amf", "-usage", "ultralowlatency", "-quality", "speed", "-rc", "cbr", "-b:v", "32M", "-maxrate", "32M", "-bufsize", "2M", "-pix_fmt", "nv12", "-g", fps.ToString(), "-bf", "0", "-async_depth", "1", "-preanalysis", "false", "-frame_skipping", "false", "-aud", "true", "-header_spacing", fps.ToString()],
            _ => ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-crf", "22", "-pix_fmt", "yuv420p", "-g", fps.ToString(), "-bf", "0", "-x264-params", $"aud=1:repeat-headers=1:scenecut=0:keyint={fps}:min-keyint={fps}"]
        };
        foreach (var arg in codec) psi.ArgumentList.Add(arg);
        foreach (var arg in new[] { "-flush_packets", "1", "-f", "h264", "pipe:1" }) psi.ArgumentList.Add(arg);
        return psi;
    }
    public static async Task RunAsync(string executable, Rectangle rect, int fps, VideoEncoding encoding, GraphicsOutput? output, SecureChannel channel, Action<long> bytesSent, Action<long> framesEncoded, CancellationToken ct, VideoTransferMetrics? metrics = null)
    {
        using var process = new Process { StartInfo = Arguments(executable, rect, fps, encoding, output), EnableRaisingEvents = true };
        string lastError = "";
        process.ErrorDataReceived += (_, e) =>
        {
            if (e.Data?.StartsWith("frame=") == true && long.TryParse(e.Data.AsSpan(6), out long frames)) framesEncoded(frames);
            else if (!string.IsNullOrWhiteSpace(e.Data) && (!e.Data.Contains('=') || e.Data.StartsWith('['))) lastError = e.Data.Length > 500 ? e.Data[..500] : e.Data;
        };
        if (!process.Start()) throw new VideoCaptureException("Could not start screen capture.");
        process.BeginErrorReadLine();
        using var stop = ct.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
        try
        {
            var buffer = new byte[65536];
            while (true)
            {
                int count;
                long readStarted = Stopwatch.GetTimestamp();
                using (var frameDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct))
                {
                    frameDeadline.CancelAfter(TimeSpan.FromSeconds(8));
                    try { count = await process.StandardOutput.BaseStream.ReadAsync(buffer, frameDeadline.Token); }
                    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new VideoCaptureException("Screen capture stopped producing video."); }
                }
                if (metrics is not null) Interlocked.Add(ref metrics.ReadTicks, Stopwatch.GetTimestamp() - readStarted);
                if (count == 0) throw new VideoCaptureException("Screen capture ended. " + lastError);
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(3));
                long sendStarted = Stopwatch.GetTimestamp();
                await channel.SendAsync(2, buffer.AsMemory(0, count), deadline.Token); bytesSent(count);
                if (metrics is not null) { Interlocked.Add(ref metrics.SendTicks, Stopwatch.GetTimestamp() - sendStarted); Interlocked.Increment(ref metrics.Chunks); }
            }
        }
        finally { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
    }
}
