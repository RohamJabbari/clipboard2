using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;
using Clipboard2.App.Platform;
using Clipboard2.Core.Sync;

namespace Clipboard2.App.Views;

/// <summary>A small notice near the bottom of the screen that never takes focus or clicks: a group item's download
/// while "Paste from group" waits for it, or a one-line message that hides itself.</summary>
public sealed class HudWindow : Window
{
    private readonly TextBlock _icon = Glyphs.Icon(Glyphs.Download, 20);
    private readonly TextBlock _title = Fluent.Label("", 13, null, FontWeights.SemiBold);
    private readonly ProgressBar _bar = new() { Height = 4, Minimum = 0, Maximum = 1, Margin = new Thickness(0, 6, 0, 4) };
    private readonly TextBlock _detail = Fluent.Label("", 12, Fluent.Secondary);
    private readonly DispatcherTimer _hideTimer = new() { Interval = TimeSpan.FromSeconds(2.5) };

    public HudWindow()
    {
        Title = "Clipboard2";
        Width = 340;
        Height = 76;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        Background = Brushes.Transparent;
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 0, GlassFrameThickness = new Thickness(-1), ResizeBorderThickness = new Thickness(0) });
        SourceInitialized += (_, _) =>
        {
            Fluent.ApplyBackdrop(this);
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetWindowLong(hwnd, Native.GWL_EXSTYLE, Native.GetWindowLong(hwnd, Native.GWL_EXSTYLE)
                | Native.WS_EX_NOACTIVATE | Native.WS_EX_TOOLWINDOW | Native.WS_EX_TRANSPARENT);
        };

        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(_title);
        text.Children.Add(_bar);
        text.Children.Add(_detail);
        _icon.Margin = new Thickness(0, 0, 14, 0);
        var row = new DockPanel { Margin = new Thickness(18, 10, 18, 10) };
        DockPanel.SetDock(_icon, Dock.Left);
        row.Children.Add(_icon);
        row.Children.Add(text);
        Content = new Border { Background = Fluent.PanelBackground, Child = row };
        _hideTimer.Tick += (_, _) => HideHud();
    }

    /// <summary>"Downloading ‹name›", a bar and "12.4 of 80 MB". Stays until replaced or hidden.</summary>
    public void ShowProgress(IntPtr near, IncomingDownload download)
    {
        _hideTimer.Stop();
        Set(Glyphs.Download, $"Downloading {download.Name}", download.ProgressText);
        _bar.IsIndeterminate = download.Fraction is null;
        _bar.Value = download.Fraction ?? 0;
        ShowNear(near);
    }

    /// <summary>A one-line message ("Paste cancelled") that hides itself after a moment.</summary>
    public void ShowMessage(IntPtr near, string glyph, string message)
    {
        Set(glyph, message, null);
        ShowNear(near);
        _hideTimer.Stop();
        _hideTimer.Start();
    }

    public void HideHud()
    {
        _hideTimer.Stop();
        if (IsVisible) Hide();
    }

    private void Set(string glyph, string title, string? detail)
    {
        _icon.Text = glyph;
        _title.Text = title;
        _detail.Text = detail ?? "";
        _bar.Visibility = _detail.Visibility = detail is null ? Visibility.Collapsed : Visibility.Visible;
        System.Windows.Automation.AutomationProperties.SetName(this, detail is null ? title : $"{title}, {detail}");
    }

    /// <summary>Centred above the bottom of the work area of the monitor <paramref name="near"/> is on. Placed once
    /// per showing, so live updates don't move it.</summary>
    private void ShowNear(IntPtr near)
    {
        if (IsVisible) return;
        var hwnd = new WindowInteropHelper(this).EnsureHandle();
        var monitor = near != IntPtr.Zero ? Native.MonitorFromWindow(near, Native.MONITOR_DEFAULTTONEAREST)
            : (Native.GetCursorPos(out var p) ? Native.MonitorFromPoint(p, Native.MONITOR_DEFAULTTONEAREST) : IntPtr.Zero);
        var info = new Native.MONITORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFO>() };
        if (monitor != IntPtr.Zero && Native.GetMonitorInfo(monitor, ref info))
        {
            Native.GetDpiForMonitor(monitor, 0, out var dpi, out _);
            var scale = dpi == 0 ? 1.0 : dpi / 96.0;
            int w = (int)(Width * scale), h = (int)(Height * scale);
            var work = info.rcWork;
            var x = work.Left + (work.Right - work.Left - w) / 2;
            var y = work.Bottom - h - (int)(48 * scale);
            Native.SetWindowPos(hwnd, IntPtr.Zero, x, y, w, h, Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        }
        Show();
    }
}
