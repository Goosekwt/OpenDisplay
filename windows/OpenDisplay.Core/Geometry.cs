namespace OpenDisplay.Core;
public record DisplayRect(int X, int Y, int Width, int Height);
public static class Geometry
{
    public static DisplayRect FitWindow(DisplayRect window, DisplayRect workArea)
    {
        if (workArea.Width <= 0 || workArea.Height <= 0) return window;
        int width = Math.Min(window.Width, workArea.Width), height = Math.Min(window.Height, workArea.Height);
        return new(Math.Clamp(window.X, workArea.X, workArea.X + workArea.Width - width),
                   Math.Clamp(window.Y, workArea.Y, workArea.Y + workArea.Height - height), width, height);
    }
    public static DisplayRect ResizeAttached(DisplayRect display, int width, int height, IReadOnlyList<DisplayRect> neighbors)
    {
        var resized = display with { Width = width, Height = height };
        foreach (var n in neighbors)
        {
            bool verticalOverlap = Math.Min(display.Y + display.Height, n.Y + n.Height) > Math.Max(display.Y, n.Y);
            bool horizontalOverlap = Math.Min(display.X + display.Width, n.X + n.Width) > Math.Max(display.X, n.X);
            // Keep the shared edge attached when a left/top display changes size.
            if (verticalOverlap && (display.X + display.Width == n.X || display.X == n.X + n.Width))
                return resized with { X = display.X < n.X ? n.X - width : n.X + n.Width, Y = Math.Clamp(display.Y, n.Y - height + 1, n.Y + n.Height - 1) };
            if (horizontalOverlap && (display.Y + display.Height == n.Y || display.Y == n.Y + n.Height))
                return resized with { Y = display.Y < n.Y ? n.Y - height : n.Y + n.Height, X = Math.Clamp(display.X, n.X - width + 1, n.X + n.Width - 1) };
        }
        return neighbors.Count == 0 ? resized : resized with { X = neighbors[0].X + neighbors[0].Width, Y = neighbors[0].Y };
    }

    public static (string Computer, string Ipad) Edges(DisplayRect computer, DisplayRect ipad)
    {
        double dx = ipad.X + ipad.Width / 2.0 - computer.X - computer.Width / 2.0;
        double dy = ipad.Y + ipad.Height / 2.0 - computer.Y - computer.Height / 2.0;
        // Compare normalized displacement so tall/wide screens do not distort the relation.
        if (Math.Abs(dx) / (computer.Width + ipad.Width) >= Math.Abs(dy) / (computer.Height + ipad.Height))
            return dx >= 0 ? ("right", "left") : ("left", "right");
        return dy >= 0 ? ("bottom", "top") : ("top", "bottom");
    }
}
