using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using Clipboard2.App.Platform;
using Clipboard2.Core;

namespace Clipboard2.App.Views;

/// <summary>Settings → General → Backup (encrypted export and import, docs/BACKUP-FORMAT.md), and the privacy
/// notice and Impressum (About, and a link at sign-up).</summary>
public sealed partial class SettingsWindow
{
    private const int MinBackupPassphraseLength = 8;
    private const string BackupFilter = "Clipboard2 backup (*.clipboard2backup)|*.clipboard2backup";
    private bool _backupIncludeSecrets;
    private bool _backupBusy;
    private string? _backupStatus;
    private TextBlock? _backupStatusLabel;
    private StackPanel? _backupButtons;

    // MARK: Backup

    private void AddBackupSection(StackPanel page)
    {
        page.Children.Add(Header("Backup"));
        var include = new CheckBox { Content = "Include secrets (asks for Windows Hello)", IsChecked = _backupIncludeSecrets };
        include.Checked += (_, _) => _backupIncludeSecrets = true;
        include.Unchecked += (_, _) => _backupIncludeSecrets = false;
        _backupButtons = Buttons(Action("Export Backup…", ExportBackup), Action("Import Backup…", ImportBackup));
        _backupButtons.IsEnabled = !_backupBusy;
        _backupStatusLabel = Fluent.Label(_backupStatus ?? "", 13, Fluent.Secondary, wrap: true);
        _backupStatusLabel.Visibility = _backupStatus is null ? Visibility.Collapsed : Visibility.Visible;
        page.Children.Add(Card(
            Row("History, pinned items and snippets", _backupButtons),
            include,
            _backupStatusLabel));
        page.Children.Add(Hint("One file, encrypted with a passphrase you choose — without it the backup can't be opened, by anyone. " +
            "Images are included; files are listed by name only. Sync group items aren't included. The same file opens in Clipboard2 for Mac. " +
            "Importing adds what's missing and never overwrites or deletes; your history limits still apply afterwards."));
    }

    private void SetBackupStatus(string? text, bool busy)
    {
        _backupStatus = text;
        _backupBusy = busy;
        if (_backupStatusLabel is not null)
        {
            _backupStatusLabel.Text = text ?? "";
            _backupStatusLabel.Visibility = text is null ? Visibility.Collapsed : Visibility.Visible;
        }
        if (_backupButtons is not null) _backupButtons.IsEnabled = !busy;
    }

    /// <summary>Asks for a new passphrase twice. Null when cancelled.</summary>
    private string? AskNewBackupPassphrase()
    {
        while (true)
        {
            var first = InputDialog.Ask("Export Backup",
                $"Choose a passphrase for this backup (at least {MinBackupPassphraseLength} characters). You'll need it to open the backup, and it can't be recovered.",
                secret: true, okTitle: "Next");
            if (first is null) return null;
            if (first.Length < MinBackupPassphraseLength)
            {
                MessageBox.Show(this, $"Use at least {MinBackupPassphraseLength} characters — a few words are best.", "Export Backup");
                continue;
            }
            var second = InputDialog.Ask("Export Backup", "Type the passphrase again.", secret: true, okTitle: "Export");
            if (second is null) return null;
            if (second == first) return first;
            MessageBox.Show(this, "The passphrases don't match. Try again.", "Export Backup");
        }
    }

    private async void ExportBackup()
    {
        if (_backupBusy) return;
        List<BackupSecret>? secrets = null;
        if (_backupIncludeSecrets)
        {
            // Windows Hello first: secret values end up in the file, protected only by the passphrase.
            if (!await _services.Secrets.AuthenticateAsync("export your secrets to a backup"))
            {
                SetBackupStatus("Nothing was exported: Windows Hello was cancelled. Untick “Include secrets” to export without them.", busy: false);
                return;
            }
            secrets = [.. _services.Secrets.All.Where(s => s.SpaceId is null)
                .Select(s => (Secret: s, Value: _services.Secrets.ReadValue(s)))
                .Where(x => x.Value is not null)
                .Select(x => new BackupSecret(x.Secret.Id, x.Secret.Name, x.Value!, x.Secret.CreatedAt))];
        }
        if (AskNewBackupPassphrase() is not { } passphrase) return;
        var dialog = new Microsoft.Win32.SaveFileDialog
        {
            Title = "Export Backup", Filter = BackupFilter, DefaultExt = Backup.Extension, AddExtension = true, OverwritePrompt = true,
            FileName = $"Clipboard2 {DateTime.Now:yyyy-MM-dd}{Backup.Extension}",
        };
        if (dialog.ShowDialog(this) != true) return;
        var path = dialog.FileName;
        SetBackupStatus("Exporting…", busy: true);
        try
        {
            var source = Backup.Snapshot(_services.Store);
            await Task.Run(() =>
            {
                var plaintext = Backup.CreatePlaintext(source, secrets, app: "windows");
                var file = BackupCrypto.Encrypt(plaintext, passphrase);
                CryptographicOperations.ZeroMemory(plaintext);
                var temp = path + ".tmp";
                File.WriteAllBytes(temp, file);
                File.Move(temp, path, overwrite: true);
            });
            var clips = source.Items.Count(i => i.Kind != ClipKind.Image || i.ImageFile is not null);
            var what = $"{clips} items, {source.Snippets.Count} snippets" + (secrets is null ? "" : $" and {secrets.Count} secrets");
            SetBackupStatus($"Exported {what} to {Path.GetFileName(path)}.", busy: false);
        }
        catch (Exception ex)
        {
            Log.Error("Backup export failed", ex);
            SetBackupStatus("The backup couldn't be written: " + ex.Message, busy: false);
        }
    }

