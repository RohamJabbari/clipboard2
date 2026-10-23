using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using Clipboard2.App.Platform;
using Clipboard2.Core;
using Clipboard2.Core.AI;
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App.Views;

/// <summary>The Ctrl+Shift+V panel: search, filter chips, list, preview, Ctrl+K actions, AI.</summary>
public sealed class QuickPanelWindow : Window
{
    private readonly AppServices _services;
    private PanelModel Model => _services.Panel;

    private readonly TextBox _search = new();
    private readonly TextBlock _targetLabel = Fluent.Label("", 12, Fluent.Secondary);
    private readonly StackPanel _chips = new() { Orientation = Orientation.Horizontal };
    private readonly StackPanel _rows = new();
    private readonly ScrollViewer _rowScroll;
    private readonly Border _detail = new();
    private readonly TextBlock _hints = Fluent.Label("", 12, Fluent.Secondary);
    private readonly TextBlock _notice = Fluent.Label("", 12);
    private readonly Dictionary<string, Border> _rowViews = [];
    private List<string> _renderedIds = [];
    private bool _renderQueued;
    private bool _syncingText;

    // Detail pane caching so forms keep focus while the model changes.
    private (PanelMode Mode, string? Key) _detailState;
    private TextBox? _actionFilter;
    private TextBlock? _actionHint;
    private StackPanel? _actionList;
    private TextBox? _aiOutput;
    private TextBlock? _aiStatus;
    private StackPanel? _aiButtons;

