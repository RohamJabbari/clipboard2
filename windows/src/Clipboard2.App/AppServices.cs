using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Clipboard2.App.Platform;
using Clipboard2.App.Views;
using Clipboard2.Core;
using Clipboard2.Core.AI;
using Clipboard2.Core.Sync;
using Transform = Clipboard2.Core.Transform;

namespace Clipboard2.App;

/// <summary>Owns every long-lived service; the Windows counterpart of the Mac AppEnvironment.</summary>
public sealed class AppServices : IPanelHost
{
    public static AppServices Shared { get; private set; } = null!;

    public static string DataDirectory { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Softmaze", "Clipboard2");
    public static string SettingsPath { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Softmaze", "Clipboard2", "settings.json");

    public Settings Settings { get; }
    public ClipStore Store { get; }
    public CredentialKeyStore Keys { get; } = new();
    public SecretVault Secrets { get; }
    /// <summary>Authenticators and codes shared with this user, in Credential Manager.</summary>
    public AuthenticatorStore Authenticators { get; }
    public QuickSlots Slots { get; }
    public ForegroundTracker Tracker { get; } = new();
    public HotkeyManager Hotkeys { get; } = new();
    public PanelModel Panel { get; }
    public UpdateService Updates { get; } = new();
    public SubscriptionAccount ClaudeAccount { get; } = new(SubscriptionCli.Claude);
    public SubscriptionAccount ChatGptAccount { get; } = new(SubscriptionCli.Codex);
    public ModelLister Models { get; }
    public SyncAccount Sync { get; }
    /// <summary>Reads the text in history images in the background, for search.</summary>
    public ImageTextIndexer ImageText { get; }
    public Dispatcher Dispatcher { get; }
    /// <summary>Windows toasts (docs/features/notifications-contacts.md).</summary>
    public ToastNotifier Notifier { get; }
    private readonly NotificationDispatcher _notifications;

    private readonly ClipboardListener _listener = new();
    private QuickPanelWindow? _panelWindow;
    private FlyoutWindow? _flyout;
    private SettingsWindow? _settingsWindow;
    private TrayIcon? _tray;
    private ContextMenuService? _contextMenu;
    private int _suspendCapture;
    private IntPtr _panelTarget;
    private readonly DispatcherTimer _maintenance = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly DispatcherTimer _updateTimer = new() { Interval = TimeSpan.FromHours(1) };
    /// <summary>Sync runs 3 s after the last local change.</summary>
    private readonly DispatcherTimer _syncDebounce = new() { Interval = TimeSpan.FromSeconds(3) };
    /// <summary>Asks sync every second whether its poll is due (3 s / 15 s / 60 s, see SyncAccount.PollInterval).</summary>
    private readonly DispatcherTimer _syncPoll = new() { Interval = TimeSpan.FromSeconds(1) };
    private int _maintenanceRuns;

    public event Action? StoreChanged;

    public AppServices()
    {
        Shared = this;
        Dispatcher = Dispatcher.CurrentDispatcher;
        Directory.CreateDirectory(DataDirectory);
        Log.FilePath = Path.Combine(DataDirectory, "clipboard2.log");
        Settings = Settings.Load(SettingsPath);
        Store = new ClipStore(Path.Combine(DataDirectory, "history.db"), new BlobStore(Path.Combine(DataDirectory, "Blobs")),
            Path.Combine(DataDirectory, "Synced Files"));
        ImageText = new ImageTextIndexer(Store, (path, ct) => Task.Run(() => TextRecognizer.RecognizeFileAsync(path), ct))
        {
            Logger = message => Log.Info("Image text: " + message),
        };
        Secrets = new SecretVault(Settings);
        Authenticators = new AuthenticatorStore(new CredentialProtectedStore());
        Slots = new QuickSlots(Settings);
        Models = new ModelLister(Keys);
        Panel = new PanelModel(Store, Settings, Slots, Secrets, this);
        Panel.GroupFilterSelected += () => _ = Sync.SyncNowAsync();
        Sync = new SyncAccount(Store, Secrets, Settings, Keys) { Logger = message => Log.Info("Sync: " + message), Authenticators = Authenticators };
        Panel.Authenticators = Authenticators;
        Panel.AuthenticatorSync = new AuthenticatorSyncAdapter(Sync);
        Panel.ContactService = new SyncContactService(Sync);
        Notifier = new ToastNotifier();
        _notifications = new NotificationDispatcher(Settings, Notifier,
            view => _panelWindow is { IsVisible: true } && Panel.IsShowing(view), ShowNotificationInHud);
        Authenticators.Changed += () =>
        {
            StoreChanged?.Invoke();
            ScheduleSync();
        };
        Panel.Self = () => Sync.Self;
        Panel.Devices = () => Sync.IsSignedIn
            ? [.. Sync.Devices.Where(d => !d.IsCurrent).Select(d => new DeviceTarget(d.Id, d.Name))]
            : [];
        Panel.SendToDevice = (item, device) => _ = SendToDeviceAsync(item, device, fromPanel: true);
        Store.Changed += () => _ = ImageText.Kick();
        Store.Changed += () => StoreChanged?.Invoke();
        Store.Changed += ScheduleSync;
        Secrets.Changed += () =>
        {
            RemoveSecretCopies();
            ScheduleSync();
        };
        _syncDebounce.Tick += (_, _) =>
        {
            _syncDebounce.Stop();
            _ = Sync.SyncNowAsync();
        };
    }

    /// <summary>A saved secret never stays in the history of its own space.</summary>
    private void RemoveSecretCopies()
    {
        foreach (var (space, hashes) in Secrets.HashesBySpace)
            Store.RemoveUnpinned(hashes, space == SecretVault.PersonalSpaceKey ? null : space);
    }

    /// <summary>Debounced: restarts the 3-second timer on every change.</summary>
    public void ScheduleSync()
    {
        if (!Sync.IsSignedIn) return;
        _syncDebounce.Stop();
        _syncDebounce.Start();
    }

    public void Start(bool background)
    {
        KeyNames.Refresh(Native.GetForegroundWindow());
        ApplyAppearance();
        _listener.Changed += OnClipboardChanged;
        RemoveSecretCopies();
        Sync.Restore();
        Sync.Changed += () =>
        {
            if (Sync.IsSignedIn == _sendToGroupRegistered) return;
            UpdateSendToGroupHotkey();
        };
        Sync.ReceivedFromDevice += (item, from) => _tray?.ShowBalloon($"Sent from {from}", item.Preview);
        // Contacts' items and requests, group activity and authenticators: system notifications (the HUD only when
        // they're off or not allowed).
        ToastNotifier.Activated += target => Dispatcher.BeginInvoke(() => OpenTarget(target));
        ToastNotifier.Initialize();
        Sync.Notifications += found => Dispatcher.BeginInvoke(() => _notifications.Dispatch(found));
        _contactNoticeTimer.Tick += (_, _) => ShowContactNotice();
        RunMaintenance();
        ScheduleSync();
        _maintenance.Tick += (_, _) => RunMaintenance();
        _maintenance.Start();
        _syncPoll.Tick += (_, _) => Sync.PollIfDue();
        _syncPoll.Start();

        RegisterHotkeys();
        _tray = new TrayIcon(this);
        _contextMenu = new ContextMenuService(this);
        _contextMenu.Update();

        _updateTimer.Tick += async (_, _) => { if (Settings.CheckForUpdates) await Updates.CheckAsync(Settings.InstallUpdatesAutomatically); };
        _updateTimer.Start();
        Updates.Changed += () => Dispatcher.Invoke(() => _tray?.ShowUpdate(Updates.AvailableVersion));
        _ = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(20));
            if (Settings.CheckForUpdates) await Updates.CheckAsync(Settings.InstallUpdatesAutomatically);
        });
        // Older images are read a little after launch, so starting up stays quick.
        Dispatcher.BeginInvoke(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(15));
            _ = ImageText.Kick();
        });
        _ = ClaudeAccount.RefreshAsync();
        _ = ChatGptAccount.RefreshAsync();

        if (!Settings.HasLaunchedBefore)
        {
            Settings.HasLaunchedBefore = true;
            Settings.Save();
            StartupRegistration.SetEnabled(Settings.LaunchAtLogin);
            _tray.ShowBalloon("Clipboard2 is running", $"Press {KeyCombo.Display(Settings.Hotkeys.GetValueOrDefault(Hotkey.QuickPanel))} to open your clipboard history. Click the tray icon for more.");
        }
        else if (!background)
        {
            _tray.ShowBalloon("Clipboard2 is running", $"Press {KeyCombo.Display(Settings.Hotkeys[Hotkey.QuickPanel])} to open it.");
        }
    }

    public void Shutdown()
    {
        ImageText.Stop();
        _tray?.Dispose();
        _contextMenu?.Dispose();
        Hotkeys.Dispose();
        _listener.Dispose();
        Tracker.Dispose();
        Store.Dispose();
    }

    public void RegisterHotkeys()
    {
        Hotkeys.Register(Hotkey.QuickPanel, Settings.Hotkeys.GetValueOrDefault(Hotkey.QuickPanel), TogglePanel);
        Hotkeys.Register(Hotkey.SelectionActions, Settings.Hotkeys.GetValueOrDefault(Hotkey.SelectionActions), () => _ = ShowSelectionActionsAsync());
        Hotkeys.Register(Hotkey.PasteAsText, Settings.Hotkeys.GetValueOrDefault(Hotkey.PasteAsText), () => _ = PasteClipboardAsTextAsync());
        Hotkeys.Register(Hotkey.CaptureText, Settings.Hotkeys.GetValueOrDefault(Hotkey.CaptureText), () => _ = CaptureScreenTextAsync());
        UpdateSendToGroupHotkey();
        for (var n = QuickSlots.First; n <= QuickSlots.Last; n++)
        {
            var slot = n;
            Hotkeys.Register(Hotkey.Slot(slot), Settings.Hotkeys.GetValueOrDefault(Hotkey.Slot(slot)), () => PasteSlot(slot));
        }
    }

    private bool _sendToGroupRegistered;

    /// <summary>Ctrl+Alt+C and Ctrl+Alt+V are only taken while signed in to sync, so they don't block other apps otherwise.</summary>
    private void UpdateSendToGroupHotkey()
    {
        _sendToGroupRegistered = Sync.IsSignedIn;
        if (Sync.IsSignedIn)
        {
            Hotkeys.Register(Hotkey.SendToGroup, Settings.Hotkeys.GetValueOrDefault(Hotkey.SendToGroup), () => _ = SendSelectionToGroupAsync());
            Hotkeys.Register(Hotkey.PasteFromGroup, Settings.Hotkeys.GetValueOrDefault(Hotkey.PasteFromGroup), () => _ = PasteFromGroupAsync());
        }
        else
        {
            Hotkeys.Unregister(Hotkey.SendToGroup);
            Hotkeys.Unregister(Hotkey.PasteFromGroup);
        }
    }

    public void ApplyAppearance()
    {
        Application.Current.ThemeMode = Settings.Appearance switch
        {
            AppearanceMode.Light => ThemeMode.Light,
            AppearanceMode.Dark => ThemeMode.Dark,
            _ => ThemeMode.System,
        };
    }

    public void RunMaintenance()
    {
        try
        {
            Store.EnforceRetention(Settings.MaxItems, Settings.MaxAge);
            if (_maintenanceRuns++ % 30 == 0) Store.RemoveOrphanedBlobs();
        }
        catch (Exception ex) { Log.Error("Maintenance failed", ex); }
    }

    // MARK: Capture

    private async void OnClipboardChanged()
    {
        if (Settings.IsPaused || _suspendCapture > 0) return;
        try
        {
            var owner = Native.GetClipboardOwner();
            var sourceWindow = owner != IntPtr.Zero ? owner : Native.GetForegroundWindow();
            var source = Tracker.AppFor(sourceWindow);
            var raw = ClipboardIO.Read(Settings.IgnoredIds, source, out _);
            if (raw is null) return;
            // An authenticator link is a 2FA seed: never history. Offered as Add to Authenticator instead.
            if (raw.Kind.IsTextual() && OtpAuthUri.IsOtpAuth(raw.Text))
            {
                OfferAuthenticatorLink(raw.Text);
                return;
            }
            var processed = await CaptureProcessor.ProcessAsync(raw, Store.Blobs);
            if (processed is null || !CaptureFilter.ShouldStore(processed)) return;
            if (raw.Image is { } image) _ = FindOtpQrAsync(image);
            if (processed.Kind.IsTextual() && Secrets.ValueHashes.Contains(processed.Hash))
                return;   // a saved secret: never in history
            Store.Ingest(processed);
            Store.EnforceRetention(Settings.MaxItems, Settings.MaxAge);
            Sync.ReportActivity();
        }
        catch (Exception ex)
        {
            Log.Error("Capture failed", ex);
        }
    }

    /// <summary>A copied otpauth link: "Authenticator link copied", and the panel offers to add it (HOTP is refused).</summary>
    private void OfferAuthenticatorLink(string text)
    {
        if (OtpAuthUri.Parse(text, out var error) is { } draft)
        {
            Panel.OfferAuthenticator(draft);
            Hud.ShowNotice(Tracker.TargetWindow, Glyphs.Lock, "Authenticator link copied", "Open Clipboard2 to add it to your authenticators. It isn't kept in history.");
        }
        else
        {
            Hud.ShowWarning(Tracker.TargetWindow, "Authenticator link not added", error ?? "That link can't be used.");
        }
    }

    /// <summary>A copied image or screenshot with an otpauth QR code: offered like a copied link (the image itself
    /// is kept as a normal clip).</summary>
    private async Task FindOtpQrAsync(System.Windows.Media.Imaging.BitmapSource image)
    {
        try
        {
            var link = await Task.Run(() =>
            {
                var bgra = new System.Windows.Media.Imaging.FormatConvertedBitmap(image, System.Windows.Media.PixelFormats.Bgra32, null, 0);
                if ((long)bgra.PixelWidth * bgra.PixelHeight > 25_000_000) return null;
                var pixels = new byte[bgra.PixelWidth * 4 * bgra.PixelHeight];
                bgra.CopyPixels(pixels, bgra.PixelWidth * 4, 0);
                return QrCodes.FindOtpAuth(pixels, bgra.PixelWidth, bgra.PixelHeight);
            });
            if (link is not null) await Dispatcher.InvokeAsync(() => OfferAuthenticatorLink(link));
        }
        catch (Exception ex)
        {
            Log.Error("Looking for a QR code failed", ex);
        }
    }

    /// <summary>Runs <paramref name="work"/> while clipboard changes are ignored (borrowing the clipboard).</summary>
    private async Task WithoutCapture(Func<Task> work)
    {
        _suspendCapture++;
        try { await work(); }
        finally
        {
            await Task.Delay(300);   // WM_CLIPBOARDUPDATE for our restore arrives asynchronously
            _suspendCapture--;
        }
    }

    // MARK: Panel

    public void TogglePanel()
    {
        if (_panelWindow is { IsVisible: true }) { ClosePanel(); return; }
        ShowPanel();
    }

    public void ShowPanel()
    {
        _panelTarget = Tracker.TargetWindow;
        KeyNames.Refresh(_panelTarget);   // shortcut names as printed on the keyboard in use (Strg on German ones)
        Panel.PrepareForOpen(Tracker.AppFor(_panelTarget));
        PanelWindow.ShowNear(_panelTarget);
        Sync.SetPanelOpen(true);   // syncs once, then polls every 3 s while open
    }

    private QuickPanelWindow PanelWindow => _panelWindow ??= new QuickPanelWindow(this);

    public void ClosePanel()
    {
        _panelWindow?.HidePanel();
        Panel.DidClose();
        Sync.SetPanelOpen(false);
        // A paste right after closing reads the target synchronously; any later one (tray, right-click menu)
        // must not be sent back to the window the panel was opened over.
        Dispatcher.BeginInvoke(() => _panelTarget = IntPtr.Zero, System.Windows.Threading.DispatcherPriority.Background);
    }

    public void ShowFlyout(Point nearScreenPoint)
    {
        Sync.ReportActivity();
        _flyout ??= new FlyoutWindow(this);
        _flyout.ShowNear(nearScreenPoint);
    }

    void IPanelHost.OpenSettings() => OpenSettings("AI");

    public void OpenSettings(string? tab = null)
    {
        Dispatcher.BeginInvoke(() =>
        {
            KeyNames.Refresh(Native.GetForegroundWindow());
            if (_settingsWindow is null || !_settingsWindow.IsLoaded)
            {
                _settingsWindow = new SettingsWindow(this);
                _settingsWindow.Closed += (_, _) => _settingsWindow = null;
            }
            _settingsWindow.Show();
            _settingsWindow.SelectTab(tab);
            if (_settingsWindow.WindowState == WindowState.Minimized) _settingsWindow.WindowState = WindowState.Normal;
            _settingsWindow.Activate();
        });
    }

    // MARK: Paste flows

    private IntPtr TargetForPaste => _panelTarget != IntPtr.Zero ? _panelTarget : Tracker.TargetWindow;

    /// <summary>Focus the target app, release held modifiers, then Ctrl+V.</summary>
    private async Task SendPasteAsync(IntPtr target, int cursorOffsetFromEnd = 0)
    {
        await InputSender.ReleaseModifiersAsync();
        Native.ForceForeground(target);
        await Task.Delay(90);
        InputSender.CtrlPlus('V');
        if (cursorOffsetFromEnd > 0)
        {
            await Task.Delay(60);
            InputSender.Press(Native.VK_LEFT, Math.Min(cursorOffsetFromEnd, 5_000));
        }
        _panelTarget = IntPtr.Zero;
    }

    public void Paste(ClipItem item, Transform? transform)
    {
        var target = TargetForPaste;
        var appTransform = transform ?? Settings.DefaultTransform(Tracker.AppFor(target)?.Id is { } path ? Path.GetFileName(path) : null);
        Sync.ReportActivity();
        // Keeps its place in the list. Ctrl+V only when the clipboard really holds it, never the old contents.
        if (ClipboardIO.Write(item, appTransform, Store.Blobs)) _ = SendPasteAsync(target);
        else ClipboardFailed(target, [item]);
    }

    public void Paste(IReadOnlyList<ClipItem> items, Transform? transform)
    {
        var target = TargetForPaste;
        Sync.ReportActivity();
        if (ClipboardIO.Write(items, transform, Store.Blobs)) _ = SendPasteAsync(target);
        else ClipboardFailed(target, items);
    }

    public void PasteText(string text, int cursorOffsetFromEnd = 0)
    {
        var target = TargetForPaste;
        Sync.ReportActivity();
        if (ClipboardIO.WriteText(text)) _ = SendPasteAsync(target, cursorOffsetFromEnd);
        else ClipboardFailed(target, []);
    }

    public void Copy(ClipItem item)
    {
        if (!ClipboardIO.Write(item, null, Store.Blobs)) ClipboardFailed(Tracker.TargetWindow, [item]);
    }

    public void Copy(IReadOnlyList<ClipItem> items)
    {
        if (!ClipboardIO.Write(items, null, Store.Blobs)) ClipboardFailed(Tracker.TargetWindow, items);
    }

    public void CopyText(string text)
    {
        if (!ClipboardIO.WriteText(text)) ClipboardFailed(Tracker.TargetWindow, []);
    }

    /// <summary>Says why nothing was pasted or copied, instead of pasting whatever was on the clipboard before.</summary>
    private void ClipboardFailed(IntPtr near, IReadOnlyList<ClipItem> items)
    {
        _panelTarget = IntPtr.Zero;
        System.Media.SystemSounds.Beep.Play();
        if (items.Count > 0 && items.All(i => i.Kind == ClipKind.File))
            Hud.ShowWarning(near, items.Count == 1 ? "The file is gone" : "The files are gone",
                "It was moved or deleted since it was copied.");
        else
            Hud.ShowWarning(near, "Couldn't use the clipboard", "Another app is holding it. Try again in a moment.");
    }
    public string? CurrentClipboardText() => ClipboardIO.CurrentText();

    // MARK: Saving to a folder

    public string SaveFolder => Settings.SaveFolder is { Length: > 0 } folder ? folder : Native.DownloadsFolder();

    /// <summary>The folder picker, over the panel (which stays open while it's shown).</summary>
    public string? ChooseSaveFolder() => PanelWindow.ChooseFolder(SaveFolder);

    /// <summary>Pastes text, then puts the previous clipboard back.</summary>
    public async Task PasteKeepingClipboardAsync(string text, IntPtr target)
    {
        await WithoutCapture(async () =>
        {
            var saved = ClipboardIO.Snapshot();
            ClipboardIO.WriteText(text);
            await SendPasteAsync(target);
            await Task.Delay(600);
            ClipboardIO.Restore(saved);
        });
    }

    // MARK: Secrets

    public void PasteSecret(SecretRef secret) => _ = PasteSecretAsync(secret, TargetForPaste);

    // MARK: Authenticator codes

    /// <summary>Codes are cleared like copied secrets: after 30 s.</summary>
    public const int CodeClearSeconds = 30;

    /// <summary>A code: kept out of history (ours, Win+V and cloud clipboard), cleared after 30 s.</summary>
    public void PasteTransient(string text)
    {
        var target = TargetForPaste;
        WriteSecretWithAutoClear(text, CodeClearSeconds);
        _ = SendPasteAsync(target);
    }

    public void CopyTransient(string text) => WriteSecretWithAutoClear(text, CodeClearSeconds);

    public Task<bool> VerifyUserAsync(string reason) => Secrets.VerifyFreshAsync(reason);

    private async Task PasteSecretAsync(SecretRef secret, IntPtr target)
    {
        var value = await Secrets.RevealAsync(secret, $"paste “{secret.Name}”");
        if (value is null) return;
        WriteSecretWithAutoClear(value);
        await SendPasteAsync(target);
    }

    public void CopySecret(SecretRef secret) => _ = Task.Run(async () =>
    {
        var value = await Secrets.RevealAsync(secret, $"copy “{secret.Name}”");
        if (value is not null) Dispatcher.Invoke(() => WriteSecretWithAutoClear(value));
    });

    public void CopySecrets(IReadOnlyList<SecretRef> secrets, string? spaceId, Guid? folderId, string reason, string notice) =>
        _ = CopySecretsAsync(secrets, spaceId, folderId, reason, notice);

    /// <summary>One Windows Hello confirmation, then each value is read and written again as a new secret.</summary>
    private async Task CopySecretsAsync(IReadOnlyList<SecretRef> secrets, string? spaceId, Guid? folderId, string reason, string notice)
    {
        if (secrets.Count == 0 || !await Secrets.AuthenticateAsync(reason)) return;
        Dispatcher.Invoke(() =>
        {
            var copied = 0;
            foreach (var secret in secrets)
            {
                if (Secrets.ReadValue(secret) is not { } value || Secrets.Add(secret.Name, value, spaceId) is not { } copy) continue;
                if (folderId is { } folder) Store.SetSecretFolder(copy.Id, folder);
                copied++;
            }
            Panel.ShowNotice(copied == secrets.Count ? notice : "Couldn't save to Credential Manager");
        });
    }

    /// <summary>A shared folder tree's secrets: one Windows Hello, then each into its new folder.</summary>
    public void CopySecretsToFolders(IReadOnlyList<(SecretRef Secret, Guid? FolderId)> secrets, string? spaceId, string reason, string notice) =>
        _ = CopySecretsToFoldersAsync(secrets, spaceId, reason, notice);

    private async Task CopySecretsToFoldersAsync(IReadOnlyList<(SecretRef Secret, Guid? FolderId)> secrets, string? spaceId, string reason, string notice)
    {
        if (secrets.Count == 0 || !await Secrets.AuthenticateAsync(reason)) return;
        Dispatcher.Invoke(() =>
        {
            var copied = 0;
            foreach (var (secret, folderId) in secrets)
            {
                if (Secrets.ReadValue(secret) is not { } value || Secrets.Add(secret.Name, value, spaceId) is not { } copy) continue;
                if (folderId is { } folder) Store.SetSecretFolder(copy.Id, folder);
                copied++;
            }
            Panel.ShowNotice(copied == secrets.Count ? notice : "Couldn't save to Credential Manager");
        });
    }

    /// <summary>Send to Contact with secrets: one Windows Hello, then each copy into its contact's space and folder.</summary>
    public void CopySecretsToSpaces(IReadOnlyList<(SecretRef Secret, string SpaceId, Guid? FolderId)> secrets, string reason, string notice) =>
        _ = CopySecretsToSpacesAsync(secrets, reason, notice);

    private async Task CopySecretsToSpacesAsync(IReadOnlyList<(SecretRef Secret, string SpaceId, Guid? FolderId)> secrets, string reason, string notice)
    {
        if (secrets.Count == 0 || !await Secrets.AuthenticateAsync(reason)) return;
        Dispatcher.Invoke(() =>
        {
            var copied = 0;
            foreach (var (secret, spaceId, folderId) in secrets)
            {
                if (Secrets.ReadValue(secret) is not { } value || Secrets.Add(secret.Name, value, spaceId) is not { } copy) continue;
                if (folderId is { } folder) Store.SetSecretFolder(copy.Id, folder);
                copied++;
            }
            Panel.ShowNotice(copied == secrets.Count ? notice : "Couldn't save to Credential Manager");
        });
    }

    private void WriteSecretWithAutoClear(string value, int? seconds = null)
    {
        ClipboardIO.WriteSecret(value);
        var clearAfter = seconds ?? Settings.SecretClearSeconds;
        if (clearAfter <= 0) return;
        var sequence = Native.GetClipboardSequenceNumber();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(clearAfter) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            if (Native.GetClipboardSequenceNumber() == sequence) ClipboardIO.Clear();
        };
        timer.Start();
    }

    // MARK: Quick slots (global)

    public void PasteSlot(int slot)
    {
        _panelTarget = Tracker.TargetWindow;
        switch (Panel.EntryForSlot(slot))
        {
            case PanelEntry.Clip c: Paste(c.Item, null); break;
            case PanelEntry.SecretEntry k: PasteSecret(k.Secret); break;
            case PanelEntry.SnippetEntry s when SnippetExpander.CustomFields(s.Snippet.Body).Count == 0:
                var expansion = SnippetExpander.Expand(s.Snippet.Body, null, CurrentClipboardText());
                PasteText(expansion.Text, expansion.CursorOffsetFromEnd);
                break;
            case PanelEntry.SnippetEntry s:
                ShowPanel();
                Panel.Activate(s);
                break;
            default:
                System.Media.SystemSounds.Beep.Play();
                break;
        }
    }

    // MARK: Actions on selected text, paste as text, capture text

    /// <summary>Copies the selection in the frontmost app with Ctrl+C, then puts the previous clipboard back.</summary>
    private async Task<string?> CopySelectionAsync()
    {
        string? text = null;
        await WithoutCapture(async () =>
        {
            var saved = ClipboardIO.Snapshot();
            var before = Native.GetClipboardSequenceNumber();
            await InputSender.ReleaseModifiersAsync();
            InputSender.CtrlPlus('C');
            for (var i = 0; i < 25 && Native.GetClipboardSequenceNumber() == before; i++) await Task.Delay(20);
            if (Native.GetClipboardSequenceNumber() != before) text = ClipboardIO.CurrentText();
            ClipboardIO.Restore(saved);
        });
        return text;
    }

    /// <summary>Presses Ctrl+C in the foreground app and reads what it copied the way history capture does,
    /// so a file selected in Explorer arrives as the file, not its name. Null when nothing (or something
    /// concealed, or from an ignored app) was copied.</summary>
    private async Task<RawCapture?> CopySelectionCaptureAsync(AppRef? source)
    {
        RawCapture? raw = null;
        await WithoutCapture(async () =>
        {
            var saved = ClipboardIO.Snapshot();
            var before = Native.GetClipboardSequenceNumber();
            await InputSender.ReleaseModifiersAsync();
            InputSender.CtrlPlus('C');
            for (var i = 0; i < 25 && Native.GetClipboardSequenceNumber() == before; i++) await Task.Delay(20);
            if (Native.GetClipboardSequenceNumber() != before) raw = ClipboardIO.Read(Settings.IgnoredIds, source, out _);
            ClipboardIO.Restore(saved);
        });
        return raw;
    }

    public async Task ShowSelectionActionsAsync()
    {
        var target = Tracker.TargetWindow;
        var text = await CopySelectionAsync();
        if (string.IsNullOrEmpty(text))
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        _panelTarget = target;
        Panel.PrepareForSelection(text, Tracker.AppFor(target));
        PanelWindow.ShowNear(target);
        Sync.SetPanelOpen(true);
    }

    /// <summary>Ctrl+Alt+C: the selected text goes straight into the default sync group's history.</summary>
    public async Task SendSelectionToGroupAsync()
    {
        if (!Sync.IsSignedIn || Sync.DefaultGroup is not { } group)
        {
            OpenSettings("Sync");
            return;
        }
        // The group's owner turned this user's Send off: reading and pasting still work, sending doesn't.
        if (!group.CanSend)
        {
            Hud.ShowMessage(Tracker.TargetWindow, Glyphs.Cancel, SyncAccount.CantSendMessage(group));
            return;
        }
        var source = Tracker.AppFor(Tracker.TargetWindow);
        var raw = await CopySelectionCaptureAsync(source);
        var capture = raw is null ? null : await CaptureProcessor.ProcessAsync(raw, Store.Blobs);
        // A saved secret (or blank text) never goes to a group this way.
        if (capture is null || !CaptureFilter.ShouldStore(capture)
            || (capture.Kind.IsTextual() && (string.IsNullOrWhiteSpace(capture.Text) || Secrets.ValueHashes.Contains(capture.Hash))))
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        if (capture.Kind == ClipKind.File && SyncEngine.GroupShareProblem(capture.Files) is { } problem)
        {
            ShowGroupShareProblem(group.DisplayName, problem);
            return;
        }
        Store.Ingest(capture, spaceId: group.Id);
        _tray?.ShowBalloon($"Sent to {group.DisplayName}", capture.Preview);
        _syncDebounce.Stop();
        _ = Sync.SyncNowAsync();
    }

    /// <summary>Shares a history item to a group from outside the panel, or says why it can't be.</summary>
    public void ShareToGroup(ClipItem item, SpaceRecord group)
    {
        if (!group.CanSend)
        {
            Hud.ShowMessage(Tracker.TargetWindow, Glyphs.Cancel, SyncAccount.CantSendMessage(group));
            return;
        }
        if (SyncEngine.GroupShareProblem(item) is { } problem)
        {
            ShowGroupShareProblem(group.DisplayName, problem);
            return;
        }
        Store.CopyToSpace(item, group.Id);
    }

    private void ShowGroupShareProblem(string groupName, string problem) =>
        Hud.ShowWarning(Tracker.TargetWindow, $"Can't share to {groupName}", problem);

    /// <summary>Sends a history item to a contact from outside the panel (it lands in their Inbox), or says why it can't.</summary>
    public void SendToContact(ClipItem item, SpaceRecord contact)
    {
        if (SyncEngine.ContactSendProblem(item) is { } problem)
        {
            Hud.ShowWarning(Tracker.TargetWindow, $"Can't send to {contact.DisplayName}", problem);
            return;
        }
        Store.CopyToSpace(item, contact.Id, keepLabel: false);
        Hud.ShowMessage(Tracker.TargetWindow, Glyphs.Check, $"Sent to {contact.DisplayName}");
    }

    // With notifications off or not allowed, what contacts send (and their requests) is still announced: one quiet
    // HUD notice for a burst, never a dialog.
    private readonly List<AppNotification> _hudNotices = [];
    private readonly DispatcherTimer _contactNoticeTimer = new() { Interval = TimeSpan.FromSeconds(1) };

    private void ShowNotificationInHud(AppNotification notification)
    {
        _hudNotices.Add(notification);
        _contactNoticeTimer.Stop();
        _contactNoticeTimer.Start();
    }

    private void ShowContactNotice()
    {
        _contactNoticeTimer.Stop();
        if (_hudNotices.Count == 0) return;
        var notices = _hudNotices.ToList();
        _hudNotices.Clear();
        var hotkey = KeyCombo.Display(Settings.Hotkeys.GetValueOrDefault(Hotkey.QuickPanel));
        if (notices.All(n => n.Target is NotificationTarget.People))
        {
            var first = notices[0];
            var title = notices.Count == 1 ? (first.Title == "Contact request" ? first.Body : $"{first.Title} {first.Body}") : $"{notices.Count} contact updates";
            Hud.ShowNotice(Tracker.TargetWindow, Glyphs.Contact, title, $"See Contacts ({hotkey} → Contacts → People)");
            return;
        }
        var items = notices.Where(n => n.Target is NotificationTarget.Inbox).ToList();
        var line = items.Count == 1 ? $"{items[0].Title} {items[0].Body}" : $"{items.Count} contacts sent you items";
        Hud.ShowNotice(Tracker.TargetWindow, Glyphs.Inbox, line, $"In your Inbox ({hotkey} → Contacts)");
    }

    /// <summary>A notification was clicked: the panel opens at what it's about.</summary>
    public void OpenTarget(NotificationTarget? target)
    {
        if (target is null) return;
        if (_panelWindow is not { IsVisible: true }) ShowPanel();
        Panel.ShowTarget(target);
    }

    private HudWindow? _hud;
    private HudWindow Hud => _hud ??= new HudWindow();
    /// <summary>Set while "Paste from group" waits for an item to download; the shortcut pressed again cancels it.</summary>
    private CancellationTokenSource? _groupPasteWait;

    /// <summary>Pastes the newest item of the default group. Fetches first (briefly), so something a group
    /// member just sent is pasted; if the server is slow or unreachable, the newest known one is. An item that's
    /// still downloading is waited for, with its progress on screen.</summary>
    public async Task PasteFromGroupAsync()
    {
        if (_groupPasteWait is { } waiting)
        {
            waiting.Cancel();
            return;
        }
        if (!Sync.IsSignedIn || Sync.DefaultGroup is not { } group)
        {
            OpenSettings("Sync");
            return;
        }
        var target = Tracker.TargetWindow;
        // Set before the fetch, so pressing the shortcut again during it cancels too.
        using var wait = _groupPasteWait = new CancellationTokenSource();
        try
        {
            await Task.WhenAny(Sync.SyncNowAsync(), Task.Delay(TimeSpan.FromMilliseconds(1500), wait.Token));
            if (wait.IsCancellationRequested)
            {
                Hud.ShowMessage(target, Glyphs.Cancel, "Paste cancelled");
                return;
            }
            if (Sync.Downloads.FirstOrDefault(d => d.SpaceId == group.Id) is { } incoming)
            {
                await PasteWhenDownloadedAsync(incoming, target, wait);
                return;
            }
        }
        finally
        {
            _groupPasteWait = null;
        }
        if (Store.ItemsInSpace(group.Id).FirstOrDefault() is not { } item)
        {
            _tray?.ShowBalloon(group.DisplayName, "Nothing in this group yet.");
            return;
        }
        _panelTarget = target;
        Paste(item, null);
    }

    /// <summary>Shows the download's progress and pastes the item once it's in. If another window came to the front
    /// meanwhile, the item only goes on the clipboard.</summary>
    private async Task PasteWhenDownloadedAsync(IncomingDownload incoming, IntPtr target, CancellationTokenSource wait)
    {
        var arrived = new TaskCompletionSource<ClipItem?>(TaskCreationOptions.RunContinuationsAsynchronously);
        // Gone from the list: applied (it's in the store now) or failed.
        void Update()
        {
            if (Sync.Downloads.FirstOrDefault(d => d.ItemId == incoming.ItemId) is { } current) Hud.ShowProgress(target, current);
            else arrived.TrySetResult(Store.Find(incoming.ItemId));
        }
        void OnDownloadsChanged() => Dispatcher.BeginInvoke(Update);
        Sync.DownloadsChanged += OnDownloadsChanged;
        ClipItem? item;
        try
        {
            Update();
            using var _ = wait.Token.Register(() => arrived.TrySetCanceled());
            item = await arrived.Task;
        }
        catch (OperationCanceledException)
        {
            Hud.ShowMessage(target, Glyphs.Cancel, "Paste cancelled");
            return;
        }
        finally
        {
            Sync.DownloadsChanged -= OnDownloadsChanged;
        }
        if (item is null)
        {
            Hud.ShowMessage(target, Glyphs.Warning, $"Couldn't download {incoming.Name}");
            return;
        }
        if (Tracker.TargetWindow != target)
        {
            Copy(item);
            Hud.ShowMessage(target, Glyphs.Check, $"Ready — press {KeyLabels.Show("Ctrl+V")} to paste");
            return;
        }
        Hud.HideHud();
        _panelTarget = target;
        Paste(item, null);
    }

    public async Task PasteClipboardAsTextAsync()
    {
        var target = Tracker.TargetWindow;
        if (ClipboardIO.CurrentImage() is { } image)
        {
            var text = await TextRecognizer.RecognizeAsync(image);
            if (text.Length == 0) { System.Media.SystemSounds.Beep.Play(); return; }
            Store.Ingest(ProcessedCapture.ForText(text, source: new AppRef("clipboard2", "Text from Image")));
            await PasteKeepingClipboardAsync(text, target);
            return;
        }
        if (ClipboardIO.CurrentText() is { Length: > 0 } plain) await PasteKeepingClipboardAsync(plain, target);
        else System.Media.SystemSounds.Beep.Play();
    }

    public async Task CaptureScreenTextAsync()
    {
        var target = Tracker.TargetWindow;
        System.Windows.Media.Imaging.BitmapSource? image = null;
        await WithoutCapture(async () =>
        {
            var saved = ClipboardIO.Snapshot();
            image = await ScreenCapture.CaptureRegionAsync(TimeSpan.FromSeconds(60));
            ClipboardIO.Restore(saved);
        });
        if (image is null) return;   // cancelled
        var text = await TextRecognizer.RecognizeAsync(image);
        if (text.Length == 0) { System.Media.SystemSounds.Beep.Play(); return; }
        Store.Ingest(ProcessedCapture.ForText(text, source: new AppRef("clipboard2", "Text from Screen")));
        await PasteKeepingClipboardAsync(text, target);
    }

    // MARK: Send to device, drops

    /// <summary>Sends a history item to another of the account's devices; it shows up there as "Sent from ‹this PC›".</summary>
    public async Task SendToDeviceAsync(ClipItem item, DeviceTarget device, bool fromPanel)
    {
        Sync.ReportActivity();
        // Failures don't throw: the account keeps the reason in Error.
        if (await Sync.SendToDeviceAsync(item, device.Id))
        {
            if (fromPanel) Panel.ShowNotice($"Sent to {device.Name}");
            else _tray?.ShowBalloon($"Sent to {device.Name}", item.DisplayTitle);
            return;
        }
        var message = Sync.Error ?? "Not sent yet. Try again in a moment.";
        Log.Info($"Sending to {device.Name} failed: {message}");
        if (fromPanel) Panel.ShowNotice($"Couldn't send to {device.Name}: {message}");
        else _tray?.ShowBalloon($"Couldn't send to {device.Name}", message);
    }

    /// <summary>The account's other devices, by name (none when signed out).</summary>
    public List<DeviceTarget> OtherDevices => Panel.Devices?.Invoke().OrderBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase).ToList() ?? [];

    /// <summary>Right-click menu: sends the selection (copied with Ctrl+C) to a device, or the newest copy when
    /// nothing is selected. A saved secret is never sent this way.</summary>
    public async Task SendSelectionToDeviceAsync(DeviceTarget device)
    {
        if (!Sync.IsSignedIn)
        {
            OpenSettings("Sync");
            return;
        }
        var source = Tracker.AppFor(Tracker.TargetWindow);
        var raw = await CopySelectionCaptureAsync(source);
        var capture = raw is null ? null : await CaptureProcessor.ProcessAsync(raw, Store.Blobs);
        ClipItem? item = null;
        if (capture is not null)
        {
            if (!CaptureFilter.ShouldStore(capture) || capture.Kind.IsTextual() && (string.IsNullOrWhiteSpace(capture.Text) || Secrets.ValueHashes.Contains(capture.Hash)))
            {
                System.Media.SystemSounds.Beep.Play();
                return;
            }
            item = Store.Ingest(capture);
        }
        item ??= Store.ItemsInSpace(null).FirstOrDefault();
        if (item is null)
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        await SendToDeviceAsync(item, device, fromPanel: false);
    }

    /// <summary>Files dropped on the panel's list (into history) or on a group chip (shared to that group).</summary>
    public ClipItem? AddDroppedFiles(IReadOnlyList<string> paths, string? spaceId = null)
    {
        if (paths.Count == 0 || !CanSendTo(spaceId)) return null;
        var item = Store.Ingest(ProcessedCapture.ForFiles(paths), spaceId: spaceId);
        Sync.ReportActivity();
        return item;
    }

    /// <summary>Text dragged in from another app. Blank text and saved secrets are refused.</summary>
    public ClipItem? AddDroppedText(string text, string? spaceId = null)
    {
        var capture = ProcessedCapture.ForText(text);
        if (string.IsNullOrWhiteSpace(text) || Secrets.ValueHashes.Contains(capture.Hash) || !CaptureFilter.ShouldStore(capture) || !CanSendTo(spaceId)) return null;
        var item = Store.Ingest(capture, spaceId: spaceId);
        Sync.ReportActivity();
        return item;
    }

    /// <summary>Whether this user may add to a space: anything but a group whose owner turned their Send off.</summary>
    public bool CanSendTo(string? spaceId) => spaceId is null || Store.Groups().FirstOrDefault(g => g.Id == spaceId) is not { CanSend: false };

    // MARK: AI

    public SubscriptionAccount? AccountFor(AIProviderKind provider) => provider switch
    {
        AIProviderKind.ClaudeCode => ClaudeAccount,
        AIProviderKind.ChatGPT => ChatGptAccount,
        _ => null,
    };

    public bool IsAIReady
    {
        get
        {
            var provider = Settings.AIProvider;
            if (AccountFor(provider) is { } account) return account.IsSignedIn;
            return !provider.RequiresApiKey() || Keys.Read(provider.KeychainAccount()) is not null;
        }
    }

    public string AIShortName => Settings.AIProvider.ShortName();
    public string AIProviderTitle => Settings.AIProvider.Title();
    public IAIStreamingClient MakeAIClient() => AIClientFactory.Make(Settings.AIProvider, Settings.AIModel, Settings.CustomBaseUrl, Keys);
}

/// <summary>The panel's view of sync for authenticators.</summary>
public sealed class AuthenticatorSyncAdapter(SyncAccount sync) : IAuthenticatorSync
{
    public bool IsSignedIn => sync.IsSignedIn;
    public string? Error => sync.Error;
    public List<(string Uid, string Name)> ShareCandidates(Authenticator a) => sync.ShareCandidates(a);
    public Task<bool> ShareAsync(Authenticator a, string uid, string name) => sync.ShareAuthenticatorAsync(a, uid, name);
    public Task<DateTime?> RemoveAsync(Authenticator a, string uid) => sync.RemoveAuthenticatorShareAsync(a, uid);
    public Task<bool> TransferAsync(Authenticator a, string uid, string name) => sync.TransferAuthenticatorAsync(a, uid, name);
    public Task<bool> LeaveAsync(SharedAuthenticator shared) => sync.LeaveAuthenticatorAsync(shared);
    public Task<bool> DeleteAsync(Authenticator a) => sync.DeleteAuthenticatorAsync(a);
}
