namespace Clipboard2.Core.Sync;

/// <summary>Endpoints and keys for cloud sync (docs/sync/PROTOCOL.md → Endpoints).</summary>
public static class SyncConfig
{
    public const string DefaultApiBaseUrl = "https://clipboard2-api-120641536104.europe-west1.run.app";

    /// <summary>The settings override (debug) wins over the built-in base URL.</summary>
    public static string ApiBaseUrl(Settings settings) =>
        string.IsNullOrWhiteSpace(settings.SyncApiBaseUrl) ? DefaultApiBaseUrl : settings.SyncApiBaseUrl.Trim().TrimEnd('/');

    /// <summary>Shared client for all sync traffic; tests pass their own handler instead.</summary>
    public static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(2) };
}
