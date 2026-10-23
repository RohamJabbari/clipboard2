using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Clipboard2.App.Platform;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

public static class Glyphs
{
    public const string Search = "", Pin = "", Pinned = "", Settings = "", Delete = "",
        Pause = "", Play = "", Power = "", Key = "", Snippet = "", Text = "",
        Image = "", File = "", Sparkle = "", Copy = "", Paste = "", Lock = "",
        Unlock = "", Download = "", All = "", App = "", Tag = "", Check = "",
        Panel = "", Clock = "", Cut = "", SelectAll = "", Undo = "", Redo = "",
        OpenWith = "", Info = "", Rename = "", Menu = "", Eye = "", Book = "",
        Group = "\uE716", Cloud = "\uE753", Filter = "\uE71C";

    public static TextBlock Icon(string glyph, double size = 16, Brush? brush = null) => new()
    {
        Text = glyph,
        FontFamily = (FontFamily)Application.Current.Resources["IconFont"],
        FontSize = size,
        VerticalAlignment = VerticalAlignment.Center,
        Foreground = brush ?? (Brush)Application.Current.Resources[SystemColors.ControlTextBrushKey],
    };

    public static string For(PanelFilter filter) => filter switch
    {
        PanelFilter.All => All,
        PanelFilter.Pinned => Pin,
        PanelFilter.Text => Text,
        PanelFilter.Images => Image,
        PanelFilter.Files => File,
        PanelFilter.Snippets => Snippet,
        PanelFilter.Secrets => Key,
        _ => App,
    };
}

/// <summary>Executable icons (cached by path) and image thumbnails.</summary>
public static class Icons
{
    private static readonly Dictionary<string, ImageSource?> Cache = [];

    public static ImageSource? ForApp(string? exePath)
    {
        if (string.IsNullOrEmpty(exePath) || !exePath.Contains('\\')) return null;
        if (Cache.TryGetValue(exePath, out var cached)) return cached;
        ImageSource? image = null;
        try
        {
            if (File.Exists(exePath) && System.Drawing.Icon.ExtractAssociatedIcon(exePath) is { } icon)
            {
                image = Imaging.CreateBitmapSourceFromHIcon(icon.Handle, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
                image.Freeze();
                icon.Dispose();
            }
        }
        catch { /* inaccessible executable */ }
        if (Cache.Count > 300) Cache.Clear();
        Cache[exePath] = image;
        return image;
    }

    private static readonly Dictionary<string, ImageSource?> Thumbs = [];

    public static ImageSource? Thumbnail(BlobStore blobs, string? name)
    {
        if (name is null) return null;
        if (Thumbs.TryGetValue(name, out var cached)) return cached;
        var image = ImageTools.Load(blobs.PathFor(name), decodeWidth: 96);
        if (Thumbs.Count > 300) Thumbs.Clear();
        Thumbs[name] = image;
        return image;
    }

    public static readonly ImageSource AppIcon = LoadAppIcon();

    private static ImageSource LoadAppIcon()
    {
        var image = new BitmapImage(new Uri("pack://application:,,,/Assets/app.png"));
        image.Freeze();
        return image;
    }
}

public static class Fluent
{
    public static bool IsDark => Application.Current.ThemeMode == ThemeMode.Dark
        || (Application.Current.ThemeMode == ThemeMode.System && SystemUsesDarkTheme());

    private static bool SystemUsesDarkTheme()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch { return false; }
    }

    /// <summary>Rounded corners + acrylic (Windows 11) for a borderless popup window.</summary>
    public static void ApplyBackdrop(Window window, bool transient = true)
    {
        var hwnd = new WindowInteropHelper(window).EnsureHandle();
        Native.SetDwm(hwnd, Native.DWMWA_USE_IMMERSIVE_DARK_MODE, IsDark ? 1 : 0);
        Native.SetDwm(hwnd, Native.DWMWA_WINDOW_CORNER_PREFERENCE, Native.DWMWCP_ROUND);
        Native.SetDwm(hwnd, Native.DWMWA_SYSTEMBACKDROP_TYPE, transient ? Native.DWMSBT_TRANSIENTWINDOW : Native.DWMSBT_MAINWINDOW);
    }

