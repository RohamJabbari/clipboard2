using System.Text;
using Clipboard2.Core;

namespace Clipboard2.Core.Tests;

public sealed class ItemSaverTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2saver-" + Guid.NewGuid());
    private readonly BlobStore _blobs;
    private string Out => Path.Combine(_dir, "Out");

    public ItemSaverTests() => _blobs = new BlobStore(Path.Combine(_dir, "Blobs"));

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch { }
    }

    private static ClipItem Text(string text, string? label = null) =>
        new() { Kind = ClipKind.Text, Text = text, Preview = TextPreview.Make(text), Label = label };

    [Theory]
    [InlineData("Hello world", null, "Hello world")]
    [InlineData("  first line\nsecond line  ", null, "first line second line")]
    [InlineData("a/b\\c:d*e?f\"g<h>i|j", null, "a b c d e f g h")]   // at most eight words
    [InlineData("one two three four five six seven eight nine ten", null, "one two three four five six seven eight")]
    [InlineData("The quick brown fox jumps over the lazy dog again", null, "The quick brown fox jumps over the lazy")]
    [InlineData("Supercalifragilisticexpialidocious-and-then-some-more", null, "Supercalifragilisticexpialidocious-and-t")]
    [InlineData("ignored", "API token", "API token")]
    [InlineData("ignored", "  ", "ignored")]
    [InlineData("etc.", null, "etc")]
    [InlineData("CON", null, "CON_")]
    [InlineData("nul.txt", null, "nul_.txt")]
    [InlineData("Com1", null, "Com1_")]
    [InlineData("CONSOLE", null, "CONSOLE")]
    [InlineData("???", null, "Text")]
    [InlineData("", null, "Text")]
    public void NamesComeFromTheLabelOrFirstWords(string text, string? label, string expected)
    {
        Assert.Equal(expected, ItemSaver.BaseName(label, text, "Text"));
        Assert.True(ItemSaver.BaseName(label, text, "Text").Length <= ItemSaver.MaxNameLength + 1);
    }

    [Fact]
    public void ACutNeverSplitsAnEmoji()
    {
        var name = ItemSaver.BaseName(null, new string('a', 39) + "😀", "Text");
        Assert.Equal(new string('a', 39), name);
    }

    [Fact]
    public void FileNamesPerKind()
    {
        Assert.Equal("Meeting notes.txt", ItemSaver.FileName(Text("Meeting notes")));
        Assert.Equal("Image.png", ItemSaver.FileName(new ClipItem { Kind = ClipKind.Image }));
        Assert.Equal("Logo.png", ItemSaver.FileName(new ClipItem { Kind = ClipKind.Image, Label = "Logo" }));
    }

    [Fact]
    public void CollisionsGetExplorerStyleNumbers()
    {
        Directory.CreateDirectory(Out);
        Assert.Equal(Path.Combine(Out, "a.txt"), ItemSaver.UniquePath(Out, "a.txt"));
        File.WriteAllText(Path.Combine(Out, "a.txt"), "");
        Assert.Equal(Path.Combine(Out, "a (2).txt"), ItemSaver.UniquePath(Out, "a.txt"));
        File.WriteAllText(Path.Combine(Out, "a (2).txt"), "");
        Assert.Equal(Path.Combine(Out, "a (3).txt"), ItemSaver.UniquePath(Out, "a.txt"));
        Directory.CreateDirectory(Path.Combine(Out, "my.folder"));
        Assert.Equal(Path.Combine(Out, "my.folder (2)"), ItemSaver.UniquePath(Out, "my.folder", isDirectory: true));
        // A folder takes the name of a file too.
        Directory.CreateDirectory(Path.Combine(Out, "b.txt"));
        Assert.Equal(Path.Combine(Out, "b (2).txt"), ItemSaver.UniquePath(Out, "b.txt"));
    }

    [Fact]
    public void TextIsSavedAsUtf8WithoutOverwriting()
    {
        var item = Text("Grüße — 東京 😀\nline two");
        var first = Assert.Single(ItemSaver.Save(item, Out, _blobs));
        var second = Assert.Single(ItemSaver.Save(item, Out, _blobs));
        Assert.Equal("Grüße — 東京 😀 line two.txt", Path.GetFileName(first));
        Assert.Equal("Grüße — 東京 😀 line two (2).txt", Path.GetFileName(second));
        var bytes = File.ReadAllBytes(first);
        Assert.Equal(item.Text, Encoding.UTF8.GetString(bytes));
        Assert.NotEqual(0xEF, bytes[0]);   // no BOM
    }

    [Fact]
    public void ImagesAreCopiedAsPng()
    {
        _blobs.Write([1, 2, 3], "img.png");
        var item = new ClipItem { Kind = ClipKind.Image, ImageFile = "img.png" };
        var saved = Assert.Single(ItemSaver.Save(item, Out, _blobs));
        Assert.Equal(Path.Combine(Out, "Image.png"), saved);
        Assert.Equal([1, 2, 3], File.ReadAllBytes(saved));
        _blobs.Delete("img.png");
        Assert.Throws<IOException>(() => ItemSaver.Save(item, Out, _blobs));
    }

    [Fact]
    public void FilesAndFoldersAreCopied()
    {
        var source = Path.Combine(_dir, "Source");
        Directory.CreateDirectory(Path.Combine(source, "Folder", "Sub"));
        File.WriteAllText(Path.Combine(source, "doc.txt"), "doc");
        File.WriteAllText(Path.Combine(source, "Folder", "Sub", "deep.txt"), "deep");
        Directory.CreateDirectory(Out);
        File.WriteAllText(Path.Combine(Out, "doc.txt"), "already here");
        var item = new ClipItem
        {
            Kind = ClipKind.File,
            Files = [Path.Combine(source, "doc.txt"), Path.Combine(source, "Folder"), Path.Combine(source, "missing.txt")],
        };
        var saved = ItemSaver.Save(item, Out, _blobs);
        Assert.Equal([Path.Combine(Out, "doc (2).txt"), Path.Combine(Out, "Folder")], saved);
        Assert.Equal("doc", File.ReadAllText(Path.Combine(Out, "doc (2).txt")));
        Assert.Equal("already here", File.ReadAllText(Path.Combine(Out, "doc.txt")));
        Assert.Equal("deep", File.ReadAllText(Path.Combine(Out, "Folder", "Sub", "deep.txt")));
        Assert.True(File.Exists(Path.Combine(source, "doc.txt")));   // copied, not moved

        var gone = new ClipItem { Kind = ClipKind.File, Files = [Path.Combine(source, "missing.txt")] };
        Assert.Equal("The file is gone.", Assert.Throws<IOException>(() => ItemSaver.Save(gone, Out, _blobs)).Message);
    }

    [Fact]
    public void SeveralItemsReportTheOutcome()
    {
        var ok = ItemSaver.Save([Text("one"), Text("two")], Out, _blobs);
        Assert.Equal((2, null as string, "Saved 2 items to Out"), (ok.SavedItems, ok.Error, ok.Notice("Out")));
        Assert.Equal("Saved to Out", ItemSaver.Save([Text("three")], Out, _blobs).Notice("Out"));

        var image = new ClipItem { Kind = ClipKind.Image, ImageFile = "missing.png" };
        var partial = ItemSaver.Save([Text("four"), image], Out, _blobs);
        Assert.Equal("Saved 1 of 2 items to Out: The image is gone.", partial.Notice("Out"));
        Assert.Equal("Couldn't save to Out: The image is gone.", ItemSaver.Save([image], Out, _blobs).Notice("Out"));
    }
}
