using System.Linq;
using System.Windows;
using System.Windows.Controls;
using Clipboard2.App.Platform;

namespace Clipboard2.App.Views;

/// <summary>Settings → Notifications: a master switch, one per kind, groups muted one by one, and whether Windows
/// lets the app notify at all (docs/features/notifications-contacts.md).</summary>
public sealed partial class SettingsWindow
{
    private UIElement BuildNotifications()
    {
        var page = Page();
        page.Children.Add(Header("Notifications"));
        if (!_services.Notifier.IsAllowed)
        {
            // Windows has no permission prompt for toasts: they're on unless turned off for the app (or everywhere).
            page.Children.Add(Card(
                Fluent.Label("Notifications are off in Windows Settings", 13, null, FontWeights.SemiBold),
                Fluent.Label("Clipboard2 can't show notifications until they're turned on for it. Until then, what contacts send is announced with a small notice instead.",
                    12, Fluent.Secondary, wrap: true),
                Row("", Action("Open Notification Settings", () => { ToastNotifier.OpenSystemSettings(); }, accent: true)),
                Row("", Action("Check Again", () => RefreshTab("Notifications")))));
        }

        CheckBox? Kind(bool value, System.Action<bool> set)
        {
            var box = Toggle(value, on => { set(on); Save(); });
            box.IsEnabled = S.NotificationsEnabled;
            return box;
        }
        page.Children.Add(Card(
            Row("Show notifications", Toggle(S.NotificationsEnabled, on => { S.NotificationsEnabled = on; Save(); RefreshTab("Notifications"); })),
            Row("Group activity: shared items, renames", Kind(S.NotifyGroupActivity, on => S.NotifyGroupActivity = on)!),
            Row("Group members: joins and leaves", Kind(S.NotifyGroupMembers, on => S.NotifyGroupMembers = on)!),
            Row("Contacts: requests, new contacts, what they send", Kind(S.NotifyContacts, on => S.NotifyContacts = on)!),
            Row("Authenticators shared with you", Kind(S.NotifyAuthenticators, on => S.NotifyAuthenticators = on)!)));
        page.Children.Add(Hint("Nothing is shown for what you do yourself, on any device, or for what's already open in the panel. " +
            "Focus assist / Do not disturb applies. Notifications never include the content of secrets."));

        var groups = _services.Sync.Groups;
        if (groups.Count > 0)
        {
            page.Children.Add(Header("Groups"));
            page.Children.Add(Card([.. groups.Select(g =>
            {
                var id = g.Id;
                return (UIElement)Row(g.DisplayName, Toggle(S.MutedGroups.Contains(id), muted => _services.Panel.SetGroupMuted(id, muted)));
            })]));
            page.Children.Add(Hint("Ticked groups are muted. You can also right-click a group's chip in the panel → Mute Notifications."));
        }
        return page;
    }
}
