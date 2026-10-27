using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Clipboard2.Core;
using Clipboard2.Core.AI;
using Microsoft.Win32;
using Windows.Security.Credentials.UI;

namespace Clipboard2.App.Platform;

/// <summary>Windows Credential Manager (generic credentials), the counterpart of the macOS Keychain.</summary>
public static class CredentialManager
{
    public sealed record Entry(string Target, string? UserName, string? Comment, DateTime Written);

    public static bool Write(string target, string secret, string? userName = null, string? comment = null)
    {
        var bytes = Encoding.Unicode.GetBytes(secret);
        var blob = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, blob, bytes.Length);
            var credential = new Native.CREDENTIAL
            {
                Type = Native.CRED_TYPE_GENERIC,
                TargetName = target,
                Comment = comment,
                CredentialBlobSize = (uint)bytes.Length,
                CredentialBlob = blob,
                Persist = Native.CRED_PERSIST_LOCAL_MACHINE,
                UserName = userName ?? Environment.UserName,
            };
            return Native.CredWrite(ref credential, 0);
        }
        finally
        {
            Marshal.FreeHGlobal(blob);
        }
    }

    public static string? Read(string target)
    {
        if (!Native.CredRead(target, Native.CRED_TYPE_GENERIC, 0, out var pointer)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<Native.CREDENTIAL>(pointer);
            if (credential.CredentialBlobSize == 0) return "";
            return Marshal.PtrToStringUni(credential.CredentialBlob, (int)credential.CredentialBlobSize / 2);
        }
        finally
        {
            Native.CredFree(pointer);
        }
    }

    public static void Delete(string target) => Native.CredDelete(target, Native.CRED_TYPE_GENERIC, 0);

    public static List<Entry> Enumerate(string filter)
    {
        var list = new List<Entry>();
        if (!Native.CredEnumerate(filter, 0, out var count, out var array)) return list;
        try
        {
            for (var i = 0; i < count; i++)
            {
                var c = Marshal.PtrToStructure<Native.CREDENTIAL>(Marshal.ReadIntPtr(array, i * IntPtr.Size));
                var written = DateTime.FromFileTimeUtc(((long)c.LastWritten.dwHighDateTime << 32) | (uint)c.LastWritten.dwLowDateTime);
                list.Add(new Entry(c.TargetName, c.UserName, c.Comment, written));
            }
        }
        finally
        {
            Native.CredFree(array);
        }
        return list;
    }
}

/// <summary>API keys in Credential Manager under "Clipboard2/&lt;account&gt;".</summary>
public sealed class CredentialKeyStore : IKeyStore
{
    private static string Target(string account) => $"Clipboard2/{account}";
    public string? Read(string account) => CredentialManager.Read(Target(account)) is { Length: > 0 } v ? v : null;
    public bool Save(string account, string value, string label) => CredentialManager.Write(Target(account), value, comment: label);
    public void Delete(string account) => CredentialManager.Delete(Target(account));
}

/// <summary>Secrets: values only in Credential Manager; pasting asks Windows Hello unless unlocked.
/// A synced group secret keeps its group id in the credential's UserName (personal ones have the Windows user name).</summary>
public sealed class SecretVault : ISecretVault
{
    private const string Prefix = "Clipboard2/secret/";
    private readonly Settings _settings;
    private DateTime? _lastAuthentication;
    public DateTime? UnlockedUntil { get; private set; }
    public List<SecretRef> All { get; private set; } = [];
    public IReadOnlyList<SecretRef> Secrets => All;
    public IReadOnlySet<string> ValueHashes { get; private set; } = new HashSet<string>();
    /// <summary>Value hashes per space (null key = personal), for removing history copies within one space.</summary>
    public IReadOnlyDictionary<string, IReadOnlySet<string>> HashesBySpace { get; private set; } = new Dictionary<string, IReadOnlySet<string>>();
    public const string PersonalSpaceKey = "";
    public event Action? Changed;

    public SecretVault(Settings settings)
    {
        _settings = settings;
        Reload();
        // Forget the automatic unlock window when the PC locks or sleeps.
        SystemEvents.SessionSwitch += (_, e) => { if (e.Reason == SessionSwitchReason.SessionLock) _lastAuthentication = null; };
        SystemEvents.PowerModeChanged += (_, e) => { if (e.Mode == PowerModes.Suspend) _lastAuthentication = null; };
    }

    public void Reload()
    {
        All = CredentialManager.Enumerate(Prefix + "*")
            .Select(e => new SecretRef(e.Target[Prefix.Length..], e.Comment ?? "Untitled", e.Written, SpaceFrom(e.UserName)))
            .OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        var hashes = All.Select(s => (s.SpaceId, Value: CredentialManager.Read(Prefix + s.Id))).Where(x => x.Value is not null)
            .Select(x => (x.SpaceId, Hash: ContentHasher.HashText(x.Value!))).ToList();
        ValueHashes = hashes.Select(h => h.Hash).ToHashSet();
        HashesBySpace = hashes.GroupBy(h => h.SpaceId ?? PersonalSpaceKey)
            .ToDictionary(g => g.Key, g => (IReadOnlySet<string>)g.Select(h => h.Hash).ToHashSet());
        Changed?.Invoke();
    }

