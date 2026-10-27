namespace Clipboard2.Core;

/// <summary>
/// Reads the text in history images, one at a time and newest first, so image text is searchable. New images
/// are picked up on the next <see cref="Kick"/>; older ones are worked through in the background with a pause
/// between images so it never hogs the CPU. Recognition itself runs off the UI thread (the recognizer's job);
/// the store is only touched on the thread that calls <see cref="Kick"/> (the UI thread).
/// </summary>
/// <param name="recognize">Reads one PNG file. Returns null when text recognition isn't available on this PC
/// (no OCR language installed), which stops the indexer until the next launch. Throwing marks just that
/// image as done, so a broken file isn't retried forever.</param>
public sealed class ImageTextIndexer(ClipStore store, Func<string, CancellationToken, Task<string?>> recognize,
                                     TimeSpan? spacing = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
{
    /// <summary>The pause between two images.</summary>
    public TimeSpan Spacing { get; } = spacing ?? TimeSpan.FromSeconds(1.5);
    private readonly Func<TimeSpan, CancellationToken, Task> _delay = delay ?? Task.Delay;
    private Task? _running;
    private bool _busy, _again;
    private CancellationTokenSource _cts = new();

    /// <summary>False once the recognizer said OCR isn't available.</summary>
    public bool IsAvailable { get; private set; } = true;
    public Action<string>? Logger { get; set; }
    /// <summary>An image's text was stored.</summary>
    public event Action<ClipItem>? Indexed;

    /// <summary>Starts working through unread images, or notes that there's more once the current run ends.</summary>
    public Task Kick()
    {
        if (!IsAvailable) return Task.CompletedTask;
        if (_busy)
        {
            _again = true;
            return _running ?? Task.CompletedTask;
        }
        return _running = RunAsync(_cts.Token);
    }

    public void Stop()
    {
        _cts.Cancel();
        _cts = new CancellationTokenSource();
    }

    private async Task RunAsync(CancellationToken ct)
    {
        _busy = true;
        try
        {
            do
            {
                _again = false;
                while (!ct.IsCancellationRequested && IsAvailable && store.ImagesNeedingOcr(1).FirstOrDefault() is { } item)
                {
                    await IndexAsync(item, ct);
                    await _delay(Spacing, ct);
                }
            } while (_again && IsAvailable && !ct.IsCancellationRequested);
        }
        catch (OperationCanceledException) { }
        finally { _busy = false; }
    }

    private async Task IndexAsync(ClipItem item, CancellationToken ct)
    {
        var path = item.ImageFile is { } file ? store.Blobs.PathFor(file) : null;
        string? text;
        if (path is null || !File.Exists(path))
        {
            text = "";
        }
        else
        {
            try
            {
                text = await recognize(path, ct);
                ct.ThrowIfCancellationRequested();   // stopped (quitting): the store may be gone
                if (text is null)
                {
                    IsAvailable = false;
                    Logger?.Invoke("Text recognition isn't available on this PC; image text won't be searchable.");
                    return;
                }
            }
            catch (OperationCanceledException) { throw; }
            catch (Exception ex)
            {
                Logger?.Invoke($"Reading the text in an image failed: {ex.Message}");
                text = "";
            }
        }
        // The item may have been deleted while the text was read: the UPDATE then simply matches nothing.
        text = Normalize(text);
        store.SetOcrText(item.Id, text);
        item.OcrText = text;
        Indexed?.Invoke(item);
    }

    /// <summary>Joins the recognised lines, trims them and caps the length (search only looks at the start anyway).</summary>
    public static string Normalize(string text)
    {
        var lines = text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0);
        var joined = string.Join("\n", lines);
        return joined.Length > MaxLength ? joined[..MaxLength] : joined;
    }

    public const int MaxLength = 4_000;
}
