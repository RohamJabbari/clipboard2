using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Clipboard2.App.Platform;
using Clipboard2.Core;
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App.Views;

/// <summary>Opened from the tray icon: search, pinned + recent history, quick actions.</summary>
public sealed class FlyoutWindow : Window
{
    private readonly AppServices _services;
    private readonly TextBox _search = new() { FontSize = 14 };
    private readonly StackPanel _list = new();
    private readonly Border _footer = new();
    private readonly Border _banner = new();
    private bool _confirmClear;

    public FlyoutWindow(AppServices services)
    {
        _services = services;
        Title = "Clipboard2";
        Width = 380;
        Height = 540;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Background = Brushes.Transparent;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, GlassFrameThickness = new Thickness(-1), ResizeBorderThickness = new Thickness(0) });
        SourceInitialized += (_, _) => Fluent.ApplyBackdrop(this);

        _search.TextChanged += (_, _) => Render();
        System.Windows.Automation.AutomationProperties.SetName(_search, "Search history");

        var root = new DockPanel();
        var top = new StackPanel { Margin = new Thickness(10, 10, 10, 6) };
        top.Children.Add(_search);
        DockPanel.SetDock(top, Dock.Top);
        root.Children.Add(top);
        DockPanel.SetDock(_banner, Dock.Top);
        root.Children.Add(_banner);
        DockPanel.SetDock(_footer, Dock.Bottom);
        root.Children.Add(_footer);
        root.Children.Add(new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(6, 0, 6, 6) });
        Content = new Border { Background = Fluent.PanelBackground, Child = root };

        Deactivated += (_, _) => Hide();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Hide(); };
        services.StoreChanged += () => Dispatcher.BeginInvoke(() => { if (IsVisible) Render(); });
    }

    public void ShowNear(Point screenPixels)
    {
        _confirmClear = false;
        _search.Text = "";
        Render();
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        var monitor = Native.MonitorFromPoint(new Native.POINT { X = (int)screenPixels.X, Y = (int)screenPixels.Y }, Native.MONITOR_DEFAULTTONEAREST);
        var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        if (Native.GetMonitorInfo(monitor, ref info))
        {
            Native.GetDpiForMonitor(monitor, 0, out var dpi, out _);
            var scale = dpi == 0 ? 1.0 : dpi / 96.0;
            int w = (int)(Width * scale), h = (int)(Height * scale);
            // Sit above (or beside) the taskbar, next to the tray.
            var x = Math.Clamp((int)screenPixels.X - w / 2, info.rcWork.Left + 8, info.rcWork.Right - w - 8);
            var y = Math.Clamp(info.rcWork.Bottom - h - 8, info.rcWork.Top + 8, info.rcWork.Bottom - h);
            Native.SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, Native.SWP_NOZORDER);
        }
        Show();
        Activate();
        Native.ForceForeground(hwnd);
        _search.Focus();
    }

    private Dictionary<string, string> _groupNames = [];

    private void Render()
    {
        RenderBanner();
        _list.Children.Clear();
        _groupNames = _services.Store.Groups().ToDictionary(g => g.Id, g => g.DisplayName);
        var query = _search.Text.Trim();
        var items = _services.Store.AllItems();
        if (query.Length > 0)
        {
            items = items.Select(i => (Item: i, Score: FuzzyMatcher.Score(query, i.SearchableText)))
                .Where(x => x.Score is not null).OrderByDescending(x => x.Score).Select(x => x.Item).Take(200).ToList();
        }
        var pinned = items.Where(i => i.IsPinned).ToList();
        var recent = items.Where(i => !i.IsPinned).Take(200).ToList();
        if (items.Count == 0)
        {
            var empty = Fluent.Label(query.Length == 0 ? "No clipboard history yet — copy something." : "No results.", 13, Fluent.Secondary);
            empty.Margin = new Thickness(12, 30, 12, 0);
            empty.HorizontalAlignment = HorizontalAlignment.Center;
            _list.Children.Add(empty);
        }
        if (pinned.Count > 0) Section("Pinned", pinned);
        if (recent.Count > 0) Section("Recent", recent);
        RenderFooter();
    }

    private void RenderBanner()
    {
        if (_services.Updates.AvailableVersion is { } version)
        {
            var button = new Button { Content = $"Clipboard2 {version} is available — Update", HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new Thickness(10, 0, 10, 6) };
            button.Click += async (_, _) => await _services.Updates.InstallAsync();
            _banner.Child = button;
        }
        else _banner.Child = null;
    }

    private void Section(string title, System.Collections.Generic.IEnumerable<ClipItem> items)
    {
        var header = Fluent.Label(title, 12, Fluent.Secondary, FontWeights.SemiBold);
        header.Margin = new Thickness(8, 8, 0, 3);
        _list.Children.Add(header);
        foreach (var item in items) _list.Children.Add(Row(item));
    }

    private Border Row(ClipItem item)
    {
        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        FrameworkElement icon = item.Kind == ClipKind.Image && Icons.Thumbnail(_services.Store.Blobs, item.ThumbnailFile) is { } thumb
            ? new Image { Source = thumb, Width = 22, Height = 22, Stretch = Stretch.UniformToFill }
            : Icons.ForApp(item.SourceId) is { } appIcon ? new Image { Source = appIcon, Width = 20, Height = 20 }
            : Glyphs.Icon(item.Kind == ClipKind.File ? Glyphs.File : Glyphs.Text, 16, Fluent.Secondary);
        icon.Margin = new Thickness(0, 0, 8, 0);
        grid.Children.Add(icon);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        if (item.Label is not null)
        {
            texts.Children.Add(Fluent.Label(item.Label, 13, null, FontWeights.SemiBold));
            texts.Children.Add(Fluent.Label(item.Preview, 12, Fluent.Secondary));
        }
        else texts.Children.Add(Fluent.Label(item.DisplayTitle, 13));
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);
        if (item.SpaceId is { } space && _groupNames.GetValueOrDefault(space) is { } groupName)
            texts.Children.Add(Fluent.Label("In " + groupName, 11, Fluent.Tertiary));
        var time = Fluent.Label(item.IsPinned ? Glyphs.Pinned : Fluent.Relative(item.LastCopiedAt), 11, Fluent.Tertiary);
        if (item.IsPinned) time.FontFamily = (FontFamily)Application.Current.Resources["IconFont"];
        time.Margin = new Thickness(8, 0, 0, 0);
        Grid.SetColumn(time, 2);
        grid.Children.Add(time);

        var row = new Border { Child = grid, Padding = new Thickness(8, 5, 8, 5), CornerRadius = new CornerRadius(6), Background = Brushes.Transparent };
        row.MouseEnter += (_, _) => row.Background = Fluent.Subtle;
        row.MouseLeave += (_, _) => row.Background = Brushes.Transparent;
        row.MouseLeftButtonUp += (_, _) => Paste(item, null);
        System.Windows.Automation.AutomationProperties.SetName(row, item.DisplayTitle);
        row.ContextMenu = BuildMenu(item);
        return row;
    }

    private void Paste(ClipItem item, Transform? transform)
    {
        Hide();
        _services.Paste(item, transform);
    }

    private ContextMenu BuildMenu(ClipItem item)
    {
        var menu = new ContextMenu();
        MenuItem Item(string header, Action action) { var i = new MenuItem { Header = header }; i.Click += (_, _) => action(); return i; }
        menu.Items.Add(Item("Paste", () => Paste(item, null)));
        if (item.Kind.IsTextual()) menu.Items.Add(Item("Paste as Plain Text", () => Paste(item, Transform.PlainText)));
        menu.Items.Add(Item("Copy", () => _services.Copy(item)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item(item.IsPinned ? "Unpin" : "Pin", () => _services.Store.TogglePin(item)));
        menu.Items.Add(Item(item.Label is null ? "Label…" : "Edit Label…", () =>
        {
            if (InputDialog.Ask("Label", "Labelled items are pinned and never expire. Leave empty to remove the label.", item.Label ?? "") is { } label)
                _services.Store.SetLabel(label, item);
        }));
        if (item.Kind.IsTextual())
        {
            menu.Items.Add(Item("Save as Secret…", () =>
            {
                var suggested = item.SourceName is { } app ? $"Password from {app}" : "New Secret";
                if (InputDialog.Ask("Save as Secret", "Moves it to Credential Manager and out of history.", suggested, okTitle: "Save") is { Length: > 0 } name
                    && _services.Secrets.Add(name.Trim(), item.Text) is not null)
                {
                    _services.Slots.Remove(SlotTarget.ForClip(item.Id));
                    _services.Store.Delete(item);
                }
            }));
        }
        var slots = new MenuItem { Header = "Assign to Quick Slot" };
        for (var n = QuickSlots.First; n <= QuickSlots.Last; n++)
        {
            var slot = n;
            slots.Items.Add(Item($"Ctrl+{slot}", () =>
            {
                if (!item.IsPinned) _services.Store.TogglePin(item);
                _services.Slots.Assign(SlotTarget.ForClip(item.Id), slot);
            }));
        }
        menu.Items.Add(slots);
        var groups = _services.Store.Groups().Where(g => g.Id != item.SpaceId).ToList();
        if (groups.Count > 0)
        {
            var share = new MenuItem { Header = "Share to Group" };
            foreach (var group in groups)
                share.Items.Add(Item(group.DisplayName, () => _services.Store.CopyToSpace(item, group.Id)));
            menu.Items.Add(share);
        }
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("Delete", () => _services.Store.Delete(item)));
        return menu;
    }

    private void RenderFooter()
    {
        var bar = new DockPanel { Margin = new Thickness(8, 6, 8, 8) };
        if (_confirmClear)
        {
            var clear = new Button { Content = "Clear" };
            clear.Click += (_, _) => { _services.Store.ClearHistory(); _confirmClear = false; Render(); };
            var cancel = new Button { Content = "Cancel", Margin = new Thickness(0, 0, 6, 0) };
            cancel.Click += (_, _) => { _confirmClear = false; RenderFooter(); };
            DockPanel.SetDock(clear, Dock.Right);
            DockPanel.SetDock(cancel, Dock.Right);
            bar.Children.Add(clear);
            bar.Children.Add(cancel);
            bar.Children.Add(Fluent.Label("Clear history? Pinned items are kept.", 13));
            _footer.Child = bar;
            return;
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        void Add(string glyph, string tip, Action action)
        {
            var b = new Button { Content = Glyphs.Icon(glyph, 14), ToolTip = tip, Margin = new Thickness(4, 0, 0, 0), Padding = new Thickness(8, 4, 8, 4) };
            System.Windows.Automation.AutomationProperties.SetName(b, tip);
            b.Click += (_, _) => action();
            buttons.Children.Add(b);
        }
        Add(_services.Settings.IsPaused ? Glyphs.Play : Glyphs.Pause, _services.Settings.IsPaused ? "Resume Capture" : "Pause Capture", () =>
        {
            _services.Settings.IsPaused = !_services.Settings.IsPaused;
            _services.Settings.Save();
            RenderFooter();
        });
        Add(Glyphs.Delete, "Clear History", () => { _confirmClear = true; RenderFooter(); });
        Add(Glyphs.Settings, "Settings", () => { Hide(); _services.OpenSettings(); });
        Add(Glyphs.Power, "Quit Clipboard2", () => Application.Current.Shutdown());
        var open = new Button { Content = Glyphs.Icon(Glyphs.Panel, 14), ToolTip = "Open Quick Panel", Padding = new Thickness(8, 4, 8, 4) };
        open.Click += (_, _) => { Hide(); _services.ShowPanel(); };
        DockPanel.SetDock(buttons, Dock.Right);
        bar.Children.Add(buttons);
        bar.Children.Add(open);
        _footer.Child = bar;
    }
}