    private static string? SpaceFrom(string? userName) => Guid.TryParse(userName, out var g) ? g.ToString("D") : null;

    public SecretRef? Add(string name, string value, string? spaceId = null)
    {
        var id = Guid.NewGuid().ToString("N");
        if (!CredentialManager.Write(Prefix + id, value, userName: spaceId, comment: name)) return null;
        Reload();
        return All.FirstOrDefault(s => s.Id == id);
    }

    public void Rename(SecretRef secret, string name)
    {
        if (CredentialManager.Read(Prefix + secret.Id) is { } value) CredentialManager.Write(Prefix + secret.Id, value, userName: secret.SpaceId, comment: name);
        Reload();
    }

    public void SetValue(SecretRef secret, string value)
    {
        CredentialManager.Write(Prefix + secret.Id, value, userName: secret.SpaceId, comment: secret.Name);
        Reload();
    }

    /// <summary>For sync only: reads without Windows Hello. Pasting and showing go through <see cref="RevealAsync"/>.</summary>
    public string? ReadValue(SecretRef secret) => CredentialManager.Read(Prefix + secret.Id);

    public void Put(Guid id, string name, string value, string? spaceId)
    {
        // Reuse the local spelling of an existing id (older secrets use "N", synced ones may arrive as "D").
        var existing = All.FirstOrDefault(s => Guid.TryParse(s.Id, out var g) && g == id)?.Id ?? id.ToString("N");
        CredentialManager.Write(Prefix + existing, value, userName: spaceId, comment: name);
        Reload();
    }

    public void Delete(SecretRef secret)
    {
        CredentialManager.Delete(Prefix + secret.Id);
        Reload();
    }

    // MARK: Unlocking

    public bool IsManuallyUnlocked => UnlockedUntil is { } until && until > DateTime.Now;

    public bool IsUnlocked =>
        IsManuallyUnlocked ||
        (_settings.SecretGraceMinutes > 0 && _lastAuthentication is { } last && DateTime.Now - last < TimeSpan.FromMinutes(_settings.SecretGraceMinutes));

    public void Lock()
    {
        _lastAuthentication = null;
        UnlockedUntil = null;
        Changed?.Invoke();
    }

    public static async Task<bool> HelloAvailableAsync()
    {
        try { return await UserConsentVerifier.CheckAvailabilityAsync() == UserConsentVerifierAvailability.Available; }
        catch { return false; }
    }

    public const string HelloRequiredMessage =
        "Secrets need Windows Hello. Set up a PIN, face or fingerprint in Windows Settings → Accounts → Sign-in options, then try again.";

    /// <summary>Why the last check refused, for callers that want to say so; null after a success.</summary>
    public string? LastDenial { get; private set; }

    /// <summary>Windows Hello (face, fingerprint or PIN). Fails closed: without Hello, or when it can't be asked,
    /// secrets stay locked.</summary>
    private async Task<bool> VerifyAsync(string reason)
    {
        LastDenial = null;
        if (!await HelloAvailableAsync())
        {
            Log.Info("Windows Hello isn't available; secrets stay locked");
            LastDenial = HelloRequiredMessage;
            TellUser(HelloRequiredMessage);
            return false;
        }
        try
        {
            var result = await UserConsentVerifier.RequestVerificationAsync($"Clipboard2 wants to {reason}.");
            if (result == UserConsentVerificationResult.Verified) return true;
            LastDenial = result == UserConsentVerificationResult.Canceled ? null : $"Windows Hello didn't confirm it's you ({result}).";
            return false;
        }
        catch (Exception ex)
        {
            Log.Error("Windows Hello failed", ex);
            LastDenial = "Windows Hello couldn't be asked, so the secret stays locked.";
            return false;
        }
    }

    /// <summary>Says why, so a missing Windows Hello doesn't look like a broken button.</summary>
    private static void TellUser(string message)
    {
        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            System.Windows.MessageBox.Show(message, "Clipboard2", System.Windows.MessageBoxButton.OK, System.Windows.MessageBoxImage.Information));
    }

    public async Task<bool> AuthenticateAsync(string reason)
    {
        if (IsUnlocked) return true;
        if (!await VerifyAsync(reason)) return false;
        _lastAuthentication = DateTime.Now;
        return true;
    }

    public async Task<bool> UnlockForAsync(TimeSpan duration, string label)
    {
        if (!await VerifyAsync($"leave secrets unlocked for {label}")) return false;
        UnlockedUntil = DateTime.Now + duration;
        Changed?.Invoke();
        return true;
    }

    public async Task<string?> RevealAsync(SecretRef secret, string reason) =>
        await AuthenticateAsync(reason) ? CredentialManager.Read(Prefix + secret.Id) : null;
}

/// <summary>Run at sign-in via HKCU\...\Run (no admin rights, works with Velopack's install folder).</summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Clipboard2";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue(Name) is string;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
            if (enabled && Environment.ProcessPath is { } path) key.SetValue(Name, $"\"{path}\" --background");
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
        catch (Exception ex)
        {
            Log.Error("Changing the startup entry failed", ex);
        }
    }
}
