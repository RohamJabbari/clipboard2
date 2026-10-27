using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;
using Clipboard2.Core;
using Clipboard2.Core.Sync;

namespace Clipboard2.App.Views;

/// <summary>Colours for the sync states, shared by the tray dot and the panel's footer dot.</summary>
public static class SyncStatusColors
{
    public static Color For(SyncStatus status) => status switch
    {
        SyncStatus.Syncing => Color.FromRgb(0x00, 0x78, 0xD4),   // Windows accent blue
        SyncStatus.Offline => Color.FromRgb(0x8A, 0x8A, 0x8A),
        SyncStatus.Error => Color.FromRgb(0xE8, 0x11, 0x23),
        _ => Color.FromRgb(0x10, 0x89, 0x3E),                    // synced: green
    };
}

/// <summary>The tray icon with a small status dot in its corner. Synced and signed out use the plain icon,
/// so the tray only draws attention while something is happening or wrong.</summary>
public sealed class TrayStatusIcons(System.Drawing.Icon baseIcon) : IDisposable
{
    private readonly Dictionary<SyncStatus, System.Drawing.Icon> _cache = [];

    public System.Drawing.Icon For(SyncStatus status)
    {
        if (status is SyncStatus.Idle or SyncStatus.SignedOut) return baseIcon;
        if (_cache.TryGetValue(status, out var icon)) return icon;
        return _cache[status] = WithDot(SyncStatusColors.For(status));
    }

    private System.Drawing.Icon WithDot(Color color)
    {
        using var bitmap = baseIcon.ToBitmap();
        using (var g = System.Drawing.Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            var size = bitmap.Width * 0.5f;
            var outer = new System.Drawing.RectangleF(bitmap.Width - size, bitmap.Height - size, size, size);
            var inner = System.Drawing.RectangleF.Inflate(outer, -bitmap.Width / 16f, -bitmap.Height / 16f);
            using var ring = new System.Drawing.SolidBrush(System.Drawing.Color.White);
            using var fill = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(color.R, color.G, color.B));
            g.FillEllipse(ring, outer);
            g.FillEllipse(fill, inner);
        }
        var handle = bitmap.GetHicon();
        try
        {
            using var temporary = System.Drawing.Icon.FromHandle(handle);
            return (System.Drawing.Icon)temporary.Clone();
        }
        finally { DestroyIcon(handle); }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    public void Dispose()
    {
        foreach (var icon in _cache.Values) icon.Dispose();
        _cache.Clear();
    }
}

/// <summary>The quick panel footer's "● Synced · 2 min ago". Clicking it syncs now.</summary>
public sealed class SyncStatusBadge : Border
{
    private readonly Ellipse _dot = new() { Width = 7, Height = 7, Margin = new Thickness(0, 0, 6, 0), VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _text = Fluent.Label("", 12, Fluent.Secondary);
    private readonly SyncAccount _sync;

    public SyncStatusBadge(SyncAccount sync)
    {
        _sync = sync;
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        row.Children.Add(_dot);
        row.Children.Add(_text);
        Child = row;
        Margin = new Thickness(12, 0, 12, 0);
        Cursor = Cursors.Hand;
        Background = Brushes.Transparent;
        MouseLeftButtonUp += (_, _) =>
        {
            if (SyncStatusText.From(_sync).CanSyncNow) _ = _sync.SyncNowAsync();
        };
        Update();
    }

    public void Update()
    {
        var status = SyncStatusText.From(_sync);
        Visibility = status.IsVisible ? Visibility.Visible : Visibility.Collapsed;
        _dot.Fill = new SolidColorBrush(SyncStatusColors.For(status.Status));
        _text.Text = status.Text;
        ToolTip = status.CanSyncNow ? "Click to sync now" : null;
        System.Windows.Automation.AutomationProperties.SetName(this, "Sync status: " + status.Text);
    }
}
