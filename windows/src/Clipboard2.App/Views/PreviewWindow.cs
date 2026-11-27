using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shell;
using Clipboard2.App.Platform;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

/// <summary>The large preview (Ctrl+Y): the selected item at most of the screen's size. Owned by the quick panel,
/// which stays open behind it; keys that move through items go to the panel's model.</summary>
public sealed class PreviewWindow : Window
{
    private const int MaxPdfPages = 20;

    private readonly AppServices _services;
    private readonly QuickPanelWindow _panel;
    private PanelModel Model => _services.Panel;

    private readonly ContentControl _icon = new() { Width = 32, Height = 32, Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _title = Fluent.Label("", 15, null, FontWeights.SemiBold);
    private readonly TextBlock _subtitle = Fluent.Label("", 12, Fluent.Secondary);
    private readonly TextBlock _position = Fluent.Label("", 13, Fluent.Secondary);
    private readonly StackPanel _tools = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border _body = new();
    private readonly TextBlock _hints = Fluent.Label("", 12, Fluent.Secondary);
    private string? _shownKey;
    private CancellationTokenSource? _loading;
    /// <summary>Remembered while the app runs: text is shown in the UI font unless asked otherwise.</summary>
    private static bool _monospace;

    public PreviewWindow(AppServices services, QuickPanelWindow panel)
    {
        _services = services;
        _panel = panel;
        Owner = panel;
        Title = "Clipboard2 Preview";
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Background = Brushes.Transparent;
        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0, GlassFrameThickness = new Thickness(-1), ResizeBorderThickness = new Thickness(0), UseAeroCaptionButtons = false,
        });
        SourceInitialized += (_, _) => Fluent.ApplyBackdrop(this);

        var header = new DockPanel { Margin = new Thickness(16, 10, 10, 10) };
        var close = new Button
        {
            Content = Glyphs.Icon(Glyphs.Cancel, 12), Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(8, 0, 0, 0),
            Background = Brushes.Transparent, BorderThickness = new Thickness(0), ToolTip = "Close (Esc)", VerticalAlignment = VerticalAlignment.Center,
        };
        System.Windows.Automation.AutomationProperties.SetName(close, "Close preview");
        close.Click += (_, _) => Model.ClosePreview();
        DockPanel.SetDock(close, Dock.Right);
        DockPanel.SetDock(_tools, Dock.Right);
        DockPanel.SetDock(_position, Dock.Right);
        DockPanel.SetDock(_icon, Dock.Left);
        _position.Margin = new Thickness(12, 0, 4, 0);
        header.Children.Add(close);
        header.Children.Add(_tools);
        header.Children.Add(_position);
        header.Children.Add(_icon);
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(_title);
        titles.Children.Add(_subtitle);
        header.Children.Add(titles);

        var footer = new Border { Padding = new Thickness(16, 7, 16, 8), Child = _hints };

        var root = new Grid();
        foreach (var height in new[] { GridLength.Auto, new GridLength(1), new GridLength(1, GridUnitType.Star), new GridLength(1), GridLength.Auto })
            root.RowDefinitions.Add(new RowDefinition { Height = height });
        void Add(UIElement element, int row) { Grid.SetRow(element, row); root.Children.Add(element); }
        Add(header, 0);
        Add(new Border { Background = Fluent.Separator }, 1);
        Add(_body, 2);
        Add(new Border { Background = Fluent.Separator }, 3);
        Add(footer, 4);
        Content = new Border { Background = Fluent.PanelBackground, Child = root };

