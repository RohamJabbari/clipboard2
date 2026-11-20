using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;
using System.Windows.Threading;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

/// <summary>A small ring that empties as a code's period runs out.</summary>
public sealed class CountdownRing : Grid
{
    private readonly Path _arc = new() { StrokeThickness = 2.5, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round };
    private readonly double _size;

    public CountdownRing(double size, Brush track, Brush fill)
    {
        _size = size;
        Width = Height = size;
        VerticalAlignment = VerticalAlignment.Center;
        Children.Add(new Ellipse { Stroke = track, StrokeThickness = 2.5, Width = size, Height = size });
        _arc.Stroke = fill;
        Children.Add(_arc);
    }

    /// <summary>0…1: the part of the period that's left.</summary>
    public void Set(double fraction)
    {
        fraction = Math.Clamp(fraction, 0, 0.9999);
        var r = (_size - 2.5) / 2;
        var c = _size / 2;
        var angle = fraction * 2 * Math.PI;
        var start = new Point(c, c - r);
        var end = new Point(c + r * Math.Sin(angle), c - r * Math.Cos(angle));
        var figure = new PathFigure { StartPoint = start, IsClosed = false };
        figure.Segments.Add(new ArcSegment(end, new Size(r, r), 0, fraction > 0.5, SweepDirection.Clockwise, true));
        _arc.Data = new PathGeometry([figure]);
    }
}

public sealed partial class QuickPanelWindow
{
    /// <summary>Redraws codes and rings once a second, only while the panel is visible.</summary>
    private readonly DispatcherTimer _codeTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Dictionary<string, (TextBlock Code, CountdownRing Ring)> _codeViews = [];
    private bool _codeTimerHooked;

    private void StartCodeTimer()
    {
        if (!_codeTimerHooked)
        {
            _codeTimer.Tick += (_, _) => UpdateCodes();
            IsVisibleChanged += (_, _) => { if (IsVisible) _codeTimer.Start(); else _codeTimer.Stop(); };
            _codeTimerHooked = true;
        }
        if (IsVisible) _codeTimer.Start();
    }

    private static bool IsOtpEntry(PanelEntry entry) => entry is PanelEntry.AuthenticatorEntry or PanelEntry.SharedCodeEntry;

    private static string ViewKey(PanelEntry entry, bool detail) => (detail ? "detail:" : "row:") + entry.Id;

    private void UpdateCodes()
    {
        if (!IsVisible) return;
        foreach (var (key, (code, ring)) in _codeViews.ToList())
        {
            var id = key[(key.IndexOf(':') + 1)..];
            if (Model.Entries.FirstOrDefault(e => e.Id == id) is not { } entry || !IsOtpEntry(entry))
            {
                _codeViews.Remove(key);
                continue;
            }
            var text = Model.CurrentCode(entry);
            code.Text = text is null ? "––– –––" : Totp.Grouped(text);
            ring.Set(text is null ? 0 : Model.SecondsLeft(entry) / PanelModel.PeriodOf(entry));
        }
        // "Codes until" and "No codes" change with time too.
        if (Model.Entries.Any(e => e is PanelEntry.SharedCodeEntry)) foreach (var entry in Model.Entries.Where(e => e is PanelEntry.SharedCodeEntry))
            if (_rowViews.TryGetValue(entry.Id, out var row)) StyleRow(row, entry, Model.Entries.IndexOf(entry), Model.IsMultiSelecting);
    }

    /// <summary>The row's code in monospaced digits and its countdown ring.</summary>
    private FrameworkElement CodeBadge(PanelEntry entry, bool selected, double size, bool detail)
    {
        var text = Model.CurrentCode(entry);
        var code = new TextBlock
        {
            Text = text is null ? "––– –––" : Totp.Grouped(text),
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = size, FontWeight = FontWeights.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = selected ? Fluent.AccentText : text is null ? Fluent.Tertiary : (Brush)Application.Current.Resources[SystemColors.ControlTextBrushKey],
        };
        var ring = new CountdownRing(detail ? 22 : 14, selected ? Fluent.Subtle : Fluent.Separator, selected ? Fluent.AccentText : Fluent.Accent)
        {
            Margin = new Thickness(detail ? 12 : 8, 0, detail ? 0 : 6, 0),
        };
        ring.Set(text is null ? 0 : Model.SecondsLeft(entry) / PanelModel.PeriodOf(entry));
        _codeViews[ViewKey(entry, detail)] = (code, ring);
        var stack = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(code);
        stack.Children.Add(ring);
        return stack;
    }

