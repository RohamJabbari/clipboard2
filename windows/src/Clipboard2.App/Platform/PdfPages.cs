using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Media.Imaging;
using Windows.Data.Pdf;
using Windows.Storage;
using Windows.Storage.Streams;

namespace Clipboard2.App.Platform;

/// <summary>Renders PDF pages with the PDF renderer built into Windows (Windows.Data.Pdf): no extra dependency.</summary>
public static class PdfPages
{
    public sealed record Rendered(IReadOnlyList<BitmapSource> Pages, int PageCount);

    /// <summary>The first <paramref name="maxPages"/> pages at <paramref name="width"/> pixels. Throws for files
    /// Windows can't open (damaged, password-protected).</summary>
    public static async Task<Rendered> RenderAsync(string path, int maxPages, uint width, CancellationToken cancel)
    {
        var file = await StorageFile.GetFileFromPathAsync(path);
        var document = await PdfDocument.LoadFromFileAsync(file);
        var pages = new List<BitmapSource>();
        var count = (int)document.PageCount;
        for (uint i = 0; i < Math.Min(count, maxPages); i++)
        {
            cancel.ThrowIfCancellationRequested();
            using var page = document.GetPage(i);
            using var stream = new InMemoryRandomAccessStream();
            await page.RenderToStreamAsync(stream, new PdfPageRenderOptions { DestinationWidth = width });
            stream.Seek(0);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream.AsStream();
            image.EndInit();
            image.Freeze();
            pages.Add(image);
        }
        return new Rendered(pages, count);
    }
}
