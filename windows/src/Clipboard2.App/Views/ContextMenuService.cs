using System;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Interop;
using System.Windows.Media;
using Clipboard2.App.Platform;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

/// <summary>
/// Ctrl+right-click anywhere opens Clipboard2's menu: its actions, the usual edit items (File
/// Explorer items in Explorer), and "Show app menu" for the app's own menu. Windows has no API to
/// add items to other apps' menus, so a low-level mouse hook swallows only the modified
/// right-click; plain right-clicks pass straight through.
/// </summary>
public sealed class ContextMenuService : IDisposable
{
    public static ContextMenuService? Shared { get; private set; }
    private readonly AppServices _services;
    private readonly Native.LowLevelProc _proc;   // kept alive for the hook
    private IntPtr _hook;
    private bool _swallowNextUp;
    private Native.POINT _location;
    private IntPtr _target;
    private Window? _host;

    public ContextMenuService(AppServices services)
    {
        _services = services;
        _proc = HookProc;
        Shared = this;
    }

    public void Update()
    {
        if (_services.Settings.ContextMenuEnabled && _hook == IntPtr.Zero)
            _hook = Native.SetWindowsHookEx(Native.WH_MOUSE_LL, _proc, Native.GetModuleHandle(null), 0);
        else if (!_services.Settings.ContextMenuEnabled && _hook != IntPtr.Zero)
        {
            Native.UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
    }

    private bool ModifierHeld()
    {
        var ctrl = Native.IsDown(Native.VK_CONTROL);
        var alt = Native.IsDown(Native.VK_MENU);
        var shift = Native.IsDown(Native.VK_SHIFT);
        return _services.Settings.ContextMenuModifier == ContextMenuModifier.Control ? ctrl && !alt && !shift : alt && !ctrl && !shift;
    }

    private IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code >= 0)
        {
            var message = wParam.ToInt32();
            var data = Marshal.PtrToStructure<Native.MSLLHOOKSTRUCT>(lParam);
            var synthetic = data.dwExtraInfo == Native.SyntheticMarker;
            if (message == Native.WM_RBUTTONDOWN && !synthetic && ModifierHeld())
            {
                _swallowNextUp = true;
                _location = data.pt;
                _target = Native.GetAncestor(Native.WindowFromPoint(data.pt), 2);   // GA_ROOT
                _services.Dispatcher.BeginInvoke(ShowMenu);
                return new IntPtr(1);
            }
            if (message == Native.WM_RBUTTONUP && _swallowNextUp && !synthetic)
            {
                _swallowNextUp = false;
                return new IntPtr(1);
            }
        }
        return Native.CallNextHookEx(_hook, code, wParam, lParam);
    }

    private bool IsExplorer()
    {
        Native.GetWindowThreadProcessId(_target, out var pid);
        return Path.GetFileName(Native.ProcessPath(pid)).Equals("explorer.exe", StringComparison.OrdinalIgnoreCase);
    }

    private async void ShowMenu()
    {
        try
        {
            var explorer = IsExplorer();
            if (explorer)
            {
                // A real right-click selects the item under the pointer; do the same first.
                InputSender.Click(_location);
                await Task.Delay(80);
            }
            _services.Sync.ReportActivity();
            var menu = Build(explorer);
            _host ??= CreateHost();
            Native.SetWindowPos(new WindowInteropHelper(_host).EnsureHandle(), IntPtr.Zero, _location.X, _location.Y, 1, 1, Native.SWP_NOZORDER);
            _host.Show();
            _host.Activate();
            menu.PlacementTarget = _host;
            menu.Placement = PlacementMode.Relative;
            menu.Closed += (_, _) => _host?.Hide();
            menu.IsOpen = true;
        }
        catch (Exception ex)
        {
            Log.Error("Showing the right-click menu failed", ex);
        }
    }

    private static Window CreateHost() => new()
    {
        Width = 1, Height = 1, WindowStyle = WindowStyle.None, AllowsTransparency = true, Background = Brushes.Transparent,
        ShowInTaskbar = false, Topmost = true, ShowActivated = true, ResizeMode = ResizeMode.NoResize,
    };

    /// <summary>Runs an item after giving focus back to the app that was right-clicked.</summary>
    private void Do(Func<Task> work)
    {
        _services.Dispatcher.BeginInvoke(async () =>
        {
            _host?.Hide();
            await InputSender.ReleaseModifiersAsync();
            Native.ForceForeground(_target);
            await Task.Delay(120);
            try { await work(); } catch (Exception ex) { Log.Error("Right-click menu action failed", ex); }
        });
    }

    private void Keys(params int[] keys) => Do(() => { InputSender.Chord(keys); return Task.CompletedTask; });

    private ContextMenu Build(bool explorer)
    {
        var menu = new ContextMenu();
        MenuItem Item(string header, string glyph, Action action, string? gesture = null, bool enabled = true)
        {
            var item = new MenuItem { Header = header, Icon = Glyphs.Icon(glyph, 14), InputGestureText = gesture ?? "", IsEnabled = enabled };
            item.Click += (_, _) => action();
            return item;
        }
        // Every global shortcut is listed with its keys, as a reminder.
        string? ShortcutFor(string hotkey) => _services.Settings.Hotkeys.TryGetValue(hotkey, out var combo) && combo.Length > 0 ? combo : null;
        var heading = new MenuItem { Header = "Clipboard2", IsEnabled = false, FontWeight = FontWeights.SemiBold };
        menu.Items.Add(heading);
        menu.Items.Add(Item("Search Clipboard2…", Glyphs.Search, () => Do(() => { _services.ShowPanel(); return Task.CompletedTask; }), ShortcutFor(Hotkey.QuickPanel)));
        if (!explorer) menu.Items.Add(Item("Actions on Selection…", Glyphs.Sparkle, () => Do(_services.ShowSelectionActionsAsync), ShortcutFor(Hotkey.SelectionActions)));
        menu.Items.Add(Item("Paste Text from Clipboard Image", Glyphs.Image, () => Do(_services.PasteClipboardAsTextAsync), ShortcutFor(Hotkey.PasteAsText),
            enabled: ClipboardIO.CurrentImage() is not null));
        menu.Items.Add(Item("Capture Text from Screen…", Glyphs.Image, () => Do(_services.CaptureScreenTextAsync), ShortcutFor(Hotkey.CaptureText)));
        if (_services.Sync.IsSignedIn)
        {
            menu.Items.Add(Item("Send Selection to Group", Glyphs.Group, () => Do(_services.SendSelectionToGroupAsync), ShortcutFor(Hotkey.SendToGroup)));
            menu.Items.Add(Item("Paste from Group", Glyphs.Group, () => Do(_services.PasteFromGroupAsync), ShortcutFor(Hotkey.PasteFromGroup)));
            // One entry per other device: sends the selection, or the newest copy when nothing is selected.
            foreach (var device in _services.OtherDevices)
                menu.Items.Add(Item($"Send to {device.Name}", Glyphs.Cloud, () => Do(() => _services.SendSelectionToDeviceAsync(device))));
        }
        menu.Items.Add(Submenu("Recent", Glyphs.Clock, _services.Store.AllItems().Take(12).Select(item =>
            Item(item.DisplayTitle.Length > 60 ? item.DisplayTitle[..60] + "…" : item.DisplayTitle, item.IsPinned ? Glyphs.Pin : Glyphs.Text,
                () => Do(() => { _services.Paste(item, null); return Task.CompletedTask; })))));
        menu.Items.Add(Submenu("Snippets", Glyphs.Snippet, _services.Store.AllSnippets().Select(snippet =>
            Item(snippet.Name, Glyphs.Snippet, () => Do(() =>
            {
                var expansion = SnippetExpander.Expand(snippet.Body, null, _services.CurrentClipboardText());
                if (SnippetExpander.CustomFields(snippet.Body).Count > 0) { _services.ShowPanel(); _services.Panel.Activate(new PanelEntry.SnippetEntry(snippet)); }
                else _services.PasteText(expansion.Text, expansion.CursorOffsetFromEnd);
                return Task.CompletedTask;
            })))));
        menu.Items.Add(Submenu("Secrets", Glyphs.Key, _services.Secrets.All.Select(secret =>
            Item(secret.Name, Glyphs.Key, () => Do(() => { _services.PasteSecret(secret); return Task.CompletedTask; })))));
        var slots = Enumerable.Range(QuickSlots.First, QuickSlots.Last - QuickSlots.First + 1)
            .Select(n => (Number: n, Entry: _services.Panel.EntryForSlot(n)))
            .Where(s => s.Entry is not null)
            .Select(s => Item($"{s.Number} — {SlotTitle(s.Entry!)}", Glyphs.Pin,
                () => Do(() => { _services.PasteSlot(s.Number); return Task.CompletedTask; }), ShortcutFor(Hotkey.Slot(s.Number))))
            .ToList();
        if (slots.Count > 0) menu.Items.Add(Submenu("Quick Slots", Glyphs.Pin, slots));
        menu.Items.Add(new Separator());

        if (explorer)
        {
            menu.Items.Add(Item("Open", Glyphs.OpenWith, () => Keys(Native.VK_RETURN), "Enter"));
            menu.Items.Add(Item("Copy", Glyphs.Copy, () => Keys(Native.VK_CONTROL, 'C'), "Ctrl+C"));
            menu.Items.Add(Item("Copy as Path", Glyphs.Copy, () => Keys(Native.VK_CONTROL, Native.VK_SHIFT, 'C'), "Ctrl+Shift+C"));
            menu.Items.Add(Item("Paste", Glyphs.Paste, () => Keys(Native.VK_CONTROL, 'V'), "Ctrl+V"));
            menu.Items.Add(Item("Rename", Glyphs.Rename, () => Keys(Native.VK_F2), "F2"));
            menu.Items.Add(Item("Properties", Glyphs.Info, () => Keys(Native.VK_MENU, Native.VK_RETURN), "Alt+Enter"));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Delete", Glyphs.Delete, () => Keys(Native.VK_DELETE), "Delete"));
        }
        else
        {
            menu.Items.Add(Item("Cut", Glyphs.Cut, () => Keys(Native.VK_CONTROL, 'X'), "Ctrl+X"));
            menu.Items.Add(Item("Copy", Glyphs.Copy, () => Keys(Native.VK_CONTROL, 'C'), "Ctrl+C"));
            menu.Items.Add(Item("Paste", Glyphs.Paste, () => Keys(Native.VK_CONTROL, 'V'), "Ctrl+V"));
            menu.Items.Add(Item("Paste as Plain Text", Glyphs.Text, () => Do(_services.PasteClipboardAsTextAsync), ShortcutFor(Hotkey.PasteAsText)));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Select All", Glyphs.SelectAll, () => Keys(Native.VK_CONTROL, 'A'), "Ctrl+A"));
            var at = _location;
            menu.Items.Add(Item("Select Word", Glyphs.Text, () => Do(() => { InputSender.Click(at, count: 2); return Task.CompletedTask; })));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Undo", Glyphs.Undo, () => Keys(Native.VK_CONTROL, 'Z'), "Ctrl+Z"));
            menu.Items.Add(Item("Redo", Glyphs.Redo, () => Keys(Native.VK_CONTROL, 'Y'), "Ctrl+Y"));
        }
        menu.Items.Add(new Separator());
        Native.GetWindowThreadProcessId(_target, out var pid);
        var appName = ForegroundTracker.AppForProcess(pid)?.Name ?? "App";
        var location = _location;
        menu.Items.Add(Item($"Show {appName} Menu", Glyphs.Menu, () => Do(() => { InputSender.Click(location, right: true); return Task.CompletedTask; })));
        return menu;

        static string SlotTitle(PanelEntry entry)
        {
            var title = entry switch
            {
                PanelEntry.Clip c => c.Item.DisplayTitle,
                PanelEntry.SnippetEntry s => s.Snippet.Name,
                PanelEntry.SecretEntry k => k.Secret.Name,
                _ => "",
            };
            return title.Length > 50 ? title[..50] + "…" : title;
        }

        MenuItem Submenu(string header, string glyph, System.Collections.Generic.IEnumerable<MenuItem> items)
        {
            var parent = new MenuItem { Header = header, Icon = Glyphs.Icon(glyph, 14) };
            foreach (var item in items) parent.Items.Add(item);
            if (parent.Items.Count == 0) parent.Items.Add(new MenuItem { Header = "Nothing here yet", IsEnabled = false });
            return parent;
        }
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) Native.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }
}
