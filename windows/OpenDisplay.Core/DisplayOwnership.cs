namespace OpenDisplay.Core;

public static class DisplayOwnership
{
    public static bool Matches(string receipt, string adapterPath)
    {
        const string suffix = " (restart required)";
        string id = receipt.Trim();
        if (id.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) id = id[..^suffix.Length];
        string[] parts = id.Split('\\');
        if (parts.Length != 3 || !parts[0].Equals("ROOT", StringComparison.OrdinalIgnoreCase) ||
            !parts[1].Equals("OPENDISPLAY", StringComparison.OrdinalIgnoreCase) || parts[2].Length == 0 ||
            !parts[2].All(char.IsAsciiLetterOrDigit)) return false;
        return adapterPath.StartsWith(@"\\?\" + id.Replace('\\', '#') + "#", StringComparison.OrdinalIgnoreCase);
    }
}
