using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Clipboard2.App.Platform;
using Clipboard2.App.Views;
using Clipboard2.Core;
using Clipboard2.Core.AI;
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
    public QuickSlots Slots { get; }
    public ForegroundTracker Tracker { get; } = new();
    public HotkeyManager Hotkeys { get; } = new();
    public PanelModel Panel { get; }
    public UpdateService Updates { get; } = new();
    public SubscriptionAccount ClaudeAccount { get; } = new(SubscriptionCli.Claude);
    public SubscriptionAccount ChatGptAccount { get; } = new(SubscriptionCli.Codex);
    public ModelLister Models { get; }
    public Dispatcher Dispatcher { get; }

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
    private int _maintenanceRuns;

    public event Action? StoreChanged;

    public AppServices()
    {
        Shared = this;
        Dispatcher = Dispatcher.CurrentDispatcher;
        Directory.CreateDirectory(DataDirectory);
        Log.FilePath = Path.Combine(DataDirectory, "clipboard2.log");
        Settings = Settings.Load(SettingsPath);
        Store = new ClipStore(Path.Combine(DataDirectory, "history.db"), new BlobStore(Path.Combine(DataDirectory, "Blobs")));
        Secrets = new SecretVault(Settings);
        Slots = new QuickSlots(Settings);
        Models = new ModelLister(Keys);
        Panel = new PanelModel(Store, Settings, Slots, Secrets, this);
        Store.Changed += () => StoreChanged?.Invoke();
        Secrets.Changed += () => Store.RemoveUnpinned(Secrets.ValueHashes);
    }

    public void Start(bool background)
    {
        ApplyAppearance();
        _listener.Changed += OnClipboardChanged;
        Store.RemoveUnpinned(Secrets.ValueHashes);
        RunMaintenance();
        _maintenance.Tick += (_, _) => RunMaintenance();
        _maintenance.Start();

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
        _ = ClaudeAccount.RefreshAsync();
        _ = ChatGptAccount.RefreshAsync();

        if (!Settings.HasLaunchedBefore)
        {
            Settings.HasLaunchedBefore = true;
            Settings.Save();
            StartupRegistration.SetEnabled(Settings.LaunchAtLogin);
            _tray.ShowBalloon("Clipboard2 is running", "Press Ctrl+Shift+V to open your clipboard history. Click the tray icon for more.");
        }
        else if (!background)
        {
            _tray.ShowBalloon("Clipboard2 is running", $"Press {Settings.Hotkeys[Hotkey.QuickPanel]} to open it.");
        }
    }

    public void Shutdown()
    {
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
        for (var n = QuickSlots.First; n <= QuickSlots.Last; n++)
        {
            var slot = n;
            Hotkeys.Register(Hotkey.Slot(slot), Settings.Hotkeys.GetValueOrDefault(Hotkey.Slot(slot)), () => PasteSlot(slot));
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
            var processed = await CaptureProcessor.ProcessAsync(raw, Store.Blobs);
            if (processed is null) return;
            if (processed.Kind.IsTextual() && Secrets.ValueHashes.Contains(processed.Hash))
                return;   // a saved secret: never in history
            Store.Ingest(processed);
            Store.EnforceRetention(Settings.MaxItems, Settings.MaxAge);
        }
        catch (Exception ex)
        {
            Log.Error("Capture failed", ex);
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
        Panel.PrepareForOpen(Tracker.AppFor(_panelTarget));
        PanelWindow.ShowNear(_panelTarget);
    }

    private QuickPanelWindow PanelWindow => _panelWindow ??= new QuickPanelWindow(this);

    public void ClosePanel()
    {
        _panelWindow?.HidePanel();
        Panel.DidClose();
    }

    public void ShowFlyout(Point nearScreenPoint)
    {
        _flyout ??= new FlyoutWindow(this);
        _flyout.ShowNear(nearScreenPoint);
    }

    void IPanelHost.OpenSettings() => OpenSettings("AI");

    public void OpenSettings(string? tab = null)
    {
        Dispatcher.BeginInvoke(() =>
        {
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
        ClipboardIO.Write(item, appTransform, Store.Blobs);
        Store.Touch(item);
        _ = SendPasteAsync(target);
    }

    public void Paste(IReadOnlyList<ClipItem> items, Transform? transform)
    {
        var target = TargetForPaste;
        ClipboardIO.Write(items, transform, Store.Blobs);
        _ = SendPasteAsync(target);
    }

    public void PasteText(string text, int cursorOffsetFromEnd = 0)
    {
        var target = TargetForPaste;
        ClipboardIO.WriteText(text);
        _ = SendPasteAsync(target, cursorOffsetFromEnd);
    }

    public void Copy(ClipItem item)
    {
        ClipboardIO.Write(item, null, Store.Blobs);
        Store.Touch(item);
    }

    public void Copy(IReadOnlyList<ClipItem> items) => ClipboardIO.Write(items, null, Store.Blobs);
    public void CopyText(string text) => ClipboardIO.WriteText(text);
    public string? CurrentClipboardText() => ClipboardIO.CurrentText();

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

    private void WriteSecretWithAutoClear(string value)
    {
        ClipboardIO.WriteSecret(value);
        if (Settings.SecretClearSeconds <= 0) return;
        var sequence = Native.GetClipboardSequenceNumber();
        var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(Settings.SecretClearSeconds) };
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

    public async Task ShowSelectionActionsAsync()
    {
        var target = Tracker.TargetWindow;
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
        if (string.IsNullOrEmpty(text))
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        _panelTarget = target;
        Panel.PrepareForSelection(text, Tracker.AppFor(target));
        PanelWindow.ShowNear(target);
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
