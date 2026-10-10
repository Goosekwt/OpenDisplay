namespace OpenDisplay.Host;

/// <summary>
/// The OpenDisplay icon, loaded once from the embedded OpenDisplay.ico. The window and the tray
/// share these instances for the life of the process, so they are deliberately never disposed:
/// disposing one while a Form or NotifyIcon still uses it would leave them with a dead handle.
/// </summary>
internal static class AppIcon
{
    private static Icon? window, tray;

    /// <summary>All frames, so Windows can pick title-bar, Alt+Tab and taskbar sizes.</summary>
    public static Icon Window => window ??= Load(null);

    /// <summary>The frame closest to the notification area's small-icon size at the current DPI.</summary>
    public static Icon Tray => tray ??= Load(SystemInformation.SmallIconSize);

    private static Icon Load(Size? size)
    {
        using var stream = typeof(AppIcon).Assembly.GetManifestResourceStream("OpenDisplay.ico")
            ?? throw new InvalidOperationException("The OpenDisplay.ico resource is missing.");
        return size is { } s ? new Icon(stream, s) : new Icon(stream);
    }
}
