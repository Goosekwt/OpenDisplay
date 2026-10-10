using System.Security.Cryptography;
using System.Text.Json;
namespace OpenDisplay.Host;

public sealed class Settings
{
    [System.Text.Json.Serialization.JsonIgnore]
    internal bool Persist { get; set; } = true;
    public string DisplayName { get; set; } = "";
    public string WifiAddress { get; set; } = "";
    public string ProtectedKey { get; set; } = "";
    public bool AutoConnect { get; set; } = true;
    public bool Mirror { get; set; }
    public string MirrorSide { get; set; } = "right";
    public int Fps { get; set; } = 30;
    public string FfmpegPath { get; set; } = "";
    public string PreferredDevice { get; set; } = "";
    public string LastDeviceId { get; set; } = "";
    public static string Folder => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenDisplay");
    public static string PathName => Path.Combine(Folder, "settings.json");
    public static Settings Load()
    {
        if (!File.Exists(PathName)) return new();
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(PathName)) ?? new(); }
        catch (JsonException) { throw new IOException("OpenDisplay settings are damaged. Rename settings.json in %LOCALAPPDATA%\\OpenDisplay and pair again."); }
    }
    public void Save()
    {
        if (!Persist) return;
        Directory.CreateDirectory(Folder);
        string temp = PathName + ".tmp"; File.WriteAllText(temp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, PathName, true);
    }
    public byte[] GetKey()
    {
        if (string.IsNullOrEmpty(ProtectedKey))
        {
            var key = RandomNumberGenerator.GetBytes(32);
            ProtectedKey = Convert.ToBase64String(ProtectedData.Protect(key, null, DataProtectionScope.CurrentUser)); Save(); return key;
        }
        return ProtectedData.Unprotect(Convert.FromBase64String(ProtectedKey), null, DataProtectionScope.CurrentUser);
    }
}