    private async void ImportBackup()
    {
        if (_backupBusy) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Import Backup", Filter = BackupFilter + "|All files (*.*)|*.*" };
        if (dialog.ShowDialog(this) != true) return;
        byte[] file;
        try { file = await File.ReadAllBytesAsync(dialog.FileName); }
        catch (Exception ex)
        {
            SetBackupStatus("The file couldn't be read: " + ex.Message, busy: false);
            return;
        }
        JsonObject? root = null;
        while (root is null)
        {
            if (InputDialog.Ask("Import Backup", $"Enter the passphrase for “{Path.GetFileName(dialog.FileName)}”.", secret: true, okTitle: "Import") is not { } passphrase)
                return;
            SetBackupStatus("Opening the backup…", busy: true);
            try
            {
                root = await Task.Run(() => Backup.Parse(BackupCrypto.Decrypt(file, passphrase)));
            }
            catch (BackupException ex)
            {
                SetBackupStatus(null, busy: false);
                MessageBox.Show(this, ex.Message, "Import Backup", MessageBoxButton.OK, MessageBoxImage.Warning);
                if (!ex.WrongPassphrase) return;
            }
        }
        try
        {
            var summary = Backup.Summarize(root);
            var includeSecrets = summary.Secrets > 0 && MessageBox.Show(this,
                $"This backup contains {summary.Secrets} secrets. Add them to Credential Manager too?", "Import Backup",
                MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
            var result = Backup.Merge(root, _services.Store, includeSecrets ? _services.Secrets : null);
            _services.RunMaintenance();
            SetBackupStatus(result.Describe(), busy: false);
        }
        catch (Exception ex)
        {
            Log.Error("Backup import failed", ex);
            SetBackupStatus("The backup couldn't be imported: " + ex.Message, busy: false);
        }
    }

    // MARK: Privacy notice and Impressum

    private void AddLegalSection(StackPanel page)
    {
        page.Children.Add(Header("Privacy and legal"));
        page.Children.Add(Card(
            Row("What sync stores, where, and your rights", Action("Privacy Notice", () => LegalWindow.Open(this, "Privacy Notice", Legal.PrivacyNotice))),
            Row($"Operated by {Legal.Operator}, Austria", Action("Impressum", () => LegalWindow.Open(this, "Impressum", Legal.Impressum)))));
    }

    /// <summary>Shown above "Create Account".</summary>
    private UIElement PrivacyNoticeLink()
    {
        var text = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 13 };
        text.Inlines.Add("What the sync server stores, where, and your rights: ");
        var link = new Hyperlink(new Run("Privacy Notice"));
        link.Click += (_, _) => LegalWindow.Open(this, "Privacy Notice", Legal.PrivacyNotice);
        text.Inlines.Add(link);
        return text;
    }
}

/// <summary>A readable, scrollable legal text with a Copy button.</summary>
public sealed class LegalWindow : Window
{
    private LegalWindow(string title, IReadOnlyList<LegalSection> sections)
    {
        Title = title;
        Width = 620;
        Height = 640;
        MinWidth = 420;
        MinHeight = 320;
        Icon = Icons.AppIcon;
        var stack = new StackPanel { Margin = new Thickness(24, 20, 24, 12), MaxWidth = 640 };
        var heading = Fluent.Label(title, 20, null, FontWeights.SemiBold);
        heading.Margin = new Thickness(0, 0, 0, 12);
        stack.Children.Add(heading);
        foreach (var section in sections)
        {
            var header = Fluent.Label(section.Title, 14, null, FontWeights.SemiBold, wrap: true);
            header.Margin = new Thickness(0, 10, 0, 4);
            stack.Children.Add(header);
            var body = new TextBox
            {
                Text = section.Body, IsReadOnly = true, TextWrapping = TextWrapping.Wrap, BorderThickness = new Thickness(0),
                Background = System.Windows.Media.Brushes.Transparent, FontSize = 13, Padding = new Thickness(0),
            };
            stack.Children.Add(body);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(16, 8, 16, 12) };
        var copy = new Button { Content = "Copy Text", MinWidth = 90, Margin = new Thickness(0, 0, 8, 0) };
        copy.Click += (_, _) => ClipboardIO.WriteText(Legal.PlainText(sections));
        var close = new Button { Content = "Close", MinWidth = 90, IsCancel = true, IsDefault = true };
        close.Click += (_, _) => Close();
        buttons.Children.Add(copy);
        buttons.Children.Add(close);
        var dock = new DockPanel();
        DockPanel.SetDock(buttons, Dock.Bottom);
        dock.Children.Add(buttons);
        dock.Children.Add(new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        Content = dock;
    }

    public static void Open(Window owner, string title, IReadOnlyList<LegalSection> sections)
    {
        var window = new LegalWindow(title, sections) { Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        window.Show();
    }
}
