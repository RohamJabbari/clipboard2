using System;
using System.Collections.Generic;
using System.IO;
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
using Clipboard2.Core.Sync;
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App.Views;

/// <summary>The Ctrl+Shift+V panel: search, filter chips, list, preview, Ctrl+K actions, AI.</summary>
public sealed partial class QuickPanelWindow : Window
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
    private readonly SyncStatusBadge _syncStatus;
    private readonly IncomingDownloadBanner _incoming = new();
    /// <summary>Above the list in Saved: the breadcrumb and New Folder.</summary>
    private readonly StackPanel _savedBar = new();
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

        // Not focusable: a click on the empty space below the rows leaves the keyboard in the search box. (Clicks
        // anywhere in the panel are inside its window, so they never deactivate it and close it.)
        _rowScroll = new ScrollViewer { Content = _rows, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(8, 6, 8, 6), Focusable = false };

        var content = new Grid();
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(44, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(56, GridUnitType.Star) });
        var list = new DockPanel();
        DockPanel.SetDock(_savedBar, Dock.Top);
        list.Children.Add(_savedBar);
        DockPanel.SetDock(_incoming, Dock.Top);
        list.Children.Add(_incoming);
        list.Children.Add(_rowScroll);
        content.Children.Add(list);
        var divider = new Border { Background = Fluent.Separator };
        Grid.SetColumn(divider, 1);
        content.Children.Add(divider);
        Grid.SetColumn(_detail, 2);
        content.Children.Add(_detail);

        var footer = new DockPanel { Margin = new Thickness(16, 7, 16, 8) };
        _syncStatus = new SyncStatusBadge(services.Sync);
        DockPanel.SetDock(_notice, Dock.Right);
        DockPanel.SetDock(_syncStatus, Dock.Right);
        footer.Children.Add(_notice);
        footer.Children.Add(_syncStatus);
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
        Deactivated += (_, _) => OwnWindowDeactivated();
        Model.Changed += QueueRender;
        _services.StoreChanged += () => Dispatcher.BeginInvoke(() => { if (IsVisible) Model.Refresh(); });
        _services.Sync.Changed += () => Dispatcher.BeginInvoke(() =>
        {
            _syncStatus.Update();
            if (IsVisible && Model.ShowsPeople) Model.Refresh();   // requests answered, contacts added
        });
        _services.Sync.DownloadsChanged += () => Dispatcher.BeginInvoke(() => { if (IsVisible) UpdateIncoming(); });
        _services.ImageText.Indexed += OnImageTextRead;
        SetUpDropTargets();
        StartCodeTimer();
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
        _snapChips = true;
        Render();
        Show();
        Activate();
        Native.ForceForeground(hwnd);
        FocusForMode();
    }

    public void HidePanel()
    {
        _preview?.HidePreview();
        if (IsVisible) Hide();
    }

    /// <summary>The panel or its preview lost focus. Focus moving between the two isn't leaving the panel; which
    /// window got it is only known once the activation is done, so this checks a moment later.</summary>
    public void OwnWindowDeactivated() => Dispatcher.BeginInvoke(() =>
    {
        if (IsVisible && !OwnWindowActive) CloseAfterDeactivation();
    }, System.Windows.Threading.DispatcherPriority.Input);

    private bool OwnWindowActive => IsActive || _preview?.IsActive == true;

    /// <summary>Closes when another window is activated, except while the mouse button is held: the user may be
    /// dragging files in from File Explorer. Then it waits for the release, and stays if something was dropped.</summary>
    private void CloseAfterDeactivation()
    {
        const int VK_LBUTTON = 0x01;
        if (_choosingFolder) return;   // "Save to…": the folder picker is in front, the panel stays
        if (_services.Secrets.IsAuthenticating)
        {
            // Windows Hello took focus for something asked from the panel: stay, and come back once it's answered.
            var hello = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
            hello.Tick += (_, _) =>
            {
                if (_services.Secrets.IsAuthenticating) return;
                hello.Stop();
                if (IsVisible) ReactivateAfterDrop();
            };
            hello.Start();
            return;
        }
        if (!Native.IsDown(VK_LBUTTON))
        {
            _services.ClosePanel();
            return;
        }
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        timer.Tick += (_, _) =>
        {
            if (Native.IsDown(VK_LBUTTON)) return;
            timer.Stop();
            if (IsVisible && !OwnWindowActive) _services.ClosePanel();
        };
        timer.Start();
    }

    private bool _choosingFolder;

    /// <summary>"Save to…": a folder picker owned by the panel, which stays open behind it. Null when cancelled.</summary>
    public string? ChooseFolder(string initial)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = "Save to", InitialDirectory = Directory.Exists(initial) ? initial : "" };
        _choosingFolder = true;
        try
        {
            var chosen = IsVisible ? dialog.ShowDialog(this) : dialog.ShowDialog();
            return chosen == true ? dialog.FolderName : null;
        }
        finally
        {
            _choosingFolder = false;
            if (IsVisible) ReactivateAfterDrop();
        }
    }

    /// <summary>Brings the panel back to the front after something was dropped on it from another app.</summary>
    private void ReactivateAfterDrop()
    {
        Activate();
        Native.ForceForeground(new WindowInteropHelper(this).Handle);
        FocusForMode();
    }

    private void OnImageTextRead(ClipItem item)
    {
        if (!IsVisible) return;
        var selected = Model.SelectedEntry?.ClipItem?.Id == item.Id;
        if (Model.Query.Length == 0 && !selected) return;
        Model.Refresh();
        if (selected) _detailState = default;   // show "Text in image"
        QueueRender();
    }

    // MARK: Drag and drop

    private const string EntryFormat = "Clipboard2.PanelEntry";
    private Point _dragStart;
    private PanelEntry? _dragEntry;

    private void BeginRowDrag(Border row, PanelEntry entry, MouseEventArgs e)
    {
        if (e.LeftButton != MouseButtonState.Pressed || _dragEntry != entry) return;
        if (entry is not (PanelEntry.Clip or PanelEntry.SecretEntry or PanelEntry.FolderEntry) || entry.ClipItem is { } selection && selection == Model.SelectionItem) return;
        if (entry is PanelEntry.FolderEntry f && !Model.CanChangeFolder(f.Folder)) return;
        var delta = e.GetPosition(this) - _dragStart;
        if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        _dragEntry = null;
        var data = new DataObject();
        data.SetData(EntryFormat, entry.Id);
        // A secret (or a folder) drags only within the panel (onto a folder or a group): a secret's value never goes on the drag.
        if (entry.ClipItem is not { } item)
        {
            DragDrop.DoDragDrop(row, data, DragDropEffects.Copy);
            return;
        }
        if (item.Kind.IsTextual()) data.SetText(item.Text);
        else if (DraggedFiles(Model.ItemForUse(item)) is { Count: > 0 } files) data.SetFileDropList(files);
        if (item.Kind == ClipKind.Image && item.ImageFile is { } image && File.Exists(_services.Store.Blobs.PathFor(image)))
            data.SetData("PNG", new MemoryStream(File.ReadAllBytes(_services.Store.Blobs.PathFor(image))));
        DragDrop.DoDragDrop(row, data, DragDropEffects.Copy);
    }

    /// <summary>What Explorer and other apps receive: a file clip's files that still exist; an image as a PNG
    /// file (apps that take images directly also get the "PNG" format).</summary>
    private System.Collections.Specialized.StringCollection DraggedFiles(ClipItem item)
    {
        var files = new System.Collections.Specialized.StringCollection();
        if (item.Kind == ClipKind.File)
            files.AddRange([.. item.Files.Where(f => File.Exists(f) || Directory.Exists(f))]);
        else if (item.Kind == ClipKind.Image && ClipboardIO.ImageAsFile(item, _services.Store.Blobs) is { } png)
            files.Add(png);
        return files;
    }

    /// <summary>Files dropped in from other apps; not a row of this panel dragged around (it carries its own files).</summary>
    private static List<string> DroppedFiles(IDataObject data) =>
        !data.GetDataPresent(EntryFormat) && data.GetDataPresent(DataFormats.FileDrop) && data.GetData(DataFormats.FileDrop) is string[] files ? [.. files] : [];

    private static string? DroppedText(IDataObject data) =>
        !data.GetDataPresent(EntryFormat) && data.GetDataPresent(DataFormats.UnicodeText) ? data.GetData(DataFormats.UnicodeText) as string : null;

    /// <summary>Files or text from other apps can be dropped on the list; they go into history.</summary>
    private void SetUpDropTargets()
    {
        _rowScroll.AllowDrop = true;
        _rowScroll.DragOver += (_, e) =>
        {
            e.Effects = DroppedFiles(e.Data).Count > 0 || DroppedText(e.Data) is not null ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        _rowScroll.Drop += (_, e) =>
        {
            e.Handled = true;
            var files = DroppedFiles(e.Data);
            var added = files.Count > 0 ? _services.AddDroppedFiles(files)
                : DroppedText(e.Data) is { } text ? _services.AddDroppedText(text) : null;
            if (added is null) return;
            ReactivateAfterDrop();
            Model.Refresh(resetSelection: true);
            Model.ShowNotice(files.Count > 1 ? $"Added {files.Count} files to history" : "Added to history");
        };
    }

    /// <summary>Dropping a panel item, files or text on a group chip shares it to that group.</summary>
    private void MakeGroupDropTarget(GroupChip chip)
    {
        var groupId = chip.GroupId;
        chip.AllowDrop = true;
        // A group whose owner turned this user's Send off takes no drops.
        bool Accepts(IDataObject data) => Model.CanSendTo(groupId)
            && (data.GetDataPresent(EntryFormat) || DroppedFiles(data).Count > 0 || DroppedText(data) is not null);
        chip.DragEnter += (_, e) =>
        {
            if (!Accepts(e.Data)) return;
            chip.BorderBrush = Fluent.Accent;
            chip.BorderThickness = new Thickness(2);
        };
        chip.DragLeave += (_, _) => chip.BorderThickness = new Thickness(0);
        chip.DragOver += (_, e) =>
        {
            e.Effects = Accepts(e.Data) ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        chip.Drop += (_, e) =>
        {
            e.Handled = true;
            chip.BorderThickness = new Thickness(0);
            var groupName = chip.GroupName;
            if (!Model.CanSendTo(groupId))
            {
                ReactivateAfterDrop();
                Model.ShowNotice($"You can't send to {groupName}");
                return;
            }
            if (e.Data.GetData(EntryFormat) is string id)
            {
                // Dragging one of several selected items shares the whole selection, to the group's root.
                if (!(Model.IsMultiSelecting && Model.SelectedIds.Contains(id))) Model.Select(id);
                Model.ShareSelection(groupId, groupName, null);
                return;
            }
            var files = DroppedFiles(e.Data);
            if (files.Count > 0 && SyncEngine.GroupShareProblem(files) is { } problem)
            {
                ReactivateAfterDrop();
                Model.ShowNotice(problem);
                return;
            }
            var added = files.Count > 0 ? _services.AddDroppedFiles(files, groupId)
                : DroppedText(e.Data) is { } text ? _services.AddDroppedText(text, groupId) : null;
            if (added is null) return;
            ReactivateAfterDrop();
            Model.Refresh();
            Model.ShowNotice($"Shared to “{groupName}”");
        };
    }

    /// <summary>A folder row (or, with null, the "Saved" breadcrumb inside a folder) takes rows of this panel dragged
    /// onto it: they move in (or out). Highlighted while it's the drop target.</summary>
    private void MakeFolderDropTarget(Border target, Guid? folderId)
    {
        target.AllowDrop = true;
        // A folder never goes into itself or below itself: such a target doesn't light up and refuses the drop.
        bool Valid(DragEventArgs e) => e.Data.GetData(EntryFormat) is string id && Model.CanDrop(id, folderId);
        target.DragEnter += (_, e) =>
        {
            if (!Valid(e)) return;
            target.BorderBrush = Fluent.Accent;
            target.BorderThickness = new Thickness(2);
        };
        target.DragLeave += (_, _) => target.BorderThickness = new Thickness(0);
        target.DragOver += (_, e) =>
        {
            // Copy: the only effect rows offer (Move would let Explorer move a file clip's real files).
            e.Effects = Valid(e) ? DragDropEffects.Copy : DragDropEffects.None;
            e.Handled = true;
        };
        target.Drop += (_, e) =>
        {
            e.Handled = true;
            target.BorderThickness = new Thickness(0);
            if (e.Data.GetData(EntryFormat) is string id && Model.CanDrop(id, folderId)) Model.DropOnFolder(id, folderId);
        };
    }

    // MARK: Saved bar

    private void RenderSavedBar()
    {
        _savedBar.Children.Clear();
        if (!Model.IsSavedView) return;

        var bar = new DockPanel { Margin = new Thickness(14, 6, 10, 2) };
        var newFolder = new Border { Padding = new Thickness(6, 2, 6, 2), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand, Background = Brushes.Transparent, ToolTip = "New Folder" };
        var newContent = new StackPanel { Orientation = Orientation.Horizontal };
        var newIcon = Glyphs.Icon(Glyphs.NewFolder, 13, Fluent.Accent);
        newIcon.Margin = new Thickness(0, 0, 5, 0);
        newContent.Children.Add(newIcon);
        newContent.Children.Add(Fluent.Label("New Folder", 12, Fluent.Accent));
        newFolder.Child = newContent;
        newFolder.MouseLeftButtonUp += (_, _) => Model.CreateFolder();
        AutomationName(newFolder, "New Folder");
        DockPanel.SetDock(newFolder, Dock.Right);
        // A group this user can't send to is only read: no New Folder (nor Add Items).
        if (Model.CanCreateFolder) bar.Children.Add(newFolder);
        if (Model.CanAddItems)
        {
            var addItems = new Border { Padding = new Thickness(6, 2, 6, 2), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand, Background = Brushes.Transparent, ToolTip = "Add from clipboard history" };
            var addContent = new StackPanel { Orientation = Orientation.Horizontal };
            var addIcon = Glyphs.Icon(PlusGlyph, 13, Fluent.Accent);
            addIcon.Margin = new Thickness(0, 0, 5, 0);
            addContent.Children.Add(addIcon);
            addContent.Children.Add(Fluent.Label("Add Items", 12, Fluent.Accent));
            addItems.Child = addContent;
            addItems.MouseLeftButtonUp += (_, _) => Model.BeginAddItems();
            AutomationName(addItems, "Add Items");
            DockPanel.SetDock(addItems, Dock.Right);
            bar.Children.Add(addItems);
        }
        if (Model.SavedSpace is null && Model.OpenFolderId is null && Model.Authenticators is not null)
        {
            // Authenticators are personal tools: only in the personal Saved, never in folders.
            var newOtp = new Border { Padding = new Thickness(6, 2, 6, 2), CornerRadius = new CornerRadius(6), Cursor = Cursors.Hand, Background = Brushes.Transparent, ToolTip = "New Authenticator…" };
            var otpContent = new StackPanel { Orientation = Orientation.Horizontal };
            var otpIcon = Glyphs.Icon(Glyphs.Lock, 13, Fluent.Accent);
            otpIcon.Margin = new Thickness(0, 0, 5, 0);
            otpContent.Children.Add(otpIcon);
            otpContent.Children.Add(Fluent.Label("New Authenticator…", 12, Fluent.Accent));
            newOtp.Child = otpContent;
            newOtp.MouseLeftButtonUp += (_, _) => Model.BeginAddAuthenticator();
            AutomationName(newOtp, "New Authenticator");
            DockPanel.SetDock(newOtp, Dock.Right);
            bar.Children.Add(newOtp);
        }

        var crumbs = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        var open = Model.OpenFolder;
        var root = new Border
        {
            Child = Fluent.Label("Saved", 13, open is null ? null : Fluent.Accent, FontWeights.SemiBold),
            Padding = new Thickness(4, 1, 4, 1), CornerRadius = new CornerRadius(4), Background = Brushes.Transparent,
        };
        crumbs.Children.Add(root);
        if (open is not null)
        {
            // The full path; every segment but the last goes there, and every segment takes drops.
            root.Cursor = Cursors.Hand;
            root.ToolTip = "Back to Saved. Drop items here to move them to the top level.";
            root.MouseLeftButtonUp += (_, _) => Model.GoToFolder(null);
            AutomationName(root, "Back to Saved");
            MakeFolderDropTarget(root, null);
            var path = Model.OpenFolderPath;
            foreach (var segment in path)
            {
                var chevron = Glyphs.Icon(Glyphs.ChevronRight, 10, Fluent.Secondary);
                chevron.Margin = new Thickness(4, 0, 4, 0);
                crumbs.Children.Add(chevron);
                var last = segment.Id == open.Id;
                var crumb = new Border
                {
                    Child = Fluent.Label(segment.Name, 13, last ? null : Fluent.Accent, FontWeights.SemiBold),
                    Padding = new Thickness(4, 1, 4, 1), CornerRadius = new CornerRadius(4), Background = Brushes.Transparent,
                };
                var id = segment.Id;
                if (!last)
                {
                    crumb.Cursor = Cursors.Hand;
                    crumb.ToolTip = $"Go to “{segment.Name}”. Drop items here to move them into it.";
                    crumb.MouseLeftButtonUp += (_, _) => Model.GoToFolder(id);
                    AutomationName(crumb, $"Go to {segment.Name}");
                }
                MakeFolderDropTarget(crumb, id);
                crumbs.Children.Add(crumb);
            }
            if (open.Label is { } label) crumbs.Children.Add(LabelPill(label, false));
        }
        bar.Children.Add(crumbs);
        _savedBar.Children.Add(bar);
    }

    /// <summary>A folder's label, as a small tag.</summary>
    private static Border LabelPill(string label, bool selected)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Glyphs.Icon(Glyphs.Tag, 10, selected ? Fluent.AccentText : Fluent.Secondary);
        icon.Margin = new Thickness(0, 0, 4, 0);
        content.Children.Add(icon);
        content.Children.Add(Fluent.Label(label.Length > 18 ? label[..17] + "…" : label, 11, selected ? Fluent.AccentText : Fluent.Secondary));
        return new Border
        {
            Child = content, Padding = new Thickness(6, 1, 6, 1), CornerRadius = new CornerRadius(8), Margin = new Thickness(6, 0, 0, 0),
            Background = selected ? Brushes.Transparent : Fluent.Subtle, VerticalAlignment = VerticalAlignment.Center,
        };
    }

    private void FocusForMode()
    {
        Dispatcher.BeginInvoke(() =>
        {
            switch (Model.Mode)
            {
                case PanelMode.Actions when _actionFilter is not null: _actionFilter.Focus(); break;
                case PanelMode.AddItems when _addItemsFilter is not null: _addItemsFilter.Focus(); break;
                case PanelMode.SendToContact when _contactPickerFilter is not null: _contactPickerFilter.Focus(); break;
                case PanelMode.Browse: _search.Focus(); _search.CaretIndex = _search.Text.Length; break;
            }
        }, System.Windows.Threading.DispatcherPriority.Input);
    }

    // MARK: Keyboard

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var input = ToKeyInput(e);
        // Tab moves between fields inside forms.
        if (input.Key == PanelKey.Tab && Model.Mode is PanelMode.SnippetForm) return;
        // Typing in People's Add Contact field: the field takes the keys (it handles Enter itself).
        if (_addContactField is { IsKeyboardFocused: true } && input.Key is not (PanelKey.Escape or PanelKey.Tab or PanelKey.Up or PanelKey.Down)) return;
        if (input.Key != PanelKey.Other && Model.HandleKey(input)) e.Handled = true;
    }

    /// <summary>A WPF key press as the model sees it (the preview window forwards some through this too).</summary>
    public static KeyInput ToKeyInput(KeyEventArgs e)
    {
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var mods = KeyMods.None;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods |= KeyMods.Ctrl;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= KeyMods.Shift;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= KeyMods.Alt;
        return key switch
        {
            Key.Escape => new(PanelKey.Escape, mods),
            Key.Up => new(PanelKey.Up, mods),
            Key.Down => new(PanelKey.Down, mods),
            Key.Left => new(PanelKey.Left, mods),
            Key.Right => new(PanelKey.Right, mods),
            Key.PageUp => new(PanelKey.PageUp, mods),
            Key.PageDown => new(PanelKey.PageDown, mods),
            Key.Enter => new(PanelKey.Enter, mods),
            Key.Tab => new(PanelKey.Tab, mods),
            Key.Delete => new(PanelKey.Delete, mods),
            Key.Back => new(PanelKey.Backspace, mods),
            Key.Space => new(PanelKey.Space, mods),
            >= Key.D1 and <= Key.D9 => new(PanelKey.Digit, mods, Digit: key - Key.D0),
            >= Key.NumPad1 and <= Key.NumPad9 => new(PanelKey.Digit, mods, Digit: key - Key.NumPad0),
            >= Key.A and <= Key.Z => new(PanelKey.Letter, mods, Letter: (char)('a' + (key - Key.A))),
            Key.OemComma => new(PanelKey.Letter, mods, Letter: ','),
            _ => new(PanelKey.Other, mods),
        };
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
        RenderSavedBar();
        UpdateIncoming();
        RenderRows();
        var previousMode = _detailState.Mode;
        RenderDetail();
        RenderHints();
        if (previousMode != Model.Mode) FocusForMode();
        SyncPreview();
    }

    // MARK: Large preview

    private PreviewWindow? _preview;

    /// <summary>Opens, updates or closes the preview window to match the model. Closing it hands focus back here.</summary>
    private void SyncPreview()
    {
        if (Model.IsPreviewing)
        {
            _preview ??= new PreviewWindow(_services, this);
            var opening = !_preview.IsVisible;
            _preview.Update();
            if (opening) _preview.ShowOver(this);
        }
        else if (_preview is { IsVisible: true })
        {
            _preview.HidePreview();
            ReactivateAfterDrop();
        }
    }

    private void RenderChips()
    {
        // All · Saved · ‹App› · Inbox, a divider, then the groups (Tab cycles through them in this order, a group's
        // Copies and Saved included). The row is rebuilt only when it changes; group chips are kept, so a selected
        // one can morph into its Copies | Saved pill.
        var groups = Model.GroupNames.OrderBy(g => g.Value, StringComparer.CurrentCultureIgnoreCase).ToList();
        string ChipTitle(PanelFilter filter) => filter == PanelFilter.ThisApp && Model.TargetApp is { } app ? app.Name : filter.Title();
        var key = string.Join("|", Model.ChipFilters.Select(ChipTitle)) + "#" + (Model.GroupFilter is null ? Model.Filter.ToString() : "")
            + "#" + string.Join("|", groups.Select(g => g.Key + "=" + g.Value));
        if (key != _chipRowKey)
        {
            _chipRowKey = key;
            _chips.Children.Clear();
            foreach (var filter in Model.ChipFilters)
            {
                var f = filter;
                if (filter == PanelFilter.Inbox)
                {
                    // Contacts: [Contacts | Inbox · People], morphing like a group's chip.
                    if (_contactsChip is null)
                    {
                        _contactsChip = new GroupChip("contacts", PanelFilter.Inbox.Title(), Glyphs.Contact, ("Inbox", "People"));
                        _contactsChip.Chosen += () => Model.SetFilter(PanelFilter.Inbox);
                        _contactsChip.SegmentChosen += people => Model.SetContactsShowPeople(people);
                    }
                    _chips.Children.Add(_contactsChip);
                    continue;
                }
                AddChip(ChipTitle(filter), Glyphs.For(filter), Model.GroupFilter is null && filter == Model.Filter, () => Model.SetFilter(f));
            }
            if (groups.Count > 0)
                _chips.Children.Add(new Border { Width = 1, Height = 16, Margin = new Thickness(2, 0, 8, 0), Background = Fluent.Separator, VerticalAlignment = VerticalAlignment.Center });
            foreach (var (id, name) in groups)
            {
                if (!_groupChips.TryGetValue(id, out var chip))
                {
                    chip = _groupChips[id] = new GroupChip(id, name);
                    var groupId = id;
                    chip.Chosen += () => Model.SetGroupFilter(groupId);   // on the open pill: back to its root, nothing new
                    chip.SegmentChosen += saved => Model.SetGroupShowsSaved(saved);
                    MakeGroupDropTarget(chip);
                    // Right-click: Mute Notifications, per group.
                    var muteMenu = new ContextMenu();
                    chip.ContextMenu = muteMenu;
                    chip.ContextMenuOpening += (_, _) =>
                    {
                        muteMenu.Items.Clear();
                        var mute = new MenuItem { Header = "Mute Notifications", IsCheckable = true, IsChecked = Model.IsGroupMuted(groupId) };
                        mute.Click += (_, _) => Model.SetGroupMuted(groupId, mute.IsChecked);
                        muteMenu.Items.Add(mute);
                    };
                }
                chip.SetName(name);
                _chips.Children.Add(chip);
            }
            foreach (var gone in _groupChips.Keys.Where(id => !Model.GroupNames.ContainsKey(id)).ToList()) _groupChips.Remove(gone);
        }
        foreach (var (id, _) in groups)
            _groupChips[id].Update(Model.GroupFilter == id, Model.GroupShowsSaved(id), animate: !_snapChips);
        _contactsChip?.Update(Model.GroupFilter is null && Model.Filter == PanelFilter.Inbox, _services.Settings.ContactsShowPeople, animate: !_snapChips);
        _snapChips = false;
    }

    private GroupChip? _contactsChip;
    private readonly Dictionary<string, GroupChip> _groupChips = [];
    private string? _chipRowKey;
    /// <summary>Set when the panel opens: the chips take their state without animating.</summary>
    private bool _snapChips = true;

    /// <summary>Group items still downloading, while that group (or All) is shown, and contacts' while the Inbox is.
    /// Updated in place: no list render.</summary>
    private void UpdateIncoming() => _incoming.Update([.. _services.Sync.Downloads.Where(d => Model.GroupFilter is { } group
        ? d.SpaceId == group
        : Model.Filter == PanelFilter.Inbox ? Model.ContactNames.ContainsKey(d.SpaceId)
        : Model.Filter == PanelFilter.All && Model.GroupNames.ContainsKey(d.SpaceId))]);

    private Border AddChip(string title, string glyph, bool selected, Action choose)
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
            Height = 26,
            Background = selected ? Fluent.Accent : Fluent.Subtle,
            Cursor = Cursors.Hand,
        };
        AutomationName(chip, $"{title} filter" + (selected ? ", selected" : ""));
        chip.MouseLeftButtonUp += (_, _) => choose();
        _chips.Children.Add(chip);
        return chip;
    }

    private void RenderRows()
    {
        if (Model.ShowsPeople)
        {
            RenderPeople();
            return;
        }
        _peopleKey = null;
        var ids = Model.Entries.Select(e => e.Id).ToList();
        var multi = Model.IsMultiSelecting;
        if (!ids.SequenceEqual(_renderedIds) || _rowViews.Count != ids.Count)
        {
            _rows.Children.Clear();
            _rowViews.Clear();
            if (Model.Entries.Count == 0)
            {
                var empty = new StackPanel { Margin = new Thickness(20, 60, 20, 0), HorizontalAlignment = HorizontalAlignment.Center };
                var inbox = Model.Filter == PanelFilter.Inbox && Model.GroupFilter is null;
                var (emptyTitle, emptyHint) = Model.Query.Length > 0 ? ("No matches", "Try fewer letters or another filter.")
                    : Model.OpenFolderId is not null ? ("This folder is empty", "Drag items here, or use Move to Folder in Ctrl+K.")
                    : Model.IsSavedView ? ("Nothing saved yet", "Label an item or use Add to Saved to keep it. Secrets and snippets are kept here too.")
                    : inbox ? ("Your Inbox is empty", "What your contacts send you appears here.")
                    : ("Nothing here yet", "Items appear as you copy them.");
                empty.Children.Add(Fluent.Label(emptyTitle, 16, null, FontWeights.SemiBold));
                empty.Children.Add(Fluent.Label(emptyHint, 13, Fluent.Secondary));
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
    private long _folderOpenedAt;
    /// <summary>Longer than Windows' default double-click time (500 ms).</summary>
    private const long FolderClickGuardMs = 700;

    private Border BuildRow(PanelEntry entry, int index, bool multi)
    {
        var border = new Border { CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 1, 0, 1), Cursor = Cursors.Arrow };
        border.MouseMove += (_, e) => BeginRowDrag(border, entry, e);
        border.MouseLeftButtonDown += (_, e) =>
        {
            _dragStart = e.GetPosition(this);
            _dragEntry = e.ClickCount >= 2 ? null : entry;
            if (e.ClickCount >= 2)
            {
                // A double-click on a folder: its first click opened it, and the second lands on whatever row is now
                // under the pointer. It mustn't paste that.
                if (entry is PanelEntry.FolderEntry || Environment.TickCount64 - _folderOpenedAt < FolderClickGuardMs) { }
                else if (Model.IsMultiSelecting && Model.IsSelected(entry)) Model.PasteSelection();
                else Model.Activate(entry);
            }
            else if (entry is PanelEntry.FolderEntry && Keyboard.Modifiers == ModifierKeys.None)
            {
                _folderOpenedAt = Environment.TickCount64;
                Model.Activate(entry);   // a click opens a folder
            }
            else
            {
                Model.Click(entry, Keyboard.Modifiers.HasFlag(ModifierKeys.Control), Keyboard.Modifiers.HasFlag(ModifierKeys.Shift));
            }
            e.Handled = true;
        };
        border.ContextMenu = new ContextMenu();
        // The row outlives renames and moves (it's kept while the ids stay the same): use the entry as it is now.
        border.ContextMenuOpening += (_, _) => FillContextMenu(border.ContextMenu, Model.Entries.FirstOrDefault(e => e.Id == entry.Id) ?? entry);
        if (entry is PanelEntry.FolderEntry folder) MakeFolderDropTarget(border, folder.Folder.Id);
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

        var (title, subtitle) = entry switch
        {
            PanelEntry.AuthenticatorEntry a => (a.Authenticator.Title, Model.AuthenticatorSubtitle(entry)),
            PanelEntry.SharedCodeEntry o => (o.Shared.Title, Model.AuthenticatorSubtitle(entry)),
            _ => Describe(entry),
        };
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Fluent.Label(title, 14, fg));
        texts.Children.Add(Fluent.Label(subtitle, 12, sub));
        Grid.SetColumn(texts, 2);
        grid.Children.Add(texts);

        var trailing = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (IsOtpEntry(entry)) trailing.Children.Add(CodeBadge(entry, selected, 17, detail: false));
        var groupName = Model.GroupName(entry);
        var author = entry is PanelEntry.FolderEntry ? null : Model.GroupBadge(entry);
        if (entry is PanelEntry.FolderEntry { Folder.Label: { } folderLabel }) trailing.Children.Add(LabelPill(folderLabel, selected));
        if (Model.FolderCaption(entry) is { } folderName)
        {
            // A clip shown outside its folder (a search, History) says where it lives.
            var captionContent = new StackPanel { Orientation = Orientation.Horizontal };
            var folderIcon = Glyphs.Icon(Glyphs.Folder, 10, sub);
            folderIcon.Margin = new Thickness(0, 0, 4, 0);
            captionContent.Children.Add(folderIcon);
            captionContent.Children.Add(Fluent.Label(folderName.Length > 18 ? folderName[..17] + "…" : folderName, 11, sub));
            trailing.Children.Add(new Border
            {
                Child = captionContent, Padding = new Thickness(6, 1, 6, 1), Margin = new Thickness(6, 0, 0, 0), ToolTip = $"In the folder “{folderName}”",
            });
        }
        if (Model.SenderName(entry) is { } sender)
        {
            var badgeContent = new StackPanel { Orientation = Orientation.Horizontal };
            var contactIcon = Glyphs.Icon(Glyphs.Contact, 10, sub);
            contactIcon.Margin = new Thickness(0, 0, 4, 0);
            badgeContent.Children.Add(contactIcon);
            badgeContent.Children.Add(Fluent.Label(sender.Length > 18 ? sender[..17] + "…" : sender, 11, sub));
            trailing.Children.Add(new Border
            {
                Child = badgeContent, Padding = new Thickness(6, 1, 6, 1), CornerRadius = new CornerRadius(8), Margin = new Thickness(6, 0, 0, 0),
                Background = selected ? Brushes.Transparent : Fluent.Subtle,
                ToolTip = $"Sent to you by {sender}",
            });
        }
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
        if (entry.ClipItem is { IsPinned: true } pinned)
        {
            var tag = Glyphs.Icon(pinned.Label is null ? Glyphs.Saved : Glyphs.Tag, 12, sub);
            tag.Margin = new Thickness(6, 0, 6, 0);
            tag.ToolTip = pinned.Label is null ? "Saved: kept until you remove it from Saved" : "Labelled: kept until you remove the label";
            trailing.Children.Add(tag);
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
            case PanelEntry.FolderEntry:
                return Box(Glyphs.Icon(Glyphs.Folder, 18, selected ? Fluent.AccentText : Fluent.Accent));
            case PanelEntry.SharedCodeEntry:
                return Box(Glyphs.Icon(Glyphs.Contact, 18, selected ? Fluent.AccentText : Fluent.Accent));
            case PanelEntry.AuthenticatorEntry or PanelEntry.OtpSuggestion:
                return Box(Glyphs.Icon(Glyphs.Clock, 18, selected ? Fluent.AccentText : Fluent.Accent));
            default:   // a secret: the lock, as it sits among clips in Saved
                return Box(Glyphs.Icon(Glyphs.Lock, 18, selected ? Fluent.AccentText : Fluent.Accent));
        }
        static FrameworkElement Box(TextBlock icon) => new Border { Width = 28, Height = 28, Child = icon, HorizontalAlignment = HorizontalAlignment.Center };
    }

    private static (string Title, string Subtitle) Describe(PanelEntry entry) => entry switch
    {
        PanelEntry.Clip c when c.Item.Label is not null => (c.Item.Label, c.Item.Preview.Length == 0 ? c.Item.Kind.DisplayName() : c.Item.Preview),
        PanelEntry.Clip c => (c.Item.DisplayTitle, string.Join(" · ", new[] { c.Item.SourceName, Fluent.Relative(c.Item.LastCopiedAt) }.Where(s => !string.IsNullOrEmpty(s)))),
        PanelEntry.SnippetEntry s => (s.Snippet.Name.Length == 0 ? "Untitled Snippet" : s.Snippet.Name, s.Snippet.Keyword.Length == 0 ? "Snippet" : $"Snippet · {s.Snippet.Keyword}"),
        PanelEntry.SecretEntry k => (k.Secret.Name, "••••••••"),
        PanelEntry.FolderEntry f => (f.Folder.Name, FolderCount(f.Folders, f.Count)),
        PanelEntry.OtpSuggestion o => ("Add to Authenticator", string.Join(" · ", new[] { o.Draft.Issuer, o.Draft.Account }.Where(s => s.Length > 0))),
        _ => ("", ""),
    };

    private static string ItemCount(int count) => count == 1 ? "1 item" : $"{count} items";

    /// <summary>"3 folders · 12 items", leaving out a zero part.</summary>
    private static string FolderCount(int folders, int items) =>
        folders == 0 ? ItemCount(items)
        : (folders == 1 ? "1 folder" : $"{folders} folders") + (items == 0 ? "" : " · " + ItemCount(items));

    private void FillContextMenu(ContextMenu menu, PanelEntry entry)
    {
        menu.Items.Clear();
        MenuItem Item(string header, Action action) { var i = new MenuItem { Header = header }; i.Click += (_, _) => action(); return i; }
        // Right-clicking one of several selected items acts on them all.
        void Focus() { if (!(Model.IsMultiSelecting && Model.IsSelected(entry))) Model.Select(entry.Id); }
        if (entry is PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry or PanelEntry.OtpSuggestion)
        {
            FillAuthenticatorMenu(menu, entry);
            return;
        }
        if (entry is PanelEntry.FolderEntry f)
        {
            menu.Items.Add(Item("Open", () => Model.Activate(entry)));
            // A group's folder can't change without Send.
            if (Model.CanSendTo(f.Folder.SpaceId))
            {
                menu.Items.Add(Item("Rename…", () => Model.BeginRenameFolder(f.Folder)));
                menu.Items.Add(Item(f.Folder.Label is null ? "Label…" : "Edit Label…", () => Model.BeginLabel(entry)));
                menu.Items.Add(Item("New Folder Inside…", () => Model.NewFolderInside(f.Folder)));
            }
            if (Model.FolderMenuSections([entry]).Count > 0) menu.Items.Add(MoveToFolderMenu(entry, Focus));
            if (Model.ParentFolder(f.Folder) is not null && Model.CanChangeFolder(f.Folder))
                menu.Items.Add(Item("Move to Top Level", () => Model.MoveFolder(f.Folder, null)));
            if (f.Folder.SpaceId is null && ShareMenu(entry, Focus) is { } shareFolder) menu.Items.Add(shareFolder);
            if (Model.ContactNames.Count > 0 && Model.CanSendToContact(entry))
                menu.Items.Add(Item("Send to Contact…", () => { Focus(); Model.BeginSendToContact(); }));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Delete Folder", () => Model.DeleteFolder(f.Folder)));
            return;
        }
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
        if (ShareMenu(entry, Focus) is { } share) menu.Items.Add(share);
        if (Model.ContactNames.Count > 0 && Model.CanSendToContact(entry))
            menu.Items.Add(Item("Send to Contact…", () => { Focus(); Model.BeginSendToContact(); }));
        if (entry.ClipItem is { } sendable && sendable != Model.SelectionItem && _services.OtherDevices is { Count: > 0 } devices)
        {
            var send = new MenuItem { Header = "Send to Device" };
            foreach (var device in devices)
                send.Items.Add(Item($"Send to {device.Name}", () => _ = _services.SendToDeviceAsync(sendable, device, fromPanel: true)));
            menu.Items.Add(send);
        }
        if (entry is PanelEntry.SecretEntry)
        {
            menu.Items.Add(new Separator());
            if (Model.CanUseFolders(entry)) menu.Items.Add(MoveToFolderMenu(entry, Focus));
            if (Model.FolderOf(entry) is not null) menu.Items.Add(Item("Move to Top Level", () => { Focus(); Model.Perform(new PanelAction.RemoveFromFolder()); }));
        }
        if (entry.ClipItem is { } item)
        {
            menu.Items.Add(Item("Paste as Plain Text", () => Model.Activate(entry, Transform.PlainText)));
            menu.Items.Add(Item("Copy", () => _services.Copy(Model.ItemForUse(item))));
            menu.Items.Add(new Separator());
            if (item != Model.SelectionItem)
            {
                var preview = Item("Preview", () =>
                {
                    Focus();   // right-clicking one of several selected items previews them all
                    Model.OpenPreview();
                });
                preview.InputGestureText = "Ctrl+Y";
                menu.Items.Add(preview);
            }
            menu.Items.Add(Item(item.Label is null ? "Label…" : "Edit Label…", () => Model.BeginLabel(entry)));
            List<ClipItem> Targets() => Model.IsMultiSelecting && Model.IsSelected(entry) ? Model.SelectedClips : [item];
            if (item != Model.SelectionItem)
            {
                // Another member's group item can't be saved in the group (the server refuses): a personal copy is.
                if (!item.IsPinned) menu.Items.Add(Item(Model.CanChange(item) ? "Add to Saved" : "Save a Copy", () => Model.AddToSaved(Targets())));
                if (item.IsPinned && item.Label is null) menu.Items.Add(Item("Remove from Saved", () => Model.RemoveFromSaved(Targets())));
                if (Model.CanUseFolders(item)) menu.Items.Add(MoveToFolderMenu(entry, Focus));
                if (Model.FolderOf(item) is not null) menu.Items.Add(Item("Move to Top Level", () => { Focus(); Model.Perform(new PanelAction.RemoveFromFolder()); }));
                menu.Items.Add(Item($"Save to {Model.SaveFolderName}", () => Model.Save(Targets(), _services.SaveFolder)));
                menu.Items.Add(Item("Save to…", () => { if (_services.ChooseSaveFolder() is { } folder) Model.Save(Targets(), folder); }));
            }
            if (item.Kind.IsTextual()) menu.Items.Add(Item("Save as Secret…", () => Model.BeginSaveSecret(item)));
            // A group item is deleted for everyone in the group.
            menu.Items.Add(Item(Model.IsGroupItem(item) ? "Remove from Group" : "Delete", () => { _services.Store.Delete(item); Model.Refresh(); }));
        }
    }

    /// <summary>Move to Folder ▸ the folders the item (or the selection it's in) can go into, then New Folder… (named
    /// inline in the panel). For group items, the group's folders and then the personal ones under "Mine", which take
    /// personal copies.</summary>
    private MenuItem MoveToFolderMenu(PanelEntry entry, Action focus)
    {
        // A tree: a folder with subfolders is a submenu whose first entry is the folder itself; New Folder… comes last
        // at each level. Moving a folder leaves out itself and everything below it.
        var menu = new MenuItem { Header = "Move to Folder" };
        var targets = Model.IsMultiSelecting && Model.IsSelected(entry) ? Model.FolderTargets : [entry];
        var moving = targets is [PanelEntry.FolderEntry f] ? f.Folder : null;
        var current = targets.Select(t => Model.FolderOf(t)?.Id).Distinct().ToList() is [{ } only] ? only : (Guid?)null;
        MenuItem Row(string header, string glyph, PanelAction action)
        {
            var row = new MenuItem { Header = header, Icon = Glyphs.Icon(glyph, 14) };
            row.Click += (_, _) =>
            {
                focus();
                Model.Perform(action);
            };
            return row;
        }
        void Level(ItemsControl into, Guid? parent, string? space, string? section, bool mine)
        {
            foreach (var folder in Model.FolderChildren(parent, space))
            {
                if (moving is not null && folder.Id == moving.Id) continue;
                var children = Model.FolderChildren(folder.Id, space).Where(c => moving is null || c.Id != moving.Id).ToList();
                var usable = moving is null ? folder.Id != current : Model.CanMoveFolder(moving, folder);
                var move = new PanelAction.MoveTo(folder.Id, folder.Name, section);
                if (children.Count == 0)
                {
                    var row = Row(folder.Name, Glyphs.Folder, move);
                    row.IsEnabled = usable;
                    into.Items.Add(row);
                    continue;
                }
                var sub = new MenuItem { Header = folder.Name, Icon = Glyphs.Icon(Glyphs.Folder, 14) };
                var self = Row(folder.Name, Glyphs.Folder, move);
                self.IsEnabled = usable;
                sub.Items.Add(self);
                sub.Items.Add(new Separator());
                Level(sub, folder.Id, space, section, mine);
                into.Items.Add(sub);
            }
            if (into.Items.Count > 0 && into.Items[^1] is not Separator) into.Items.Add(new Separator());
            into.Items.Add(Row("New Folder…", Glyphs.NewFolder, new PanelAction.MoveToNewFolder(mine, section, parent)));
        }
        foreach (var (title, space, mine) in Model.FolderMenuSections(targets))
        {
            if (title is not null)
            {
                if (menu.Items.Count > 0) menu.Items.Add(new Separator());
                menu.Items.Add(new MenuItem { Header = title, IsEnabled = false, FontWeight = FontWeights.SemiBold });
            }
            Level(menu, null, space, title, mine);
        }
        return menu;
    }

    /// <summary>Share to Group ▸ the groups; for a group with folders, a clip or secret can go into one of them.</summary>
    private MenuItem? ShareMenu(PanelEntry entry, Action focus)
    {
        var own = entry switch
        {
            PanelEntry.Clip c => c.Item.SpaceId,
            PanelEntry.SnippetEntry s => s.Snippet.SpaceId,
            PanelEntry.SecretEntry k => k.Secret.SpaceId,
            _ => null,
        };
        // Only groups this user can send to; a secret only to those whose secrets they get.
        var groups = Model.GroupNames.Where(g => g.Key != own && Model.CanSendTo(g.Key) && (entry is not PanelEntry.SecretEntry || Model.CanSeeSecretsIn(g.Key)))
            .OrderBy(g => g.Value, StringComparer.CurrentCultureIgnoreCase).ToList();
        if (groups.Count == 0) return null;
        var menu = new MenuItem { Header = "Share to Group" };
        foreach (var (id, name) in groups)
        {
            var item = new MenuItem { Header = name };
            var folders = entry is PanelEntry.Clip or PanelEntry.SecretEntry or PanelEntry.FolderEntry ? Model.FoldersIn(id) : [];
            if (folders.Count == 0)
            {
                item.Click += (_, _) => { focus(); Model.ShareSelection(id, name, null); };
            }
            else
            {
                var root = new MenuItem { Header = "No Folder" };
                root.Click += (_, _) => { focus(); Model.ShareSelection(id, name, null); };
                item.Items.Add(root);
                item.Items.Add(new Separator());
                foreach (var folder in folders)
                {
                    var into = new MenuItem { Header = Model.FolderPathText(folder.Id), Icon = Glyphs.Icon(Glyphs.Folder, 14) };
                    var folderId = folder.Id;
                    into.Click += (_, _) => { focus(); Model.ShareSelection(id, name, folderId); };
                    item.Items.Add(into);
                }
            }
            menu.Items.Add(item);
        }
        return menu;
    }

    // MARK: Detail pane

    private void RenderDetail()
    {
        var key = Model.Mode switch
        {
            PanelMode.Browse when Model.IsMultiSelecting => "multi:" + string.Join(",", Model.SelectedIds.Order()),
            // A folder's details change without the selection changing (renamed, labelled, items dropped in).
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.FolderEntry f => $"{f.Id}|{f.Folder.Name}|{f.Folder.Label}|{f.Count}",
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.AuthenticatorEntry a =>
                $"{a.Id}|{a.Authenticator.Title}|{a.Authenticator.Account}|{string.Join(",", a.Authenticator.People.Select(p => p.Name))}",
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.SharedCodeEntry o => $"{o.Id}|{o.Shared.ReceivedAt.Ticks}|{o.Shared.IsOut(Model.Clock())}",
            PanelMode.AuthenticatorPeople => "people:" + string.Join(",", Model.PeopleOf?.People.Select(p => p.Uid) ?? []),
            PanelMode.AuthenticatorForm => "form:" + Model.AuthenticatorForm?.GetHashCode() + "|" + Model.AuthenticatorForm?.Error,
            PanelMode.AddItems => "additems:" + Model.AddItemsForm?.GetHashCode(),
            PanelMode.SendToContact => "picker:" + Model.ContactPicker?.GetHashCode(),
            PanelMode.Browse when Model.ShowsPeople => "person:" + Model.SelectedPerson?.Id,
            PanelMode.Browse => Model.SelectedId,
            PanelMode.AI => Model.AIRun?.GetHashCode().ToString(),
            _ => Model.SelectedId,
        };
        var state = (Model.Mode, key);
        if (state != _detailState)
        {
            _detailState = state;
            _actionFilter = null;
            _addItemsFilter = null;
            _addItemsList = null;
            _contactPickerFilter = null;
            _contactPickerList = null;
            _aiOutput = null;
            _fileRows.Clear();
            foreach (var stale in _codeViews.Keys.Where(k => k.StartsWith("detail:", StringComparison.Ordinal)).ToList()) _codeViews.Remove(stale);
            _detail.Child = Model.Mode switch
            {
                PanelMode.AuthenticatorForm => BuildAuthenticatorForm(),
                PanelMode.AddItems => BuildAddItems(),
                PanelMode.SendToContact => BuildContactPicker(),
                PanelMode.AuthenticatorSecret => BuildAuthenticatorSecret(),
                PanelMode.AuthenticatorPeople => BuildAuthenticatorPeople(),
                PanelMode.ConfirmDelete => BuildConfirmDelete(),
                PanelMode.Actions => BuildActions(),
                PanelMode.SnippetForm => BuildSnippetForm(),
                PanelMode.SaveSecret => BuildSaveSecret(),
                PanelMode.Label => BuildLabel(),
                PanelMode.EditSecret => BuildEditSecret(),
                PanelMode.FolderName => BuildFolderName(),
                PanelMode.AI => BuildAI(),
                _ when Model.ShowsPeople => BuildPersonDetail(),
                _ => Model.IsMultiSelecting ? BuildMulti() : (Model.SelectedEntry is { } e ? BuildPreview(e) : new Border()),
            };
        }
        if (Model.Mode == PanelMode.Actions) FillActionList();
        if (Model.Mode == PanelMode.AddItems) FillAddItems();
        if (Model.Mode == PanelMode.SendToContact) FillContactPicker();
        if (Model.Mode == PanelMode.AI) UpdateAI();
        if (Model.Mode == PanelMode.Browse) UpdateFileRows();
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
            PanelEntry.Clip { Item.Kind: ClipKind.Image } c => ImagePreview(c.Item),
            PanelEntry.Clip { Item.Kind: ClipKind.File } c => Padded(FileList(c.Item)),
            PanelEntry.Clip c => TextView(c.Item.Text),
            PanelEntry.SnippetEntry s => TextView(s.Snippet.Body),
            PanelEntry.SecretEntry k => SecretView(k.Secret),
            PanelEntry.FolderEntry f => FolderView(f),
            PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry => AuthenticatorView(entry),
            PanelEntry.OtpSuggestion o => OtpSuggestionView(o),
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

    private UIElement FolderView(PanelEntry.FolderEntry entry)
    {
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
        var icon = Glyphs.Icon(Glyphs.Folder, 36, Fluent.Accent);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var name = Fluent.Label(entry.Folder.Name, 17, null, FontWeights.SemiBold);
        name.HorizontalAlignment = HorizontalAlignment.Center;
        name.Margin = new Thickness(0, 10, 0, 4);
        stack.Children.Add(name);
        var count = Fluent.Label(ItemCount(entry.Count), 13, Fluent.Secondary);
        count.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(count);
        var hint = Fluent.Label("Press Enter to open it. Drag items onto it to move them in.", 13, Fluent.Secondary, wrap: true);
        hint.TextAlignment = TextAlignment.Center;
        hint.MaxWidth = 320;
        hint.Margin = new Thickness(0, 12, 0, 0);
        stack.Children.Add(hint);
        return stack;
    }

    /// <summary>The picture, and below it the text read from it (when there is any).</summary>
    private UIElement ImagePreview(ClipItem item)
    {
        var image = new Image
        {
            Source = item.ImageFile is { } f ? ImageTools.Load(_services.Store.Blobs.PathFor(f), 900) : null,
            Stretch = Stretch.Uniform, Margin = new Thickness(14),
        };
        if (string.IsNullOrEmpty(item.OcrText)) return image;
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(image);
        var section = new StackPanel { Margin = new Thickness(14, 0, 14, 10) };
        var header = new DockPanel { Margin = new Thickness(0, 0, 0, 4) };
        var copy = new Button { Content = "Copy", FontSize = 12, Padding = new Thickness(8, 1, 8, 1), ToolTip = "Copy the text in the image" };
        AutomationName(copy, "Copy the text in the image");
        var text = item.OcrText;
        // Written with the internal marker (ClipboardIO.WriteText), so it isn't captured as a new item.
        copy.Click += (_, _) => { _services.CopyText(text); Model.ShowNotice("Copied text"); };
        DockPanel.SetDock(copy, Dock.Right);
        header.Children.Add(copy);
        header.Children.Add(Fluent.Label("Text in image", 12, Fluent.Secondary, FontWeights.SemiBold));
        section.Children.Add(header);
        section.Children.Add(new TextBox
        {
            Text = text, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0), Background = Fluent.Subtle,
            MaxHeight = 120, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(8), FontSize = 13,
        });
        Grid.SetRow(section, 1);
        grid.Children.Add(section);
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

    private readonly List<(string Path, Border Row, TextBlock Check, TextBlock Name, TextBlock Folder)> _fileRows = [];

    /// <summary>The files of a file item. With several, each row toggles: the picked ones are all that Enter, Paste,
    /// Copy and drag use.</summary>
    private UIElement FileList(ClipItem item)
    {
        var pickable = Model.PickableItem == item;
        var stack = new StackPanel();
        if (pickable)
        {
            var hint = Fluent.Label("Click files to use only those. Shift+click picks a range.", 12, Fluent.Secondary, wrap: true);
            hint.Margin = new Thickness(0, 0, 0, 8);
            stack.Children.Add(hint);
        }
        foreach (var path in item.Files)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            var check = Glyphs.Icon("\uE739", 15, Fluent.Tertiary);
            check.Margin = new Thickness(0, 0, 10, 0);
            check.Visibility = pickable ? Visibility.Visible : Visibility.Collapsed;
            grid.Children.Add(check);
            var texts = new StackPanel();
            var name = Fluent.Label(System.IO.Path.GetFileName(path), 14);
            var folder = Fluent.Label(System.IO.Path.GetDirectoryName(path) ?? "", 12, Fluent.Secondary);
            texts.Children.Add(name);
            texts.Children.Add(folder);
            Grid.SetColumn(texts, 1);
            grid.Children.Add(texts);
            var row = new Border { Child = grid, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 4, 8, 4), Margin = new Thickness(-8, 0, -8, 4), Background = Brushes.Transparent };
            if (pickable)
            {
                var p = path;
                row.Cursor = Cursors.Hand;
                row.MouseLeftButtonUp += (_, e) => { Model.ClickFile(p, Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)); e.Handled = true; };
                _fileRows.Add((path, row, check, name, folder));
            }
            stack.Children.Add(row);
        }
        UpdateFileRows();
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    private void UpdateFileRows()
    {
        foreach (var (path, row, check, name, folder) in _fileRows)
        {
            var picked = Model.IsFilePicked(path);
            row.Background = picked ? Fluent.Accent : Brushes.Transparent;
            check.Text = picked ? "\uE73A" : "\uE739";
            check.Foreground = picked ? Fluent.AccentText : Fluent.Tertiary;
            name.Foreground = picked ? Fluent.AccentText : (Brush)Application.Current.Resources[SystemColors.ControlTextBrushKey];
            folder.Foreground = picked ? Fluent.AccentText : Fluent.Secondary;
            AutomationName(row, System.IO.Path.GetFileName(path) + (picked ? ", picked" : ""));
        }
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
        LabelAndFolderRows(stack, entry);
        switch (entry)
        {
            case PanelEntry.Clip c:
                var item = c.Item;
                if (item.SourceName is not null) Line("From", item.SourceName);
                Line("Copied", item.LastCopiedAt.ToLocalTime().ToString("g"));
                if (item.CopyCount > 1) Line("Times copied", item.CopyCount.ToString());
                Line("Type", item.Kind switch
                {
                    ClipKind.Image => $"Image · {item.ImageWidth}×{item.ImageHeight}",
                    ClipKind.File => item.Files.Count == 1 ? "File" : $"{item.Files.Count} files",
                    _ => $"{item.Kind.DisplayName()} · {item.Text.Length} characters",
                });
                if (item.Label is not null && !Model.CanLabel(entry)) Line("Label", item.Label);
                if (Model.FolderOf(item) is not null && !Model.CanMoveSelection) Line("Folder", Model.FolderLocation(entry)!);
                Line("Expires", item.IsPinned ? "Never (saved)"
                    : item.ExpiryDate(_services.Settings.MaxAge) is { } expiry ? expiry.ToLocalTime().ToString("g") : "Never");
                break;
            case PanelEntry.FolderEntry f:
                if (f.Folder.Label is not null && !Model.CanLabel(f)) Line("Label", f.Folder.Label);
                if (Model.ParentFolder(f.Folder) is not null) Line("In", "Saved › " + Model.FolderPathText(Model.ParentFolder(f.Folder)!.Id));
                if (Model.GroupName(f) is { } group) Line("Group", group);
                Line("Created", f.Folder.CreatedAt.ToLocalTime().ToString("g"));
                break;
            case PanelEntry.SnippetEntry s:
                Line("Snippet", s.Snippet.Name);
                if (s.Snippet.Keyword.Length > 0) Line("Keyword", s.Snippet.Keyword);
                break;
            case PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry:
                AuthenticatorMetadata(entry, Line);
                break;
            case PanelEntry.SecretEntry k:
                Line("Stored in", "Credential Manager");
                if (k.Secret.CreatedAt is { } created) Line("Added", created.ToLocalTime().ToString("g"));
                if (Model.FolderOf(k.Secret) is not null && !Model.CanMoveSelection) Line("Folder", Model.FolderLocation(entry)!);
                if (Model.GroupName(k) is { } secretGroup) Line("Group", secretGroup);
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
        MultiFolderRow(stack);
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
        if (_actionHint is not null)
            _actionHint.Text = Model.OtpPicker is { } otpPicker
                ? (otpPicker.Kind == OtpPickerKind.Share ? "Share with… " : "Transfer to… ") + Model.OtpPickerNote
                : Model.IsPickingGroup ? "Choose a group to share with"
                : Model.PickingShareFolder is { } share ? $"Choose where in “{share.GroupName}” it goes"
                : Model.IsPickingFolder ? "Choose a folder to move to" : $"Filter actions or ask {Model.AIName}";
        var actions = Model.FilteredActions;
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
                Child = ActionRowContent(action, selected),
            };
            var a = action;
            row.MouseLeftButtonUp += (_, _) => Model.Perform(a);
            _actionList.Children.Add(row);
            if (selected) selectedRow = row;
        }
        if (actions.Count == 0) _actionList.Children.Add(Fluent.Label(
            Model.OtpPicker is { Kind: OtpPickerKind.Share } ? "Nobody to share with. Add contacts or join groups in Settings → Sync." : "No matching actions",
            13, Fluent.Secondary, wrap: true));
        selectedRow?.BringIntoView();
    }

    /// <summary>An action's title, with its shortcut on the right (Ctrl+L next to Label…).</summary>
    private static UIElement ActionRowContent(PanelAction action, bool selected)
    {
        var title = Fluent.Label(action.Title, 14, selected ? Fluent.AccentText : null);
        if (action.Shortcut is not { } shortcut) return title;
        var dock = new DockPanel();
        var keys = Fluent.Label(shortcut, 12, selected ? Fluent.AccentText : Fluent.Tertiary);
        DockPanel.SetDock(keys, Dock.Right);
        dock.Children.Add(keys);
        dock.Children.Add(title);
        return dock;
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
        stack.Children.Add(Fluent.Label(form.IsSecret ? "The name shown for this secret."
            : form.IsFolder ? "A tag shown next to the folder's name, and searchable. Leave empty to remove it."
            : "Shown instead of the content and searchable. Labelling an item saves it: it never expires. Leave empty to remove the label, and the item expires like the rest of history unless it's in a folder.",
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

    /// <summary>The inline name prompt: renaming a folder, or naming a new one the selection moves into.</summary>
    private UIElement BuildFolderName()
    {
        var form = Model.FolderForm!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label(form.IsRename ? "Rename Folder" : "New Folder", 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label(form.IsRename ? "Folders are listed by name in Saved."
            : form.ItemIds.Count == 1 ? "The item moves into the new folder and stays saved." : $"The {form.ItemIds.Count} items move into the new folder and stay saved.",
            13, Fluent.Secondary, wrap: true));
        var box = new TextBox { Text = form.Text, Margin = new Thickness(0, 12, 0, 0) };
        AutomationName(box, "Folder name");
        box.TextChanged += (_, _) => form.Text = box.Text;
        stack.Children.Add(box);
        var save = new Button { Content = form.IsRename ? "Rename" : "Create", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        save.Click += (_, _) => Model.SubmitFolderName();
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
        _syncStatus.Update();
        _hints.Text = Model.Mode switch
        {
            PanelMode.Browse when Model.ShowsPeople => Model.SelectedPerson switch
            {
                PersonRow.Incoming => "↑↓ Choose    Enter Accept    Type to Search    Tab Filter    Esc Close",
                PersonRow.Contact c when Model.ConfirmingRemoval == c.Space.Id => "Enter Remove    Esc Keep",
                PersonRow.Contact => "↑↓ Choose    Enter Send…    Type to Search    Tab Filter    Esc Close",
                _ => "↑↓ Choose    Type to Search    Tab Filter    Esc Close",
            },
            PanelMode.Browse when Model.IsPreviewing => "←→ Previous/Next    ↑↓ Choose Item    Enter Paste    Esc Close Preview",
            PanelMode.Browse when Model.PickedFiles.Count > 0 && Model.PickableItem is { } item =>
                $"Enter Paste {Model.PickedFiles.Count} of {item.Files.Count} files    Ctrl+K Actions    Esc All Files",
            PanelMode.Browse when Model.IsMultiSelecting => $"Enter Paste {Model.SelectedClips.Count} items    Shift+Enter Plain Text    Ctrl+K Actions    Ctrl+Y Preview    Del Delete    Esc Close",
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.FolderEntry => "Enter Open    Ctrl+K Actions    Del Delete Folder    Tab Filter    Esc Close",
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.AuthenticatorEntry => "Enter Paste Code    Ctrl+K Actions    Del Delete    Tab Filter    Esc Close",
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.SharedCodeEntry => "Enter Paste Code    Ctrl+K Actions    Tab Filter    Esc Close",
            PanelMode.Browse when Model.SelectedEntry is PanelEntry.OtpSuggestion => "Enter Add to Authenticator    Esc Dismiss",
            PanelMode.Browse when Model.OpenFolderId is not null => "Enter Paste    Ctrl+K Actions    Ctrl+Y Preview    Backspace Saved    Esc Back",
            // The compact panel has no room for one more hint.
            PanelMode.Browse when _services.Settings.PanelSize == PanelSize.Compact =>
                "Enter Paste    Shift+Enter Plain Text    Ctrl+K Actions    Ctrl+Shift+1–9 Assign Slot    Tab Filter    Esc Close",
            PanelMode.Browse => "Enter Paste    Shift+Enter Plain Text    Ctrl+K Actions    Ctrl+Y Preview    Ctrl+Shift+1–9 Assign Slot    Tab Filter    Esc Close",
            PanelMode.Actions when Model.OtpPicker is { Kind: OtpPickerKind.Share } => "↑↓ Choose Person    Enter Share    Esc Back",
            PanelMode.Actions when Model.OtpPicker is { Kind: OtpPickerKind.Transfer } => "↑↓ Choose Person    Enter Transfer    Esc Back",
            PanelMode.ConfirmDelete => "Enter Delete    Esc Cancel",
            PanelMode.AddItems when Model.AddItemsForm?.SendTo is not null => "↑↓ Choose    Space Check    Enter Send    Esc Cancel",
            PanelMode.AddItems => "↑↓ Choose    Space Check    Enter Add    Esc Cancel",
            PanelMode.SendToContact => "↑↓ Choose    Space Tick    Enter Send    Ctrl+Enter Send to Several    Esc Cancel",
            PanelMode.AuthenticatorSecret or PanelMode.AuthenticatorPeople => "Esc Back",
            PanelMode.Actions when Model.IsPickingGroup => "↑↓ Choose Group    Enter Share    Esc Back",
            PanelMode.Actions when Model.PickingShareFolder is not null => "↑↓ Choose Folder    Enter Share    Esc Back",
            PanelMode.Actions when Model.IsPickingFolder => "↑↓ Choose Folder    Enter Move    Esc Back",
            PanelMode.Actions => "↑↓ Choose    Enter Run    Esc Back",
            PanelMode.AI => "Enter Paste    Ctrl+C Copy    Ctrl+R Replace Item    Esc Back",
            _ => "Enter Save    Esc Back",
        };
    }
}
