using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

/// <summary>The details section's Label and Folder rows, and Saved's Add Items picker.</summary>
public sealed partial class QuickPanelWindow
{
    private const string PlusGlyph = "";
    private TextBox? _addItemsFilter;
    private StackPanel? _addItemsList;

    private static StackPanel DetailRow(string label, UIElement content)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 1, 0, 3) };
        var l = Fluent.Label(label, 12, Fluent.Secondary);
        l.Width = 90;
        l.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(l);
        row.Children.Add(content);
        return row;
    }

    /// <summary>A small clickable chip (a label's tag, or a folder path).</summary>
    private Border Chip(string glyph, string text, string tooltip, Action click, bool accent)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Glyphs.Icon(glyph, 10, accent ? Fluent.AccentText : Fluent.Accent);
        icon.Margin = new Thickness(0, 0, 4, 0);
        content.Children.Add(icon);
        content.Children.Add(Fluent.Label(text.Length > 40 ? text[..39] + "…" : text, 11, accent ? Fluent.AccentText : Fluent.Accent));
        var chip = new Border
        {
            Child = content, Padding = new Thickness(7, 1, 7, 2), CornerRadius = new CornerRadius(8), Cursor = Cursors.Hand, ToolTip = tooltip,
            Background = accent ? Fluent.Accent : Fluent.Subtle, VerticalAlignment = VerticalAlignment.Center,
        };
        chip.MouseLeftButtonUp += (_, e) => { e.Handled = true; click(); };
        AutomationName(chip, tooltip);
        return chip;
    }

    /// <summary>"＋ Add label" / "＋ Move to folder".</summary>
    private Border AddButton(string text, string tooltip, Action click)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal };
        var icon = Glyphs.Icon(PlusGlyph, 10, Fluent.Accent);
        icon.Margin = new Thickness(0, 0, 4, 0);
        content.Children.Add(icon);
        content.Children.Add(Fluent.Label(text, 12, Fluent.Accent));
        var button = new Border
        {
            Child = content, Padding = new Thickness(4, 1, 4, 1), CornerRadius = new CornerRadius(4), Cursor = Cursors.Hand,
            Background = Brushes.Transparent, ToolTip = tooltip, VerticalAlignment = VerticalAlignment.Center,
        };
        button.MouseLeftButtonUp += (_, e) => { e.Handled = true; click(); };
        AutomationName(button, text);
        return button;
    }

    /// <summary>The first rows of the details: Label (clips, secrets, folders) and Folder (clips, secrets).</summary>
    private void LabelAndFolderRows(StackPanel stack, PanelEntry entry)
    {
        if (Model.CanLabel(entry))
        {
            void Edit() { Model.Select(entry.Id); Model.BeginLabel(entry); }
            UIElement content = PanelModel.LabelText(entry) is { } label
                ? Chip(Glyphs.Tag, label, entry is PanelEntry.SecretEntry ? "Rename (Ctrl+L)" : "Edit the label (Ctrl+L)", Edit, accent: true)
                : AddButton("Add label", "Ctrl+L", Edit);
            stack.Children.Add(DetailRow(entry is PanelEntry.SecretEntry ? "Name" : "Label", content));
        }
        if (entry is PanelEntry.Clip or PanelEntry.SecretEntry && Model.SelectedEntry?.Id == entry.Id && Model.CanMoveSelection)
        {
            void Move() { Model.Select(entry.Id); Model.BeginMoveSelection(); }
            UIElement content = Model.FolderLocation(entry) is { } path
                ? Chip(Glyphs.Folder, path, "Move to another folder (Ctrl+Shift+M)", Move, accent: false)
                : AddButton("Move to folder", "Ctrl+Shift+M", Move);
            stack.Children.Add(DetailRow("Folder", content));
        }
    }

    /// <summary>The multi-select summary's Folder row.</summary>
    private void MultiFolderRow(StackPanel stack)
    {
        if (!Model.CanMoveSelection) return;
        UIElement content = Model.CommonFolderLocation is { } path
            ? Chip(Glyphs.Folder, path, "Move them to another folder (Ctrl+Shift+M)", Model.BeginMoveSelection, accent: false)
            : AddButton("Move to folder", "Ctrl+Shift+M", Model.BeginMoveSelection);
        var row = DetailRow("Folder", content);
        row.Margin = new Thickness(0, 10, 0, 0);
        stack.Children.Add(row);
    }

    // MARK: Add Items

    private UIElement BuildAddItems()
    {
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new StackPanel { Margin = new Thickness(14, 8, 14, 8) };
        var where = Model.OpenFolder?.Name ?? "Saved";
        header.Children.Add(Fluent.Label(Model.AddItemsForm?.SendTo is { } to ? $"Send to {to.DisplayName}" : $"Add to {where}", 15, null, FontWeights.SemiBold));
        var filter = new Grid();
        _addItemsFilter = new TextBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent, FontSize = 14, Text = Model.AddItemsForm?.Query ?? "" };
        _addItemsFilter.TextChanged += (_, _) => Model.SetAddItemsQuery(_addItemsFilter.Text);
        AutomationName(_addItemsFilter, "Search clipboard history");
        var hint = Fluent.Label("Search clipboard history", 14, Fluent.Tertiary);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(4, 0, 0, 0);
        _addItemsFilter.TextChanged += (_, _) => hint.Visibility = _addItemsFilter.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        filter.Children.Add(_addItemsFilter);
        filter.Children.Add(hint);
        filter.Margin = new Thickness(0, 6, 0, 0);
        header.Children.Add(filter);
        grid.Children.Add(header);
        var line = new Border { Background = Fluent.Separator };
        Grid.SetRow(line, 1);
        grid.Children.Add(line);
        _addItemsList = new StackPanel { Margin = new Thickness(8) };
        var scroll = new ScrollViewer { Content = _addItemsList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 2);
        grid.Children.Add(scroll);
        Dispatcher.BeginInvoke(() => _addItemsFilter?.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        return grid;
    }

    private void FillAddItems()
    {
        if (_addItemsList is null || Model.AddItemsForm is not { } form) return;
        _addItemsList.Children.Clear();
        Border? current = null;
        for (var i = 0; i < form.Candidates.Count; i++)
        {
            var item = form.Candidates[i];
            var isCurrent = i == form.Cursor;
            var isChecked = form.Checked.Contains(item.Id);
            var fg = isCurrent ? Fluent.AccentText : null;
            var row = new DockPanel();
            var check = Glyphs.Icon(isChecked ? "" : "", 15, fg ?? (isChecked ? Fluent.Accent : Fluent.Tertiary));
            check.Margin = new Thickness(0, 0, 8, 0);
            DockPanel.SetDock(check, Dock.Left);
            row.Children.Add(check);
            var texts = new StackPanel();
            texts.Children.Add(Fluent.Label(item.DisplayTitle, 13, fg));
            texts.Children.Add(Fluent.Label(string.Join(" · ", new[] { item.SourceName, Fluent.Relative(item.LastCopiedAt) }.Where(s => !string.IsNullOrEmpty(s))),
                11, isCurrent ? Fluent.AccentText : Fluent.Secondary));
            row.Children.Add(texts);
            var border = new Border
            {
                Child = row, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 4, 8, 4), Cursor = Cursors.Hand,
                Background = isCurrent ? Fluent.Accent : Brushes.Transparent,
            };
            var id = item.Id;
            border.MouseLeftButtonUp += (_, _) => Model.ToggleAddItem(id);
            AutomationName(border, item.DisplayTitle + (isChecked ? ", checked" : ""));
            _addItemsList.Children.Add(border);
            if (isCurrent) current = border;
        }
        if (form.Candidates.Count == 0)
            _addItemsList.Children.Add(Fluent.Label(form.Query.Length > 0 ? "No matches" : "Everything in your history is saved already.", 13, Fluent.Secondary, wrap: true));
        current?.BringIntoView();
    }
}