        PreviewKeyDown += OnPreviewKeyDown;
        // Focus moving back to the panel is fine; to another app, it closes the panel like the panel losing focus.
        Deactivated += (_, _) => _panel.OwnWindowDeactivated();
        // Alt+F4 closes the preview, not the window (it's reused).
        Closing += (_, e) =>
        {
            e.Cancel = true;
            Model.ClosePreview();
        };
    }

    // MARK: Showing

    /// <summary>Sized to most of the work area of the monitor the panel is on, and focused.</summary>
    public void ShowOver(Window panel)
    {
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        var monitor = Native.MonitorFromWindow(new WindowInteropHelper(panel).Handle, Native.MONITOR_DEFAULTTONEAREST);
        var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        if (monitor != IntPtr.Zero && Native.GetMonitorInfo(monitor, ref info))
        {
            Native.GetDpiForMonitor(monitor, 0, out var dpi, out _);
            var scale = dpi == 0 ? 1.0 : dpi / 96.0;
            var work = info.rcWork;
            int w = (int)((work.Right - work.Left) * 0.88), h = (int)((work.Bottom - work.Top) * 0.88);
            Width = w / scale;
            Height = h / scale;
            Native.SetWindowPos(hwnd, IntPtr.Zero, work.Left + (work.Right - work.Left - w) / 2, work.Top + (work.Bottom - work.Top - h) / 2, w, h,
                Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        }
        Show();
        Activate();
        FocusContent();
    }

    public void HidePreview()
    {
        _loading?.Cancel();
        _shownKey = null;
        _body.Child = null;   // let go of big bitmaps and text
        if (IsVisible) Hide();
    }

    /// <summary>Shows the model's current page; rebuilds only when that changed.</summary>
    public void Update()
    {
        _position.Text = Model.PreviewPosition ?? "";
        var page = Model.CurrentPreviewPage;
        var key = page?.Key ?? "none:" + Model.PreviewUnavailableReason;
        if (key == _shownKey) return;
        _shownKey = key;
        _loading?.Cancel();
        _loading = new CancellationTokenSource();
        _tools.Children.Clear();
        _icon.Content = null;
        if (page is null) ShowMessage(Model.PreviewUnavailableReason, "");
        else Build(page, _loading.Token);
        UpdateHints(page);
        if (IsVisible) FocusContent();
    }

    private void FocusContent() => Dispatcher.BeginInvoke(() =>
    {
        if (!IsActive) return;
        if (FindFocusable(_body.Child) is { } target) target.Focus(); else Focus();
    }, System.Windows.Threading.DispatcherPriority.Input);

    private static UIElement? FindFocusable(object? element) => element switch
    {
        TextBoxBase box => box,
        ZoomableImage zoom => zoom,
        ScrollViewer scroll => scroll,
        Decorator d => FindFocusable(d.Child),
        Panel p when p.Children.Count > 0 => FindFocusable(p.Children[0]),
        _ => null,
    };

    private void UpdateHints(PreviewPage? page)
    {
        var paging = Model.PreviewPosition is null ? "" : "←→ Previous/Next    ";
        var zoom = _body.Child is ZoomableImage || page?.Kind == PreviewKind.Image ? "Ctrl+Wheel or +/− Zoom    0 Fit    " : "";
        _hints.Text = KeyLabels.Hints(paging + "↑↓ Other Items    " + zoom + "Enter Paste    Esc Close");
    }

    // MARK: Keyboard

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        if (_body.Child is ZoomableImage zoom)
        {
            switch (key)
            {
                case Key.OemPlus or Key.Add: zoom.ZoomBy(1.25); e.Handled = true; return;
                case Key.OemMinus or Key.Subtract: zoom.ZoomBy(0.8); e.Handled = true; return;
                case Key.D0 or Key.NumPad0: zoom.Fit(); e.Handled = true; return;
            }
        }
        // Only what moves through items, pastes or closes goes to the panel; Ctrl+A, Ctrl+C, Page Up/Down stay here.
        var forward = key switch
        {
            Key.Escape or Key.Up or Key.Down or Key.Left or Key.Right => true,
            Key.Enter => Keyboard.FocusedElement is not ButtonBase,
            Key.Y => ctrl,
            _ => false,
        };
        if (forward && QuickPanelWindow.ToKeyInput(e) is { Key: not PanelKey.Other } input && Model.HandleKey(input)) e.Handled = true;
    }

    // MARK: Pages

    private void SetHeader(string title, string subtitle, UIElement? icon)
    {
        _title.Text = title;
        _subtitle.Text = subtitle;
        _icon.Content = icon;
        _icon.Visibility = icon is null ? Visibility.Collapsed : Visibility.Visible;
    }

    private void Build(PreviewPage page, CancellationToken cancel)
    {
        var item = page.Item;
        switch (page.Kind)
        {
            case PreviewKind.Image:
                SetHeader(item.DisplayTitle, $"Image · {item.ImageWidth}×{item.ImageHeight}" + Source(item), Glyphs.Icon(Glyphs.Image, 22, Fluent.Secondary));
                var path = _services.Store.Blobs.PathFor(item.ImageFile!);
                LoadImage(path, page.Key, cancel, () => ShowMessage("The image is missing", "It was removed from this PC's history."));
                break;
            case PreviewKind.RichText:
                SetHeader(item.DisplayTitle, $"Rich Text · {item.Text.Length:N0} characters" + Source(item), Glyphs.Icon(Glyphs.Text, 22, Fluent.Secondary));
                _body.Child = RichTextView(item.Rtf!) ?? TextView(item.Text);
                break;
            case PreviewKind.Text:
                var (text, truncated) = ItemPreview.Truncate(item.Text);
                SetHeader(item.DisplayTitle, $"{item.Kind.DisplayName()} · {item.Text.Length:N0} characters" + (truncated ? " (the first 2 million shown)" : "") + Source(item),
                    Glyphs.Icon(Glyphs.Text, 22, Fluent.Secondary));
                AddMonospaceToggle();
                _body.Child = TextView(text);
                break;
            default:
                BuildFile(page, cancel);
                break;
        }
    }

    private static string Source(ClipItem item) => item.SourceName is { } app ? $" · from {app}" : "";

    private void BuildFile(PreviewPage page, CancellationToken cancel)
    {
        var path = page.FilePath!;
        var folder = Path.GetDirectoryName(path) ?? "";
        SetHeader(page.Title, folder, FileIcon(path, 28));
        _body.Child = Loading();
        // File access can be slow (network shares, sleeping disks): off the UI thread.
        Run(() =>
        {
            var kind = FilePreview.Classify(path);
            var size = FilePreview.SizeText(path);
            var text = kind == FilePreviewKind.Text ? FilePreview.ReadText(path) : null;
            return (kind, size, text);
        }, page.Key, cancel, result =>
        {
            var (kind, size, text) = result;
            _subtitle.Text = string.Join(" · ", new[] { size, folder }.Where(s => s.Length > 0));
            if (kind is not FilePreviewKind.Missing) AddFileButtons(path, kind == FilePreviewKind.Folder);
            switch (kind)
            {
                case FilePreviewKind.Image:
                    LoadImage(path, page.Key, cancel, () => _body.Child = FileCard(path, kind, size));
                    break;
                case FilePreviewKind.Text when text is { } t:
                    if (t.Truncated) _subtitle.Text = $"{size} (the first {FilePreview.MaxTextBytes / (1024 * 1024)} MB shown) · {folder}";
                    AddMonospaceToggle();
                    _body.Child = TextView(t.Text);
                    break;
                case FilePreviewKind.Pdf:
                    _ = ShowPdfAsync(path, page.Key, size, cancel);
                    break;
                default:
                    _body.Child = FileCard(path, kind, size);
                    break;
            }
            UpdateHints(page);
            FocusContent();
        });
    }

    /// <summary>Runs <paramref name="work"/> in the background and shows its result if the page is still the one shown.</summary>
    private void Run<T>(Func<T> work, string key, CancellationToken cancel, Action<T> show)
    {
        Task.Run(work, cancel).ContinueWith(task =>
        {
            if (task.IsCompletedSuccessfully && !cancel.IsCancellationRequested && _shownKey == key) show(task.Result);
        }, TaskScheduler.FromCurrentSynchronizationContext());
    }

    private void LoadImage(string path, string key, CancellationToken cancel, Action failed)
    {
        _body.Child = Loading();
        Run(() => File.Exists(path) ? ImageTools.Load(path) : null, key, cancel, image =>
        {
            if (image is null) { failed(); return; }
            var zoom = new ZoomableImage(image);
            var label = Fluent.Label("", 12, Fluent.Secondary);
            label.Margin = new Thickness(0, 0, 8, 0);
            label.MinWidth = 40;
            label.TextAlignment = TextAlignment.Right;
            zoom.ZoomChanged += () => label.Text = zoom.ZoomText;
            var fit = ToolButton("Fit", "Fit the image to the window (0)", zoom.Fit);
            var actual = ToolButton("100%", "Actual size", () => zoom.ZoomTo(1));
            _tools.Children.Insert(0, actual);
            _tools.Children.Insert(0, fit);
            _tools.Children.Insert(0, label);
            _body.Child = zoom;
            FocusContent();
        });
    }

    private async Task ShowPdfAsync(string path, string key, string size, CancellationToken cancel)
    {
        _body.Child = Loading();
        try
        {
            var dpi = VisualTreeHelper.GetDpi(this).DpiScaleX;
            var width = (uint)Math.Clamp((_body.ActualWidth - 80) * dpi, 400, 2000);
            var pdf = await PdfPages.RenderAsync(path, MaxPdfPages, width, cancel);
            if (cancel.IsCancellationRequested || _shownKey != key) return;
            var pages = new StackPanel { Margin = new Thickness(40, 20, 40, 20) };
            foreach (var bitmap in pdf.Pages)
            {
                pages.Children.Add(new Border
                {
                    Child = new Image { Source = bitmap, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly },
                    Background = Brushes.White, Margin = new Thickness(0, 0, 0, 16), HorizontalAlignment = HorizontalAlignment.Center,
                });
            }
            if (pdf.PageCount > pdf.Pages.Count)
            {
                var more = Fluent.Label($"The first {pdf.Pages.Count} of {pdf.PageCount} pages. Open the file to see the rest.", 13, Fluent.Secondary);
                more.HorizontalAlignment = HorizontalAlignment.Center;
                pages.Children.Add(more);
            }
            _subtitle.Text = $"PDF · {(pdf.PageCount == 1 ? "1 page" : $"{pdf.PageCount} pages")} · {size} · {Path.GetDirectoryName(path)}";
            _body.Child = new ScrollViewer { Content = pages, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = true };
            FocusContent();
        }
        catch (Exception e) when (e is not OperationCanceledException)
        {
            Log.Info("Preview: couldn't render PDF: " + e.Message);
            if (_shownKey == key) _body.Child = FileCard(path, FilePreviewKind.Pdf, size, "Windows couldn't show this PDF (it may be protected or damaged).");
        }
        catch (OperationCanceledException) { /* another page is shown */ }
    }

    // MARK: Views

    private static UIElement Loading()
    {
        var label = Fluent.Label("Loading…", 14, Fluent.Secondary);
        label.HorizontalAlignment = HorizontalAlignment.Center;
        return label;
    }

    private void ShowMessage(string title, string detail)
    {
        SetHeader("", "", null);
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        var t = Fluent.Label(title, 17, null, FontWeights.SemiBold);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(t);
        if (detail.Length > 0)
        {
            var d = Fluent.Label(detail, 13, Fluent.Secondary);
            d.HorizontalAlignment = HorizontalAlignment.Center;
            d.Margin = new Thickness(0, 6, 0, 0);
            stack.Children.Add(d);
        }
        _body.Child = stack;
    }

    private static TextBox TextView(string text) => new()
    {
        Text = text,
        IsReadOnly = true,
        IsReadOnlyCaretVisible = false,
        TextWrapping = TextWrapping.Wrap,
        AcceptsReturn = true,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Padding = new Thickness(24, 16, 24, 16),
        FontSize = 15,
        FontFamily = _monospace ? new FontFamily("Cascadia Mono, Consolas") : SystemFonts.MessageFontFamily,
    };

    /// <summary>The formatted text on a white page (RTF usually sets black text). Null when it can't be read.</summary>
    private static UIElement? RichTextView(string rtf)
    {
        if (rtf.Length > 20_000_000) return null;   // a huge RTF (embedded pictures) would stall the UI thread
        try
        {
            var box = new RichTextBox
            {
                IsReadOnly = true, IsReadOnlyCaretVisible = false, BorderThickness = new Thickness(0), Background = Brushes.White, Foreground = Brushes.Black,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(24, 16, 24, 16), FontSize = 15,
            };
            // RTF is 8-bit text: characters past ASCII are escaped or in the document's code page.
            using var stream = new MemoryStream(Encoding.Latin1.GetBytes(rtf));
            new TextRange(box.Document.ContentStart, box.Document.ContentEnd).Load(stream, DataFormats.Rtf);
            return new Border { Child = box, Background = Brushes.White, CornerRadius = new CornerRadius(6), Margin = new Thickness(16), ClipToBounds = true };
        }
        catch (Exception e)
        {
            Log.Info("Preview: couldn't read RTF: " + e.Message);
            return null;
        }
    }

    /// <summary>For what can't be shown inline: the file's icon, name, size and place, and ways to open it.</summary>
    private UIElement FileCard(string path, FilePreviewKind kind, string size, string? note = null)
    {
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 640 };
        var icon = kind == FilePreviewKind.Missing ? Glyphs.Icon(Glyphs.Warning, 48, Fluent.Secondary) : FileIcon(path, 64);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var name = Fluent.Label(Path.GetFileName(path.TrimEnd('\\', '/')) is { Length: > 0 } n ? n : path, 20, null, FontWeights.SemiBold);
        name.HorizontalAlignment = HorizontalAlignment.Center;
        name.Margin = new Thickness(0, 14, 0, 4);
        stack.Children.Add(name);
        var details = kind == FilePreviewKind.Missing ? "This file was moved or deleted since it was copied." : size;
        try
        {
            if (kind is not FilePreviewKind.Missing) details += (details.Length > 0 ? " · " : "") + "Modified " + File.GetLastWriteTime(path).ToString("g");
        }
        catch { /* no access: size only */ }
        var info = Fluent.Label(note ?? details, 13, Fluent.Secondary, wrap: true);
        info.TextAlignment = TextAlignment.Center;
        info.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(info);
        stack.Children.Add(new TextBox
        {
            Text = path, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent, TextWrapping = TextWrapping.Wrap,
            HorizontalContentAlignment = HorizontalAlignment.Center, Foreground = Fluent.Secondary, FontSize = 12, Margin = new Thickness(0, 6, 0, 0),
        });
        if (kind is not FilePreviewKind.Missing)
        {
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 16, 0, 0) };
            var open = new Button { Content = "Open", MinWidth = 90, Padding = new Thickness(12, 4, 12, 4) };
            open.Click += (_, _) => Open(path);
            var reveal = new Button { Content = "Show in Explorer", Padding = new Thickness(12, 4, 12, 4), Margin = new Thickness(8, 0, 0, 0) };
            reveal.Click += (_, _) => ShowInExplorer(path);
            buttons.Children.Add(open);
            buttons.Children.Add(reveal);
            stack.Children.Add(buttons);
        }
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    /// <summary>The shell's icon for the file (as Explorer shows it), or a glyph.</summary>
    private static FrameworkElement FileIcon(string path, double size)
    {
        try
        {
            if (File.Exists(path) && System.Drawing.Icon.ExtractAssociatedIcon(path) is { } icon)
            {
                using (icon)
                {
                    var image = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                    image.Freeze();
                    return new Image { Source = image, Width = size, Height = size };
                }
            }
        }
        catch { /* no access: the glyph */ }
        return Glyphs.Icon(Directory.Exists(path) ? "" : Glyphs.File, size * 0.75, Fluent.Secondary);
    }

    // MARK: Header tools

    private static Button ToolButton(string title, string tip, Action action)
    {
        var button = new Button { Content = title, FontSize = 12, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(6, 0, 0, 0), ToolTip = tip, Focusable = false };
        button.Click += (_, _) => action();
        return button;
    }

    private void AddMonospaceToggle()
    {
        var toggle = new ToggleButton
        {
            Content = "Monospace", FontSize = 12, Padding = new Thickness(10, 3, 10, 3), Margin = new Thickness(6, 0, 0, 0),
            IsChecked = _monospace, Focusable = false, ToolTip = "Show the text in a fixed-width font",
        };
        toggle.Click += (_, _) =>
        {
            _monospace = toggle.IsChecked == true;
            if (FindFocusable(_body.Child) is TextBox box)
                box.FontFamily = _monospace ? new FontFamily("Cascadia Mono, Consolas") : SystemFonts.MessageFontFamily;
        };
        _tools.Children.Add(toggle);
    }

    private void AddFileButtons(string path, bool folder)
    {
        _tools.Children.Add(ToolButton("Open", folder ? "Open the folder" : "Open with its app", () => Open(path)));
        _tools.Children.Add(ToolButton("Show in Explorer", "Show it in its folder", () => ShowInExplorer(path)));
    }

    /// <summary>Opens the file like a double-click in Explorer would.</summary>
    private void Open(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
        catch (Exception e) { Model.ShowNotice("Couldn't open it: " + e.Message); }
    }

    private void ShowInExplorer(string path)
    {
        try { Process.Start(new ProcessStartInfo("explorer.exe") { ArgumentList = { "/select," + path } }); }
        catch (Exception e) { Model.ShowNotice("Couldn't show it: " + e.Message); }
    }
}

