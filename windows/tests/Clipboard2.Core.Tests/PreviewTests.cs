using System.Text;
using Clipboard2.Core;

namespace Clipboard2.Core.Tests;

public sealed class PreviewTests : IDisposable
{
    private readonly ClipStore _store = new(":memory:", new BlobStore(Path.Combine(Path.GetTempPath(), "c2preview-" + Guid.NewGuid())));
    private readonly Settings _settings = new();
    private readonly FakeVault _vault = new();
    private readonly FakeHost _host = new();
    private readonly PanelModel _model;
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "c2previewfiles-" + Guid.NewGuid());

    public PreviewTests()
    {
        _model = new PanelModel(_store, _settings, new QuickSlots(_settings), _vault, _host);
        Directory.CreateDirectory(_dir);
    }

    public void Dispose()
    {
        _store.Dispose();
        try { Directory.Delete(_dir, recursive: true); } catch { /* best effort */ }
    }

    private static KeyInput K(PanelKey key, KeyMods mods = KeyMods.None, char letter = '\0') => new(key, mods, Letter: letter);
    private static readonly KeyInput CtrlY = K(PanelKey.Letter, KeyMods.Ctrl, 'y');

    private ClipItem AddText(string text, int ageSeconds = 0, string? rtf = null, string? html = null) =>
        _store.Ingest(ProcessedCapture.ForText(text, rtf, html), DateTime.UtcNow.AddSeconds(-ageSeconds));

    private ClipItem AddImage(string name, int ageSeconds = 0) =>
        _store.Ingest(new ProcessedCapture { Kind = ClipKind.Image, Preview = "Image", Hash = "image:" + name, ImageFile = name + ".png", ImageWidth = 4, ImageHeight = 3 },
            DateTime.UtcNow.AddSeconds(-ageSeconds));

    private ClipItem AddFiles(int ageSeconds, params string[] files) =>
        _store.Ingest(ProcessedCapture.ForFiles(files), DateTime.UtcNow.AddSeconds(-ageSeconds));

    private string Write(string name, string text)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllText(path, text);
        return path;
    }

    // MARK: Content per kind

    [Fact]
    public void EachKindPreviewsAsItsContent()
    {
        Assert.Equal(PreviewKind.Text, ItemPreview.KindOf(new ClipItem { Kind = ClipKind.Text, Text = "a" }));
        Assert.Equal(PreviewKind.RichText, ItemPreview.KindOf(new ClipItem { Kind = ClipKind.RichText, Text = "a", Rtf = @"{\rtf1 a}" }));
        // HTML without RTF: nothing rich to render, so the plain text.
        Assert.Equal(PreviewKind.Text, ItemPreview.KindOf(new ClipItem { Kind = ClipKind.RichText, Text = "a", Html = "<b>a</b>" }));
        Assert.Equal(PreviewKind.Image, ItemPreview.KindOf(new ClipItem { Kind = ClipKind.Image, ImageFile = "x.png" }));
        Assert.Equal(PreviewKind.File, ItemPreview.KindOf(new ClipItem { Kind = ClipKind.File }));
    }

    [Fact]
    public void FileItemsHaveOnePagePerFileAndImagesWithoutPixelsNone()
    {
        string[] paths = [Path.Combine(_dir, "a.txt"), Path.Combine(_dir, "b.png"), Path.Combine(_dir, "c.docx")];
        var files = new ClipItem { Kind = ClipKind.File, Files = [.. paths] };
        var pages = ItemPreview.Pages([files, new ClipItem { Kind = ClipKind.Image }, new ClipItem { Kind = ClipKind.Text, Text = "t" }]);
        Assert.Equal([.. paths, null], pages.Select(p => p.FilePath));
        Assert.Equal([0, 1, 2], pages.Take(3).Select(p => p.FileIndex));
        Assert.All(pages.Take(3), p => Assert.Equal(3, p.FileCount));
        Assert.Equal("b.png", pages[1].Title);
        Assert.Equal(PreviewKind.Text, pages[3].Kind);
    }

    [Fact]
    public void LongTextIsCutWithoutSplittingASurrogatePair()
    {
        Assert.Equal(("short", false), ItemPreview.Truncate("short", 10));
        var (text, truncated) = ItemPreview.Truncate("abc😀def", 4);   // the emoji is two chars at index 3–4
        Assert.True(truncated);
        Assert.Equal("abc", text);
        Assert.Equal(("abcd", true), ItemPreview.Truncate("abcdef", 4));
    }

    // MARK: Opening and closing

    [Fact]
    public void CtrlYOpensAndClosesThePreviewOfTheSelectedItem()
    {
        AddText("hello world");
        _model.PrepareForOpen(null);
        Assert.True(_model.HandleKey(CtrlY));
        Assert.True(_model.IsPreviewing);
        Assert.Equal(PreviewKind.Text, _model.CurrentPreviewPage!.Kind);
        Assert.Equal("hello world", _model.CurrentPreviewPage.Item.Text);
        Assert.Null(_model.PreviewPosition);
        _model.HandleKey(CtrlY);
        Assert.False(_model.IsPreviewing);
        Assert.Empty(_host.Log);
    }

    [Fact]
    public void EscapeClosesThePreviewBeforePickedFilesAndThePanel()
    {
        var a = Write("a.txt", "a");
        var b = Write("b.txt", "b");
        AddFiles(0, a, b);
        _model.PrepareForOpen(null);
        _model.ClickFile(a, shift: false);
        _model.HandleKey(CtrlY);
        _model.HandleKey(K(PanelKey.Escape));
        Assert.False(_model.IsPreviewing);
        Assert.Equal([a], _model.PickedFiles);
        _model.HandleKey(K(PanelKey.Escape));
        Assert.Empty(_model.PickedFiles);
        Assert.Empty(_host.Log);
        _model.HandleKey(K(PanelKey.Escape));
        Assert.Equal(["close"], _host.Log);
    }

    [Fact]
    public void PreviewActionIsInTheActionListAndOpensThePreview()
    {
        AddText("note");
        _model.PrepareForOpen(null);
        _model.OpenActions();
        var preview = Assert.Single(_model.AvailableActions.OfType<PanelAction.Preview>());
        Assert.Equal("Preview", preview.Title);
        _model.Perform(preview);
        Assert.Equal(PanelMode.Browse, _model.Mode);
        Assert.True(_model.IsPreviewing);
    }

    [Fact]
    public void SecretsAndSnippetsAreNotPreviewed()
    {
        _vault.Add("Bank", "hunter2");
        _store.CreateSnippet("greet", ";hi", "Hello");
        _model.PrepareForOpen(null);
        _model.SetFilter(PanelFilter.Labelled);   // Saved holds both
        _model.Select(_model.Entries.Single(e => e is PanelEntry.SecretEntry).Id);
        Assert.False(_model.CanPreview);
        Assert.DoesNotContain(_model.AvailableActions, a => a is PanelAction.Preview);
        _model.HandleKey(CtrlY);
        Assert.False(_model.IsPreviewing);
        Assert.Equal("Secrets aren't previewed", _model.Notice);
        _model.Select(_model.Entries.Single(e => e is PanelEntry.SnippetEntry).Id);
        _model.HandleKey(CtrlY);
        Assert.False(_model.IsPreviewing);
        Assert.Equal("Snippets aren't previewed", _model.Notice);
    }

    [Fact]
    public void ClosingThePanelClosesThePreview()
    {
        AddText("x");
        _model.PrepareForOpen(null);
        _model.OpenPreview();
        _model.DidClose();
        Assert.False(_model.IsPreviewing);
        _model.OpenPreview();
        _model.PrepareForOpen(null);
        Assert.False(_model.IsPreviewing);
    }

    [Fact]
    public void EnterInThePreviewPastesTheItem()
    {
        AddText("paste me");
        _model.PrepareForOpen(null);
        _model.OpenPreview();
        _model.HandleKey(K(PanelKey.Enter));
        Assert.Contains("close", _host.Log);
        Assert.Contains("paste:paste me:", _host.Log);
    }

    // MARK: Paging

    [Fact]
    public void LeftRightPageThroughFilesAndStopAtTheEnds()
    {
        var files = new[] { Write("1.txt", "1"), Write("2.txt", "2"), Write("3.txt", "3") };
        AddFiles(0, files);
        _model.PrepareForOpen(null);
        // Not previewing: the arrows belong to the search box.
        Assert.False(_model.HandleKey(K(PanelKey.Right)));
        _model.HandleKey(CtrlY);
        Assert.Equal("1 of 3", _model.PreviewPosition);
        Assert.True(_model.HandleKey(K(PanelKey.Left)));
        Assert.Equal(0, _model.PreviewIndex);
        _model.HandleKey(K(PanelKey.Right));
        _model.HandleKey(K(PanelKey.Right));
        _model.HandleKey(K(PanelKey.Right));
        Assert.Equal("3 of 3", _model.PreviewPosition);
        Assert.Equal(files[2], _model.CurrentPreviewPage!.FilePath);
        _model.HandleKey(K(PanelKey.Left));
        Assert.Equal(files[1], _model.CurrentPreviewPage!.FilePath);
    }

    [Fact]
    public void PreviewShowsOnlyThePickedFiles()
    {
        var files = new[] { Write("1.txt", "1"), Write("2.txt", "2"), Write("3.txt", "3"), Write("4.txt", "4") };
        AddFiles(0, files);
        _model.PrepareForOpen(null);
        _model.ClickFile(files[1], shift: false);
        _model.ClickFile(files[3], shift: false);
        _model.OpenPreview();
        Assert.Equal([files[1], files[3]], _model.PreviewPages.Select(p => p.FilePath));
        Assert.Equal("1 of 2", _model.PreviewPosition);
        // The picked files' item is made anew on every read; what's shown stays the same page.
        Assert.Equal(_model.CurrentPreviewPage!.Key, _model.CurrentPreviewPage!.Key);
        _model.StepPreview(1);
        // Picking another file starts over at the first page of the new subset.
        _model.ClickFile(files[0], shift: false);
        Assert.Equal(0, _model.PreviewIndex);
        Assert.Equal([files[0], files[1], files[3]], _model.PreviewPages.Select(p => p.FilePath));
    }

    [Fact]
    public void MultiSelectionPagesThroughEverySelectedItemInListOrder()
    {
        var f1 = Write("one.md", "# one");
        var f2 = Write("two.json", "{}");
        AddText("oldest", 30);
        AddFiles(20, f1, f2);
        AddImage("pic", 10);
        AddText("newest", 0);
        _vault.Add("Bank", "hunter2");
        _model.PrepareForOpen(null);
        _model.SelectAll();
        _model.HandleKey(CtrlY);
        var pages = _model.PreviewPages;
        Assert.Equal([PreviewKind.Text, PreviewKind.Image, PreviewKind.File, PreviewKind.File, PreviewKind.Text], pages.Select(p => p.Kind));
        Assert.Equal("newest", pages[0].Item.Text);
        Assert.Equal("oldest", pages[^1].Item.Text);
        Assert.Equal("1 of 5", _model.PreviewPosition);
        _model.HandleKey(K(PanelKey.Right));
        Assert.Equal("2 of 5", _model.PreviewPosition);
        Assert.Equal(PreviewKind.Image, _model.CurrentPreviewPage!.Kind);
    }

    [Fact]
    public void UpDownMoveTheSelectionAndThePreviewFollowsFromItsFirstPage()
    {
        var files = new[] { Write("1.txt", "1"), Write("2.txt", "2") };
        AddText("text", 10);
        AddFiles(0, files);
        _model.PrepareForOpen(null);
        _model.HandleKey(CtrlY);
        _model.HandleKey(K(PanelKey.Right));
        Assert.Equal(1, _model.PreviewIndex);
        _model.HandleKey(K(PanelKey.Down));
        Assert.True(_model.IsPreviewing);
        Assert.Equal(0, _model.PreviewIndex);
        Assert.Equal("text", _model.CurrentPreviewPage!.Item.Text);
        _model.HandleKey(K(PanelKey.Up));
        Assert.Equal(files[0], _model.CurrentPreviewPage!.FilePath);
    }

    [Fact]
    public void MovingOntoASecretKeepsThePreviewOpenWithNothingToShow()
    {
        _vault.Add("Bank", "hunter2");
        AddText("visible");
        _model.PrepareForOpen(null);
        _model.SetQuery("b");   // secrets join All while searching
        var text = _model.Entries.First(e => e is PanelEntry.Clip);
        _model.Select(text.Id);
        _model.OpenPreview();
        _model.Select(_model.Entries.First(e => e is PanelEntry.SecretEntry).Id);
        Assert.True(_model.IsPreviewing);
        Assert.Null(_model.CurrentPreviewPage);
        Assert.Equal("Secrets aren't previewed", _model.PreviewUnavailableReason);
    }

    // MARK: Files

    [Fact]
    public void FilesAreSortedIntoWhatCanBeShownInline()
    {
        Assert.Equal(FilePreviewKind.Text, FilePreview.KindByName(@"C:\x\notes.TXT"));
        Assert.Equal(FilePreviewKind.Text, FilePreview.KindByName(@"C:\x\data.json"));
        Assert.Equal(FilePreviewKind.Text, FilePreview.KindByName(@"C:\x\Program.cs"));
        Assert.Equal(FilePreviewKind.Text, FilePreview.KindByName(Path.Combine(_dir, "README")));
        Assert.Equal(FilePreviewKind.Image, FilePreview.KindByName(@"C:\x\photo.JPG"));
        Assert.Equal(FilePreviewKind.Pdf, FilePreview.KindByName(@"C:\x\paper.pdf"));
        Assert.Equal(FilePreviewKind.Other, FilePreview.KindByName(@"C:\x\report.docx"));
        Assert.Equal(FilePreviewKind.Other, FilePreview.KindByName(@"C:\x\setup.exe"));
        Assert.Equal(FilePreviewKind.Other, FilePreview.KindByName(Path.Combine(_dir, "archive")));

        Assert.Equal(FilePreviewKind.Missing, FilePreview.Classify(Path.Combine(_dir, "gone.txt")));
        Assert.Equal(FilePreviewKind.Folder, FilePreview.Classify(_dir));
        Assert.Equal(FilePreviewKind.Text, FilePreview.Classify(Write("here.log", "x")));
    }

    [Fact]
    public void TextFilesAreReadUpToTheCap()
    {
        var small = Write("small.txt", "héllo");
        Assert.Equal(("héllo", false), FilePreview.ReadText(small));
        var big = Write("big.log", new string('a', 100));
        Assert.Equal((new string('a', 40), true), FilePreview.ReadText(big, maxBytes: 40));
        Assert.Equal(2 * 1024 * 1024, FilePreview.MaxTextBytes);
    }

    [Fact]
    public void ACutInsideAMultiByteCharacterIsDropped()
    {
        var path = Write("utf8.txt", "abé");   // é is 2 bytes: a b 0xC3 0xA9
        Assert.Equal(("ab", true), FilePreview.ReadText(path, maxBytes: 3));
    }

    [Fact]
    public void BinaryLookingFilesAreNotShownAsText()
    {
        var path = Path.Combine(_dir, "data.txt");
        File.WriteAllBytes(path, [0x50, 0x4B, 0x00, 0x01]);
        Assert.Null(FilePreview.ReadText(path));
        var utf16 = Path.Combine(_dir, "utf16.txt");
        File.WriteAllText(utf16, "wide", Encoding.Unicode);
        Assert.Equal(("wide", false), FilePreview.ReadText(utf16));
        Assert.Null(FilePreview.ReadText(Path.Combine(_dir, "missing.txt")));
    }
}
