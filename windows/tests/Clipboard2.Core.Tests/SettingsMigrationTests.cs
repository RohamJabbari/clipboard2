namespace Clipboard2.Core.Tests;

/// <summary>Settings migration: automatic updates are the default, also for existing installs.</summary>
public sealed class SettingsMigrationTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2-tests-" + Guid.NewGuid().ToString("N"));

    public SettingsMigrationTests() => Directory.CreateDirectory(_dir);
    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void NewSettingsInstallUpdatesAutomatically()
    {
        var settings = Settings.Load(Path.Combine(_dir, "missing.json"));
        Assert.True(settings.InstallUpdatesAutomatically);
        Assert.Equal(Settings.CurrentVersion, settings.Version);
        Assert.False(File.Exists(Path.Combine(_dir, "missing.json")));   // nothing written for a fresh install
    }

    [Fact]
    public void OldSettingsTurnAutomaticUpdatesOnOnceAndPersist()
    {
        var path = Path.Combine(_dir, "settings.json");
        // Written by 1.4.x: every default persisted, no Version.
        File.WriteAllText(path, """{ "MaxItems": 250, "InstallUpdatesAutomatically": false, "CheckForUpdates": true }""");
        var settings = Settings.Load(path);
        Assert.True(settings.InstallUpdatesAutomatically);
        Assert.Equal(250, settings.MaxItems);
        Assert.Contains("\"Version\": 1", File.ReadAllText(path));

        // Turning it off afterwards sticks.
        settings.InstallUpdatesAutomatically = false;
        settings.Save();
        Assert.False(Settings.Load(path).InstallUpdatesAutomatically);
    }

    [Fact]
    public void CorruptSettingsStillDefaultToAutomaticUpdates()
    {
        var path = Path.Combine(_dir, "settings.json");
        File.WriteAllText(path, "{ not json");
        Assert.True(Settings.Load(path).InstallUpdatesAutomatically);
    }
}