/// <summary>An image fit to its space (never enlarged). Ctrl+wheel and <see cref="ZoomBy"/> zoom around a point,
/// dragging pans, double-click toggles between fit and actual size.</summary>
public sealed class ZoomableImage : Border
{
    private readonly ScrollViewer _scroll;
    private readonly Image _image;
    private readonly BitmapSource _source;
    /// <summary>Null: fit to the window. Otherwise 1 is one image pixel per screen pixel.</summary>
    private double? _zoom;
    private Point? _dragFrom;
    private (double X, double Y) _dragOffset;

    public event Action? ZoomChanged;

    public ZoomableImage(BitmapSource source)
    {
        _source = source;
        Focusable = true;
        FocusVisualStyle = null;
        Background = Brushes.Transparent;
        _image = new Image
        {
            Source = source, Stretch = Stretch.Uniform, StretchDirection = StretchDirection.DownOnly,
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
        };
        RenderOptions.SetBitmapScalingMode(_image, BitmapScalingMode.HighQuality);
        _scroll = new ScrollViewer
        {
            Content = _image, Focusable = false, Padding = new Thickness(16),
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
        };
        Child = _scroll;
        _image.SizeChanged += (_, _) => ZoomChanged?.Invoke();
        _scroll.PreviewMouseWheel += (_, e) =>
        {
            if (!Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) return;
            ZoomBy(e.Delta > 0 ? 1.25 : 0.8, e.GetPosition(_scroll));
            e.Handled = true;
        };
        _scroll.PreviewMouseLeftButtonDown += (_, e) =>
        {
            Focus();
            if (e.ClickCount == 2)
            {
                if (_zoom is null) ZoomTo(1, e.GetPosition(_scroll)); else Fit();
                e.Handled = true;
                return;
            }
            if (_zoom is null) return;
            _dragFrom = e.GetPosition(_scroll);
            _dragOffset = (_scroll.HorizontalOffset, _scroll.VerticalOffset);
            _scroll.CaptureMouse();
            e.Handled = true;
        };
        _scroll.PreviewMouseMove += (_, e) =>
        {
            if (_dragFrom is not { } from) return;
            var now = e.GetPosition(_scroll);
            _scroll.ScrollToHorizontalOffset(_dragOffset.X - (now.X - from.X));
            _scroll.ScrollToVerticalOffset(_dragOffset.Y - (now.Y - from.Y));
        };
        _scroll.PreviewMouseLeftButtonUp += (_, _) =>
        {
            if (_dragFrom is null) return;
            _dragFrom = null;
            _scroll.ReleaseMouseCapture();
        };
    }

