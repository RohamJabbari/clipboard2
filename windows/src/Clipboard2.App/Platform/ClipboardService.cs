using System;
using System.Collections.Generic;
using System.Collections.Specialized;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Clipboard2.Core;
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App.Platform;

/// <summary>What was read off the clipboard on the UI thread, before off-thread processing.</summary>
public sealed record RawCapture(ClipKind Kind, string Text, string? Rtf, string? Html, IReadOnlyList<string> Files, BitmapSource? Image, AppRef? Source);

public static class ClipboardFilter
{
    /// <summary>Formats password managers and Windows use to say "don't record this".</summary>
    public const string ExcludeFromMonitoring = "ExcludeClipboardContentFromMonitorProcessing";
    public const string ViewerIgnore = "Clipboard Viewer Ignore";
    public const string CanIncludeInHistory = "CanIncludeInClipboardHistory";
    public const string CanUploadToCloud = "CanUploadToCloudClipboard";
    /// <summary>Added to everything Clipboard2 writes so the monitor doesn't re-capture it.</summary>
    public const string InternalMarker = "Clipboard2.Internal";

    public enum Decision { Capture, Blocked, IgnoredApp, OwnWrite, Empty }

    public static Decision Decide(IReadOnlyCollection<string> formats, Func<string, object?> read, string? sourcePath, ISet<string> ignoredExeNames)
    {
        if (formats.Count == 0) return Decision.Empty;
        if (formats.Contains(InternalMarker)) return Decision.OwnWrite;
        if (formats.Contains(ExcludeFromMonitoring) || formats.Contains(ViewerIgnore)) return Decision.Blocked;
        if (formats.Contains(CanIncludeInHistory) && DwordIsZero(read(CanIncludeInHistory))) return Decision.Blocked;
        if (sourcePath is not null && ignoredExeNames.Contains(Path.GetFileName(sourcePath).ToLowerInvariant())) return Decision.IgnoredApp;
        return Decision.Capture;
    }

    private static bool DwordIsZero(object? value) => value switch
    {
        MemoryStream ms when ms.Length >= 4 => BitConverter.ToInt32(ms.ToArray(), 0) == 0,
        byte[] b when b.Length >= 4 => BitConverter.ToInt32(b, 0) == 0,
        int i => i == 0,
        _ => false,
    };
}

/// <summary>Reads and writes the Windows clipboard. The clipboard can be briefly locked by other
/// apps, so every access retries.</summary>
public static class ClipboardIO
{
    public const int MaxTextLength = 5_000_000;

    private static T Retry<T>(Func<T> action, T fallback)
    {
        for (var attempt = 0; attempt < 8; attempt++)
        {
            try { return action(); }
            catch (COMException) { System.Threading.Thread.Sleep(25 * (attempt + 1)); }
            catch (ExternalException) { System.Threading.Thread.Sleep(25 * (attempt + 1)); }
        }
        return fallback;
    }

    private static void Retry(Action action) => Retry(() => { action(); return true; }, false);

    public static RawCapture? Read(ISet<string> ignoredExeNames, AppRef? source, out ClipboardFilter.Decision decision)
    {
        decision = ClipboardFilter.Decision.Empty;
        var data = Retry(System.Windows.Clipboard.GetDataObject, null);
        if (data is null) return null;
        var formats = Retry(() => data.GetFormats(false), []);
        decision = ClipboardFilter.Decide(formats, f => Retry(() => data.GetData(f), null), source?.Id, ignoredExeNames);
        if (decision != ClipboardFilter.Decision.Capture) return null;

        if (formats.Contains(DataFormats.FileDrop) && Retry(() => data.GetData(DataFormats.FileDrop) as string[], null) is { Length: > 0 } files)
            return new RawCapture(ClipKind.File, "", null, null, files, null, source);

        if (Retry(() => data.GetData(DataFormats.UnicodeText) as string, null) is { } text && !string.IsNullOrWhiteSpace(text))
        {
            if (text.Length > MaxTextLength) return null;
            var rtf = formats.Contains(DataFormats.Rtf) ? Retry(() => data.GetData(DataFormats.Rtf) as string, null) : null;
            var html = formats.Contains(DataFormats.Html) ? Retry(() => data.GetData(DataFormats.Html) as string, null) : null;
            return new RawCapture(rtf is null && html is null ? ClipKind.Text : ClipKind.RichText, text, rtf, html, [], null, source);
        }

        if (ReadImage(data, formats) is { } image)
            return new RawCapture(ClipKind.Image, "", null, null, [], image, source);

        return null;
    }

    /// <summary>Prefers the "PNG" format (keeps alpha) over the DIB WPF decodes by default.</summary>
    public static BitmapSource? ReadImage(System.Windows.IDataObject data, string[] formats)
    {
        try
        {
            if (formats.Contains("PNG") && data.GetData("PNG") is MemoryStream png)
            {
                var frame = BitmapFrame.Create(png, BitmapCreateOptions.PreservePixelFormat, BitmapCacheOption.OnLoad);
                frame.Freeze();
                return frame;
            }
            if (formats.Contains(DataFormats.Bitmap) && System.Windows.Clipboard.GetImage() is { } bitmap)
            {
                bitmap.Freeze();
                return bitmap;
            }
        }
        catch (Exception ex)
        {
            Log.Error("Reading clipboard image failed", ex);
        }
        return null;
    }