    // MARK: Detail pane

    private UIElement AuthenticatorView(PanelEntry entry)
    {
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
        var (title, account) = entry switch
        {
            PanelEntry.AuthenticatorEntry a => (a.Authenticator.Title, a.Authenticator.Subtitle),
            PanelEntry.SharedCodeEntry s => (s.Shared.Title, s.Shared.Account),
            _ => ("", ""),
        };
        var name = Fluent.Label(title, 17, null, FontWeights.SemiBold);
        name.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(name);
        if (account.Length > 0)
        {
            var sub = Fluent.Label(account, 13, Fluent.Secondary);
            sub.HorizontalAlignment = HorizontalAlignment.Center;
            stack.Children.Add(sub);
        }
        var badge = CodeBadge(entry, false, 34, detail: true);
        badge.HorizontalAlignment = HorizontalAlignment.Center;
        badge.Margin = new Thickness(0, 14, 0, 10);
        stack.Children.Add(badge);
        var hint = entry is PanelEntry.SharedCodeEntry { Shared: var shared } && shared.IsOut(Model.Clock())
            ? shared.Status(Model.Clock())
            : "Enter pastes the code. With less than 3 seconds left, it waits for the next one.";
        var hintLabel = Fluent.Label(hint, 12, Fluent.Secondary, wrap: true);
        hintLabel.TextAlignment = TextAlignment.Center;
        hintLabel.MaxWidth = 320;
        stack.Children.Add(hintLabel);
        return stack;
    }