    public static Brush Accent => (Brush)Application.Current.Resources[SystemColors.HighlightBrushKey];
    public static Brush AccentText => (Brush)Application.Current.Resources[SystemColors.HighlightTextBrushKey];
    public static Brush Secondary => new SolidColorBrush(IsDark ? Color.FromArgb(0xB0, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0xA0, 0, 0, 0));
    public static Brush Tertiary => new SolidColorBrush(IsDark ? Color.FromArgb(0x70, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x70, 0, 0, 0));
    public static Brush Subtle => new SolidColorBrush(IsDark ? Color.FromArgb(0x18, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x10, 0, 0, 0));
    public static Brush Separator => new SolidColorBrush(IsDark ? Color.FromArgb(0x28, 0xFF, 0xFF, 0xFF) : Color.FromArgb(0x20, 0, 0, 0));
    /// <summary>Opaque fallback behind the acrylic (also what shows with transparency effects off).</summary>
    public static Brush PanelBackground => new SolidColorBrush(IsDark ? Color.FromArgb(0xCC, 0x20, 0x20, 0x20) : Color.FromArgb(0xCC, 0xF3, 0xF3, 0xF3));

    public static TextBlock Label(string text, double size = 14, Brush? brush = null, FontWeight? weight = null, bool wrap = false) => new()
    {
        Text = text,
        FontSize = size,
        Foreground = brush ?? (Brush)Application.Current.Resources[SystemColors.ControlTextBrushKey],
        FontWeight = weight ?? FontWeights.Normal,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static string Relative(DateTime utc)
    {
        var span = DateTime.UtcNow - utc;
        if (span.TotalMinutes < 1) return "now";
        if (span.TotalHours < 1) return $"{(int)span.TotalMinutes} min ago";
        if (span.TotalDays < 1) return $"{(int)span.TotalHours} hr ago";
        if (span.TotalDays < 30) return $"{(int)span.TotalDays} d ago";
        return utc.ToLocalTime().ToString("d");
    }
}

/// <summary>Small modal prompt (name a secret, label an item, change a value).</summary>
public sealed class InputDialog : Window
{
    private readonly TextBox? _text;
    private readonly PasswordBox? _password;
    public string Value => _password?.Password ?? _text?.Text ?? "";

    private InputDialog(string title, string message, string initial, bool secret, string okTitle)
    {
        Title = title;
        Width = 420;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.NoResize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        ShowInTaskbar = false;
        Topmost = true;
        var stack = new StackPanel { Margin = new Thickness(20) };
        stack.Children.Add(Fluent.Label(message, wrap: true));
        Control input;
        if (secret) input = _password = new PasswordBox { Margin = new Thickness(0, 12, 0, 0) };
        else input = _text = new TextBox { Text = initial, Margin = new Thickness(0, 12, 0, 0) };
        stack.Children.Add(input);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 80, Margin = new Thickness(0, 0, 8, 0) };
        var ok = new Button { Content = okTitle, IsDefault = true, MinWidth = 80 };
        ok.Click += (_, _) => DialogResult = true;
        buttons.Children.Add(cancel);
        buttons.Children.Add(ok);
        stack.Children.Add(buttons);
        Content = stack;
        Loaded += (_, _) =>
        {
            input.Focus();
            _text?.SelectAll();
        };
    }

    public static string? Ask(string title, string message, string initial = "", bool secret = false, string okTitle = "OK")
    {
        var dialog = new InputDialog(title, message, initial, secret, okTitle);
        return dialog.ShowDialog() == true ? dialog.Value : null;
    }
}

/// <summary>Records a global shortcut: focus it and press the keys (Backspace clears).</summary>
public sealed class HotkeyBox : TextBox
{
    private readonly HotkeyManager _hotkeys;
    public event Action<string?>? ComboChanged;

    public HotkeyBox(HotkeyManager hotkeys, string? combo)
    {
        _hotkeys = hotkeys;
        IsReadOnly = true;
        IsReadOnlyCaretVisible = false;
        MinWidth = 180;
        Text = combo ?? "";
        ToolTip = "Click, then press the new shortcut. Backspace removes it.";
        GotKeyboardFocus += (_, _) => { _hotkeys.Suspend(true); if (Text.Length == 0) Text = "Press keys…"; };
        LostKeyboardFocus += (_, _) => { _hotkeys.Suspend(false); if (Text == "Press keys…") Text = ""; };
    }