    public static BitmapSource? CurrentImage()
    {
        var data = Retry(System.Windows.Clipboard.GetDataObject, null);
        if (data is null) return null;
        var formats = Retry(() => data.GetFormats(false), []);
        var hasText = Retry(() => data.GetData(DataFormats.UnicodeText) as string, null) is { Length: > 0 };
        if (formats.Contains(DataFormats.FileDrop) && Retry(() => data.GetData(DataFormats.FileDrop) as string[], null) is { Length: > 0 } files
            && ImageTools.IsImageFile(files[0]))
        {
            try
            {
                var frame = BitmapFrame.Create(new Uri(files[0]), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                frame.Freeze();
                return frame;
            }
            catch { return null; }
        }
        return hasText ? null : ReadImage(data, formats);
    }

    public static string? CurrentText() => Retry(() => System.Windows.Clipboard.ContainsText() ? System.Windows.Clipboard.GetText() : null, null);

    // MARK: Writing

    private static void Mark(DataObject data) => data.SetData(ClipboardFilter.InternalMarker, "1");

    private static void Commit(DataObject data) => Retry(() => System.Windows.Clipboard.SetDataObject(data, copy: true));

    /// <summary>Writes an item; a transform (or the target app's default) applies to text.</summary>
    public static void Write(ClipItem item, Transform? transform, BlobStore blobs)
    {
        var data = new DataObject();
        switch (item.Kind)
        {
            case ClipKind.Text or ClipKind.RichText:
                if (transform is { } t && t != Transform.PlainText)
                {
                    data.SetData(DataFormats.UnicodeText, t.Apply(item.Text) ?? item.Text);
                }
                else
                {
                    if (transform is null && item.Rtf is not null) data.SetData(DataFormats.Rtf, item.Rtf);
                    if (transform is null && item.Html is not null) data.SetData(DataFormats.Html, item.Html);
                    data.SetData(DataFormats.UnicodeText, item.Text);
                }
                break;
            case ClipKind.Image:
                if (item.ImageFile is { } name && File.Exists(blobs.PathFor(name)))
                {
                    var bytes = File.ReadAllBytes(blobs.PathFor(name));
                    data.SetData("PNG", new MemoryStream(bytes));
                    var frame = BitmapFrame.Create(new MemoryStream(bytes), BitmapCreateOptions.None, BitmapCacheOption.OnLoad);
                    data.SetImage(frame);
                }
                break;
            case ClipKind.File:
                var files = new StringCollection();
                files.AddRange([.. item.Files.Where(File.Exists).Concat(item.Files.Where(Directory.Exists))]);
                if (files.Count > 0) data.SetFileDropList(files);
                if (transform is not null) data.SetData(DataFormats.UnicodeText, item.Text);
                break;
        }
        Mark(data);
        Commit(data);
    }

    /// <summary>Several items: text joined by line breaks, files as one drop, otherwise the first item.</summary>
    public static void Write(IReadOnlyList<ClipItem> items, Transform? transform, BlobStore blobs)
    {
        if (items.Count == 1) { Write(items[0], transform, blobs); return; }
        if (items.All(i => i.Kind.IsTextual()))
        {
            WriteText(string.Join("\n", items.Select(i => transform?.Apply(i.Text) ?? i.Text)));
        }
        else if (items.All(i => i.Kind == ClipKind.File))
        {
            var data = new DataObject();
            var files = new StringCollection();
            files.AddRange([.. items.SelectMany(i => i.Files)]);
            data.SetFileDropList(files);
            Mark(data);
            Commit(data);
        }
        else
        {
            // Windows has no multi-item clipboard; text where possible, then the first image.
            var text = string.Join("\n", items.Where(i => i.Kind != ClipKind.Image).Select(i => i.Text));
            if (text.Length > 0) WriteText(text); else Write(items[0], transform, blobs);
        }
    }

    public static void WriteText(string text)
    {
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, text);
        Mark(data);
        Commit(data);
    }