    private UIElement OtpSuggestionView(PanelEntry.OtpSuggestion suggestion)
    {
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
        var icon = Glyphs.Icon(Glyphs.Lock, 32, Fluent.Accent);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var title = Fluent.Label("Authenticator link copied", 17, null, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.Margin = new Thickness(0, 10, 0, 4);
        stack.Children.Add(title);
        var who = string.Join(" · ", new[] { suggestion.Draft.Issuer, suggestion.Draft.Account }.Where(s => s.Length > 0));
        var detail = Fluent.Label((who.Length > 0 ? who + ". " : "") + "It wasn't kept in history. Press Enter to add it, or Esc to dismiss.",
            13, Fluent.Secondary, wrap: true);
        detail.TextAlignment = TextAlignment.Center;
        detail.MaxWidth = 320;
        stack.Children.Add(detail);
        var add = new Button { Content = "Add to Authenticator", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
        add.Click += (_, _) => Model.BeginAddAuthenticator(suggestion.Draft);
        stack.Children.Add(add);
        return stack;
    }

    private void AuthenticatorMetadata(PanelEntry entry, Action<string, string> line)
    {
        switch (entry)
        {
            case PanelEntry.AuthenticatorEntry { Authenticator: var a }:
                line("Owner", "You");
                line("People", a.People.Count == 0 ? "Only you" : string.Join(", ", a.People.Select(p => p.Name)));
                line("Type", $"{a.Digits} digits · {a.Period} s · {a.Algorithm}");
                line("Stored in", a.SpaceId is null ? "Credential Manager (not synced yet)" : "Credential Manager, synced to your devices");
                break;
            case PanelEntry.SharedCodeEntry { Shared: var s }:
                line("Owner", s.OwnerName);
                line("Codes until", s.Codes.Count == 0 ? "None yet" : s.CodesUntil.ToLocalTime().ToString("g"));
                line("Secret", "Not shared: you get codes only");
                break;
        }
    }

    private UIElement BuildAuthenticatorForm()
    {
        var form = Model.AuthenticatorForm!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label(form.IsRename ? "Rename Authenticator" : "Add Authenticator", 16, null, FontWeights.SemiBold));
        if (form.ShowTip)
        {
            var tip = new Border
            {
                Background = Fluent.Subtle, CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 6, 10, 6), Margin = new Thickness(0, 8, 0, 0),
                Child = Fluent.Label(PanelModel.AuthenticatorTip, 12, Fluent.Secondary, wrap: true),
            };
            stack.Children.Add(tip);
        }
        TextBox Field(string label, string value, Action<string> set)
        {
            stack.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 10, 0, 4) });
            var box = new TextBox { Text = value };
            box.TextChanged += (_, _) => set(box.Text);
            stack.Children.Add(box);
            return box;
        }
        var first = Field("Issuer", form.Issuer, v => form.Issuer = v);
        Field("Account", form.Account, v => form.Account = v);
        if (!form.IsRename && !form.SecretFromLink)
        {
            var secret = Field("Secret (base32)", form.Secret, v => form.Secret = v);
            secret.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        }
        if (!form.IsRename)
        {
            var advanced = new Expander { Header = "Advanced", IsExpanded = form.ShowAdvanced, Margin = new Thickness(0, 10, 0, 0) };
            advanced.Expanded += (_, _) => form.ShowAdvanced = true;
            var grid = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 6, 0, 0) };
            var algorithm = new ComboBox { MinWidth = 90 };
            foreach (var alg in Enum.GetValues<OtpAlgorithm>()) algorithm.Items.Add(alg);
            algorithm.SelectedItem = form.Algorithm;
            algorithm.SelectionChanged += (_, _) => { if (algorithm.SelectedItem is OtpAlgorithm a) form.Algorithm = a; };
            var digits = new ComboBox { MinWidth = 70, Margin = new Thickness(8, 0, 0, 0) };
            foreach (var d in new[] { 6, 7, 8 }) digits.Items.Add(d);
            digits.SelectedItem = form.Digits;
            digits.SelectionChanged += (_, _) => { if (digits.SelectedItem is int d) form.Digits = d; };
            var period = new TextBox { Text = form.Period.ToString(), MinWidth = 50, Margin = new Thickness(8, 0, 0, 0), ToolTip = "Period in seconds" };
            period.TextChanged += (_, _) => { if (int.TryParse(period.Text, out var p) && p > 0) form.Period = p; };
            grid.Children.Add(algorithm);
            grid.Children.Add(digits);
            grid.Children.Add(period);
            grid.Children.Add(Fluent.Label(" seconds", 12, Fluent.Secondary));
            advanced.Content = grid;
            stack.Children.Add(advanced);
        }
        if (form.Error is { } error)
        {
            var warning = Fluent.Label(error, 12, Brushes.IndianRed, wrap: true);
            warning.Margin = new Thickness(0, 8, 0, 0);
            stack.Children.Add(warning);
        }
        var save = new Button { Content = form.IsRename ? "Save" : "Add", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) };
        save.Click += (_, _) => Model.SubmitAuthenticatorForm();
        stack.Children.Add(save);
        Dispatcher.BeginInvoke(() => { first.Focus(); first.SelectAll(); }, DispatcherPriority.Input);
        return Padded(new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 16);
    }

    /// <summary>Show Secret / QR (after Windows Hello): the base32 secret and a QR code for a phone app.</summary>
    private UIElement BuildAuthenticatorSecret()
    {
        var a = Model.RevealedAuthenticator!;
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(16) };
        stack.Children.Add(Fluent.Label(a.Title, 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label("Scan it with a phone app, or type the secret. Anyone who sees this can make codes.", 12, Fluent.Secondary, wrap: true));
        var (pixels, w, h) = QrCodes.Render(OtpAuthUri.Format(a), scale: 4);
        var bitmap = BitmapSource.Create(w, h, 96, 96, PixelFormats.Bgra32, null, pixels, w * 4);
        bitmap.Freeze();
        stack.Children.Add(new Image
        {
            Source = bitmap, Width = Math.Min(200, w), Height = Math.Min(200, h), Margin = new Thickness(0, 10, 0, 10),
            HorizontalAlignment = HorizontalAlignment.Center,
        });
        RenderOptions.SetBitmapScalingMode(stack.Children[^1], BitmapScalingMode.NearestNeighbor);
        stack.Children.Add(new TextBox
        {
            Text = string.Join(" ", Base32.Normalize(a.Secret).Chunk(4).Select(c => new string(c))), IsReadOnly = true,
            FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 14, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
            HorizontalContentAlignment = HorizontalAlignment.Center, TextWrapping = TextWrapping.Wrap,
        });
        var done = new Button { Content = "Hide", HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
        done.Click += (_, _) => Model.ResetMode();
        stack.Children.Add(done);
        return new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    }

    /// <summary>People…: who it's shared with, how long their codes last, and Remove.</summary>
    private UIElement BuildAuthenticatorPeople()
    {
        var a = Model.PeopleOf!;
        var stack = new StackPanel();
        stack.Children.Add(Fluent.Label($"People · {a.Title}", 16, null, FontWeights.SemiBold));
        stack.Children.Add(Fluent.Label("They get codes for the next 24 hours, renewed whenever one of your devices syncs. They never get the secret.",
            12, Fluent.Secondary, wrap: true));
        foreach (var person in a.People)
        {
            var row = new DockPanel { Margin = new Thickness(0, 10, 0, 0) };
            var remove = new Button { Content = "Remove" };
            var uid = person.Uid;
            remove.Click += async (_, _) => { remove.IsEnabled = false; await Model.RemovePersonAsync(a, uid); };
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);
            var texts = new StackPanel();
            texts.Children.Add(Fluent.Label(person.Name, 14));
            texts.Children.Add(Fluent.Label($"Codes until {person.CodesUntil.ToLocalTime():g}", 12, Fluent.Secondary));
            row.Children.Add(texts);
            stack.Children.Add(row);
        }
        return Padded(new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, 16);
    }

    /// <summary>The inline delete confirmation (no dialog).</summary>
    private UIElement BuildConfirmDelete()
    {
        var a = Model.ConfirmingDelete!;
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
        var icon = Glyphs.Icon(Glyphs.Warning, 28, Brushes.IndianRed);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var title = Fluent.Label($"Delete “{a.Title}”?", 16, null, FontWeights.SemiBold);
        title.HorizontalAlignment = HorizontalAlignment.Center;
        title.Margin = new Thickness(0, 8, 0, 4);
        stack.Children.Add(title);
        var detail = Fluent.Label(a.People.Count > 0
            ? $"It's deleted on all your devices, and the {a.People.Count} people it's shared with stop getting codes. Make sure you can still sign in to {a.Title} another way."
            : $"It's deleted on all your devices. Make sure you can still sign in to {a.Title} another way.", 13, Fluent.Secondary, wrap: true);
        detail.TextAlignment = TextAlignment.Center;
        detail.MaxWidth = 340;
        stack.Children.Add(detail);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
        var cancel = new Button { Content = "Cancel" };
        cancel.Click += (_, _) => Model.ResetMode();
        var delete = new Button { Content = "Delete", Margin = new Thickness(8, 0, 0, 0) };
        delete.Click += (_, _) => _ = Model.ConfirmDeleteAsync();
        buttons.Children.Add(cancel);
        buttons.Children.Add(delete);
        stack.Children.Add(buttons);
        return stack;
    }

    private void FillAuthenticatorMenu(ContextMenu menu, PanelEntry entry)
    {
        MenuItem Item(string header, Action action) { var i = new MenuItem { Header = header }; i.Click += (_, _) => action(); return i; }
        Model.Select(entry.Id);
        foreach (var action in Model.AvailableActions)
        {
            if (action is PanelAction.DeleteAuthenticator or PanelAction.LeaveAuthenticator) menu.Items.Add(new Separator());
            var a = action;
            menu.Items.Add(Item(action.Title, () => { Model.Select(entry.Id); Model.Perform(a); }));
        }
    }
}