    public QuickPanelWindow(AppServices services)
    {
        _services = services;
        Title = "Clipboard2";
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

        _search.FontSize = 20;
        _search.BorderThickness = new Thickness(0);
        _search.Background = Brushes.Transparent;
        _search.VerticalContentAlignment = VerticalAlignment.Center;
        _search.TextChanged += (_, _) => { if (!_syncingText) Model.SetQuery(_search.Text); };
        AutomationName(_search, "Search clipboard history");

        var searchRow = new DockPanel { Margin = new Thickness(16, 12, 16, 8) };
        var searchIcon = Glyphs.Icon(Glyphs.Search, 18, Fluent.Secondary);
        searchIcon.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(searchIcon, Dock.Left);
        DockPanel.SetDock(_targetLabel, Dock.Right);
        searchRow.Children.Add(searchIcon);
        searchRow.Children.Add(_targetLabel);
        searchRow.Children.Add(_search);

        _rowScroll = new ScrollViewer { Content = _rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(8, 6, 8, 6) };

        var content = new Grid();
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56, GridUnitType.Star) });
        content.Children.Add(_rowScroll);
        var divider = new Border { Background = Fluent.Separator };
        Grid.SetColumn(divider, 1);
        content.Children.Add(divider);
        Grid.SetColumn(_detail, 2);
        content.Children.Add(_detail);

        var footer = new DockPanel { Margin = new Thickness(16, 7, 16, 8) };
        DockPanel.SetDock(_notice, Dock.Right);
        footer.Children.Add(_notice);
        footer.Children.Add(_hints);

        var root = new Grid();
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1), new GridLength(1, GridUnitType.Star), new GridLength(1), GridLength.Auto })
            root.RowDefinitions.Add(new RowDefinition { Height = height });
        void Add(UIElement element, int row) { Grid.SetRow(element, row); root.Children.Add(element); }
        Add(searchRow, 0);
        _chips.Margin = new Thickness(14, 0, 14, 10);
        Add(new ScrollViewer { Content = _chips, HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled }, 1);
        Add(new Border { Background = Fluent.Separator }, 2);
        Add(content, 3);
        Add(new Border { Background = Fluent.Separator }, 4);
        Add(footer, 5);

        Content = new Border { Background = Fluent.PanelBackground, Child = root };

        PreviewKeyDown += OnPreviewKeyDown;
        Deactivated += (_, _) => { if (IsVisible) _services.ClosePanel(); };
        Model.Changed += QueueRender;
        _services.StoreChanged += () => Dispatcher.BeginInvoke(() => { if (IsVisible) Model.Refresh(); });
    }

    private static void AutomationName(DependencyObject element, string name) =>
        System.Windows.Automation.AutomationProperties.SetName(element, name);

    // MARK: Showing

    public void ShowNear(IntPtr target)
    {
        var size = _services.Settings.PanelSize switch
        {
            PanelSize.Compact => new Size(680, 420),
            PanelSize.Large => new Size(940, 600),
            _ => new Size(800, 500),
        };
        Width = size.Width;
        Height = size.Height;
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        var monitor = target != IntPtr.Zero ? Native.MonitorFromWindow(target, Native.MONITOR_DEFAULTTONEAREST)
            : (Native.GetCursorPos(out var p) ? Native.MonitorFromPoint(p, Native.MONITOR_DEFAULTTONEAREST) : IntPtr.Zero);
        var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        if (monitor != IntPtr.Zero && Native.GetMonitorInfo(monitor, ref info))
        {
            Native.GetDpiForMonitor(monitor, 0, out var dpi, out _);
            var scale = dpi == 0 ? 1.0 : dpi / 96.0;
            int w = (int)(size.Width * scale), h = (int)(size.Height * scale);
            var work = info.rcWork;
            var x = work.Left + (work.Right - work.Left - w) / 2;
            var y = work.Top + (int)((work.Bottom - work.Top - h) * 0.4);
            Native.SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        }
        _detailState = default;
        Render();
        Show();
        Activate();
        Native.ForceForeground(hwnd);
        FocusForMode();
    }

    public void HidePanel()
    {
        if (IsVisible) Hide();
    }

    private void FocusForMode()
    {
        Dispatcher.BeginInvoke(() =>
        {
            switch (Model.Mode)
            {
                case PanelMode.Actions when _actionFilter is not null: _actionFilter.Focus(); break;
                case PanelMode.Browse: _search.Focus(); _search.CaretIndex = _search.Text.Length; break;
            }
        }, System.Windows.Threading.DispatcherPriority.Input);
    }

    // MARK: Keyboard

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = KeyMods.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods |= KeyMods.Ctrl;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= KeyMods.Shift;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= KeyMods.Alt;
        KeyInput input = key switch
        {
            Key.Escape => new(PanelKey.Escape, mods),
            Key.Up => new(PanelKey.Up, mods),
            Key.Down => new(PanelKey.Down, mods),
            Key.PageUp => new(PanelKey.PageUp, mods),
            Key.PageDown => new(PanelKey.PageDown, mods),
            Key.Enter => new(PanelKey.Enter, mods),
            Key.Tab => new(PanelKey.Tab, mods),
            Key.Delete => new(PanelKey.Delete, mods),
            >= Key.D1 and <= Key.D9 => new(PanelKey.Digit, mods, Digit: key - Key.D0),
            >= Key.NumPad1 and <= Key.NumPad9 => new(PanelKey.Digit, mods, Digit: key - Key.NumPad0),
            >= Key.A and <= Key.Z => new(PanelKey.Letter, mods, Letter: (char)('a' + (key - Key.A))),
            Key.OemComma => new(PanelKey.Letter, mods, Letter: ','),
            _ => new(PanelKey.Other, mods),
        };
        // Tab moves between fields inside forms.
        if (input.Key == PanelKey.Tab && Model.Mode is PanelMode.SnippetForm) return;
        if (input.Key != PanelKey.Other && Model.HandleKey(input)) e.Handled = true;
    }

    // MARK: Rendering

    private void QueueRender()
    {
        if (_renderQueued) return;
        _renderQueued = true;
        Dispatcher.BeginInvoke(() =>
        {
            _renderQueued = false;
            if (IsVisible) Render();
        });
    }

    private void Render()
    {
        if (_search.Text != Model.Query)
        {
            _syncingText = true;
            _search.Text = Model.Query;
            _search.CaretIndex = _search.Text.Length;
            _syncingText = false;
        }
        _targetLabel.Text = Model.TargetApp is { } app ? $"Pastes into {app.Name}" : "";
        RenderChips();
        RenderRows();
        var previousMode = _detailState.Mode;
        RenderDetail();
        RenderHints();
        if (previousMode != Model.Mode) FocusForMode();
    }

    private void RenderChips()
    {
        _chips.Children.Clear();
        foreach (var filter in PanelFilters.All)
        {
            var title = filter == PanelFilter.ThisApp && Model.TargetApp is { } app ? app.Name : filter.Title();
            var f = filter;
            AddChip(title, Glyphs.For(filter), Model.GroupFilter is null && filter == Model.Filter, () => Model.SetFilter(f));
        }
        // Sync groups come after the built-in filters (Tab cycles through them too).
        foreach (var (id, name) in Model.GroupNames.OrderBy(g => g.Value, StringComparer.CurrentCultureIgnoreCase))
            AddChip(name, Glyphs.Group, Model.GroupFilter == id, () => Model.SetGroupFilter(id));
    }

    private void AddChip(string title, string glyph, bool selected, Action choose)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Glyphs.Icon(glyph, 13, selected ? Fluent.AccentText : Fluent.Secondary);
        icon.Margin = new Thickness(0, 0, 6, 0);
        content.Children.Add(icon);
        content.Children.Add(Fluent.Label(title, 13, selected ? Fluent.AccentText : null));
        var chip = new Border
        {
            Child = content,
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(10, 4, 10, 4),
            Margin = new Thickness(0, 0, 6, 0),
            Background = selected ? Fluent.Accent : Fluent.Subtle,
            Cursor = Cursors.Hand,
        };
        AutomationName(chip, $"{title} filter");
        chip.MouseLeftButtonUp += (_, _) => choose();
        _chips.Children.Add(chip);
    }

    private void RenderRows()
    {
        var ids = Model.Entries.Select(e => e.Id).ToList();
        var multi = Model.IsMultiSelecting;
        if (!ids.SequenceEqual(_renderedIds) || _rowViews.Count != ids.Count)
        {
            _rows.Children.Clear();
            _rowViews.Clear();
            if (Model.Entries.Count == 0)
            {
                var empty = new StackPanel { Margin = new Thickness(20, 60, 20, 0), HorizontalAlignment = HorizontalAlignment.Center };
                empty.Children.Add(Fluent.Label(Model.Query.Length == 0 ? "Nothing here yet" : "No matches", 16, null, FontWeights.SemiBold));
                empty.Children.Add(Fluent.Label(Model.Query.Length == 0 ? "Items appear as you copy them." : "Try fewer letters or another filter.", 13, Fluent.Secondary));
                _rows.Children.Add(empty);
            }
            for (var index = 0; index < Model.Entries.Count; index++)
            {
                var row = BuildRow(Model.Entries[index], index, multi);
                _rowViews[Model.Entries[index].Id] = row;
                _rows.Children.Add(row);
            }
            _renderedIds = ids;
            if (Model.OpenToken != _lastOpenToken)
            {
                _lastOpenToken = Model.OpenToken;
                _rowScroll.ScrollToTop();
            }
        }
        else
        {
            for (var index = 0; index < Model.Entries.Count; index++)
            {
                var entry = Model.Entries[index];
                StyleRow(_rowViews[entry.Id], entry, index, multi);
            }
        }
        if (Model.SelectedId is { } selected && _rowViews.TryGetValue(selected, out var view)) view.BringIntoView();
    }

    private int _lastOpenToken = -1;

    private Border BuildRow(PanelEntry entry, int index, bool multi)
    {
        var border = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 1, 0, 1), Cursor = Cursors.Arrow };
        border.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ClickCount >= 2)
            {
                if (Model.IsMultiSelecting && Model.IsSelected(entry)) Model.PasteSelection(); else Model.Activate(entry);
            }
            else
            {
                Model.Click(entry, Keyboard.Modifiers.HasFlag(ModifierKeys.Control), Keyboard.Modifiers.HasFlag(ModifierKeys.Shift));
            }
            e.Handled = true;
        };
        border.ContextMenu = new ContextMenu();
        border.ContextMenuOpening += (_, _) => FillContextMenu(border.ContextMenu, entry);
        StyleRow(border, entry, index, multi);
        return border;
    }

    private void StyleRow(Border border, PanelEntry entry, int index, bool multi)
    {
        var selected = Model.IsSelected(entry);
        var fg = selected ? Fluent.AccentText : null;
        var sub = selected ? Fluent.AccentText : Fluent.Secondary;
        border.Background = selected ? Fluent.Accent : Brushes.Transparent;

        var grid = new Grid();
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (multi)
        {
            var check = Glyphs.Icon(selected ? "" : "", 15, fg ?? Fluent.Tertiary);
            check.Margin = new Thickness(0, 0, 8, 0);
            grid.Children.Add(check);
        }
        var leading = LeadingVisual(entry, selected);
        leading.Margin = new Thickness(0, 0, 10, 0);
        Grid.SetColumn(leading, 1);
        grid.Children.Add(leading);

        var (title, subtitle) = Describe(entry);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Fluent.Label(title, 14, fg));
        texts.Children.Add(Fluent.Label(subtitle, 12, sub));
        Grid.SetColumn(texts, 2);
        grid.Children.Add(texts);

        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var groupName = Model.GroupName(entry);
        var author = Model.GroupBadge(entry);
        if (author is not null)
        {
            var badgeContent = new StackPanel { Orientation = Orientation.Horizontal };
            var groupIcon = Glyphs.Icon(Glyphs.Group, 10, sub);
            groupIcon.Margin = new Thickness(0, 0, 4, 0);
            badgeContent.Children.Add(groupIcon);
            badgeContent.Children.Add(Fluent.Label(author.Length > 18 ? author[..17] + "…" : author, 11, sub));
            trailing.Children.Add(new Border
            {
                Child = badgeContent, Padding = new Thickness(6, 1, 6, 1), CornerRadius = new CornerRadius(8), Margin = new Thickness(6, 0, 0, 0),
                Background = selected ? Brushes.Transparent : Fluent.Subtle,
                ToolTip = author == groupName ? $"Shared in “{groupName}”" : $"Copied by {author} in “{groupName}”",
            });
        }
        if (entry.ClipItem is { IsPinned: true })
        {
            var pin = Glyphs.Icon(Glyphs.Pinned, 12, sub);
            pin.Margin = new Thickness(6, 0, 6, 0);
            trailing.Children.Add(pin);
        }
        if (Model.ShortcutNumber(entry, index) is { } shortcut)
        {
            var badge = new Border
            {
                Child = Fluent.Label($"Ctrl+{shortcut.Number}", 11, selected ? Fluent.AccentText : (shortcut.IsSlot ? Fluent.Accent : Fluent.Tertiary),
                    shortcut.IsSlot ? FontWeights.SemiBold : FontWeights.Normal),
                Padding = new Thickness(shortcut.IsSlot ? 5 : 0, 1, shortcut.IsSlot ? 5 : 0, 1),
                CornerRadius = new CornerRadius(4),
                BorderThickness = new Thickness(shortcut.IsSlot ? 1 : 0),
                BorderBrush = selected ? Fluent.AccentText : Fluent.Accent,
            };
            trailing.Children.Add(badge);
        }
        Grid.SetColumn(trailing, 3);
        grid.Children.Add(trailing);
        border.Child = grid;
        var shared = author is null ? "" : author == groupName ? $", in {groupName}" : $", copied by {author} in {groupName}";
        AutomationName(border, $"{title}, {subtitle}" + shared + (selected ? ", selected" : ""));
    }

    private FrameworkElement LeadingVisual(PanelEntry entry, bool selected)
    {
        switch (entry)
        {
            case PanelEntry.Clip { Item.Kind: ClipKind.Image } c when Icons.Thumbnail(_services.Store.Blobs, c.Item.ThumbnailFile) is { } thumb:
                return new Border
                {
                    Width = 28, Height = 28, CornerRadius = new CornerRadius(4), ClipToBounds = true,
                    Child = new Image { Source = thumb, Stretch = Stretch.UniformToFill },
                };
            case PanelEntry.Clip c when Icons.ForApp(c.Item.SourceId) is { } icon && c.Item.Kind != ClipKind.File:
                return new Image { Source = icon, Width = 24, Height = 24 };
            case PanelEntry.Clip c:
                return Box(Glyphs.Icon(c.Item.Kind switch { ClipKind.File => Glyphs.File, ClipKind.Image => Glyphs.Image, _ => Glyphs.Text }, 18, selected ? Fluent.AccentText : Fluent.Secondary));
            case PanelEntry.SnippetEntry:
                return Box(Glyphs.Icon(Glyphs.Snippet, 18, selected ? Fluent.AccentText : Fluent.Accent));
            default:
                return Box(Glyphs.Icon(Glyphs.Key, 18, selected ? Fluent.AccentText : Fluent.Accent));
        }
        static FrameworkElement Box(TextBlock icon) => new Border { Width = 28, Height = 28, Child = icon, HorizontalAlignment = HorizontalAlignment.Center };
    }

    private static (string Title, string Subtitle) Describe(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c when c.Item.Label is not null => (c.Item.Label, c.Item.Preview.Length == 0 ? c.Item.Kind.DisplayName() : c.Item.Preview),
        PanelEntry.Clip c => (c.Item.DisplayTitle, string.Join(" · ", new[] { c.Item.SourceName, Fluent.Relative(c.Item.LastCopiedAt) }.Where(s => !string.IsNullOrEmpty(s)))),
        PanelEntry.SnippetEntry s => (s.Snippet.Name.Length == 0 ? "Untitled Snippet" : s.Snippet.Name, s.Snippet.Keyword.Length == 0 ? "Snippet" : $"Snippet · {s.Snippet.Keyword}"),
        PanelEntry.SecretEntry k => (k.Secret.Name, "••••••••"),
        _ => ("", ""),
    };

    private void FillContextMenu(ContextMenu menu, PanelEntry entry)
    {
        menu.Items.Clear();
        MenuItem Item(string header, Action action) { var i = new MenuItem { Header = header }; i.Click += (_, _) => action(); return i; }
        menu.Items.Add(Item("Paste", () => Model.Activate(entry)));
        if (entry is PanelEntry.SecretEntry k)
        {
            menu.Items.Add(Item("Edit…", () => EditSecret(k.Secret)));
            menu.Items.Add(Item("Rename…", () => Model.BeginLabel(entry)));
        }
        var slots = new MenuItem { Header = "Assign to Quick Slot" };
        for (var n = QuickSlots.First; n <= QuickSlots.Last; n++)
        {
            var slot = n;
            slots.Items.Add(Item($"Ctrl+{slot}", () => { Model.Select(entry.Id); Model.AssignSelection(slot); }));
        }
        menu.Items.Add(slots);
        if (ShareMenu(entry) is { } share) menu.Items.Add(share);
        if (entry.ClipItem is { } item)
        {
            menu.Items.Add(Item("Paste as Plain Text", () => Model.Activate(entry, Transform.PlainText)));
            menu.Items.Add(Item("Copy", () => _services.Copy(item)));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item(item.IsPinned ? "Unpin" : "Pin", () => { _services.Store.TogglePin(item); Model.Refresh(); }));
            menu.Items.Add(Item(item.Label is null ? "Label…" : "Edit Label…", () => Model.BeginLabel(entry)));
            if (item.Kind.IsTextual()) menu.Items.Add(Item("Save as Secret…", () => Model.BeginSaveSecret(item)));
            menu.Items.Add(Item("Delete", () => { _services.Store.Delete(item); Model.Refresh(); }));
        }
    }

    private MenuItem? ShareMenu(PanelEntry entry)
    {
        var own = entry switch
        {
            PanelEntry.Clip c => c.Item.SpaceId,
            PanelEntry.SnippetEntry s => s.Snippet.SpaceId,
            PanelEntry.SecretEntry k => k.Secret.SpaceId,
            _ => null,
        };
        var groups = Model.GroupNames.Where(g => g.Key != own).OrderBy(g => g.Value, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (groups.Count == 0) return null;
        var menu = new MenuItem { Header = "Share to Group" };
        foreach (var (id, name) in groups)
        {
            var item = new MenuItem { Header = name };
            item.Click += (_, _) =>
            {
                Model.Select(entry.Id);
                Model.Perform(new PanelAction.ShareTo(id, name));
            };
            menu.Items.Add(item);
        }
        return menu;
    }

    // MARK: Detail pane

    private void RenderDetail()
    {
        var key = Model.Mode switch
        {
            PanelMode.Browse => Model.IsMultiSelecting ? "multi:" + string.Join(",", Model.SelectedIds.Order()) : Model.SelectedId,
            PanelMode.AI => Model.AIRun?.GetHashCode().ToString(),
            _ => Model.SelectedId,
        };
        var state = (Model.Mode, key);
        if (state != _detailState)
        {
            _detailState = state;
            _actionFilter = null;
            _aiOutput = null;
            _detail.Child = Model.Mode switch
            {
                PanelMode.Actions => BuildActions(),
                PanelMode.SnippetForm => BuildSnippetForm(),
                PanelMode.SaveSecret => BuildSaveSecret(),
                PanelMode.Label => BuildLabel(),
                PanelMode.EditSecret => BuildEditSecret(),
                PanelMode.AI => BuildAI(),
                _ => Model.IsMultiSelecting ? BuildMulti() : (Model.SelectedEntry is { } e ? BuildPreview(e) : new Border()),
            };
        }
        if (Model.Mode == PanelMode.Actions) FillActionList();
        if (Model.Mode == PanelMode.AI) UpdateAI();
    }

    private static Border Padded(UIElement child, double padding = 14) => new() { Padding = new Thickness(padding), Child = child };

    private UIElement BuildPreview(PanelEntry entry)
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        UIElement body = entry switch
        {
            PanelEntry.Clip { Item.Kind: ClipKind.Image } c => new Image
            {
                Source = c.Item.ImageFile is { } f ? ImageTools.Load(_services.Store.Blobs.PathFor(f), 900) : null,
                Stretch = Stretch.Uniform, Margin = new Thickness(14),
            },
            PanelEntry.Clip { Item.Kind: ClipKind.File } c => Padded(FileList(c.Item.Files)),
            PanelEntry.Clip c => TextView(c.Item.Text),
            PanelEntry.SnippetEntry s => TextView(s.Snippet.Body),
            PanelEntry.SecretEntry k => SecretView(k.Secret),
            _ => new Border(),
        };
        grid.Children.Add(body);
        var line = new Border { Background = Fluent.Separator };
        Grid.SetRow(line, 1);
        grid.Children.Add(line);
        var meta = Padded(Metadata(entry), 12);
        Grid.SetRow(meta, 2);
        grid.Children.Add(meta);
        return grid;
    }

    private static UIElement TextView(string text) => new TextBox
    {
        Text = text.Length > 20_000 ? text[..20_000] + "\n…" : text,
        IsReadOnly = true,
        TextWrapping = TextWrapping.Wrap,
        BorderThickness = new Thickness(0),
        Background = Brushes.Transparent,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Padding = new Thickness(10),
        FontSize = 14,
    };

    private static UIElement FileList(IEnumerable<string> files)
    {
        var stack = new StackPanel();
        foreach (var path in files)
        {
            var row = new StackPanel { Margin = new Thickness(0, 0, 0, 10) };
            row.Children.Add(Fluent.Label(System.IO.Path.GetFileName(path), 14));
            row.Children.Add(Fluent.Label(System.IO.Path.GetDirectoryName(path) ?? "", 12, Fluent.Secondary));
            stack.Children.Add(row);
        }
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private UIElement SecretView(SecretRef secret)
    {
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
        var icon = Glyphs.Icon(_services.Secrets.IsUnlocked ? Glyphs.Unlock : Glyphs.Lock, 32, Fluent.Accent);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var name = Fluent.Label(secret.Name, 17, null, FontWeights.SemiBold);
        name.HorizontalAlignment = HorizontalAlignment.Center;
        name.Margin = new Thickness(0, 10, 0, 6);
        stack.Children.Add(name);
        var value = new TextBox { Text = "••••••••••", IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            FontFamily = new FontFamily("Consolas"), FontSize = 16, HorizontalContentAlignment = HorizontalAlignment.Center };
        stack.Children.Add(value);
        var show = new Button { Content = "Show", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
        show.Click += async (_, _) =>
        {
            if (value.Text.StartsWith('•'))
            {
                if (await _services.Secrets.RevealAsync(secret, $"show “{secret.Name}”") is { } v) { value.Text = v; show.Content = "Hide"; }
            }
            else { value.Text = "••••••••••"; show.Content = "Show"; }
        };
        var edit = new Button { Content = "Edit", Margin = new Thickness(8, 0, 0, 0) };
        edit.Click += (_, _) => EditSecret(secret);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 6, 0, 0) };
        show.Margin = new Thickness(0);
        buttons.Children.Add(show);
        buttons.Children.Add(edit);
        stack.Children.Add(buttons);
        var clear = _services.Settings.SecretClearSeconds > 0 ? $" The clipboard clears after {_services.Settings.SecretClearSeconds} seconds." : "";
        var hint = Fluent.Label((_services.Secrets.IsUnlocked ? "Unlocked — press Enter to paste." : "Press Enter to paste. You'll confirm with Windows Hello.") + clear,
            13, Fluent.Secondary, wrap: true);
        hint.TextAlignment = TextAlignment.Center;
        hint.MaxWidth = 340;
        hint.Margin = new Thickness(0, 10, 0, 8);
        stack.Children.Add(hint);
        stack.Children.Add(UnlockControl());
        return stack;
    }

    private FrameworkElement UnlockControl()
    {
        if (_services.Secrets.IsManuallyUnlocked && _services.Secrets.UnlockedUntil is { } until)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center };
            row.Children.Add(Fluent.Label($"Unlocked until {until:g}", 12, Fluent.Secondary));
            var lockNow = new Button { Content = "Lock Now", Margin = new Thickness(8, 0, 0, 0) };
            lockNow.Click += (_, _) => { _services.Secrets.Lock(); _detailState = default; QueueRender(); };
            row.Children.Add(lockNow);
            return row;
        }
        var combo = new ComboBox { HorizontalAlignment = HorizontalAlignment.Center, MinWidth = 200 };
        combo.Items.Add("Leave unlocked for…");
        (string Label, TimeSpan Duration)[] options = [("15 minutes", TimeSpan.FromMinutes(15)), ("1 hour", TimeSpan.FromHours(1)),
            ("8 hours", TimeSpan.FromHours(8)), ("1 day", TimeSpan.FromDays(1)), ("1 week", TimeSpan.FromDays(7))];
        foreach (var o in options) combo.Items.Add(o.Label);
        combo.SelectedIndex = 0;
        combo.SelectionChanged += async (_, _) =>
        {
            if (combo.SelectedIndex <= 0) return;
            var option = options[combo.SelectedIndex - 1];
            await _services.Secrets.UnlockForAsync(option.Duration, option.Label);
            _detailState = default;
            QueueRender();
        };
        return combo;
    }

    private UIElement Metadata(PanelEntry entry)
    {
        var stack = new StackPanel();
        void Line(string label, string value)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 1) };
            var l = Fluent.Label(label, 12, Fluent.Secondary);
            l.Width = 90;
            row.Children.Add(l);
            row.Children.Add(Fluent.Label(value, 12));
            stack.Children.Add(row);
        }
        switch (entry)
        {
            case PanelEntry.Clip c:
                var item = c.Item;
                if (item.Label is not null) Line("Label", item.Label);
                if (item.SourceName is not null) Line("From", item.SourceName);
                Line("Copied", item.LastCopiedAt.ToLocalTime().ToString("g"));
                if (item.CopyCount > 1) Line("Times copied", item.CopyCount.ToString());
                Line("Type", item.Kind switch
                {
                    ClipKind.Image => $"Image · {item.ImageWidth}×{item.ImageHeight}",
                    ClipKind.File => item.Files.Count == 1 ? "File" : $"{item.Files.Count} files",
                    _ => $"{item.Kind.DisplayName()} · {item.Text.Length} characters",
                });
                Line("Expires", item.IsPinned ? "Never (pinned)"
                    : item.ExpiryDate(_services.Settings.MaxAge) is { } expiry ? expiry.ToLocalTime().ToString("g") : "Never");
                break;
            case PanelEntry.SnippetEntry s:
                Line("Snippet", s.Snippet.Name);
                if (s.Snippet.Keyword.Length > 0) Line("Keyword", s.Snippet.Keyword);
                break;
            case PanelEntry.SecretEntry k:
                Line("Stored in", "Credential Manager");
                if (k.Secret.CreatedAt is { } created) Line("Added", created.ToLocalTime().ToString("g"));
                break;
        }
        return stack;
    }

    private UIElement BuildMulti()
    {
        var clips = Model.SelectedClips;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label($"{clips.Count} items selected", 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label(clips.All(c => c.Kind.IsTextual())
            ? "Enter pastes them as one text, one item per line, in list order."
            : "Enter pastes them together where the app supports it.", 13, Fluent.Secondary, wrap: true));
        var list = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
        foreach (var c in clips) list.Children.Add(Fluent.Label("• " + c.DisplayTitle, 13));
        stack.Children.Add(list);
        return Padded(new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }

    private UIElement BuildActions()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        var header = new DockPanel { Margin = new Thickness(14, 8, 14, 8) };
        var picker = ModelPicker(rerun: false);
        DockPanel.SetDock(picker, Dock.Right);
        header.Children.Add(picker);
        _actionFilter = new TextBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent, FontSize = 14, Text = Model.ActionQuery };
        _actionFilter.TextChanged += (_, _) => Model.SetActionQuery(_actionFilter.Text);
        AutomationName(_actionFilter, "Filter actions or ask AI");
        var placeholder = new Grid();
        var hint = _actionHint = Fluent.Label($"Filter actions or ask {Model.AIName}", 14, Fluent.Tertiary);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(4, 0, 0, 0);
        _actionFilter.TextChanged += (_, _) => hint.Visibility = _actionFilter.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        placeholder.Children.Add(_actionFilter);
        placeholder.Children.Add(hint);
        header.Children.Add(placeholder);
        grid.Children.Add(header);

        var line = new Border { Background = Fluent.Separator };
        Grid.SetRow(line, 1);
        grid.Children.Add(line);

        _actionList = new StackPanel { Margin = new Thickness(8) };
        var scroll = new ScrollViewer { Content = _actionList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 2);
        grid.Children.Add(scroll);
        return grid;
    }

    private void FillActionList()
    {
        if (_actionList is null) return;
        _actionList.Children.Clear();
        if (_actionFilter is not null && _actionFilter.Text != Model.ActionQuery) _actionFilter.Text = Model.ActionQuery;
        if (_actionHint is not null) _actionHint.Text = Model.IsPickingGroup ? "Choose a group to share with" : $"Filter actions or ask {Model.AIName}";
        var actions = Model.FilteredActions;
        var pinned = Model.SelectedEntry?.ClipItem?.IsPinned ?? false;
        string? section = null;
        Border? selectedRow = null;
        for (var i = 0; i < actions.Count; i++)
        {
            var action = actions[i];
            var actionSection = action.Section(Model.AIName);
            if (actionSection != section)
            {
                section = actionSection;
                var header = Fluent.Label(section, 12, Fluent.Secondary, FontWeights.SemiBold);
                header.Margin = new Thickness(8, i == 0 ? 2 : 10, 0, 2);
                _actionList.Children.Add(header);
            }
            var selected = i == Model.ActionSelection;
            var row = new Border
            {
                CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 5, 8, 5),
                Background = selected ? Fluent.Accent : Brushes.Transparent,
                Child = Fluent.Label(action.Title(pinned), 14, selected ? Fluent.AccentText : null),
            };
            var a = action;
            row.MouseLeftButtonUp += (_, _) => Model.Perform(a);
            _actionList.Children.Add(row);
            if (selected) selectedRow = row;
        }
        if (actions.Count == 0) _actionList.Children.Add(Fluent.Label("No matching actions", 13, Fluent.Secondary));
        selectedRow?.BringIntoView();
    }

    private ComboBox ModelPicker(bool rerun)
    {
        var settings = _services.Settings;
        var provider = settings.AIProvider;
        var combo = new ComboBox { MinWidth = 150, FontSize = 12, ToolTip = provider.Title() + " model" };
        void Fill(IEnumerable<string> models)
        {
            combo.Items.Clear();
            var list = models.ToList();
            if (settings.AIModel.Length > 0 && !list.Contains(settings.AIModel)) list.Insert(0, settings.AIModel);
            foreach (var m in list) combo.Items.Add(m);
            combo.SelectedItem = settings.AIModel;
        }
        Fill(ModelCache.TryGetValue(provider, out var cached) ? cached : [settings.AIModel]);
        if (!ModelCache.ContainsKey(provider))
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    var models = await _services.Models.FetchAsync(provider, settings.CustomBaseUrl);
                    ModelCache[provider] = models;
                    Dispatcher.Invoke(() => Fill(models));
                }
                catch { /* offline or no key: keep the current model only */ }
            });
        }
        combo.SelectionChanged += (_, _) =>
        {
            if (combo.SelectedItem is not string model || model == settings.AIModel) return;
            settings.AIModel = model;
            settings.Save();
            if (rerun) Model.RerunAI();
        };
        return combo;
    }

    public static readonly Dictionary<AIProviderKind, List<string>> ModelCache = [];

    private UIElement BuildSnippetForm()
    {
        var form = Model.SnippetForm!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label(form.Snippet.Name, 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label("Fill in the fields, then press Enter to paste.", 13, Fluent.Secondary));
        TextBox? first = null;
        foreach (var field in form.Fields)
        {
            stack.Children.Add(new TextBlock { Text = field, Margin = new Thickness(0, 12, 0, 4) });
            var box = new TextBox();
            var f = field;
            box.TextChanged += (_, _) => form.Values[f] = box.Text;
            stack.Children.Add(box);
            first ??= box;
        }
        var paste = new Button { Content = "Paste", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        paste.Click += (_, _) => Model.SubmitSnippetForm();
        stack.Children.Add(paste);
        Dispatcher.BeginInvoke(() => first?.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        return Padded(stack, 16);
    }

    private UIElement BuildSaveSecret()
    {
        var form = Model.SaveSecretForm!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label("Save as Secret", 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label("Stores the value in Credential Manager and removes it from history. Pasting it asks for Windows Hello, and the clipboard is cleared again afterwards.",
            13, Fluent.Secondary, wrap: true));
        stack.Children.Add(new TextBlock { Text = "Name", Margin = new Thickness(0, 12, 0, 4) });
        var name = new TextBox { Text = form.Name };
        name.TextChanged += (_, _) => form.Name = name.Text;
        stack.Children.Add(name);
        var save = new Button { Content = "Save", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        save.Click += (_, _) => Model.SubmitSaveSecret();
        stack.Children.Add(save);
        Dispatcher.BeginInvoke(() => { name.Focus(); name.SelectAll(); }, System.Windows.Threading.DispatcherPriority.Input);
        return Padded(stack, 16);
    }

    private async void EditSecret(SecretRef secret)
    {
        if (await _services.Secrets.RevealAsync(secret, $"edit “{secret.Name}”") is { } value)
            Model.ShowEditSecret(secret, value);
    }

    private UIElement BuildEditSecret()
    {
        var form = Model.EditSecretForm!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label("Edit Secret", 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label("Changes are saved to Credential Manager.", 13, Fluent.Secondary, wrap: true));
        stack.Children.Add(new TextBlock { Text = "Name", Margin = new Thickness(0, 12, 0, 4) });
        var name = new TextBox { Text = form.Name };
        name.TextChanged += (_, _) => form.Name = name.Text;
        stack.Children.Add(name);
        stack.Children.Add(new TextBlock { Text = "Value", Margin = new Thickness(0, 12, 0, 4) });
        var value = new TextBox { Text = form.Value, FontFamily = new FontFamily("Consolas") };
        value.TextChanged += (_, _) => form.Value = value.Text;
        stack.Children.Add(value);
        var save = new Button { Content = "Save", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        save.Click += (_, _) => Model.SubmitEditSecret();
        stack.Children.Add(save);
        Dispatcher.BeginInvoke(() => { value.Focus(); value.SelectAll(); }, System.Windows.Threading.DispatcherPriority.Input);
        return Padded(stack, 16);
    }

    private UIElement BuildLabel()
    {
        var form = Model.LabelForm!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label(form.IsSecret ? "Rename Secret" : "Label", 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label(form.IsSecret ? "The name shown for this secret." :
            "Shown instead of the content and searchable. Labelled items are pinned, so they never expire. Leave empty to remove the label.",
            13, Fluent.Secondary, wrap: true));
        var box = new TextBox { Text = form.Text, Margin = new Thickness(0, 12, 0, 0) };
        box.TextChanged += (_, _) => form.Text = box.Text;
        stack.Children.Add(box);
        if (form.Entry.ClipItem is { } item)
            stack.Children.Add(Fluent.Label("Value: " + (item.Preview.Length == 0 ? item.Kind.DisplayName() : item.Preview), 12, Fluent.Secondary));
        var save = new Button { Content = "Save", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        save.Click += (_, _) => Model.SubmitLabel();
        stack.Children.Add(save);
        Dispatcher.BeginInvoke(() => { box.Focus(); box.SelectAll(); }, System.Windows.Threading.DispatcherPriority.Input);
        return Padded(stack, 16);
    }

    private UIElement BuildAI()
    {
        var run = Model.AIRun!;
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var header = new DockPanel { Margin = new Thickness(14, 10, 14, 6) };
        var picker = ModelPicker(rerun: true);
        DockPanel.SetDock(picker, Dock.Right);
        header.Children.Add(picker);
        var title = new StackPanel();
        title.Children.Add(Fluent.Label(run.Action.Title, 15, null, FontWeights.SemiBold));
        _aiStatus = Fluent.Label("", 12, Fluent.Secondary);
        title.Children.Add(_aiStatus);
        header.Children.Add(title);
        grid.Children.Add(header);

        _aiOutput = new TextBox
        {
            IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(12), FontSize = 14,
        };
        Grid.SetRow(_aiOutput, 1);
        grid.Children.Add(_aiOutput);

        _aiButtons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(12) };
        Grid.SetRow(_aiButtons, 2);
        grid.Children.Add(_aiButtons);
        return grid;
    }

    private void UpdateAI()
    {
        if (Model.AIRun is not { } run || _aiOutput is null || _aiStatus is null || _aiButtons is null) return;
        _aiOutput.Text = run.ErrorMessage ?? (run.Output.Length == 0 ? "Thinking…" : run.Output);
        _aiOutput.ScrollToEnd();
        _aiStatus.Text = run.IsStreaming ? $"{run.ProviderName} — responding…" : run.ProviderName;
        _aiButtons.Children.Clear();
        Button Make(string text, Action action, bool enabled, string tip)
        {
            var b = new Button { Content = text, IsEnabled = enabled, Margin = new Thickness(8, 0, 0, 0), ToolTip = tip };
            b.Click += (_, _) => action();
            return b;
        }
        if (run.Error?.NeedsSettings == true) _aiButtons.Children.Add(Make("Open Settings…", () => { _services.ClosePanel(); _services.OpenSettings("AI"); }, true, ""));
        if (!Model.IsSelectionMode) _aiButtons.Children.Add(Make("Replace Item", Model.ReplaceItemWithAIOutput, run.IsFinished, "Ctrl+R"));
        _aiButtons.Children.Add(Make("Copy", Model.CopyAIOutput, run.Output.Length > 0, "Ctrl+C"));
        _aiButtons.Children.Add(Make(Model.IsSelectionMode ? "Replace Selection" : "Paste", Model.PasteAIOutput, run.IsFinished, "Enter"));
    }

    private void RenderHints()
    {
        _notice.Text = Model.Notice ?? "";
        _hints.Text = Model.Mode switch
        {
            PanelMode.Browse when Model.IsMultiSelecting => $"Enter Paste {Model.SelectedClips.Count} items    Shift+Enter Plain Text    Ctrl+K Actions    Ctrl+P Pin    Del Delete    Esc Close",
            PanelMode.Browse => "Enter Paste    Shift+Enter Plain Text    Ctrl+K Actions    Ctrl+Shift+1–9 Assign Slot    Tab Filter    Esc Close",
            PanelMode.Actions when Model.IsPickingGroup => "↑↓ Choose Group    Enter Share    Esc Back",
            PanelMode.Actions => "↑↓ Choose    Enter Run    Esc Back",
            PanelMode.AI => "Enter Paste    Ctrl+C Copy    Ctrl+R Replace Item    Esc Back",
            _ => "Enter Save    Esc Back",
        };
    }
}
