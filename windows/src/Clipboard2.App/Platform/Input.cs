using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows.Input;
using System.Windows.Interop;
using Clipboard2.Core;

namespace Clipboard2.App.Platform;

/// <summary>Remembers the last window that wasn't Clipboard2 — pastes go there.</summary>
public sealed class ForegroundTracker : IDisposable
{
    private readonly Native.WinEventDelegate _callback;   // kept alive for the hook
    private readonly IntPtr _hook;
    private readonly uint _ownPid = (uint)Environment.ProcessId;
    public IntPtr LastExternalWindow { get; private set; }

    public ForegroundTracker()
    {
        _callback = OnForeground;
        _hook = Native.SetWinEventHook(Native.EVENT_SYSTEM_FOREGROUND, Native.EVENT_SYSTEM_FOREGROUND, IntPtr.Zero,
            _callback, 0, 0, Native.WINEVENT_OUTOFCONTEXT);
        var current = Native.GetForegroundWindow();
        if (!IsOwn(current)) LastExternalWindow = current;
    }

    /// <summary>Taskbar, tray overflow and Start aren't paste targets (clicking the tray focuses them).</summary>
    private static readonly HashSet<string> ShellClasses =
    [
        "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland",
        "Windows.UI.Core.CoreWindow", "XamlExplorerHostIslandWindow", "Progman", "WorkerW",
    ];

    private static bool IsShell(IntPtr hwnd)
    {
        var name = new System.Text.StringBuilder(256);
        return Native.GetClassName(hwnd, name, name.Capacity) > 0 && ShellClasses.Contains(name.ToString());
    }

    private void OnForeground(IntPtr hook, uint type, IntPtr hwnd, int obj, int child, uint thread, uint time)
    {
        if (hwnd != IntPtr.Zero && !IsOwn(hwnd) && !IsShell(hwnd)) LastExternalWindow = hwnd;
    }

    private bool IsOwn(IntPtr hwnd)
    {
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        return pid == _ownPid;
    }

    /// <summary>The window a paste should go to right now.</summary>
    public IntPtr TargetWindow
    {
        get
        {
            var front = Native.GetForegroundWindow();
            return front != IntPtr.Zero && !IsOwn(front) && !IsShell(front) ? front : LastExternalWindow;
        }
    }

    public AppRef? AppFor(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return null;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        return AppForProcess(pid);
    }

    public static AppRef? AppForProcess(uint pid)
    {
        var path = Native.ProcessPath(pid);
        if (path.Length == 0) return null;
        string name;
        try { name = FileVersionInfo.GetVersionInfo(path).FileDescription is { Length: > 0 } d ? d : Path.GetFileNameWithoutExtension(path); }
        catch { name = Path.GetFileNameWithoutExtension(path); }
        return new AppRef(path.ToLowerInvariant(), name);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) Native.UnhookWinEvent(_hook);
    }
}

/// <summary>Synthesises keystrokes and clicks (SendInput). No permission is needed on Windows,
/// except that apps running as administrator ignore input from non-elevated apps.</summary>
public static class InputSender
{
    private static Native.INPUT Key(ushort vk, bool up) => new()
    {
        type = Native.INPUT_KEYBOARD,
        u = new Native.InputUnion
        {
            ki = new Native.KEYBDINPUT
            {
                wVk = vk,
                dwFlags = (up ? Native.KEYEVENTF_KEYUP : 0) | (IsExtended(vk) ? Native.KEYEVENTF_EXTENDEDKEY : 0),
                dwExtraInfo = Native.SyntheticMarker,
            },
        },
    };

    private static bool IsExtended(ushort vk) => vk is 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x2D or 0x2E;

    /// <summary>Releases modifiers the user may still be holding from a global shortcut, so
    /// Ctrl+V doesn't arrive as Ctrl+Alt+Shift+V.</summary>
    public static async Task ReleaseModifiersAsync()
    {
        int[] modifiers = [Native.VK_LSHIFT, Native.VK_RSHIFT, Native.VK_LCONTROL, Native.VK_RCONTROL, Native.VK_LMENU, Native.VK_RMENU, Native.VK_LWIN, Native.VK_RWIN];
        for (var i = 0; i < 40 && Array.Exists(modifiers, Native.IsDown); i++) await Task.Delay(20);
        var ups = new List<Native.INPUT>();
        foreach (var vk in modifiers)
            if (Native.IsDown(vk)) ups.Add(Key((ushort)vk, up: true));
        if (ups.Count > 0) Send([.. ups]);
    }

    public static void Chord(params int[] keys)
    {
        var inputs = new List<Native.INPUT>();
        foreach (var k in keys) inputs.Add(Key((ushort)k, up: false));
        for (var i = keys.Length - 1; i >= 0; i--) inputs.Add(Key((ushort)keys[i], up: true));
        Send([.. inputs]);
    }

    public static void Press(int vk, int times = 1)
    {
        var inputs = new List<Native.INPUT>();
        for (var i = 0; i < times; i++)
        {
            inputs.Add(Key((ushort)vk, up: false));
            inputs.Add(Key((ushort)vk, up: true));
        }
        Send([.. inputs]);
    }

    public static void CtrlPlus(char letter) => Chord(Native.VK_CONTROL, char.ToUpperInvariant(letter));

