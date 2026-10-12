using System;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Velopack;
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
    public static async Task<string> RecognizeAsync(BitmapSource image)
    {
        var engine = OcrEngine.TryCreateFromUserProfileLanguages() ?? OcrEngine.TryCreateFromLanguage(new Windows.Globalization.Language("en-US"));
        if (engine is null) return "";
        var png = ImageTools.EncodePng(image);
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

/// <summary>In-place updates from GitHub Releases (Velopack): checks hourly, the user confirms, the
/// app updates and restarts. Velopack also builds the Setup.exe installer.</summary>
public sealed class UpdateService
{
    /// <summary>CI keeps the newest Windows build in this one release, so the Mac releases in the same
    /// repo never get in the way of the Windows update feed.</summary>
    public const string FeedUrl = "https://github.com/RohamJabbari/clipboard2-macOS/releases/download/windows-latest/";
    private readonly UpdateManager _manager = new(new SimpleWebSource(FeedUrl));
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
