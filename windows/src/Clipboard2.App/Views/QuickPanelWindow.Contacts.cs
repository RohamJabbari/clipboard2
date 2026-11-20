using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

/// <summary>Contacts ▸ People in the list, and the Send to Contact… picker in the right pane
/// (docs/features/notifications-contacts.md).</summary>
public sealed partial class QuickPanelWindow
{
    private string? _peopleKey;
    /// <summary>Kept across renders so what's typed (and the focus) survives the list rebuilding.</summary>
    private TextBox? _addContactField;
    private Grid? _addContactBox;
    private TextBox? _contactPickerFilter;
    private StackPanel? _contactPickerList;

    private static Button SmallButton(string title, Action action, bool accent = false)
    {
        var button = new Button { Content = title, Padding = new Thickness(8, 1, 8, 1), Margin = new Thickness(4, 0, 0, 0), FontSize = 12 };
        if (accent) button.Style = (Style?)Application.Current.TryFindResource("AccentButtonStyle") ?? button.Style;
        button.Click += (_, _) => action();
        return button;
    }

    // MARK: People

    private void RenderPeople()
    {
        _renderedIds = ["\u0000people"];   // back to items: the rows are rebuilt
        _rowViews.Clear();
        var key = string.Join("|", Model.People.Select(p => p.Id)) + $"#{Model.PeopleCursor}#{Model.ConfirmingRemoval}#{Model.CreatedContactCode}#{Model.IsContactBusy}";
        if (key == _peopleKey) return;
        _peopleKey = key;
        _rows.Children.Clear();
        _rows.Children.Add(BuildAddContact());
        if (Model.People.Count == 0)
        {
            var empty = new StackPanel { Margin = new Thickness(20, 40, 20, 0), HorizontalAlignment = HorizontalAlignment.Center };
            var (title, hint) = Model.Query.Length > 0 ? ("No matches", "Search finds names and usernames.")
                : ("No contacts yet", "Add someone by username, or send them a contact code.");
            empty.Children.Add(Fluent.Label(title, 16, null, FontWeights.SemiBold));
            empty.Children.Add(Fluent.Label(hint, 13, Fluent.Secondary));
            _rows.Children.Add(empty);
            return;
        }
        Border? current = null;
        for (var i = 0; i < Model.People.Count; i++)
        {
            var row = BuildPersonRow(Model.People[i], i == Model.PeopleCursor);
            if (i == Model.PeopleCursor) current = row;
            _rows.Children.Add(row);
        }
        current?.BringIntoView();
    }

    /// <summary>Add Contact: a username or a code, and Create Code (shown once, inline, with Copy).</summary>
    private UIElement BuildAddContact()
    {
        var box = new StackPanel { Margin = new Thickness(6, 2, 6, 8) };
        if (_addContactField is null || _addContactBox is null)
        {
            _addContactField = new TextBox { MinWidth = 160, MaxLength = 64, VerticalContentAlignment = VerticalAlignment.Center };
            var field = _addContactField;
            var hint = Fluent.Label("Add Contact: username or code", 12, Fluent.Tertiary);
            hint.IsHitTestVisible = false;
            hint.Margin = new Thickness(6, 0, 0, 0);
            hint.VerticalAlignment = VerticalAlignment.Center;
            field.TextChanged += (_, _) => hint.Visibility = field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            _addContactBox = new Grid();
            _addContactBox.Children.Add(field);
            _addContactBox.Children.Add(hint);
            AutomationName(_addContactField, "Add contact by username or code");
            _addContactField.PreviewKeyDown += (_, e) =>
            {
                if (e.Key != Key.Enter) return;
                e.Handled = true;
                AddContactFromField();
            };
        }
        (_addContactBox.Parent as Panel)?.Children.Remove(_addContactBox);
        var row = new DockPanel();
        var add = SmallButton("Add", AddContactFromField, accent: true);
        add.IsEnabled = !Model.IsContactBusy;
        var code = SmallButton("Create Code", () => _ = Model.CreateContactCodeAsync());
        code.IsEnabled = !Model.IsContactBusy;
        DockPanel.SetDock(code, Dock.Right);
        DockPanel.SetDock(add, Dock.Right);
        row.Children.Add(code);
        row.Children.Add(add);
        row.Children.Add(_addContactBox);
        box.Children.Add(row);
        if (Model.CreatedContactCode is { } created)
        {
            var shown = new DockPanel { Margin = new Thickness(0, 6, 0, 0) };
            var dismiss = SmallButton("Done", Model.DismissContactCode);
            var copy = SmallButton("Copy", Model.CopyContactCode, accent: true);
            DockPanel.SetDock(dismiss, Dock.Right);
            DockPanel.SetDock(copy, Dock.Right);
            shown.Children.Add(dismiss);
            shown.Children.Add(copy);
            var text = new TextBox
            {
                Text = created, IsReadOnly = true, BorderThickness = new Thickness(0), Background = Brushes.Transparent,
                FontFamily = new FontFamily("Cascadia Mono, Consolas"), FontSize = 14, VerticalContentAlignment = VerticalAlignment.Center,
            };
            AutomationName(text, "Contact code");
            shown.Children.Add(text);
            box.Children.Add(shown);
            box.Children.Add(Fluent.Label("Works once, for 7 days. Whoever enters it becomes your contact, so share it privately.", 11, Fluent.Secondary, wrap: true));
        }
        return box;
    }

