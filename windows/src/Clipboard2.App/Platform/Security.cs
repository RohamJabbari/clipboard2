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

/// <summary>Secrets: values only in Credential Manager; pasting asks Windows Hello unless unlocked.</summary>
public sealed class SecretVault : ISecretVault
{
    private const string Prefix = "Clipboard2/secret/";
    private readonly Settings _settings;
    private DateTime? _lastAuthentication;
    public DateTime? UnlockedUntil { get; private set; }
    public List<SecretRef> All { get; private set; } = [];
    public IReadOnlyList<SecretRef> Secrets => All;
    public IReadOnlySet<string> ValueHashes { get; private set; } = new HashSet<string>();
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
            .Select(e => new SecretRef(e.Target[Prefix.Length..], e.Comment ?? "Untitled", e.Written))
            .OrderBy(s => s.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        ValueHashes = All.Select(s => CredentialManager.Read(Prefix + s.Id)).OfType<string>().Select(ContentHasher.HashText).ToHashSet();
        Changed?.Invoke();
    }

    public SecretRef? Add(string name, string value)
    {
        var id = Guid.NewGuid().ToString("N");
        if (!CredentialManager.Write(Prefix + id, value, comment: name)) return null;
        Reload();
        return All.FirstOrDefault(s => s.Id == id);
    }

    public void Rename(SecretRef secret, string name)
    {
        if (CredentialManager.Read(Prefix + secret.Id) is { } value) CredentialManager.Write(Prefix + secret.Id, value, comment: name);
        Reload();
    }

    public void SetValue(SecretRef secret, string value)
    {
        CredentialManager.Write(Prefix + secret.Id, value, comment: secret.Name);
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

    /// <summary>Windows Hello (face, fingerprint or PIN). Without Hello set up, secrets aren't gated.</summary>
    private async Task<bool> VerifyAsync(string reason)
    {
        if (!await HelloAvailableAsync())
        {
            Log.Info("Windows Hello isn't available; secrets are not gated");
            return true;
        }
        try
        {
            var result = await UserConsentVerifier.RequestVerificationAsync($"Clipboard2 wants to {reason}.");
            return result == UserConsentVerificationResult.Verified;
        }
        catch (Exception ex)
        {
            Log.Error("Windows Hello failed", ex);
            return false;
        }
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
