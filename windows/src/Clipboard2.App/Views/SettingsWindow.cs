using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Clipboard2.App.Platform;
using Clipboard2.Core;
using Clipboard2.Core.AI;
using Clipboard2.Core.Sync;
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App.Views;

/// <summary>Settings: General, Appearance, Ignored Apps, Snippets, Secrets, Transforms, AI, Sync, About.</summary>
public sealed partial class SettingsWindow : Window
{
    private readonly AppServices _services;
    private readonly TabControl _tabs = new() { Margin = new Thickness(12) };
    private Settings S => _services.Settings;

    public SettingsWindow(AppServices services)
    {
        _services = services;
        Title = "Clipboard2 Settings";
        Width = 820;
        Height = 680;
        MinWidth = 640;
        MinHeight = 480;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Icon = Icons.AppIcon;
        Content = _tabs;
        AddTab("General", Glyphs.Settings, BuildGeneral);
        AddTab("Appearance", "", BuildAppearance);
        AddTab("Ignored Apps", "", BuildIgnored);
        AddTab("Snippets", Glyphs.Snippet, BuildSnippets);
        AddTab("Secrets", Glyphs.Key, BuildSecrets);
        AddTab("Transforms", "", BuildTransforms);
        AddTab("AI", Glyphs.Sparkle, BuildAI);
        AddTab("Sync", "", BuildSync);
        AddTab("About", Glyphs.Info, BuildAbout);
        _services.Secrets.Changed += () => Dispatcher.BeginInvoke(() => RefreshTab("Secrets"));
        _services.ClaudeAccount.Changed += () => Dispatcher.BeginInvoke(() => RefreshTab("AI"));
        _services.ChatGptAccount.Changed += () => Dispatcher.BeginInvoke(() => RefreshTab("AI"));
        _services.Updates.Changed += () => Dispatcher.BeginInvoke(() => RefreshTab("About"));
        _services.Sync.Changed += () => Dispatcher.BeginInvoke(() => RefreshTab("Sync"));
    }

    private readonly Dictionary<string, (TabItem Tab, Func<UIElement> Build)> _pages = [];

    private void AddTab(string title, string glyph, Func<UIElement> build)
    {
        var header = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Glyphs.Icon(glyph, 14);
        icon.Margin = new Thickness(0, 0, 6, 0);
        header.Children.Add(icon);
        header.Children.Add(new TextBlock { Text = title });
        var tab = new TabItem { Header = header, Tag = title };
        tab.GotFocus += (_, _) => { if (tab.Content is null) tab.Content = Scroll(build()); };
        _tabs.Items.Add(tab);
        _pages[title] = (tab, build);
        if (_tabs.Items.Count == 1) tab.Content = Scroll(build());
    }

    public void SelectTab(string? title)
    {
        if (title is not null && _pages.TryGetValue(title, out var page))
        {
            page.Tab.Content ??= Scroll(page.Build());
            _tabs.SelectedItem = page.Tab;
        }
    }

    private void RefreshTab(string title)
    {
        if (_pages.TryGetValue(title, out var page) && page.Tab.Content is not null) page.Tab.Content = Scroll(page.Build());
    }