    /// <summary>Kept out of Windows clipboard history (Win+V), cloud sync and other managers.</summary>
    public static void WriteSecret(string value)
    {
        var data = new DataObject();
        data.SetData(DataFormats.UnicodeText, value);
        data.SetData(ClipboardFilter.ExcludeFromMonitoring, new MemoryStream(BitConverter.GetBytes(1)));
        data.SetData(ClipboardFilter.CanIncludeInHistory, new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData(ClipboardFilter.CanUploadToCloud, new MemoryStream(BitConverter.GetBytes(0)));
        Mark(data);
        Commit(data);
    }

    public static void Clear() => Retry(System.Windows.Clipboard.Clear);

    // MARK: Snapshot / restore (borrowing the clipboard for Ctrl+C or a screenshot)

    public static Dictionary<string, object> Snapshot()
    {
        var snapshot = new Dictionary<string, object>();
        var data = Retry(System.Windows.Clipboard.GetDataObject, null);
        if (data is null) return snapshot;
        foreach (var format in Retry(() => data.GetFormats(false), []))
        {
            try
            {
                if (data.GetData(format, false) is { } value) snapshot[format] = value is MemoryStream ms ? new MemoryStream(ms.ToArray()) : value;
            }
            catch { /* some formats (metafiles, delayed renders) can't be copied */ }
        }
        return snapshot;
    }

    public static void Restore(Dictionary<string, object> snapshot)
    {
        if (snapshot.Count == 0) { Clear(); return; }
        var data = new DataObject();
        foreach (var (format, value) in snapshot)
        {
            try { data.SetData(format, value is MemoryStream ms ? new MemoryStream(ms.ToArray()) : value, false); }
            catch { }
        }
        Commit(data);
    }
}

/// <summary>Raises <see cref="Changed"/> on WM_CLIPBOARDUPDATE (no polling needed on Windows).</summary>
public sealed class ClipboardListener : IDisposable
{
    private readonly HwndSource _source;
    public event Action? Changed;

    public ClipboardListener()
    {
        _source = new HwndSource(new HwndSourceParameters("Clipboard2ClipboardListener") { ParentWindow = new IntPtr(-3) });
        _source.AddHook(WndProc);
        if (!Native.AddClipboardFormatListener(_source.Handle)) Log.Error("AddClipboardFormatListener failed: " + Marshal.GetLastWin32Error());
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_CLIPBOARDUPDATE) Changed?.Invoke();
        return IntPtr.Zero;
    }

    public void Dispose()
    {
        Native.RemoveClipboardFormatListener(_source.Handle);
        _source.Dispose();
    }
}

public static class ImageTools
{
    public static readonly string[] ImageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tif", ".tiff", ".webp", ".heic"];
    public static bool IsImageFile(string path) => ImageExtensions.Contains(Path.GetExtension(path).ToLowerInvariant());

    public sealed record Processed(byte[] Png, byte[] Thumbnail, int Width, int Height, string Hash);

    /// <summary>Encodes PNG + thumbnail and hashes decoded pixels. Safe off the UI thread for frozen bitmaps.</summary>
    public static Processed Process(BitmapSource image, int thumbnailMaxPixels = 480)
    {
        var bgra = new FormatConvertedBitmap(image, PixelFormats.Bgra32, null, 0);
        var stride = bgra.PixelWidth * 4;
        var pixels = new byte[stride * bgra.PixelHeight];
        bgra.CopyPixels(pixels, stride, 0);
        var hash = ContentHasher.HashPixels(bgra.PixelWidth, bgra.PixelHeight, pixels);

        var scale = Math.Min(1.0, (double)thumbnailMaxPixels / Math.Max(image.PixelWidth, image.PixelHeight));
        BitmapSource thumb = scale < 1 ? new TransformedBitmap(image, new ScaleTransform(scale, scale)) : image;
        return new Processed(EncodePng(image), EncodePng(thumb), image.PixelWidth, image.PixelHeight, hash);
    }

    public static byte[] EncodePng(BitmapSource image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    public static BitmapImage? Load(string path, int decodeWidth = 0)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.UriSource = new Uri(path);
            if (decodeWidth > 0) image.DecodePixelWidth = decodeWidth;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch { return null; }
    }
}

/// <summary>Turns a raw capture into something storable (hashing and PNG encoding off the UI thread).</summary>
public static class CaptureProcessor
{
    public static Task<ProcessedCapture?> ProcessAsync(RawCapture raw, BlobStore blobs) => Task.Run<ProcessedCapture?>(() =>
    {
        switch (raw.Kind)
        {
            case ClipKind.File:
                return ProcessedCapture.ForFiles(raw.Files, raw.Source);
            case ClipKind.Image when raw.Image is { } image:
                var processed = ImageTools.Process(image);
                var id = Guid.NewGuid().ToString("N");
                var full = $"{id}.png";
                var thumb = $"{id}-thumb.png";
                try
                {
                    blobs.Write(processed.Png, full);
                    blobs.Write(processed.Thumbnail, thumb);
                }
                catch (Exception ex)
                {
                    blobs.Delete(full);
                    blobs.Delete(thumb);
                    Log.Error("Writing image blob failed", ex);
                    return null;
                }
                return new ProcessedCapture
                {
                    Kind = ClipKind.Image,
                    Preview = $"Image {processed.Width}×{processed.Height}",
                    Source = raw.Source,
                    Hash = processed.Hash,
                    ImageFile = full,
                    ThumbnailFile = thumb,
                    ImageWidth = processed.Width,
                    ImageHeight = processed.Height,
                    ByteCount = processed.Png.Length,
                };
            case ClipKind.Text or ClipKind.RichText:
                return ProcessedCapture.ForText(raw.Text, raw.Rtf, raw.Html, raw.Source);
            default:
                return null;
        }
    });
}
