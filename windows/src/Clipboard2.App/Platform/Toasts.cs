using System;
using Clipboard2.Core;
using Microsoft.Toolkit.Uwp.Notifications;

namespace Clipboard2.App.Platform;

/// <summary>
/// Windows toast notifications for this unpackaged (Velopack) app, through Microsoft.Toolkit.Uwp.Notifications'
/// <see cref="ToastNotificationManagerCompat"/>.
///
/// Why this library: the app isn't MSIX-packaged, so the WinRT <c>ToastNotificationManager</c> needs an AUMID and a COM
/// activator registered by hand. The compat layer does both on first use (HKCU\Software\Classes\AppUserModelId\‹AUMID›
/// with the display name, icon and a CustomActivator CLSID, plus a LocalServer32 entry pointing at this exe), takes
/// the AUMID the shell reports for the process, and raises <see cref="ToastNotificationManagerCompat.OnActivated"/>
/// for clicks, starting the app with <c>-ToastActivated</c> when it isn't running. The Windows App SDK's
/// AppNotificationManager would need its runtime (or a self-contained bootstrap) for an unpackaged app; this needs
/// nothing beyond the TFM's WinRT projection.
///
/// The AUMID: <see cref="Aumid"/> is set for the process in <c>Program.Main</c> (through Velopack, which otherwise
/// sets the same default) and is the one Velopack writes on the Start-menu shortcut it creates on install: the
/// manifest's <c>shortcutAumid</c> if any, else <c>velopack.‹packId›</c>, and the release packs with
/// <c>--packId Clipboard2</c>. Keep the two in step if the pack id ever changes.
/// </summary>
public sealed class ToastNotifier : ISystemNotifier
{
    /// <summary>Velopack's default shortcut AUMID for <c>vpk pack --packId Clipboard2</c>.</summary>
    public const string Aumid = "velopack.Clipboard2";
    private const string TargetArgument = "target";

    /// <summary>Clicks on toasts (from any thread): the decoded target, or null for a toast without one.</summary>
    public static event Action<NotificationTarget?>? Activated;

    /// <summary>Listens for clicks. Call once at startup, before anything else could raise them.</summary>
    public static void Initialize()
    {
        try
        {
            ToastNotificationManagerCompat.OnActivated += e =>
            {
                var args = ToastArguments.Parse(e.Argument);
                Activated?.Invoke(args.TryGetValue(TargetArgument, out var target) ? NotificationTarget.Decode(target) : null);
            };
        }
        catch (Exception ex)
        {
            Log.Error("Toast notifications aren't available", ex);
        }
    }

    /// <summary>The app was started by a click on a toast (it wasn't running).</summary>
    public static bool WasLaunchedByToast()
    {
        try { return ToastNotificationManagerCompat.WasCurrentProcessToastActivated(); }
        catch { return false; }
    }

    /// <summary>Uninstalling: the toasts and the AUMID/COM registration go too.</summary>
    public static void Uninstall()
    {
        try { ToastNotificationManagerCompat.Uninstall(); }
        catch (Exception ex) { Log.Error("Couldn't remove the toast registration", ex); }
    }

    public bool IsAllowed
    {
        get
        {
            try { return ToastNotificationManagerCompat.CreateToastNotifier().Setting == Windows.UI.Notifications.NotificationSetting.Enabled; }
            catch (Exception ex)
            {
                Log.Error("Couldn't read the notification setting", ex);
                return false;
            }
        }
    }

    /// <summary>Title and body only: what the detector wrote, which never holds a secret's name or value.</summary>
    public void Show(AppNotification notification)
    {
        try
        {
            var builder = new ToastContentBuilder()
                .AddText(notification.Title, hintMaxLines: 1)
                .AddText(notification.Body);
            if (notification.Target is { } target) builder.AddArgument(TargetArgument, target.Encode());
            builder.Show(toast =>
            {
                // One group per group/contact in Action Center.
                toast.Group = notification.GroupId ?? notification.Kind.ToString();
            });
        }
        catch (Exception ex)
        {
            Log.Error("Couldn't show a notification", ex);
        }
    }

    /// <summary>Settings → System → Notifications, where the user turns this app's notifications back on.</summary>
    public static void OpenSystemSettings()
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("ms-settings:notifications") { UseShellExecute = true }); }
        catch (Exception ex) { Log.Error("Couldn't open notification settings", ex); }
    }
}