    private void AddContactFromField()
    {
        if (_addContactField is not { } field || field.Text.Trim().Length == 0) return;
        var typed = field.Text;
        field.Text = "";
        _ = Model.AddContactAsync(typed);
    }

    private Border BuildPersonRow(PersonRow person, bool isCurrent)
    {
        var fg = isCurrent ? Fluent.AccentText : null;
        var row = new DockPanel();
        var icon = Glyphs.Icon(Glyphs.Contact, 15, fg ?? Fluent.Secondary);
        icon.Margin = new Thickness(0, 0, 10, 0);
        DockPanel.SetDock(icon, Dock.Left);
        row.Children.Add(icon);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        string subtitle;
        switch (person)
        {
            case PersonRow.Incoming i:
                subtitle = "Wants to add you";
                buttons.Children.Add(SmallButton("Accept", () => _ = Model.AcceptRequestAsync(i.Request), accent: true));
                buttons.Children.Add(SmallButton("Decline", () => _ = Model.DeclineRequestAsync(i.Request)));
                break;
            case PersonRow.Outgoing o:
                subtitle = "Waiting for them to accept";
                buttons.Children.Add(SmallButton("Cancel", () => _ = Model.CancelRequestAsync(o.Request)));
                break;
            case PersonRow.Contact c when Model.ConfirmingRemoval == c.Space.Id:
                subtitle = "Removing deletes everything you sent each other, for both of you.";
                buttons.Children.Add(SmallButton("Remove", () => _ = Model.ConfirmRemoveContactAsync(), accent: true));
                buttons.Children.Add(SmallButton("Keep", Model.CancelRemoveContact));
                break;
            case PersonRow.Contact c:
                subtitle = c.LastActivity is { } at ? Fluent.Relative(at) : "Nothing sent yet";
                buttons.Children.Add(SmallButton("Send…", () => Model.BeginSendItems(c.Space)));
                buttons.Children.Add(SmallButton("Remove contact", () => Model.BeginRemoveContact(c.Space.Id)));
                break;
            default:
                subtitle = "";
                break;
        }
        foreach (var b in buttons.Children.OfType<Button>()) b.IsEnabled = !Model.IsContactBusy;
        DockPanel.SetDock(buttons, Dock.Right);
        row.Children.Add(buttons);
        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        texts.Children.Add(Fluent.Label(person.Name, 13, fg, FontWeights.SemiBold));
        texts.Children.Add(Fluent.Label(subtitle, 11, isCurrent ? Fluent.AccentText : Fluent.Secondary, wrap: true));
        row.Children.Add(texts);
        var border = new Border
        {
            Child = row, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 6, 8, 6), Margin = new Thickness(0, 1, 0, 1),
            Background = isCurrent ? Fluent.Accent : Brushes.Transparent,
        };
        border.MouseLeftButtonUp += (_, _) => Model.SelectPerson(person);
        AutomationName(border, $"{person.Name}, {subtitle}");
        return border;
    }

    /// <summary>The right pane in People: who's selected and what Enter does.</summary>
    private UIElement BuildPersonDetail()
    {
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(20) };
        var icon = Glyphs.Icon(Glyphs.Contact, 28, Fluent.Secondary);
        icon.HorizontalAlignment = HorizontalAlignment.Center;
        stack.Children.Add(icon);
        var (title, detail) = Model.SelectedPerson switch
        {
            PersonRow.Incoming i => ($"{i.Request.Name} wants to add you", "Accept to send each other items. What they send appears in your Inbox."),
            PersonRow.Outgoing o => ($"Request to {o.Request.Name}", "They become your contact once they accept."),
            PersonRow.Contact c => (c.Space.DisplayName, "Send… picks items from your history to send. Right-click any item → Send to Contact… works too."),
            _ => ("People", "Your contacts and pending requests. Add someone by username or with a one-time code."),
        };
        var heading = Fluent.Label(title, 16, null, FontWeights.SemiBold);
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        heading.Margin = new Thickness(0, 8, 0, 4);
        stack.Children.Add(heading);
        var text = Fluent.Label(detail, 13, Fluent.Secondary, wrap: true);
        text.TextAlignment = TextAlignment.Center;
        text.MaxWidth = 340;
        stack.Children.Add(text);
        return stack;
    }

    // MARK: Send to Contact…

    private UIElement BuildContactPicker()
    {
        var form = Model.ContactPicker!;
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var header = new StackPanel { Margin = new Thickness(14, 8, 14, 8) };
        var what = form.Items.Count == 1 ? form.Items[0] switch
        {
            PanelEntry.Clip c => $"“{ContactNotice.Short(c.Item.DisplayTitle)}”",
            PanelEntry.SecretEntry k => $"“{k.Secret.Name}”",
            PanelEntry.FolderEntry f => $"the folder “{f.Folder.Name}”",
            _ => "1 item",
        } : $"{form.Items.Count} items";
        header.Children.Add(Fluent.Label($"Send {what} to", 15, null, FontWeights.SemiBold));
        var filter = new Grid { Margin = new Thickness(0, 6, 0, 0) };
        _contactPickerFilter = new TextBox { BorderThickness = new Thickness(0), Background = Brushes.Transparent, FontSize = 14, Text = form.Query };
        _contactPickerFilter.TextChanged += (_, _) => Model.SetContactPickerQuery(_contactPickerFilter.Text);
        AutomationName(_contactPickerFilter, "Search contacts");
        var hint = Fluent.Label("Search contacts", 14, Fluent.Tertiary);
        hint.IsHitTestVisible = false;
        hint.Margin = new Thickness(4, 0, 0, 0);
        _contactPickerFilter.TextChanged += (_, _) => hint.Visibility = _contactPickerFilter.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        filter.Children.Add(_contactPickerFilter);
        filter.Children.Add(hint);
        header.Children.Add(filter);
        grid.Children.Add(header);
        var line = new Border { Background = Fluent.Separator };
        Grid.SetRow(line, 1);
        grid.Children.Add(line);
        _contactPickerList = new StackPanel { Margin = new Thickness(8) };
        var scroll = new ScrollViewer { Content = _contactPickerList, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 2);
        grid.Children.Add(scroll);
        Dispatcher.BeginInvoke(() => _contactPickerFilter?.Focus(), System.Windows.Threading.DispatcherPriority.Input);
        return grid;
    }

    private void FillContactPicker()
    {
        if (_contactPickerList is null || Model.ContactPicker is not { } form) return;
        _contactPickerList.Children.Clear();
        Border? current = null;
        for (var i = 0; i < form.Candidates.Count; i++)
        {
            var contact = form.Candidates[i];
            var isCurrent = i == form.Cursor;
            var isChecked = form.Checked.Contains(contact.Id);
            var fg = isCurrent ? Fluent.AccentText : null;
            var row = new DockPanel();
            var check = Glyphs.Icon(isChecked ? "" : "", 15, fg ?? (isChecked ? Fluent.Accent : Fluent.Tertiary));
            check.Margin = new Thickness(0, 0, 8, 0);
            check.Cursor = Cursors.Hand;
            var id = contact.Id;
            check.MouseLeftButtonUp += (_, e) => { e.Handled = true; Model.ToggleContactPick(id); };
            DockPanel.SetDock(check, Dock.Left);
            row.Children.Add(check);
            row.Children.Add(Fluent.Label(contact.DisplayName, 13, fg));
            var border = new Border
            {
                Child = row, CornerRadius = new CornerRadius(6), Padding = new Thickness(8, 5, 8, 5), Cursor = Cursors.Hand,
                Background = isCurrent ? Fluent.Accent : Brushes.Transparent,
            };
            // A click sends to that contact (with any ticked ones); the box only ticks.
            border.MouseLeftButtonUp += (_, _) =>
            {
                if (Model.ContactPicker is not { } f) return;
                f.Cursor = f.Candidates.FindIndex(c => c.Id == id);
                Model.SubmitContactPicker(several: true);
            };
            AutomationName(border, $"Send to {contact.DisplayName}" + (isChecked ? ", ticked" : ""));
            _contactPickerList.Children.Add(border);
            if (isCurrent) current = border;
        }
        if (form.Candidates.Count == 0) _contactPickerList.Children.Add(Fluent.Label("No matches", 13, Fluent.Secondary));
        current?.BringIntoView();
    }
}
