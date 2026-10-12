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
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App.Views;

/// <summary>Settings: General, Appearance, Ignored Apps, Snippets, Secrets, Transforms, AI, Sync, About.</summary>
public sealed class SettingsWindow : Window
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
        foreach (var name in new[] { Hotkey.QuickPanel, Hotkey.SelectionActions, Hotkey.PasteAsText, Hotkey.CaptureText })
            shortcuts.Add(HotkeyRow(name));
        page.Children.Add(Card([.. shortcuts]));
        page.Children.Add(Hint("Actions on selected text: select text in any app to transform it or ask AI; Enter replaces the selection. Paste as text pastes plain text — or the text inside an image or screenshot on the clipboard. Capture text: drag over anything on screen. Text recognition runs on this PC."));

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
        page.Children.Add(Hint("Values are stored only in Windows Credential Manager — never in history, never synced, never sent to AI or transforms."));

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
            stack.Children.Add(Fluent.Label("Finish signing in in your browser, then come back here.", 12, Fluent.Secondary));
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

    // MARK: Sync & About

    private static UIElement BuildSync()
    {
        var page = Page();
        page.Children.Add(Card(Fluent.Label("End-to-end encrypted sync of pinned items and snippets is planned. Your data stays on this PC until then.", 13, Fluent.Secondary, wrap: true)));
        return page;
    }

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
        return page;
    }
}
