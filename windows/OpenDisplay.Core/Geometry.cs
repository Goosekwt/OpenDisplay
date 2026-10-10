namespace OpenDisplay.Core;
public record DisplayRect(int X, int Y, int Width, int Height);
public static class Geometry
{
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