    /// <summary>Clicks at a screen position (pixels). Marked so Clipboard2's mouse hook ignores it.</summary>
    public static void Click(Native.POINT at, bool right = false, int count = 1)
    {
        var left = Native.GetSystemMetrics(76);    // SM_XVIRTUALSCREEN
        var top = Native.GetSystemMetrics(77);
        var width = Math.Max(1, Native.GetSystemMetrics(78));
        var height = Math.Max(1, Native.GetSystemMetrics(79));
        var dx = (int)((at.X - left) * 65535.0 / (width - 1));
        var dy = (int)((at.Y - top) * 65535.0 / (height - 1));
        Native.INPUT Mouse(uint flags) => new()
        {
            type = Native.INPUT_MOUSE,
            u = new Native.InputUnion { mi = new Native.MOUSEINPUT { dx = dx, dy = dy, dwFlags = flags | Native.MOUSEEVENTF_ABSOLUTE | Native.MOUSEEVENTF_VIRTUALDESK, dwExtraInfo = Native.SyntheticMarker } },
        };
        var inputs = new List<Native.INPUT> { Mouse(Native.MOUSEEVENTF_MOVE) };
        for (var i = 0; i < count; i++)
        {
            inputs.Add(Mouse(right ? Native.MOUSEEVENTF_RIGHTDOWN : Native.MOUSEEVENTF_LEFTDOWN));
            inputs.Add(Mouse(right ? Native.MOUSEEVENTF_RIGHTUP : Native.MOUSEEVENTF_LEFTUP));
        }
        Send([.. inputs]);
    }

    private static void Send(Native.INPUT[] inputs) =>
        Native.SendInput((uint)inputs.Length, inputs, System.Runtime.InteropServices.Marshal.SizeOf<Native.INPUT>());
}

/// <summary>"Ctrl+Alt+Shift+V" ⇄ Win32 modifiers + virtual key.</summary>
public readonly record struct KeyCombo(uint Modifiers, Key Key)
{
    public static KeyCombo? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        uint mods = 0;
        Key? key = null;
        foreach (var raw in text.Split('+', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            switch (raw.ToLowerInvariant())
            {
                case "ctrl" or "control": mods |= Native.MOD_CONTROL; break;
                case "alt": mods |= Native.MOD_ALT; break;
                case "shift": mods |= Native.MOD_SHIFT; break;
                case "win": mods |= Native.MOD_WIN; break;
                default:
                    var name = raw.Length == 1 && char.IsDigit(raw[0]) ? "D" + raw : raw;
                    if (Enum.TryParse<Key>(name, ignoreCase: true, out var k)) key = k;
                    break;
            }
        }
        return key is { } found && mods != 0 ? new KeyCombo(mods, found) : null;
    }

    public override string ToString()
    {
        var parts = new List<string>();
        if ((Modifiers & Native.MOD_CONTROL) != 0) parts.Add("Ctrl");
        if ((Modifiers & Native.MOD_ALT) != 0) parts.Add("Alt");
        if ((Modifiers & Native.MOD_SHIFT) != 0) parts.Add("Shift");
        if ((Modifiers & Native.MOD_WIN) != 0) parts.Add("Win");
        var key = Key.ToString();
        parts.Add(key.Length == 2 && key[0] == 'D' && char.IsDigit(key[1]) ? key[1..] : key);
        return string.Join("+", parts);
    }

    public uint VirtualKey => (uint)KeyInterop.VirtualKeyFromKey(Key);
}

/// <summary>Global shortcuts via RegisterHotKey on a message-only window.</summary>
public sealed class HotkeyManager : IDisposable
{
    private readonly HwndSource _source;
    private readonly Dictionary<int, Action> _actions = [];
    private readonly Dictionary<string, int> _ids = [];
    private int _nextId = 1;
    /// <summary>Shortcut names that couldn't be registered (taken by another app).</summary>
    public HashSet<string> Failed { get; } = [];
    public bool Suspended { get; private set; }

    public HotkeyManager()
    {
        _source = new HwndSource(new HwndSourceParameters("Clipboard2Hotkeys") { ParentWindow = new IntPtr(-3) });   // HWND_MESSAGE
        _source.AddHook(WndProc);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == Native.WM_HOTKEY && !Suspended && _actions.TryGetValue(wParam.ToInt32(), out var action))
        {
            handled = true;
            action();
        }
        return IntPtr.Zero;
    }

    public void Register(string name, string? combo, Action action)
    {
        Unregister(name);
        Failed.Remove(name);
        if (KeyCombo.Parse(combo) is not { } parsed) return;
        var id = _nextId++;
        if (Native.RegisterHotKey(_source.Handle, id, parsed.Modifiers | Native.MOD_NOREPEAT, parsed.VirtualKey))
        {
            _actions[id] = action;
            _ids[name] = id;
        }
        else
        {
            Failed.Add(name);
            Log.Info($"Hotkey {combo} for {name} is taken by another app");
        }
    }

    public void Unregister(string name)
    {
        if (!_ids.Remove(name, out var id)) return;
        Native.UnregisterHotKey(_source.Handle, id);
        _actions.Remove(id);
    }

    /// <summary>While a shortcut field is being edited, shortcuts must not fire.</summary>
    public void Suspend(bool suspended) => Suspended = suspended;

    public void Dispose()
    {
        foreach (var id in _ids.Values) Native.UnregisterHotKey(_source.Handle, id);
        _source.Dispose();
    }
}

/// <summary>Minimal file log in %LOCALAPPDATA%\Clipboard2\clipboard2.log for support.</summary>
public static class Log
{
    private static readonly object Gate = new();
    public static string? FilePath { get; set; }

    public static void Info(string message) => Write("INFO", message);
    public static void Error(string message, Exception? ex = null) => Write("ERROR", ex is null ? message : $"{message}: {ex}");

    private static void Write(string level, string message)
    {
        if (FilePath is null) return;
        lock (Gate)
        {
            try
            {
                var info = new FileInfo(FilePath);
                if (info.Exists && info.Length > 2_000_000) info.Delete();
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {level} {message}{Environment.NewLine}");
            }
            catch { /* logging must never crash the app */ }
        }
    }
}
