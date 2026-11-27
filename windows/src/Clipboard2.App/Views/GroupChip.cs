using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace Clipboard2.App.Views;

/// <summary>A sync group's chip in the filter row. Selected, it widens into one pill, <c>[👥 Name | Copies · Saved]</c>,
/// with a highlight that slides between the two segments; selecting another chip folds it back the same way
/// (docs/features/saved-v2.md §5). Kept across renders so the motion can run: <see cref="Update"/> animates only
/// what changed, with a ~250 ms cubic ease-out, the segment labels fading in once the pill has started to widen. With
/// Windows' animations off it snaps. The Contacts chip uses it too, as <c>[👤 Contacts | Inbox · People]</c>.</summary>
internal sealed class GroupChip : Border
{
    private const double MorphMs = 250, FadeInDelayMs = 70, FadeInMs = 180, FadeOutMs = 110, ChipHeight = 26, SegmentHeight = 20;
    private static readonly IEasingFunction Ease = new CubicEase { EasingMode = EasingMode.EaseOut };
    private static readonly Thickness CompactPadding = new(10, 0, 10, 0), OpenPadding = new(10, 0, 3, 0);

    private readonly TextBlock _icon;
    private readonly TextBlock _name = Fluent.Label("", 13);
    /// <summary>Holds the segments; its width runs between 0 (compact) and the segments' natural width.</summary>
    private readonly Border _segmentsHost = new() { Width = 0, ClipToBounds = true, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel _segmentsContent = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    private readonly Border _divider = new() { Width = 1, Height = 14, Margin = new Thickness(9, 0, 5, 0), Opacity = 0 };
    private readonly Border _highlight = new()
    {
        Height = SegmentHeight, CornerRadius = new CornerRadius(SegmentHeight / 2), HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Center, Opacity = 0, IsHitTestVisible = false,
    };
    private readonly TranslateTransform _slide = new();
    private readonly Border[] _segments = new Border[2];
    private readonly TextBlock[] _labels = new TextBlock[2];

    private readonly SolidColorBrush _background = new(Colors.Transparent);
    private readonly SolidColorBrush _headBrush = new(Colors.Gray);
    private readonly SolidColorBrush _iconBrush = new(Colors.Gray);
    private readonly SolidColorBrush[] _labelBrushes = [new(Colors.White), new(Colors.White)];
    private readonly SolidColorBrush _highlightBrush = new(Colors.White);
    private readonly SolidColorBrush _dividerBrush = new(Colors.White);

    private bool? _open;
    private bool _saved;
    private bool _animate;

    /// <summary>The chip (or the name area of the open pill) was clicked.</summary>
    public event Action? Chosen;
    /// <summary>A segment of the open pill was clicked: true for Saved.</summary>
    public event Action<bool>? SegmentChosen;

    public string GroupId { get; }
    public string GroupName { get; private set; } = "";
    private readonly string _first, _second;
    private readonly bool _isGroup;

    /// <param name="segments">The two segments' labels (Copies · Saved for a group).</param>
    public GroupChip(string groupId, string name, string? glyph = null, (string First, string Second)? segments = null)
    {
        GroupId = groupId;
        _isGroup = glyph is null;
        _icon = Glyphs.Icon(glyph ?? Glyphs.Group, 13);
        (_first, _second) = segments ?? ("Copies", "Saved");
        Height = ChipHeight;
        CornerRadius = new CornerRadius(ChipHeight / 2);
        Padding = CompactPadding;
        Margin = new Thickness(0, 0, 6, 0);
        Cursor = Cursors.Hand;
        Background = _background;
        _icon.Foreground = _iconBrush;
        _icon.Margin = new Thickness(0, 0, 6, 0);
        _name.Foreground = _headBrush;
        _divider.Background = _dividerBrush;
        _highlight.Background = _highlightBrush;
        _highlight.RenderTransform = _slide;

        var segmentRow = new StackPanel { Orientation = Orientation.Horizontal };
        for (var i = 0; i < 2; i++)
        {
            var saved = i == 1;
            _labels[i] = Fluent.Label(saved ? _second : _first, 12, _labelBrushes[i], FontWeights.SemiBold);
            _labels[i].Opacity = 0;
            _segments[i] = new Border
            {
                Child = _labels[i], Height = SegmentHeight, Padding = new Thickness(10, 0, 10, 0), Background = Brushes.Transparent,
                CornerRadius = new CornerRadius(SegmentHeight / 2),
            };
            _segments[i].MouseLeftButtonUp += (_, e) =>
            {
                if (_open != true) return;   // folding away: the click picks the chip, as on a compact one
                e.Handled = true;
                SegmentChosen?.Invoke(saved);
            };
            segmentRow.Children.Add(_segments[i]);
        }
        var track = new Grid { VerticalAlignment = VerticalAlignment.Center };
        track.Children.Add(_highlight);
        track.Children.Add(segmentRow);
        _segmentsContent.Children.Add(_divider);
        _segmentsContent.Children.Add(track);
        _segmentsHost.Child = _segmentsContent;

        var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        row.Children.Add(_icon);
        row.Children.Add(_name);
        row.Children.Add(_segmentsHost);
        Child = row;
        MouseLeftButtonUp += (_, _) => Chosen?.Invoke();
        SetName(name);
    }

    public void SetName(string name)
    {
        if (name == GroupName) return;
        GroupName = name;
        _name.Text = name;
        if (_isGroup) ToolTip = $"Drop items or files here to share them to “{name}”";
        Describe();
    }

    /// <summary>Shows the chip compact or open on a segment, animating from how it looks now when
    /// <paramref name="animate"/> (and Windows' animations are on).</summary>
    public void Update(bool selected, bool saved, bool animate)
    {
        _animate = animate && SystemParameters.ClientAreaAnimation && _open is not null;
        var accent = ColorOf(Fluent.Accent, Color.FromRgb(0x00, 0x67, 0xC0));
        var onAccent = ColorOf(Fluent.AccentText, Colors.White);
        if (_open != selected)
        {
            _open = selected;
            _saved = saved;
            if (selected) Open(); else Fold();
        }
        else if (selected && _saved != saved)
        {
            _saved = saved;
            PlaceHighlight();   // slides to the other segment
        }
        // The colours follow (also picking up a theme or accent change on the next render).
        Tint(_background, selected ? accent : ColorOf(Fluent.Subtle, Colors.Transparent));
        Tint(_headBrush, selected ? onAccent : ColorOf(Fluent.Primary, Colors.Black));
        Tint(_iconBrush, selected ? onAccent : ColorOf(Fluent.Secondary, Colors.Gray));
        Tint(_highlightBrush, onAccent);
        Tint(_dividerBrush, Fade(onAccent, 0x70));
        Tint(_labelBrushes[0], saved ? onAccent : accent);
        Tint(_labelBrushes[1], saved ? accent : onAccent);
        Describe();
    }

    private void Open()
    {
        // The width the segments take: measured in place, so the panel's font is used.
        _segmentsContent.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var width = _segmentsContent.DesiredSize.Width;
        // The highlight starts under the remembered segment; only switching segments slides it.
        var animate = _animate;
        _animate = false;
        PlaceHighlight();
        _animate = animate;
        Double(_segmentsHost, WidthProperty, width, MorphMs);
        Pad(OpenPadding);
        // Labels fade in once the pill has started to widen.
        foreach (var label in _labels) Double(label, OpacityProperty, 1, FadeInMs, FadeInDelayMs);
        Double(_divider, OpacityProperty, 1, FadeInMs, FadeInDelayMs);
        Double(_highlight, OpacityProperty, 1, FadeInMs, FadeInDelayMs);
    }

    private void Fold()
    {
        foreach (var label in _labels) Double(label, OpacityProperty, 0, FadeOutMs);
        Double(_divider, OpacityProperty, 0, FadeOutMs);
        Double(_highlight, OpacityProperty, 0, FadeOutMs);
        Double(_segmentsHost, WidthProperty, 0, MorphMs);
        Pad(CompactPadding);
    }

    /// <summary>Moves the highlight under the selected segment (sliding, when animating).</summary>
    private void PlaceHighlight()
    {
        foreach (var segment in _segments) segment.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        var first = _segments[0].DesiredSize.Width;
        Double(_slide, TranslateTransform.XProperty, _saved ? first : 0, MorphMs);
        Double(_highlight, WidthProperty, _saved ? _segments[1].DesiredSize.Width : first, MorphMs);
    }

    private void Describe()
    {
        var state = _open == true ? $", selected, showing {(_saved ? _second : _first)}" : "";
        System.Windows.Automation.AutomationProperties.SetName(this, $"{GroupName} {(_isGroup ? "group " : "")}filter{state}");
        System.Windows.Automation.AutomationProperties.SetName(_segments[0],
            (_isGroup ? $"Show what was copied in {GroupName}" : $"Show {_first}") + (_open == true && !_saved ? ", selected" : ""));
        System.Windows.Automation.AutomationProperties.SetName(_segments[1],
            (_isGroup ? $"Show what's saved in {GroupName}" : $"Show {_second}") + (_open == true && _saved ? ", selected" : ""));
    }

    // MARK: Animation helpers (snap when not animating)

    private void Double(IAnimatable target, DependencyProperty property, double to, double ms, double delayMs = 0)
    {
        if (!_animate)
        {
            target.BeginAnimation(property, null);
            ((DependencyObject)target).SetValue(property, to);
            return;
        }
        target.BeginAnimation(property, new DoubleAnimation(to, TimeSpan.FromMilliseconds(ms))
        {
            BeginTime = TimeSpan.FromMilliseconds(delayMs), EasingFunction = Ease,
        }, HandoffBehavior.SnapshotAndReplace);
    }

    private void Pad(Thickness to)
    {
        if (!_animate)
        {
            BeginAnimation(PaddingProperty, null);
            Padding = to;
            return;
        }
        BeginAnimation(PaddingProperty, new ThicknessAnimation(to, TimeSpan.FromMilliseconds(MorphMs)) { EasingFunction = Ease },
            HandoffBehavior.SnapshotAndReplace);
    }

    private readonly System.Collections.Generic.Dictionary<SolidColorBrush, Color> _colorTargets = [];

    /// <summary>Colours ease with the morph. A brush already headed for its colour is left alone, so a re-render
    /// mid-morph doesn't restart it.</summary>
    private void Tint(SolidColorBrush brush, Color to)
    {
        if (_colorTargets.TryGetValue(brush, out var current) && current == to) return;
        _colorTargets[brush] = to;
        if (!_animate)
        {
            brush.BeginAnimation(SolidColorBrush.ColorProperty, null);
            brush.Color = to;
            return;
        }
        brush.BeginAnimation(SolidColorBrush.ColorProperty, new ColorAnimation(to, TimeSpan.FromMilliseconds(MorphMs)) { EasingFunction = Ease },
            HandoffBehavior.SnapshotAndReplace);
        brush.Color = to;   // the base value, kept once the animation is removed
    }

    private static Color ColorOf(Brush brush, Color fallback) => brush is SolidColorBrush solid ? solid.Color : fallback;

    private static Color Fade(Color color, byte alpha) => System.Windows.Media.Color.FromArgb(alpha, color.R, color.G, color.B);
}
