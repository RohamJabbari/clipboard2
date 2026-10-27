using System;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Clipboard2.Core;
using Velopack;
using Velopack.Logging;
using Velopack.Sources;
using Windows.Graphics.Imaging;
using BitmapDecoder = Windows.Graphics.Imaging.BitmapDecoder;
using BitmapEncoder = Windows.Graphics.Imaging.BitmapEncoder;
using Windows.Media.Ocr;
using Windows.Storage.Streams;

namespace Clipboard2.App.Platform;

/// <summary>On-device text recognition (Windows.Media.Ocr). Nothing is uploaded.</summary>
public static class TextRecognizer
{
    public static async Task<string> RecognizeAsync(BitmapSource image) => await RecognizePngAsync(ImageTools.EncodePng(image)) ?? "";

    /// <summary>Reads a PNG (or any format WIC decodes) from disk; null when no OCR language is installed.
    /// Safe on a worker thread.</summary>
    public static async Task<string?> RecognizeFileAsync(string path) => await RecognizePngAsync(await File.ReadAllBytesAsync(path));

    private static OcrEngine? CreateEngine() =>
        OcrEngine.TryCreateFromUserProfileLanguages() ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));

    /// <summary>Null when no OCR engine is available.</summary>
    public static async Task<string?> RecognizePngAsync(byte[] png)
    {
        var engine = CreateEngine();
        if (engine is null) return null;
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(png);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        // The OCR engine has a maximum image size; scale big screenshots down.
        var max = (int)OcrEngine.MaxImageDimension;
        SoftwareBitmap input = bitmap;
        if (bitmap.PixelWidth > max || bitmap.PixelHeight > max)
        {
            var scale = Math.Min((double)max / bitmap.PixelWidth, (double)max / bitmap.PixelHeight);
            using var resized = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, resized);
            encoder.SetSoftwareBitmap(bitmap);
            encoder.BitmapTransform.ScaledWidth = (uint)(bitmap.PixelWidth * scale);
            encoder.BitmapTransform.ScaledHeight = (uint)(bitmap.PixelHeight * scale);
            await encoder.FlushAsync();
            var smaller = await BitmapDecoder.CreateAsync(resized);
            input = await smaller.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
        }
        var result = await engine.RecognizeAsync(input);
        return string.Join("\n", result.Lines.Select(l => l.Text)).Trim();
    }
}

/// <summary>
/// Velopack's web source, but the feed (<c>releases.&lt;channel&gt;.json</c>) is only trusted with a valid Ed25519
/// signature (<c>….json.sig</c>) from <see cref="UpdateService.FeedPublicKey"/>. The packages are then checked
/// against the SHA-256 in that verified feed by Velopack. Fails closed: no key, no signature or a bad one means no update.
/// </summary>
public sealed class SignedFeedSource(string baseUrl, string publicKey) : IUpdateSource
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private readonly SimpleWebSource _packages = new(baseUrl);

    public async Task<VelopackAssetFeed> GetReleaseFeed(IVelopackLogger logger, string appId, string channel, Guid? stagingId = null,
                                                        VelopackAsset? latestLocalRelease = null)
    {
        if (string.IsNullOrWhiteSpace(publicKey)) throw new UpdateFeed.VerificationException("No update signing key is built into this app.");
        var name = $"releases.{(string.IsNullOrEmpty(channel) ? "win" : channel)}.json";
        var feed = await Http.GetByteArrayAsync(baseUrl + name);
        string signature;
        try { signature = await Http.GetStringAsync(baseUrl + name + ".sig"); }
        catch (HttpRequestException ex) { throw new UpdateFeed.VerificationException("The update feed isn't signed: " + ex.Message); }
        return VelopackAssetFeed.FromJson(UpdateFeed.Verify(feed, signature, publicKey));
    }

    public Task DownloadReleaseEntry(IVelopackLogger logger, VelopackAsset releaseEntry, string localFile, Action<int> progress,
                                     CancellationToken cancelToken = default) =>
        _packages.DownloadReleaseEntry(logger, releaseEntry, localFile, progress, cancelToken);
}

/// <summary>In-place updates from GitHub Releases (Velopack): checks hourly, the user confirms, the
/// app updates and restarts. Velopack also builds the Setup.exe installer. Only feeds signed with the
/// offline update key are used (README → Windows → Update signing).</summary>
public sealed class UpdateService
{
    /// <summary>CI keeps the newest Windows build in this one release, so the Mac releases in the same
    /// repo never get in the way of the Windows update feed.</summary>
    public const string FeedUrl = "https://github.com/RohamJabbari/clipboard2-macOS/releases/download/windows-latest/";
    /// <summary>The Ed25519 public key (base64) of the feed signing key in the developer's Keychain, as printed by
    /// scripts/sign-windows-feed.sh. Empty: this build refuses every update.</summary>
    public const string FeedPublicKey = "";
    public const string NotVerifiedMessage = "Update couldn't be verified";
    private readonly UpdateManager _manager = new(new SignedFeedSource(FeedUrl, FeedPublicKey));
    private UpdateInfo? _pending;
    public string? AvailableVersion => _pending?.TargetFullRelease.Version.ToString();
    public DateTime? LastCheck { get; private set; }
    public string? LastError { get; private set; }
    /// <summary>False when running from a build folder rather than an installed copy.</summary>
    public bool IsInstalled => _manager.IsInstalled;
    public string CurrentVersion => _manager.CurrentVersion?.ToString() ?? typeof(UpdateService).Assembly.GetName().Version?.ToString(3) ?? "dev";
    public event Action? Changed;

    public async Task CheckAsync(bool installAutomatically = false)
    {
        if (!IsInstalled) return;
        try
        {
            _pending = await _manager.CheckForUpdatesAsync();
            LastError = null;
            LastCheck = DateTime.Now;
            Changed?.Invoke();
            if (_pending is not null && installAutomatically) await InstallAsync();
        }
        catch (UpdateFeed.VerificationException ex)
        {
            // Quiet: no balloon, just LastError and the log.
            _pending = null;
            LastError = NotVerifiedMessage;
            Log.Info($"{NotVerifiedMessage}: {ex.Message}");
            Changed?.Invoke();
        }
        catch (Exception ex)
        {
            LastError = ex.Message;
            Log.Error("Update check failed", ex);
            Changed?.Invoke();
        }
    }

    public async Task InstallAsync()
    {
        if (_pending is null) return;
        await _manager.DownloadUpdatesAsync(_pending);
        _manager.ApplyUpdatesAndRestart(_pending);
    }
}

/// <summary>Captures a screen region with the built-in Snipping Tool (Win+Shift+S UI) and returns
/// the image it puts on the clipboard. The caller restores the previous clipboard.</summary>
public static class ScreenCapture
{
    public static async Task<BitmapSource?> CaptureRegionAsync(TimeSpan timeout)
    {
        var before = Native.GetClipboardSequenceNumber();
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-screenclip:") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            Log.Error("Couldn't start Snipping Tool", ex);
            return null;
        }
        var deadline = DateTime.Now + timeout;
        while (DateTime.Now < deadline)
        {
            await Task.Delay(150);
            if (Native.GetClipboardSequenceNumber() == before) continue;
            await Task.Delay(150);   // let the tool finish writing every format
            if (ClipboardIO.CurrentImage() is { } image) return image;
        }
        return null;
    }
}
