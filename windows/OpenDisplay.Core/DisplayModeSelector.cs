namespace OpenDisplay.Core;

public record DisplayMode(int Width, int Height, int RefreshRate);
public static class DisplayModeSelector
{
    public static DisplayMode? Select(IEnumerable<DisplayMode> modes, int width, int height, int fps)
    {
        if (width is < 320 or > 8192 || height is < 320 or > 8192) return null;
        double ratio = (double)width / height;
        return modes.Where(m => m.Width >= 320 && m.Height >= 320 && m.RefreshRate >= 24)
            .OrderBy(m => Math.Abs(Math.Log(((double)m.Width / m.Height) / ratio)))
            .ThenBy(m => Math.Abs(Math.Log((double)m.Width * m.Height / ((double)width * height))))
            .ThenBy(m => Math.Abs(m.RefreshRate - fps)).FirstOrDefault();
    }
}