    protected override void OnPreviewKeyDown(KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        if (key is Key.Back or Key.Delete)
        {
            Text = "";
            ComboChanged?.Invoke(null);
            return;
        }
        if (key is Key.Escape or Key.Tab) { MoveFocus(new TraversalRequest(FocusNavigationDirection.Next)); return; }
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin) return;
        uint mods = 0;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Control)) mods |= Native.MOD_CONTROL;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Alt)) mods |= Native.MOD_ALT;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Shift)) mods |= Native.MOD_SHIFT;
        if (Keyboard.Modifiers.HasFlag(ModifierKeys.Windows)) mods |= Native.MOD_WIN;
        if (mods == 0 || mods == Native.MOD_SHIFT) { Text = "Add Ctrl, Alt or Win"; return; }
        var combo = new KeyCombo(mods, key).ToString();
        Text = combo;
        ComboChanged?.Invoke(combo);
    }
}

/// <summary>Tray icon (WinForms NotifyIcon): left-click shows recent history, right-click the menu.</summary>
public sealed class TrayIcon : IDisposable
{
    private readonly System.Windows.Forms.NotifyIcon _icon;
    private readonly AppServices _services;
    private readonly System.Windows.Forms.ToolStripMenuItem _updateItem;
    private readonly System.Windows.Forms.ToolStripMenuItem _pauseItem;

    public TrayIcon(AppServices services)
    {
        _services = services;
        var stream = Application.GetResourceStream(new Uri("pack://application:,,,/Assets/app.ico")).Stream;
        _icon = new System.Windows.Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream, System.Windows.Forms.SystemInformation.SmallIconSize),
            Text = "Clipboard2",
            Visible = true,
        };
        var menu = new System.Windows.Forms.ContextMenuStrip();
        menu.Items.Add($"Open Clipboard2 ({services.Settings.Hotkeys[Hotkey.QuickPanel]})", null, (_, _) => services.ShowPanel());
        _pauseItem = new System.Windows.Forms.ToolStripMenuItem("Pause Capture", null, (_, _) => TogglePause());
        menu.Items.Add(_pauseItem);
        menu.Items.Add("Settings…", null, (_, _) => services.OpenSettings());
        _updateItem = new System.Windows.Forms.ToolStripMenuItem("Check for Updates…", null, async (_, _) =>
        {
            if (services.Updates.AvailableVersion is not null) await services.Updates.InstallAsync();
            else { await services.Updates.CheckAsync(); services.OpenSettings("About"); }
        });
        menu.Items.Add(_updateItem);
        menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
        menu.Items.Add("Quit Clipboard2", null, (_, _) => Application.Current.Shutdown());
        menu.Opening += (_, _) => _pauseItem.Text = services.Settings.IsPaused ? "Resume Capture" : "Pause Capture";
        _icon.ContextMenuStrip = menu;
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button != System.Windows.Forms.MouseButtons.Left) return;
            Native.GetCursorPos(out var point);
            services.ShowFlyout(new Point(point.X, point.Y));
        };
        _icon.BalloonTipClicked += async (_, _) =>
        {
            if (services.Updates.AvailableVersion is not null) await services.Updates.InstallAsync();
        };
    }

    private void TogglePause()
    {
        _services.Settings.IsPaused = !_services.Settings.IsPaused;
        _services.Settings.Save();
        _icon.Text = _services.Settings.IsPaused ? "Clipboard2 (paused)" : "Clipboard2";
    }

    public void ShowBalloon(string title, string text) => _icon.ShowBalloonTip(5000, title, text, System.Windows.Forms.ToolTipIcon.None);

    private string? _notifiedVersion;

    public void ShowUpdate(string? version)
    {
        _updateItem.Text = version is null ? "Check for Updates…" : $"Update to {version} and Restart";
        if (version is null || version == _notifiedVersion) return;
        _notifiedVersion = version;   // one balloon per new version, not one per hourly check
        ShowBalloon("Update available", $"Clipboard2 {version} is ready. Click here to update and restart.");
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