    /// <summary>Device-independent units per image pixel at 100%.</summary>
    private double DipsPerPixel => 1 / VisualTreeHelper.GetDpi(this).DpiScaleX;

    /// <summary>The scale shown, where 1 is actual size.</summary>
    public double Scale => _zoom ?? (_image.ActualWidth > 0 && _source.PixelWidth > 0 ? _image.ActualWidth / (_source.PixelWidth * DipsPerPixel) : 1);

    public string ZoomText => $"{Math.Round(Scale * 100)}%";

    public void Fit()
    {
        _zoom = null;
        _image.Width = _image.Height = double.NaN;
        _image.Stretch = Stretch.Uniform;
        _scroll.HorizontalScrollBarVisibility = _scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Disabled;
        Cursor = null;
        ZoomChanged?.Invoke();
    }

    public void ZoomBy(double factor, Point? at = null) => ZoomTo(Scale * factor, at);

    /// <summary>Zooms keeping the image point under <paramref name="at"/> (the viewport's centre by default) in place.</summary>
    public void ZoomTo(double scale, Point? at = null)
    {
        scale = Math.Clamp(scale, 0.05, 16);
        var anchor = at ?? new Point(_scroll.ActualWidth / 2, _scroll.ActualHeight / 2);
        // Where the anchor is on the image, as a fraction of its size (clamped: the anchor may be beside it).
        var onImage = _scroll.TranslatePoint(anchor, _image);
        double fx = _image.ActualWidth > 0 ? Math.Clamp(onImage.X / _image.ActualWidth, 0, 1) : 0.5;
        double fy = _image.ActualHeight > 0 ? Math.Clamp(onImage.Y / _image.ActualHeight, 0, 1) : 0.5;

        _zoom = scale;
        _image.Stretch = Stretch.Fill;
        _image.Width = _source.PixelWidth * DipsPerPixel * scale;
        _image.Height = _source.PixelHeight * DipsPerPixel * scale;
        _scroll.HorizontalScrollBarVisibility = _scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        Cursor = Cursors.SizeAll;
        _scroll.UpdateLayout();
        var moved = _image.TranslatePoint(new Point(fx * _image.Width, fy * _image.Height), _scroll);
        _scroll.ScrollToHorizontalOffset(_scroll.HorizontalOffset + moved.X - anchor.X);
        _scroll.ScrollToVerticalOffset(_scroll.VerticalOffset + moved.Y - anchor.Y);
        ZoomChanged?.Invoke();
    }
}