    private static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(8, 12, 8, 12),
    };

    // MARK: Layout helpers

    private static StackPanel Page() => new() { MaxWidth = 720, HorizontalAlignment = HorizontalAlignment.Stretch };

    private static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (var i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(new Border { Height = 1, Background = Fluent.Separator, Margin = new Thickness(0, 6, 0, 6) });
            stack.Children.Add(rows[i]);
        }
        return new Border { Child = stack, Background = Fluent.Subtle, CornerRadius = new CornerRadius(8), Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 16) };
    }

    private static TextBlock Header(string text)
    {
        var t = Fluent.Label(text, 14, null, FontWeights.SemiBold);
        t.Margin = new Thickness(2, 0, 0, 6);
        return t;
    }

    private static TextBlock Hint(string text)
    {
        var t = Fluent.Label(text, 12, Fluent.Secondary, wrap: true);
        t.Margin = new Thickness(2, -10, 0, 16);
        return t;
    }

    private static DockPanel Row(string label, UIElement control)
    {
        var dock = new DockPanel { LastChildFill = false, MinHeight = 32 };
        dock.Children.Add(Fluent.Label(label));
        DockPanel.SetDock(control, Dock.Right);
        if (control is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
        dock.Children.Add(control);
        return dock;
    }

    private static CheckBox Toggle(bool value, Action<bool> changed)
    {
        var box = new CheckBox { IsChecked = value };
        box.Checked += (_, _) => changed(true);
        box.Unchecked += (_, _) => changed(false);
        return box;
    }

    private static ComboBox Choice<T>(IEnumerable<T> values, T current, Func<T, string> title, Action<T> changed)
    {
        var combo = new ComboBox { MinWidth = 200 };
        var list = values.ToList();
        foreach (var v in list) combo.Items.Add(title(v));
        combo.SelectedIndex = Math.Max(0, list.IndexOf(current));
        combo.SelectionChanged += (_, _) => { if (combo.SelectedIndex >= 0) changed(list[combo.SelectedIndex]); };
        return combo;
    }

    private static Button Action(string title, Action action, bool accent = false)
    {
        var b = new Button { Content = title, Margin = new Thickness(6, 0, 0, 0), MinWidth = 90 };
        if (accent) b.Style = (Style)Application.Current.TryFindResource("AccentButtonStyle") ?? b.Style;
        b.Click += (_, _) => action();
        return b;
    }

    private void Save() => S.Save();

    // MARK: General

    private UIElement BuildGeneral()
    {
        var page = Page();
        page.Children.Add(Card(
            Row("Launch at sign-in", Toggle(StartupRegistration.IsEnabled, on => { S.LaunchAtLogin = on; StartupRegistration.SetEnabled(on); Save(); })),
            Row("Pause clipboard capture", Toggle(S.IsPaused, on => { S.IsPaused = on; Save(); }))));

        page.Children.Add(Header("Shortcuts"));
        var shortcuts = new List<UIElement>();
        foreach (var name in new[] { Hotkey.QuickPanel, Hotkey.SelectionActions, Hotkey.PasteAsText, Hotkey.CaptureText, Hotkey.SendToGroup, Hotkey.PasteFromGroup })
            shortcuts.Add(HotkeyRow(name));
        page.Children.Add(Card([.. shortcuts]));
        page.Children.Add(Hint("Actions on selected text: select text in any app to transform it or ask AI; Enter replaces the selection. Paste as text pastes plain text — or the text inside an image or screenshot on the clipboard. Capture text: drag over anything on screen. Text recognition runs on this PC. Send to group: copies the selected text into your default sync group (Settings → Sync). Paste from group: fetches the default group and pastes its newest item. Both are active only while you're signed in to sync; Ctrl+Alt+V replaces Paste Special in Office apps."));

        page.Children.Add(Header("Quick slots"));
        var slotRows = new List<UIElement>();
        for (var n = QuickSlots.First; n <= QuickSlots.Last; n++)
        {
            var slot = n;
            var title = SlotTitle(slot) ?? $"Empty — falls back to row {slot}";
            var row = new DockPanel { LastChildFill = true, MinHeight = 32 };
            var label = Fluent.Label($"Ctrl+{slot}", 13, null, FontWeights.SemiBold);
            label.Width = 60;
            row.Children.Add(label);
            var box = new HotkeyBox(_services.Hotkeys, S.Hotkeys.GetValueOrDefault(Hotkey.Slot(slot)));
            box.ComboChanged += combo => SetHotkey(Hotkey.Slot(slot), combo);
            DockPanel.SetDock(box, Dock.Right);
            row.Children.Add(box);
            if (_services.Slots.Target(slot) is not null)
            {
                var clear = new Button { Content = "Clear", Margin = new Thickness(6, 0, 6, 0) };
                clear.Click += (_, _) => { _services.Slots.Clear(slot); RefreshTab("General"); };
                DockPanel.SetDock(clear, Dock.Right);
                row.Children.Add(clear);
            }
            row.Children.Add(Fluent.Label(title, 13, _services.Slots.Target(slot) is null ? Fluent.Tertiary : null));
            slotRows.Add(row);
        }
        page.Children.Add(Card([.. slotRows]));
        page.Children.Add(Hint("In the quick panel, select something and press Ctrl+Shift+1–9 to bind it; Ctrl+1–9 then always pastes it. Record a global shortcut to paste a slot from any app."));

        page.Children.Add(Header("Right-click menu"));
        page.Children.Add(Card(
            Row($"Open Clipboard2's menu with {S.ContextMenuModifier}+right-click", Toggle(S.ContextMenuEnabled, on => { S.ContextMenuEnabled = on; Save(); ContextMenuService.Shared?.Update(); })),
            Row("Modifier", Choice(Enum.GetValues<ContextMenuModifier>(), S.ContextMenuModifier, m => m == ContextMenuModifier.Control ? "Ctrl" : "Alt",
                m => { S.ContextMenuModifier = m; Save(); }))));
        page.Children.Add(Hint("Works in every app: Clipboard2's actions plus Cut, Copy, Paste, Select All (and File Explorer items in Explorer). “Show app menu” opens the app's own menu. Plain right-clicks are never changed."));

        page.Children.Add(Header("History"));
        var count = Fluent.Label($"{_services.Store.Count()} items", 13, Fluent.Secondary);
        page.Children.Add(Card(
            Row("Keep up to", Choice(Settings.MaxItemChoices, S.MaxItems, v => v == 0 ? "Unlimited" : $"{v} items", v => { S.MaxItems = v; Save(); _services.RunMaintenance(); })),
            Row("Delete items after", Choice(Settings.MaxAgeChoices, S.MaxAgeMinutes, Settings.DescribeAge, v => { S.MaxAgeMinutes = v; Save(); _services.RunMaintenance(); })),
            Row("Stored", count),
            Row("", Action("Clear History…", () =>
            {
                var answer = MessageBox.Show(this, "Clear clipboard history? Pinned items are kept.\n\nChoose No to also remove pinned items.", "Clear History",
                    MessageBoxButton.YesNoCancel, MessageBoxImage.Warning);
                if (answer == MessageBoxResult.Cancel) return;
                _services.Store.ClearHistory(includingPinned: answer == MessageBoxResult.No);
                count.Text = $"{_services.Store.Count()} items";
            }))));
        page.Children.Add(Hint("Measured from the last time an item was copied. Pinned and labelled items and secrets never expire."));
        AddBackupSection(page);
        return page;
    }

    private string? SlotTitle(int slot) => _services.Panel.EntryForSlot(slot) switch
    {
        PanelEntry.Clip c => c.Item.DisplayTitle,
        PanelEntry.SnippetEntry s => s.Snippet.Name,
        PanelEntry.SecretEntry k => k.Secret.Name,
        _ => null,
    };

    private UIElement HotkeyRow(string name)
    {
        var box = new HotkeyBox(_services.Hotkeys, S.Hotkeys.GetValueOrDefault(name));
        var status = Fluent.Label(_services.Hotkeys.Failed.Contains(name) ? "In use by another app" : "", 12, Brushes.OrangeRed);
        status.Margin = new Thickness(0, 0, 8, 0);
        box.ComboChanged += combo =>
        {
            SetHotkey(name, combo);
            status.Text = _services.Hotkeys.Failed.Contains(name) ? "In use by another app" : "";
        };
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        right.Children.Add(status);
        right.Children.Add(box);
        return Row(Hotkey.Title(name), right);
    }

    private void SetHotkey(string name, string? combo)
    {
        // "" (not removal) means "no shortcut", so a cleared default doesn't come back on restart.
        S.Hotkeys[name] = combo ?? "";
        Save();
        _services.RegisterHotkeys();
    }

    // MARK: Appearance

    private UIElement BuildAppearance()
    {
        var page = Page();
        page.Children.Add(Card(
            Row("Theme", Choice(Enum.GetValues<AppearanceMode>(), S.Appearance, m => m == AppearanceMode.System ? "Follow Windows" : m.ToString(),
                m => { S.Appearance = m; Save(); _services.ApplyAppearance(); })),
            Row("Quick panel size", Choice(Enum.GetValues<PanelSize>(), S.PanelSize, s => s.ToString(), s => { S.PanelSize = s; Save(); }))));
        page.Children.Add(Hint("Transparency follows Windows' “Transparency effects” setting; animations follow “Animation effects”."));
        return page;
    }

    // MARK: Ignored apps

    private UIElement BuildIgnored()
    {
        var page = Page();
        page.Children.Add(Header("Never record copies from these apps"));
        var rows = S.IgnoredApps.Select(app => (UIElement)Row(app.Name, Action("Remove", () =>
        {
            S.IgnoredApps.RemoveAll(a => a.Id == app.Id);
            Save();
            RefreshTab("Ignored Apps");
        }))).ToList();
        if (rows.Count == 0) rows.Add(Fluent.Label("No ignored apps.", 13, Fluent.Secondary));
        page.Children.Add(Card([.. rows]));
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, -6, 0, 12) };
        buttons.Children.Add(AppPicker("Add App…", app =>
        {
            if (S.IgnoredApps.Any(a => a.Id == app.Id)) return;
            S.IgnoredApps.Add(app);
            Save();
            RefreshTab("Ignored Apps");
        }));
        buttons.Children.Add(Action("Restore Defaults", () =>
        {
            foreach (var app in AppRef.DefaultIgnored.Where(d => S.IgnoredApps.All(a => a.Id != d.Id))) S.IgnoredApps.Add(app);
            Save();
            RefreshTab("Ignored Apps");
        }));
        page.Children.Add(buttons);
        page.Children.Add(Hint("Copies that apps mark as private (password managers, Windows Security) are always skipped, whichever app they come from."));
        return page;
    }

    /// <summary>Running apps menu + "Browse…" for an .exe. AppRef.Id is the lower-case exe file name.</summary>
    private Button AppPicker(string title, Action<AppRef> picked)
    {
        var button = new Button { Content = title, MinWidth = 110 };
        button.Click += (_, _) =>
        {
            var menu = new ContextMenu { PlacementTarget = button };
            var seen = new HashSet<string>();
            foreach (var process in Process.GetProcesses().Where(p => p.MainWindowHandle != IntPtr.Zero).OrderBy(p => p.ProcessName))
            {
                AppRef? app = null;
                try { app = ForegroundTracker.AppForProcess((uint)process.Id); } catch { }
                if (app is null || app.Id.EndsWith("clipboard2.exe")) continue;
                var exe = Path.GetFileName(app.Id);
                if (!seen.Add(exe)) continue;
                var item = new MenuItem { Header = app.Name };
                var captured = app with { Id = exe };
                item.Click += (_, _) => picked(captured);
                menu.Items.Add(item);
            }
            menu.Items.Add(new Separator());
            var browse = new MenuItem { Header = "Browse…" };
            browse.Click += (_, _) =>
            {
                var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "Applications (*.exe)|*.exe" };
                if (dialog.ShowDialog(this) == true)
                {
                    var info = FileVersionInfo.GetVersionInfo(dialog.FileName);
                    picked(new AppRef(Path.GetFileName(dialog.FileName).ToLowerInvariant(),
                        info.FileDescription is { Length: > 0 } d ? d : Path.GetFileNameWithoutExtension(dialog.FileName)));
                }
            };
            menu.Items.Add(browse);
            menu.IsOpen = true;
        };
        return button;
    }

    // MARK: Snippets

    private UIElement BuildSnippets()
    {
        var grid = new Grid { MinHeight = 420 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var list = new ListBox { Margin = new Thickness(0, 0, 12, 0) };
        var editor = new StackPanel();
        Grid.SetColumn(editor, 1);
        var snippets = _services.Store.AllSnippets();
        foreach (var s in snippets) list.Items.Add(new ListBoxItem { Content = s.Name, Tag = s });

        void ShowEditor(Snippet? snippet)
        {
            editor.Children.Clear();
            if (snippet is null)
            {
                editor.Children.Add(Fluent.Label("Snippets show up in the quick panel when you search or pick the Snippets filter.", 13, Fluent.Secondary, wrap: true));
                return;
            }
            var name = new TextBox { Text = snippet.Name };
            var keyword = new TextBox { Text = snippet.Keyword };
            var body = new TextBox { Text = snippet.Body, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 180, FontFamily = new FontFamily("Cascadia Mono, Consolas"),
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
            void Persist()
            {
                snippet.Name = name.Text;
                snippet.Keyword = keyword.Text;
                snippet.Body = body.Text;
                _services.Store.SaveSnippet(snippet);
                if (list.SelectedItem is ListBoxItem selected) selected.Content = snippet.Name;
            }
            name.LostFocus += (_, _) => Persist();
            keyword.LostFocus += (_, _) => Persist();
            body.LostFocus += (_, _) => Persist();
            editor.Children.Add(new TextBlock { Text = "Name", Margin = new Thickness(0, 0, 0, 4) });
            editor.Children.Add(name);
            editor.Children.Add(new TextBlock { Text = "Keyword (e.g. ;sig)", Margin = new Thickness(0, 10, 0, 4) });
            editor.Children.Add(keyword);
            editor.Children.Add(new TextBlock { Text = "Body", Margin = new Thickness(0, 10, 0, 4) });
            editor.Children.Add(body);
            editor.Children.Add(Fluent.Label("{date}, {time} — current date and time · {clipboard} — what's on the clipboard · {cursor} — where the caret ends up · {anything} — asks for a value before pasting, e.g. {name}",
                12, Fluent.Secondary, wrap: true));
            var delete = Action("Delete Snippet", () =>
            {
                _services.Store.DeleteSnippet(snippet);
                RefreshTab("Snippets");
            });
            delete.HorizontalAlignment = HorizontalAlignment.Left;
            delete.Margin = new Thickness(0, 12, 0, 0);
            editor.Children.Add(delete);
        }

        list.SelectionChanged += (_, _) => ShowEditor((list.SelectedItem as ListBoxItem)?.Tag as Snippet);
        var left = new DockPanel();
        var add = new Button { Content = "New Snippet", Margin = new Thickness(0, 8, 12, 0) };
        add.Click += (_, _) =>
        {
            var created = _services.Store.CreateSnippet();
            var item = new ListBoxItem { Content = created.Name, Tag = created };
            list.Items.Add(item);
            list.SelectedItem = item;
        };
        DockPanel.SetDock(add, Dock.Bottom);
        left.Children.Add(add);
        left.Children.Add(list);
        grid.Children.Add(left);
        grid.Children.Add(editor);
        ShowEditor(null);
        return grid;
    }

    // MARK: Secrets

    private UIElement BuildSecrets()
    {
        var page = Page();
        page.Children.Add(Header("Secrets"));
        var rows = new List<UIElement>();
        foreach (var secret in _services.Secrets.All)
        {
            var value = Fluent.Label("••••••••", 13, Fluent.Secondary);
            value.FontFamily = new FontFamily("Consolas");
            value.Margin = new Thickness(0, 0, 8, 0);
            var actions = new StackPanel { Orientation = Orientation.Horizontal };
            actions.Children.Add(value);
            if (_services.Slots.SlotFor(SlotTarget.ForSecret(secret.Id)) is { } slot)
                actions.Children.Add(Fluent.Label($"Ctrl+{slot}  ", 12, Fluent.Accent));
            actions.Children.Add(Action("Show", async () =>
            {
                if (value.Text.StartsWith('•'))
                {
                    if (await _services.Secrets.RevealAsync(secret, $"show “{secret.Name}”") is { } v) value.Text = v;
                }
                else value.Text = "••••••••";
            }));
            actions.Children.Add(Action("Rename…", () =>
            {
                if (InputDialog.Ask("Rename Secret", "New name:", secret.Name) is { Length: > 0 } name) _services.Secrets.Rename(secret, name.Trim());
            }));
            actions.Children.Add(Action("Change Value…", () =>
            {
                if (InputDialog.Ask("Change Value", $"New value for “{secret.Name}”:", secret: true) is { Length: > 0 } v) _services.Secrets.SetValue(secret, v);
            }));
            actions.Children.Add(Action("Delete", () =>
            {
                if (MessageBox.Show(this, $"Delete “{secret.Name}”? The value is removed from Credential Manager.", "Delete Secret",
                        MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
                _services.Slots.Remove(SlotTarget.ForSecret(secret.Id));
                _services.Secrets.Delete(secret);
            }));
            rows.Add(Row(secret.Name, actions));
        }
        if (rows.Count == 0) rows.Add(Fluent.Label("No secrets yet. Add one below, or select a copied password in the quick panel and choose Ctrl+K → Save as Secret.", 13, Fluent.Secondary, wrap: true));
        page.Children.Add(Card([.. rows]));
        page.Children.Add(Hint("Values are stored in Windows Credential Manager — never in history, never sent to AI or transforms. With Sync on, they're end-to-end encrypted on this PC before upload; the server can't read them."));

        page.Children.Add(Header("Add a secret"));
        var name = new TextBox { MinWidth = 260 };
        var secretValue = new PasswordBox { MinWidth = 260 };
        page.Children.Add(Card(Row("Name", name), Row("Value", secretValue), Row("", Action("Add Secret", () =>
        {
            if (name.Text.Trim().Length == 0 || secretValue.Password.Length == 0) return;
            _services.Secrets.Add(name.Text.Trim(), secretValue.Password);
        }))));

        page.Children.Add(Header("Security"));
        var unlock = _services.Secrets.IsManuallyUnlocked && _services.Secrets.UnlockedUntil is { } until
            ? (UIElement)Row($"Unlocked until {until:g}", Action("Lock Now", () => { _services.Secrets.Lock(); RefreshTab("Secrets"); }))
            : Row("Leave unlocked for", Choice(new[] { "—", "15 minutes", "1 hour", "8 hours", "1 day", "1 week" }, "—", v => v, async v =>
            {
                var duration = v switch
                {
                    "15 minutes" => TimeSpan.FromMinutes(15), "1 hour" => TimeSpan.FromHours(1), "8 hours" => TimeSpan.FromHours(8),
                    "1 day" => TimeSpan.FromDays(1), "1 week" => TimeSpan.FromDays(7), _ => TimeSpan.Zero,
                };
                if (duration > TimeSpan.Zero && await _services.Secrets.UnlockForAsync(duration, v)) RefreshTab("Secrets");
            }));
        page.Children.Add(Card(
            Row("Ask for Windows Hello", Choice(Settings.SecretGraceChoices, S.SecretGraceMinutes,
                m => m == 0 ? "Every time" : m == 1 ? "Once per minute" : $"Once per {m} minutes", m => { S.SecretGraceMinutes = m; Save(); })),
            Row("Clear clipboard after pasting", Choice(Settings.SecretClearChoices, S.SecretClearSeconds, s => s == 0 ? "Never" : $"{s} seconds",
                s => { S.SecretClearSeconds = s; Save(); })),
            unlock));
        var helloHint = Hint("The unlock window ends when your PC locks or sleeps. Pasted secrets are excluded from Windows clipboard history (Win+V) and cloud clipboard.");
        page.Children.Add(helloHint);
        _ = Task.Run(async () =>
        {
            if (!await SecretVault.HelloAvailableAsync())
                Dispatcher.Invoke(() => helloHint.Text = "Windows Hello isn't set up on this PC, so secrets paste without confirmation. Set up a PIN, face or fingerprint in Windows Settings → Accounts → Sign-in options.");
        });
        return page;
    }

    // MARK: Transforms

    private UIElement BuildTransforms()
    {
        var page = Page();
        page.Children.Add(Header("Default transform per app"));
        var rows = new List<UIElement>();
        foreach (var rule in S.AppTransforms.ToList())
        {
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            controls.Children.Add(Choice(Transforms.All, rule.Transform, t => t.Title(), t =>
            {
                var index = S.AppTransforms.FindIndex(r => r.App.Id == rule.App.Id);
                if (index >= 0) S.AppTransforms[index] = rule with { Transform = t };
                Save();
            }));
            var id = rule.App.Id;
            controls.Children.Add(Action("Remove", () => { S.AppTransforms.RemoveAll(r => r.App.Id == id); Save(); RefreshTab("Transforms"); }));
            rows.Add(Row(rule.App.Name, controls));
        }
        if (rows.Count == 0) rows.Add(Fluent.Label("No per-app rules. Items paste with their original formatting everywhere.", 13, Fluent.Secondary));
        page.Children.Add(Card([.. rows]));
        var add = AppPicker("Add App…", app =>
        {
            if (S.AppTransforms.Any(r => r.App.Id == app.Id)) return;
            S.AppTransforms.Add(new AppTransformRule(app, Transform.PlainText));
            Save();
            RefreshTab("Transforms");
        });
        add.HorizontalAlignment = HorizontalAlignment.Left;
        add.Margin = new Thickness(0, -6, 0, 12);
        page.Children.Add(add);
        page.Children.Add(Hint("Applied automatically when pasting from Clipboard2 into that app — e.g. always plain text into Outlook. Pick a different transform any time with Ctrl+K."));
        return page;
    }

    // MARK: AI

    private UIElement BuildAI()
    {
        var page = Page();
        var provider = S.AIProvider;
        page.Children.Add(Header("AI"));

        var modes = new StackPanel();
        void Mode(string title, bool selected, Action choose)
        {
            var radio = new RadioButton { Content = title, IsChecked = selected, GroupName = "aimode", Margin = new Thickness(0, 2, 0, 2) };
            radio.Checked += (_, _) => { choose(); Save(); RefreshTab("AI"); };
            modes.Children.Add(radio);
        }
        Mode("Claude — sign in with your account", provider == AIProviderKind.ClaudeCode, () => S.AIProvider = AIProviderKind.ClaudeCode);
        Mode("ChatGPT — sign in with your account", provider == AIProviderKind.ChatGPT, () => S.AIProvider = AIProviderKind.ChatGPT);
        Mode("API key — any provider", !provider.IsSubscription(), () =>
            S.AIProvider = AIProviders.ApiProviders.FirstOrDefault(p => _services.Keys.Read(p.KeychainAccount()) is not null, AIProviderKind.Anthropic));
        var rows = new List<UIElement> { modes };

        if (_services.AccountFor(provider) is { } account) rows.Add(AccountRow(account));
        else rows.AddRange(ApiKeyRows(provider));

        if (_services.AccountFor(provider)?.IsSignedIn ?? true)
        {
            var model = new ComboBox { IsEditable = true, MinWidth = 260, Text = S.AIModel };
            model.Items.Add(S.AIModel);
            model.LostFocus += (_, _) => { if (model.Text.Trim().Length > 0) { S.AIModel = model.Text.Trim(); Save(); } };
            model.SelectionChanged += (_, _) => { if (model.SelectedItem is string m) { S.AIModel = m; Save(); } };
            var fetch = Action("Fetch Models", async () =>
            {
                try
                {
                    var list = await _services.Models.FetchAsync(provider, S.CustomBaseUrl);
                    QuickPanelWindow.ModelCache[provider] = list;
                    model.Items.Clear();
                    foreach (var m in list) model.Items.Add(m);
                    model.IsDropDownOpen = true;
                }
                catch (Exception ex) { MessageBox.Show(this, ex.Message, "Couldn't fetch models"); }
            });
            var modelControls = new StackPanel { Orientation = Orientation.Horizontal };
            modelControls.Children.Add(model);
            modelControls.Children.Add(fetch);
            rows.Add(Row("Model", modelControls));

            var testStatus = Fluent.Label("", 12, Fluent.Secondary);
            var test = Action("Test Connection", async () =>
            {
                testStatus.Text = "Testing…";
                try
                {
                    var client = AIClientFactory.Make(S.AIProvider, S.AIModel, S.CustomBaseUrl, _services.Keys);
                    var output = "";
                    await foreach (var chunk in client.StreamAsync("Reply with the single word OK.", "Ping")) output += chunk;
                    testStatus.Text = output.Length > 0 ? "✓ Connected" : "Empty response";
                }
                catch (Exception ex) { testStatus.Text = ex.Message; }
            });
            var testRow = new StackPanel { Orientation = Orientation.Horizontal };
            testRow.Children.Add(test);
            testRow.Children.Add(new Border { Width = 10 });
            testRow.Children.Add(testStatus);
            rows.Add(testRow);
        }
        page.Children.Add(Card([.. rows]));
        page.Children.Add(Hint("Keys are stored in Windows Credential Manager. Text is only sent when you run an action with Ctrl+K or Ctrl+Alt+K."));

        page.Children.Add(Header("Custom prompts"));
        var prompts = new List<UIElement>();
        foreach (var prompt in S.CustomPrompts.ToList())
        {
            var stack = new StackPanel();
            var name = new TextBox { Text = prompt.Name, FontWeight = FontWeights.SemiBold };
            var text = new TextBox { Text = prompt.Prompt, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 50, Margin = new Thickness(0, 4, 0, 0) };
            name.LostFocus += (_, _) => { prompt.Name = name.Text; Save(); };
            text.LostFocus += (_, _) => { prompt.Prompt = text.Text; Save(); };
            stack.Children.Add(name);
            stack.Children.Add(text);
            var id = prompt.Id;
            var remove = Action("Remove", () => { S.CustomPrompts.RemoveAll(p => p.Id == id); Save(); RefreshTab("AI"); });
            remove.HorizontalAlignment = HorizontalAlignment.Right;
            remove.Margin = new Thickness(0, 4, 0, 0);
            stack.Children.Add(remove);
            prompts.Add(stack);
        }
        var addPrompt = Action("Add Prompt", () => { S.CustomPrompts.Add(new CustomPrompt()); Save(); RefreshTab("AI"); });
        addPrompt.HorizontalAlignment = HorizontalAlignment.Left;
        prompts.Add(addPrompt);
        page.Children.Add(Card([.. prompts]));
        page.Children.Add(Hint("Built-in: Translate (English, German, Farsi), Summarize, Fix Grammar, Explain."));
        return page;
    }

    private UIElement AccountRow(SubscriptionAccount account)
    {
        var stack = new StackPanel();
        var state = account.State;
        var status = state.Phase switch
        {
            SubscriptionPhase.Checking => "Checking…",
            SubscriptionPhase.NotInstalled => "Not set up",
            SubscriptionPhase.Installing => "Installing…",
            SubscriptionPhase.SignedOut => "Signed out",
            SubscriptionPhase.SigningIn => "Waiting for browser…",
            SubscriptionPhase.SignedIn => "✓ " + (state.Detail ?? "Signed in"),
            _ => state.Detail ?? "Something went wrong",
        };
        var controls = new StackPanel { Orientation = Orientation.Horizontal };
        controls.Children.Add(Fluent.Label(status, 13, state.Phase == SubscriptionPhase.SignedIn ? Brushes.SeaGreen : Fluent.Secondary));
        switch (state.Phase)
        {
            case SubscriptionPhase.NotInstalled:
                controls.Children.Add(Action($"Set Up {account.Cli.ServiceName()}", async () =>
                {
                    await account.InstallAsync();
                    if (account.State.Phase == SubscriptionPhase.SignedOut) account.SignIn();
                }, accent: true));
                break;
            case SubscriptionPhase.SignedOut or SubscriptionPhase.Failed:
                controls.Children.Add(Action($"Sign in with {account.Cli.ServiceName()}", account.SignIn, accent: true));
                break;
            case SubscriptionPhase.SigningIn:
                controls.Children.Add(Action("Cancel", () => { account.CancelSignIn(); _ = account.RefreshAsync(); }));
                break;
            case SubscriptionPhase.SignedIn:
                controls.Children.Add(Action("Sign Out", () => _ = account.SignOutAsync()));
                break;
        }
        stack.Children.Add(Row("Account", controls));
        if (state.Phase == SubscriptionPhase.SigningIn)
        {
            stack.Children.Add(Fluent.Label(account.NeedsCode
                ? "Sign in on the page that opened. It then shows a code — copy it and paste it here."
                : "Finish signing in in your browser, then come back here.", 12, Fluent.Secondary, wrap: true));
            if (account.SignInUrl is { } url)
                stack.Children.Add(Action("Open Sign-In Page Again", () => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })));
            if (account.NeedsCode)
            {
                var code = new TextBox { MinWidth = 260 };
                var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
                row.Children.Add(code);
                row.Children.Add(Action("Continue", () => account.SubmitCode(code.Text)));
                stack.Children.Add(row);
            }
        }
        stack.Children.Add(Fluent.Label($"Uses your {account.Cli.PlanName()} plan through {account.Cli.ToolName()}, with no API key or API billing. Requests take a few seconds longer to start.",
            12, Fluent.Secondary, wrap: true));
        return stack;
    }

    private IEnumerable<UIElement> ApiKeyRows(AIProviderKind provider)
    {
        var hasKey = _services.Keys.Read(provider.KeychainAccount()) is not null;
        if (hasKey)
        {
            yield return Row("Provider", Choice(AIProviders.ApiProviders, provider, p => p.Title(), p => { S.AIProvider = p; Save(); RefreshTab("AI"); }));
            var keyControls = new StackPanel { Orientation = Orientation.Horizontal };
            keyControls.Children.Add(Fluent.Label("Stored in Credential Manager", 13, Fluent.Secondary));
            keyControls.Children.Add(Action("Remove", () => { _services.Keys.Delete(provider.KeychainAccount()); RefreshTab("AI"); }));
            yield return Row("API key", keyControls);
        }
        else
        {
            var box = new PasswordBox { MinWidth = 300 };
            var status = Fluent.Label("Works with Anthropic, OpenAI, Google Gemini, DeepSeek, Groq, xAI, Mistral and OpenRouter — the provider is detected from the key.",
                12, Fluent.Secondary, wrap: true);
            var connect = Action("Connect", async () =>
            {
                var key = box.Password.Trim();
                if (key.Length == 0) return;
                status.Text = "Checking the key…";
                var detected = await ApiKeyDetector.IdentifyAsync(key, _services.Models);
                if (detected is { } p) SaveKey(key, p);
                else status.Text = ApiKeyDetector.Candidates(key).Count == 0
                    ? "Couldn't tell which provider this key is for — choose it under Provider and connect again."
                    : "The key was rejected. Check it, or choose the provider manually.";
            }, accent: true);
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            controls.Children.Add(box);
            controls.Children.Add(connect);
            yield return Row("API key", controls);
            yield return status;
            yield return Row("Provider (if not detected)", Choice(AIProviders.ApiProviders, provider, p => p.Title(), p =>
            {
                S.AIProvider = p;
                Save();
                if (box.Password.Trim().Length > 0 && p != AIProviderKind.Custom) SaveKey(box.Password.Trim(), p);
            }));
        }
        if (provider == AIProviderKind.Custom)
        {
            var url = new TextBox { Text = S.CustomBaseUrl, MinWidth = 300 };
            url.LostFocus += (_, _) => { S.CustomBaseUrl = url.Text.Trim(); Save(); };
            yield return Row("Base URL", url);
        }
    }

    private void SaveKey(string key, AIProviderKind provider)
    {
        _services.Keys.Save(provider.KeychainAccount(), key, $"Clipboard2 – {provider.Title()} API key");
        S.AIProvider = provider;
        if (!S.AIModels.ContainsKey(provider.ToString()))
        {
            if (provider.DefaultModel().Length > 0) S.AIModel = provider.DefaultModel();
            else
            {
                _ = Task.Run(async () =>
                {
                    try
                    {
                        var models = await _services.Models.FetchAsync(provider, S.CustomBaseUrl);
                        if (ModelLister.PreferredModel(models, provider) is { } pick)
                            Dispatcher.Invoke(() => { S.AIModel = pick; Save(); RefreshTab("AI"); });
                    }
                    catch { }
                });
            }
        }
        Save();
        RefreshTab("AI");
    }

    // MARK: Sync

    // Form state survives page rebuilds (the page rebuilds on every account change).
    private string _syncEmail = "";
    private string _syncUsername = "";
    private string _syncPassword = "";
    private string _syncConfirm = "";
    private string _syncInvite = "";
    private bool _syncCreating;
    private bool _syncUnderstood;

    private UIElement BuildSync()
    {
        var page = Page();
        var sync = _services.Sync;
        if (sync.Email is { Length: > 0 } known && _syncEmail.Length == 0) _syncEmail = known;
        page.Children.Add(Header("Sync"));

        if (sync.Status is { } status) page.Children.Add(Card(Fluent.Label(status, 13, sync.IsBusy ? Fluent.Secondary : Fluent.Accent, wrap: true)));
        if (sync.Error is { } error && sync.Phase != SyncPhase.SignedIn)
            page.Children.Add(Card(Fluent.Label(error, 13, Brushes.OrangeRed, wrap: true)));

        switch (sync.Phase)
        {
            case SyncPhase.SignedOut: BuildSyncSignedOut(page, sync); break;
            case SyncPhase.NeedsSignIn: BuildSyncSignIn(page, sync, again: true); break;
            default: BuildSyncSignedIn(page, sync); break;
        }

        page.Children.Add(Header("Advanced"));
        var server = new TextBox { Text = S.SyncApiBaseUrl ?? "", MinWidth = 300 };
        server.LostFocus += (_, _) =>
        {
            var value = server.Text.Trim();
            S.SyncApiBaseUrl = value.Length == 0 ? null : value;
            Save();
        };
        page.Children.Add(Card(Row("Sync server (leave empty for the default)", server)));
        page.Children.Add(Hint($"Default: {SyncConfig.DefaultApiBaseUrl}. Only change this for testing."));
        return page;
    }

    private const string WhatSyncs =
        "End-to-end encrypted: your history (newest 200 items), images, pinned items, snippets and secrets are encrypted on this PC before upload. " +
        "Your password never leaves this PC. The server only sees your email, sizes and timestamps — never your content, snippet names, secret values or group names.";

    private void SyncCredentialFields(List<UIElement> rows, bool emailEditable = true, bool withUsername = false)
    {
        var email = new TextBox { Text = _syncEmail, MinWidth = 280, IsReadOnly = !emailEditable };
        email.TextChanged += (_, _) => _syncEmail = email.Text;
        var password = new PasswordBox { MinWidth = 280, Password = _syncPassword };
        password.PasswordChanged += (_, _) => _syncPassword = password.Password;
        rows.Add(Row("Email", email));
        if (withUsername)
        {
            var username = new TextBox { Text = _syncUsername, MinWidth = 280, MaxLength = 64 };
            username.TextChanged += (_, _) => _syncUsername = username.Text;
            rows.Add(Row("Username", username));
        }
        rows.Add(Row("Password", password));
    }

    private void ClearSyncPasswords()
    {
        _syncPassword = "";
        _syncConfirm = "";
        _syncUnderstood = false;
    }

    private void BuildSyncSignedOut(StackPanel page, SyncAccount sync)
    {
        page.Children.Add(Card(Fluent.Label(WhatSyncs, 13, null, wrap: true)));
        var modes = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 10) };
        foreach (var (title, creating) in new[] { ("Sign in", false), ("Create account", true) })
        {
            var radio = new RadioButton { Content = title, IsChecked = _syncCreating == creating, GroupName = "syncmode", Margin = new Thickness(0, 0, 18, 0) };
            radio.Checked += (_, _) => { _syncCreating = creating; RefreshTab("Sync"); };
            modes.Children.Add(radio);
        }
        page.Children.Add(modes);
        if (_syncCreating) BuildSyncCreate(page, sync); else BuildSyncSignIn(page, sync, again: false);
    }

    private void BuildSyncCreate(StackPanel page, SyncAccount sync)
    {
        var rows = new List<UIElement>();
        var invite = new TextBox { Text = _syncInvite, MinWidth = 280, MaxLength = 64, FontFamily = new FontFamily("Cascadia Mono, Consolas") };
        invite.TextChanged += (_, _) => _syncInvite = invite.Text;
        rows.Add(Row("Invite code", invite));
        SyncCredentialFields(rows, withUsername: true);
        var confirm = new PasswordBox { MinWidth = 280, Password = _syncConfirm };
        confirm.PasswordChanged += (_, _) => _syncConfirm = confirm.Password;
        rows.Add(Row("Confirm password", confirm));
        var warning = Fluent.Label("There is no password recovery. Your password is the only key to your synced data, and it never leaves your devices — " +
            "nobody, including Clipboard2, can reset it. If you forget it, your synced data is lost for good. Write it down or keep it in a password manager.",
            13, Brushes.OrangeRed, wrap: true);
        warning.FontWeight = FontWeights.SemiBold;
        rows.Add(warning);
        var understood = new CheckBox { Content = "I understand: a forgotten password means my synced data is lost", IsChecked = _syncUnderstood };
        understood.Checked += (_, _) => _syncUnderstood = true;
        understood.Unchecked += (_, _) => _syncUnderstood = false;
        rows.Add(understood);
        rows.Add(PrivacyNoticeLink());
        var create = Action("Create Account", async () =>
        {
            if (!_syncUnderstood) { MessageBox.Show(this, "Please confirm that you understand there's no password recovery.", "Create Account"); return; }
            if (SyncAccount.UsernameProblem(SyncAccount.NormalizeUsername(_syncUsername)) is { } problem) { MessageBox.Show(this, problem, "Create Account"); return; }
            if (await _services.Sync.CreateAccountAsync(_syncEmail, _syncUsername, _syncPassword, _syncConfirm, _syncInvite))
            {
                ClearSyncPasswords();
                _syncInvite = "";
            }
        }, accent: true);
        create.IsEnabled = !sync.IsBusy;
        rows.Add(Row("", create));
        page.Children.Add(Card([.. rows]));
        page.Children.Add(Hint("Sync is invite-only. Enter the code someone gave you: an invite to Clipboard2, or to their group (you join it right away). " +
            $"Use at least {SyncAccount.MinPasswordLength} characters — a passphrase of a few words is best. Your email is only your sign-in name; it isn't verified and gets no mail. " +
            $"Your username is shown to people in your groups on the items you share. {SyncAccount.UsernameRule}"));
    }

    private void BuildSyncSignIn(StackPanel page, SyncAccount sync, bool again)
    {
        var rows = new List<UIElement>();
        if (again)
            rows.Add(Fluent.Label("Your session ended — it expired, or the password was changed on another device. Enter your password to keep syncing. " +
                "Everything on this PC stays as it is.", 13, null, wrap: true));
        SyncCredentialFields(rows, emailEditable: !again);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal };
        if (again)
            buttons.Children.Add(Action("Sign Out…", async () =>
            {
                if (MessageBox.Show(this, "Sign out of sync on this PC? Group items are removed from this PC; your personal history stays.",
                        "Sign Out", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
                    await _services.Sync.SignOutAsync();
            }));
        var signIn = Action(again ? "Continue" : "Sign In", async () =>
        {
            if (await _services.Sync.SignInAsync(_syncEmail, _syncPassword)) ClearSyncPasswords();
        }, accent: true);
        signIn.IsEnabled = !sync.IsBusy;
        buttons.Children.Add(signIn);
        rows.Add(Row("", buttons));
        page.Children.Add(Card([.. rows]));
        if (!again) page.Children.Add(Hint("Forgot your password? It can't be reset — that's what keeps your data private. You can delete the account from a device that's still signed in and start a new one."));
    }

    private static StackPanel Buttons(params Button[] buttons)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var b in buttons) panel.Children.Add(b);
        return panel;
    }

    private void BuildSyncSignedIn(StackPanel page, SyncAccount sync)
    {
        var state = sync.IsSyncing ? "Syncing…"
            : sync.RetryAfter is { } retry && retry > DateTime.UtcNow ? $"Paused until {retry.ToLocalTime():t} (server busy)"
            : sync.CurrentStatus == SyncStatus.Offline ? "Offline — " + (sync.Error ?? "the sync server can't be reached.")
            : sync.Error is { } error ? error
            : sync.LastSync is { } last ? $"Up to date · synced {last.ToLocalTime():t}" : "Not synced yet";
        var statusLabel = Fluent.Label(state, 13, sync.Error is null ? Fluent.Secondary : Brushes.OrangeRed, wrap: true);
        statusLabel.MaxWidth = 380;
        var syncNow = Action("Sync Now", () => _ = _services.Sync.SyncNowAsync(), accent: true);
        syncNow.IsEnabled = !sync.IsSyncing;
        var rows = new List<UIElement>
        {
            Row("Account", Fluent.Label(sync.Email ?? "", 13, Fluent.Secondary)),
            Row("Username", UsernameControls(sync)),
            Row("Status", statusLabel),
        };
        if (sync.Username is null)
            rows.Add(Fluent.Label("Set a username so people in your groups see who copied each item. Until then they see the group's name.", 12, Fluent.Accent, wrap: true));
        foreach (var warning in sync.Warnings.Distinct()) rows.Add(Fluent.Label(warning, 12, Brushes.OrangeRed, wrap: true));
        rows.Add(Row("", syncNow));
        page.Children.Add(Card([.. rows]));
        page.Children.Add(Hint(WhatSyncs));

        // Groups
        page.Children.Add(Header("Groups"));
        var groups = sync.Groups;
        var groupRows = new List<UIElement>();
        foreach (var group in groups)
        {
            var id = group.Id;
            var name = group.DisplayName;
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            controls.Children.Add(Fluent.Label($"{(group.IsOwner ? "Owner" : "Member")} · {group.MemberCount} {(group.MemberCount == 1 ? "member" : "members")}  ", 12, Fluent.Secondary));
            controls.Children.Add(Action("Members…", () => ShowMembers(group)));
            if (group.IsOwner)
            {
                controls.Children.Add(Action("Invite…", async () =>
                {
                    if (await sync.CreateInviteAsync(id) is { } code) ShowInviteCode(name, code);
                    else if (sync.Error is { } e) MessageBox.Show(this, e, "Invite");
                }));
                controls.Children.Add(Action("Rename…", async () =>
                {
                    if (InputDialog.Ask("Rename Group", "New name:", name) is { Length: > 0 } newName) await sync.RenameGroupAsync(id, newName);
                }));
                controls.Children.Add(Action("Delete…", async () =>
                {
                    if (MessageBox.Show(this, $"Delete “{name}” for everyone? Its items, snippets and secrets are removed from the server and from every member's devices.",
                            "Delete Group", MessageBoxButton.OKCancel, MessageBoxImage.Warning) == MessageBoxResult.OK)
                        await sync.DeleteGroupAsync(id);
                }));
            }
            else
            {
                controls.Children.Add(Action("Leave…", async () =>
                {
                    if (MessageBox.Show(this, $"Leave “{name}”? Its items are removed from this PC.", "Leave Group",
                            MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
                        await sync.LeaveGroupAsync(id);
                }));
            }
            groupRows.Add(Row(name, controls));
        }
        if (groupRows.Count == 0) groupRows.Add(Fluent.Label("No groups yet. A group shares items with other people: everyone in it can see and add items.", 13, Fluent.Secondary, wrap: true));
        groupRows.Add(Buttons(
            Action("New Group…", async () =>
            {
                if (InputDialog.Ask("New Group", "Name (only members can read it):", okTitle: "Create") is { Length: > 0 } groupName) await sync.CreateGroupAsync(groupName);
            }),
            Action("Join a Group…", JoinGroup)));
        if (sync.Error is { } groupError && !sync.IsSyncing && sync.LastSync is not null)
            groupRows.Add(Fluent.Label(groupError, 12, Brushes.OrangeRed, wrap: true));
        page.Children.Add(Card([.. groupRows]));
        if (groups.Count > 0)
        {
            var hotkey = S.Hotkeys.GetValueOrDefault(Hotkey.SendToGroup) is { Length: > 0 } combo ? combo : "the Send to group shortcut";
            page.Children.Add(Card(Row("Default group", Choice(groups, sync.DefaultGroup ?? groups[0], g => g.DisplayName, g => sync.SetDefaultGroup(g.Id)))));
            page.Children.Add(Hint($"Select text anywhere and press {hotkey} to send it to the default group. Share any item with Ctrl+K → Share to Group, or right-click it."));
        }

        // Invite someone to Clipboard2 (sign-up codes)
        page.Children.Add(Header("Invite Someone"));
        page.Children.Add(Card(Row("", Buttons(
            Action("Create an Invite Code…", async () =>
            {
                if (await sync.CreateSignupCodeAsync() is { } code) ShowSignupCode(code);
                else if (sync.Error is { } e) MessageBox.Show(this, e, "Invite Someone");
            }),
            Action("Open Invites…", ShowSignupCodes)))));
        page.Children.Add(Hint("Sync is invite-only. A code lets one person create an account; it works once and expires in 14 days. " +
            "To share a group with someone, use Invite… next to the group instead — that code also works for signing up."));

        // Devices
        page.Children.Add(Header("Devices"));
        var deviceRows = new List<UIElement>();
        foreach (var device in sync.Devices)
        {
            var id = device.Id;
            var label = $"{device.Name}{(device.IsCurrent ? " (this PC)" : "")}";
            var controls = new StackPanel { Orientation = Orientation.Horizontal };
            controls.Children.Add(Fluent.Label($"Last used {device.LastUsedAt.ToLocalTime():g}  ", 12, Fluent.Secondary));
            controls.Children.Add(Action("Sign Out…", async () =>
            {
                var question = device.IsCurrent
                    ? "Sign out of sync on this PC? Group items are removed from this PC; your personal history stays."
                    : $"Sign out “{device.Name}”? It stops syncing until someone signs in there again.";
                if (MessageBox.Show(this, question, "Sign Out Device", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
                if (!await sync.SignOutDeviceAsync(id) && sync.Error is { } e) MessageBox.Show(this, e, "Sign Out Device");
            }));
            deviceRows.Add(Row(label, controls));
        }
        if (deviceRows.Count == 0) deviceRows.Add(Fluent.Label("No devices listed yet. Refresh to load them.", 13, Fluent.Secondary));
        deviceRows.Add(Row("", Action("Refresh", () => _ = sync.RefreshDevicesAsync())));
        page.Children.Add(Card([.. deviceRows]));
        page.Children.Add(Hint("Every PC and Mac signed in to your account. An item sent to this PC from another device appears at the top, with a notice."));

        // Account
        page.Children.Add(Header("Account"));
        page.Children.Add(Card(Row("", Buttons(
            Action("Change Password…", async () =>
            {
                if (InputDialog.Ask("Change Password", "Current password:", secret: true) is not { Length: > 0 } current) return;
                if (InputDialog.Ask("Change Password", $"New password (at least {SyncAccount.MinPasswordLength} characters). There's no recovery — don't lose it:", secret: true) is not { Length: > 0 } next) return;
                if (InputDialog.Ask("Change Password", "New password again:", secret: true) is not { } confirm) return;
                if (!await sync.ChangePasswordAsync(current, next, confirm) && sync.Error is { } e) MessageBox.Show(this, e, "Change Password");
            }),
            Action("Sign Out…", async () =>
            {
                if (MessageBox.Show(this, "Sign out of sync on this PC? Group items are removed from this PC; your personal history stays.",
                        "Sign Out", MessageBoxButton.OKCancel, MessageBoxImage.Question) == MessageBoxResult.OK)
                    await sync.SignOutAsync();
            }),
            Action("Delete Account…", async () =>
            {
                if (MessageBox.Show(this, "Delete your sync account? Everything synced — your personal space and the groups you own — is deleted from the server for good. " +
                        "Items on this PC stay.", "Delete Account", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
                if (InputDialog.Ask("Delete Account", "Enter your password to confirm:", secret: true, okTitle: "Delete") is not { Length: > 0 } password) return;
                if (!await sync.DeleteAccountAsync(password) && sync.Error is { } e) MessageBox.Show(this, e, "Delete Account");
            })))));
        page.Children.Add(Hint("Changing your password keeps your synced data; other devices ask for the new one. Your keys are stored in Windows Credential Manager."));
    }

    /// <summary>The username with a Change button, or a prominent "Set a username" for accounts made before usernames.</summary>
    private StackPanel UsernameControls(SyncAccount sync)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        if (sync.Username is { } name) panel.Children.Add(Fluent.Label(name + "  ", 13, Fluent.Secondary));
        var button = Action(sync.Username is null ? "Set a Username…" : "Change…", async () =>
        {
            var title = sync.Username is null ? "Set a Username" : "Change Username";
            if (InputDialog.Ask(title, "Shown to people in your groups on the items you copy. " + SyncAccount.UsernameRule, sync.Username ?? "", okTitle: "Save")
                is not { Length: > 0 } typed) return;
            if (!await sync.ChangeUsernameAsync(typed) && sync.Error is { } e) MessageBox.Show(this, e, title);
        }, accent: sync.Username is null);
        button.IsEnabled = !sync.IsBusy;
        panel.Children.Add(button);
        return panel;
    }

    private async void JoinGroup()
    {
        var sync = _services.Sync;
        if (InputDialog.Ask("Join a Group", "Paste the invite code you were given (like ABCD-EFGH-…):", okTitle: "Continue") is not { Length: > 0 } code) return;
        if (await sync.PreviewInviteAsync(code) is not { } invite)
        {
            MessageBox.Show(this, sync.Error ?? "That code didn't work.", "Join a Group");
            return;
        }
        var members = invite.MemberCount == 1 ? "1 member" : $"{invite.MemberCount} members";
        if (MessageBox.Show(this, $"Join “{invite.Name}” ({members})? Everyone in it can see and add items.", "Join a Group",
                MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        if (!await sync.JoinAsync(invite) && sync.Error is { } e) MessageBox.Show(this, e, "Join a Group");
    }

    /// <summary>The code is shown once; only its hash is on the server.</summary>
    private void ShowInviteCode(string groupName, string code)
    {
        var window = new Window
        {
            Title = $"Invite to {groupName}", Width = 460, SizeToContent = SizeToContent.Height, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
        };
        var stack = new StackPanel { Margin = new Thickness(20) };
        stack.Children.Add(Fluent.Label("Send this code to the person you want to invite. They choose Settings → Sync → Join a Group and paste it.", 13, null, wrap: true));
        var box = new TextBox
        {
            Text = code, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 20,
            HorizontalContentAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 10),
        };
        stack.Children.Add(box);
        stack.Children.Add(Fluent.Label("It works once and expires in 7 days. You won't see it again — anyone with the code can join, so share it privately.",
            12, Fluent.Secondary, wrap: true));
        // Copied like a secret: kept out of the history (and so out of sync) and out of Win+V.
        var copy = Action("Copy", () => ClipboardIO.WriteSecret(code), accent: true);
        var close = Action("Done", window.Close);
        var buttons = Buttons(copy, close);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 14, 0, 0);
        stack.Children.Add(buttons);
        window.Content = stack;
        window.ShowDialog();
    }

    /// <summary>A sign-up code, shown once (only its hash is on the server).</summary>
    private void ShowSignupCode(string code)
    {
        var window = new Window
        {
            Title = "Invite Someone", Width = 460, SizeToContent = SizeToContent.Height, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
        };
        var stack = new StackPanel { Margin = new Thickness(20) };
        stack.Children.Add(Fluent.Label("Send this code to the person you want to invite. They enter it as the invite code when they create their sync account.", 13, null, wrap: true));
        stack.Children.Add(new TextBox
        {
            Text = code, IsReadOnly = true, FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 20,
            HorizontalContentAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 14, 0, 10),
        });
        stack.Children.Add(Fluent.Label("It works once and expires in 14 days. You won't see it again; you can revoke it under Open Invites.", 12, Fluent.Secondary, wrap: true));
        // Copied like a secret: kept out of the history (and so out of sync) and out of Win+V.
        var buttons = Buttons(Action("Copy", () => ClipboardIO.WriteSecret(code), accent: true), Action("Done", window.Close));
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 14, 0, 0);
        stack.Children.Add(buttons);
        window.Content = stack;
        window.ShowDialog();
    }

    /// <summary>Open (unused) sign-up codes, each with Revoke.</summary>
    private async void ShowSignupCodes()
    {
        var sync = _services.Sync;
        var window = new Window
        {
            Title = "Open Invites", Width = 460, SizeToContent = SizeToContent.Height, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
        };
        var list = new StackPanel { Margin = new Thickness(20) };
        list.Children.Add(Fluent.Label("Loading…", 13, Fluent.Secondary));
        window.Content = list;
        window.Show();

        async Task Fill()
        {
            var codes = await sync.SignupCodesAsync();
            list.Children.Clear();
            foreach (var code in codes)
            {
                var row = new DockPanel { LastChildFill = false, MinHeight = 30 };
                row.Children.Add(Fluent.Label($"Created {SyncPayload.FromMillis(code.CreatedAt).ToLocalTime():g} · expires {SyncPayload.FromMillis(code.ExpiresAt).ToLocalTime():g}", 12, Fluent.Secondary));
                var id = code.Id;
                var revoke = Action("Revoke", async () =>
                {
                    await sync.RevokeSignupCodeAsync(id);
                    await Fill();
                });
                DockPanel.SetDock(revoke, Dock.Right);
                row.Children.Add(revoke);
                list.Children.Add(row);
            }
            if (codes.Count == 0) list.Children.Add(Fluent.Label(sync.Error ?? "No open invites.", 13, Fluent.Secondary, wrap: true));
            list.Children.Add(new Border { Height = 10 });
            list.Children.Add(Fluent.Label("Codes that were used or expired aren't listed. You can have up to 10 open at once.", 12, Fluent.Secondary, wrap: true));
        }
        await Fill();
    }

    private async void ShowMembers(SpaceRecord group)
    {
        var sync = _services.Sync;
        var window = new Window
        {
            Title = $"Members of {group.DisplayName}", Width = 480, SizeToContent = SizeToContent.Height, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize,
        };
        var list = new StackPanel { Margin = new Thickness(20) };
        list.Children.Add(Fluent.Label("Loading…", 13, Fluent.Secondary));
        window.Content = list;
        window.Show();

        async Task Fill()
        {
            var members = await sync.MembersAsync(group.Id);
            list.Children.Clear();
            foreach (var member in members)
            {
                var row = new DockPanel { LastChildFill = false, MinHeight = 32 };
                row.Children.Add(Fluent.Label(member.Name + (member.Role == "owner" ? "  (owner)" : "") + (member.Uid == sync.Uid ? "  — you" : ""), 13));
                if (group.IsOwner && member.Role != "owner")
                {
                    var uid = member.Uid;
                    var remove = Action("Remove", async () =>
                    {
                        if (MessageBox.Show(window, $"Remove {member.Name} from the group? They keep anything they already copied.", "Remove Member",
                                MessageBoxButton.OKCancel) != MessageBoxResult.OK) return;
                        await sync.RemoveMemberAsync(group.Id, uid);
                        await Fill();
                    });
                    DockPanel.SetDock(remove, Dock.Right);
                    row.Children.Add(remove);
                }
                list.Children.Add(row);
            }
            if (members.Count == 0) list.Children.Add(Fluent.Label(sync.Error ?? "No members found.", 13, Fluent.Secondary, wrap: true));

            if (group.IsOwner)
            {
                var invites = await sync.InvitesAsync(group.Id);
                var header = Fluent.Label("Pending invites", 13, null, FontWeights.SemiBold);
                header.Margin = new Thickness(0, 14, 0, 4);
                list.Children.Add(header);
                foreach (var invite in invites)
                {
                    var row = new DockPanel { LastChildFill = false, MinHeight = 30 };
                    row.Children.Add(Fluent.Label($"Created {SyncPayload.FromMillis(invite.CreatedAt).ToLocalTime():g} · expires {SyncPayload.FromMillis(invite.ExpiresAt).ToLocalTime():g}", 12, Fluent.Secondary));
                    var inviteId = invite.InviteId;
                    var revoke = Action("Revoke", async () =>
                    {
                        await sync.RevokeInviteAsync(group.Id, inviteId);
                        await Fill();
                    });
                    DockPanel.SetDock(revoke, Dock.Right);
                    row.Children.Add(revoke);
                    list.Children.Add(row);
                }
                if (invites.Count == 0) list.Children.Add(Fluent.Label("None.", 12, Fluent.Secondary));
            }
            list.Children.Add(new Border { Height = 10 });
            list.Children.Add(Fluent.Label("Members can read and add items. Removing someone ends their access on the server; " +
                "the group key isn't rotated.", 12, Fluent.Secondary, wrap: true));
        }
        await Fill();
    }

    // MARK: About

    private UIElement BuildAbout()
    {
        var page = Page();
        var top = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 16) };
        top.Children.Add(new Image { Source = Icons.AppIcon, Width = 88, Height = 88 });
        var title = Fluent.Label("Clipboard2", 22, null, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        top.Children.Add(title);
        var version = Fluent.Label($"Version {_services.Updates.CurrentVersion}", 13, Fluent.Secondary);
        version.HorizontalAlignment = HorizontalAlignment.Center;
        top.Children.Add(version);
        page.Children.Add(top);

        page.Children.Add(Header("Updates"));
        var updates = _services.Updates;
        var status = updates.AvailableVersion is { } v ? $"Version {v} is available"
            : !updates.IsInstalled ? "Updates work in the installed app"
            : updates.LastError is { } error ? $"Last check failed: {error}"
            : updates.LastCheck is { } last ? $"Up to date (checked {last:t})" : "Not checked yet";
        var actions = new StackPanel { Orientation = Orientation.Horizontal };
        actions.Children.Add(Fluent.Label(status, 13, updates.AvailableVersion is null ? Fluent.Secondary : Fluent.Accent));
        actions.Children.Add(updates.AvailableVersion is null
            ? Action("Check for Updates", async () => { await updates.CheckAsync(); RefreshTab("About"); })
            : Action("Update and Restart", async () => await updates.InstallAsync(), accent: true));
        page.Children.Add(Card(
            Row("Check for updates every hour", Toggle(S.CheckForUpdates, on => { S.CheckForUpdates = on; Save(); })),
            Row("Install updates automatically", Toggle(S.InstallUpdatesAutomatically, on => { S.InstallUpdatesAutomatically = on; Save(); })),
            actions));
        page.Children.Add(Hint("Updates come from GitHub and install in place — Clipboard2 restarts with your data intact."));

        page.Children.Add(Header("Data"));
        page.Children.Add(Card(
            Row("History and images", Action("Open Folder", () => Process.Start(new ProcessStartInfo(AppServices.DataDirectory) { UseShellExecute = true }))),
            Row("Settings", Action("Open Folder", () => Process.Start(new ProcessStartInfo(Path.GetDirectoryName(AppServices.SettingsPath)!) { UseShellExecute = true })))));
        AddLegalSection(page);
        return page;
    }
}
