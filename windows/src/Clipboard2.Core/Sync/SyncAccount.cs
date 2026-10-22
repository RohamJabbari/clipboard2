using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using Clipboard2.Core.AI;

namespace Clipboard2.Core.Sync;

public enum SyncPhase
{
    SignedOut,
    SignedIn,
    /// <summary>The session ended (expired, or the password was changed on another device). The keys and local data
    /// stay; entering the password again carries on.</summary>
    NeedsSignIn,
}

/// <summary>An invite code that has been opened: the group it joins and its key, before accepting.</summary>
public sealed record InvitePreview(string InviteId, string SpaceId, string Name, int MemberCount, DateTime ExpiresAt, byte[] SpaceKey);

/// <summary>
/// The sync account: sign-up, sign-in, password changes, groups, invite codes and the sync loop around
/// <see cref="SyncEngine"/>. The password never leaves the device: only authKey is sent, and wrapKey unlocks the
/// account key locally. There is no recovery: a forgotten password means the synced data is gone.
/// The session token and keys live in the key store (Credential Manager under <c>Clipboard2/sync/…</c>), never in
/// settings. Use from the UI thread; <see cref="Changed"/> fires there.
/// </summary>
public sealed class SyncAccount
{
    private const string TokenKey = "sync/session-token";
    private const string AccountKey = "sync/account";
    private const string AccountKeyKey = "sync/account-key";
    private const string IdentityKeyKey = "sync/identity-key";
    public const int MinPasswordLength = 8;

    private readonly ClipStore _store;
    private readonly ISecretVault _vault;
    private readonly Settings _settings;
    private readonly IKeyStore _keys;
    private readonly SyncApi _api;
    private readonly Func<DateTime> _now;
    private readonly int _iterations;

    private string? _token;
    private SyncEngine? _engine;
    private bool _syncing, _again;
    private Task? _running;

    public SyncPhase Phase { get; private set; } = SyncPhase.SignedOut;
    public string? Email { get; private set; }
    public string? Uid { get; private set; }
    public bool IsBusy { get; private set; }
    public string? Status { get; private set; }
    public string? Error { get; private set; }
    public bool IsSyncing => _syncing;
    public DateTime? LastSync { get; private set; }
    public DateTime? RetryAfter { get; private set; }
    public IReadOnlyList<string> Warnings { get; private set; } = [];
    public bool IsSignedIn => Phase == SyncPhase.SignedIn;
    public SyncEngine? Engine => _engine;
    public SyncApi Api => _api;
    public Action<string>? Logger { get; set; }
    public event Action? Changed;

    public SyncAccount(ClipStore store, ISecretVault vault, Settings settings, IKeyStore keys, HttpClient? http = null,
                       Func<DateTime>? clock = null, int kdfIterations = SyncCrypto.KdfIterations)
    {
        _store = store;
        _vault = vault;
        _settings = settings;
        _keys = keys;
        _now = clock ?? (() => DateTime.UtcNow);
        _iterations = kdfIterations;
        _api = new SyncApi(() => _token, () => SyncConfig.ApiBaseUrl(_settings), http);
    }

    private void Notify() => Changed?.Invoke();

    private static string DeviceName => Environment.MachineName;

    // MARK: Groups

    public List<SpaceRecord> Groups => _engine is null ? [] : _store.Groups();
    public SpaceRecord? DefaultGroup => Groups.FirstOrDefault(g => g.Id == _settings.DefaultGroupId) ?? (Groups.Count == 1 ? Groups[0] : null);

    public void SetDefaultGroup(string? id)
    {
        _settings.DefaultGroupId = id;
        _settings.Save();
        Notify();
    }

    // MARK: Startup

    /// <summary>Restores the signed-in state from the key store (no network).</summary>
    public void Restore()
    {
        var account = Parse(_keys.Read(AccountKey));
        Email = account?["email"]?.GetValue<string>();
        Uid = account?["uid"]?.GetValue<string>();
        _token = _keys.Read(TokenKey);
        if (account is not null && LoadIdentity(account) is { } identity)
        {
            StartEngine(identity);
            Phase = _token is null ? SyncPhase.NeedsSignIn : SyncPhase.SignedIn;
        }
        else
        {
            Phase = SyncPhase.SignedOut;
        }
        Notify();
    }

    private SyncIdentity? LoadIdentity(JsonObject account)
    {
        try
        {
            if (Uid is null || account["personalSpaceId"]?.GetValue<string>() is not { } personal || account["publicKey"]?.GetValue<string>() is not { } pub) return null;
            if (_keys.Read(IdentityKeyKey) is not { } priv || _keys.Read(AccountKeyKey) is null) return null;
            return new SyncIdentity(Uid, Email ?? "", new EcKeyPair(Convert.FromBase64String(priv), Convert.FromBase64String(pub)), personal);
        }
        catch (FormatException) { return null; }
    }

    // MARK: Account flows

    /// <summary>Creates the keys on this PC and the account on the server. There is no password recovery.</summary>
    public Task<bool> CreateAccountAsync(string email, string password, string confirmation) => Run("Creating your account…", async ct =>
    {
        email = SyncCrypto.NormalizeEmail(email);
        if (!email.Contains('@')) throw new SyncUserException("Enter your email address.");
        if (password.Length < MinPasswordLength) throw new SyncUserException($"Use at least {MinPasswordLength} characters for the password.");
        if (password != confirmation) throw new SyncUserException("The passwords don't match.");
        var uid = Guid.NewGuid().ToString("D");
        var m = await Task.Run(() =>
        {
            var kdf = new Kdf(SyncCrypto.RandomSalt(), _iterations);
            var keys = SyncCrypto.DerivePasswordKeys(password, kdf.Salt, kdf.Iterations);
            var accountKey = SyncCrypto.RandomKey();
            var identity = SyncCrypto.GenerateKeyPair();
            var spaceId = Guid.NewGuid().ToString("D");
            return (kdf, keys, accountKey, identity, spaceId,
                WrappedAK: SyncCrypto.Seal(keys.WrapKey, accountKey, SyncCrypto.Aad.AccountKey(uid)),
                WrappedPriv: SyncCrypto.Seal(accountKey, identity.Private, SyncCrypto.Aad.PrivateKey(uid)),
                PersonalKey: SyncCrypto.WrapSpaceKey(SyncCrypto.RandomKey(), spaceId, uid, identity.Public));
        }, ct);
        SessionInfo session;
        try
        {
            session = await _api.SignupAsync(email, m.keys.AuthKey, m.kdf, uid, m.WrappedAK, m.identity.Public, m.WrappedPriv,
                m.spaceId, m.PersonalKey, DeviceName, ct);
        }
        catch (SyncApiException ex) when (ex.Code == "conflict")
        {
            throw new SyncUserException("An account with this email already exists. Sign in instead.");
        }
        ResetLocalSync();
        FinishSignIn(session, m.accountKey, m.identity.Private);
    });

    /// <summary>prelogin → derive keys → login. Also used to continue after the session ended.</summary>
    public Task<bool> SignInAsync(string email, string password) => Run("Signing in…", async ct =>
    {
        email = SyncCrypto.NormalizeEmail(email);
        var kdf = await _api.PreloginAsync(email, ct);
        var keys = await Task.Run(() => SyncCrypto.DerivePasswordKeys(password, kdf.Salt, kdf.Iterations), ct);
        var session = await _api.LoginAsync(email, keys.AuthKey, DeviceName, ct);
        var account = session.Account;
        byte[] accountKey, priv;
        try
        {
            accountKey = SyncCrypto.Open(keys.WrapKey, account.WrappedAccountKey, SyncCrypto.Aad.AccountKey(account.Uid));
            priv = SyncCrypto.Open(accountKey, account.WrappedPrivateKey, SyncCrypto.Aad.PrivateKey(account.Uid));
        }
        catch (CryptographicException)
        {
            _token = session.Token;
            try { await _api.LogoutAsync(ct); } catch { }
            _token = null;
            throw new SyncUserException("Signed in, but your synced data couldn't be unlocked with this password.");
        }
        if (Uid is not null && Uid != account.Uid) ResetLocalSync();   // a different account than last time on this PC
        FinishSignIn(session, accountKey, priv);
    });

    /// <summary>Re-wraps the account key with the new password; items and space keys stay. Other sessions end.</summary>
    public Task<bool> ChangePasswordAsync(string current, string newPassword, string confirmation) => Run("Changing your password…", async ct =>
    {
        if (newPassword.Length < MinPasswordLength) throw new SyncUserException($"Use at least {MinPasswordLength} characters for the password.");
        if (newPassword != confirmation) throw new SyncUserException("The new passwords don't match.");
        if (Email is null || Uid is null || _keys.Read(AccountKeyKey) is not { } ak) throw new SyncUserException("Sign in first.");
        var accountKey = Convert.FromBase64String(ak);
        var kdf = await _api.PreloginAsync(Email, ct);
        var (oldKeys, newKdf, newKeys) = await Task.Run(() =>
        {
            var next = new Kdf(SyncCrypto.RandomSalt(), _iterations);
            return (SyncCrypto.DerivePasswordKeys(current, kdf.Salt, kdf.Iterations), next,
                SyncCrypto.DerivePasswordKeys(newPassword, next.Salt, next.Iterations));
        }, ct);
        try
        {
            await _api.ChangePasswordAsync(oldKeys.AuthKey, newKeys.AuthKey, newKdf,
                SyncCrypto.Seal(newKeys.WrapKey, accountKey, SyncCrypto.Aad.AccountKey(Uid)), ct);
        }
        catch (SyncApiException ex) when (ex.Code == "invalid_credentials")
        {
            throw new SyncUserException("The current password is wrong.");
        }
        Status = "Password changed. Other devices will ask for the new password.";
    }, keepStatus: true);

    /// <summary>Ends the session on the server, then removes group data, sync state and keys. Personal history stays.</summary>
    public Task<bool> SignOutAsync() => Run(null, async ct =>
    {
        if (_token is not null)
        {
            try { await _api.LogoutAsync(ct); }
            catch (Exception ex) when (ex is SyncApiException) { Logger?.Invoke("Logout failed: " + ex.Message); }
        }
        SignOutLocally();
    });

    /// <summary>Deletes the server account (personal space, owned groups). Local personal history stays.</summary>
    public Task<bool> DeleteAccountAsync(string password) => Run("Deleting your account…", async ct =>
    {
        if (Email is null) throw new SyncUserException("Sign in first.");
        var kdf = await _api.PreloginAsync(Email, ct);
        var keys = await Task.Run(() => SyncCrypto.DerivePasswordKeys(password, kdf.Salt, kdf.Iterations), ct);
        try { await _api.DeleteAccountAsync(keys.AuthKey, ct); }
        catch (SyncApiException ex) when (ex.Code is "invalid_credentials" or "forbidden")
        {
            throw new SyncUserException("The password is wrong.");
        }
        SignOutLocally();
        Status = "Your sync account was deleted.";
    }, keepStatus: true);

    // MARK: Groups

    public Task<bool> CreateGroupAsync(string name) => Run("Creating the group…", async ct =>
    {
        name = name.Trim();
        if (name.Length == 0) throw new SyncUserException("Give the group a name.");
        var engine = RequireEngine();
        var id = Guid.NewGuid().ToString("D");
        var key = SyncCrypto.RandomKey();
        var encryptedName = SyncCrypto.Seal(SyncCrypto.NameKey(key), Encoding.UTF8.GetBytes(name), SyncCrypto.Aad.Name(id));
        var wrapped = SyncCrypto.WrapSpaceKey(key, id, engine.Identity.Uid, engine.Identity.Keys.Public);
        var info = await _api.CreateGroupAsync(id, encryptedName, wrapped, ct);
        engine.AddSpace(info, key, name);
        if (DefaultGroup is null) _settings.DefaultGroupId = id;
        _settings.Save();
    });

    public Task<bool> RenameGroupAsync(string id, string name) => Run("Renaming…", async ct =>
    {
        name = name.Trim();
        if (name.Length == 0) return;
        var space = await SpaceAsync(id, ct);
        await _api.RenameGroupAsync(id, SyncCrypto.Seal(space.NameKey, Encoding.UTF8.GetBytes(name), SyncCrypto.Aad.Name(id)), ct);
        space.Name = name;
        _store.SaveSyncSpaces(RequireEngine().Spaces.Select(s => s.Record));
    });

    public async Task<List<GroupMember>> MembersAsync(string id)
    {
        try { return await _api.MembersAsync(id); }
        catch (SyncApiException ex)
        {
            Error = Friendly(ex);
            Notify();
            return [];
        }
    }

    public Task<bool> RemoveMemberAsync(string id, string uid) => Run("Removing…", async ct =>
    {
        await _api.RemoveMemberAsync(id, uid, ct);
        await RequireEngine().RefreshSpacesAsync(ct);
    });

    public Task<bool> LeaveGroupAsync(string id) => Run("Leaving…", async ct =>
    {
        await _api.RemoveMemberAsync(id, Uid!, ct);
        ForgetGroup(id);
    });

    public Task<bool> DeleteGroupAsync(string id) => Run("Deleting the group…", async ct =>
    {
        await _api.DeleteGroupAsync(id, ct);
        ForgetGroup(id);
    });

    // MARK: Invites

    /// <summary>Creates a single-use invite (valid 7 days) and returns the formatted code, shown to the owner once.</summary>
    public async Task<string?> CreateInviteAsync(string groupId)
    {
        string? code = null;
        await Run("Creating an invite code…", async ct =>
        {
            var space = await SpaceAsync(groupId, ct);
            var bytes = InviteCode.Generate();
            await _api.CreateInviteAsync(groupId, SyncCrypto.InviteId(bytes), SyncCrypto.SealInvite(bytes, space.Key, groupId), ct);
            code = InviteCode.Format(bytes);
        });
        return code;
    }

    public async Task<List<PendingInvite>> InvitesAsync(string groupId)
    {
        try { return await _api.InvitesAsync(groupId); }
        catch (SyncApiException ex)
        {
            Error = Friendly(ex);
            Notify();
            return [];
        }
    }

    public Task<bool> RevokeInviteAsync(string groupId, string inviteId) => Run("Revoking…", ct => _api.RevokeInviteAsync(groupId, inviteId, ct));

    /// <summary>Opens a typed code: fetches the invite, unseals the group key and decrypts the name. Null (with
    /// <see cref="Error"/>) if the code is malformed, unknown, used or expired.</summary>
    public async Task<InvitePreview?> PreviewInviteAsync(string typedCode)
    {
        InvitePreview? preview = null;
        await Run("Checking the code…", async ct =>
        {
            RequireEngine();
            var bytes = InviteCode.Parse(typedCode) ?? throw new SyncUserException("That doesn't look like an invite code. It has 26 letters and digits, like ABCD-EFGH-….");
            var inviteId = SyncCrypto.InviteId(bytes);
            var invite = await _api.GetInviteAsync(inviteId, ct)
                ?? throw new SyncUserException("That invite code is unknown, already used or expired. Ask for a new one.");
            byte[] key;
            try { key = SyncCrypto.OpenInvite(bytes, invite.SealedKey, invite.SpaceId); }
            catch (CryptographicException) { throw new SyncUserException("That invite code doesn't match its group."); }
            var name = "Untitled group";
            if (invite.EncryptedName is { Length: > 0 } sealedName)
            {
                try { name = Encoding.UTF8.GetString(SyncCrypto.Open(SyncCrypto.NameKey(key), sealedName, SyncCrypto.Aad.Name(invite.SpaceId))); }
                catch (CryptographicException) { }
            }
            preview = new InvitePreview(inviteId, invite.SpaceId, name, invite.MemberCount, SyncPayload.FromMillis(invite.ExpiresAt), key);
        });
        return preview;
    }

    /// <summary>Accepts an opened invite: the group key is wrapped to this account's own public key.</summary>
    public Task<bool> JoinAsync(InvitePreview invite) => Run($"Joining {invite.Name}…", async ct =>
    {
        var engine = RequireEngine();
        SpaceInfo info;
        try
        {
            info = await _api.AcceptInviteAsync(invite.InviteId,
                SyncCrypto.WrapSpaceKey(invite.SpaceKey, invite.SpaceId, engine.Identity.Uid, engine.Identity.Keys.Public), ct);
        }
        catch (SyncApiException ex) when (ex.Code == "conflict")
        {
            throw new SyncUserException($"You're already in {invite.Name}.");
        }
        catch (SyncApiException ex) when (ex.Code == "not_found")
        {
            throw new SyncUserException("That invite was used or has expired. Ask for a new one.");
        }
        engine.AddSpace(info, invite.SpaceKey, invite.Name);
        if (DefaultGroup is null) _settings.DefaultGroupId = invite.SpaceId;
        _settings.Save();
        Status = $"You joined {invite.Name}.";
        _ = SyncNowAsync();
    }, keepStatus: true);

    private void ForgetGroup(string id)
    {
        RequireEngine().RemoveGroupLocally(id);
        if (_settings.DefaultGroupId == id)
        {
            _settings.DefaultGroupId = null;
            _settings.Save();
        }
    }

    private async Task<SyncSpace> SpaceAsync(string id, CancellationToken ct)
    {
        var engine = RequireEngine();
        if (engine.Space(id) is null) await engine.RefreshSpacesAsync(ct);
        return engine.Space(id) ?? throw new SyncUserException("That group isn't available any more.");
    }

    private SyncEngine RequireEngine() => _engine is not null && Phase == SyncPhase.SignedIn ? _engine : throw new SyncUserException("Sign in to sync first.");

    // MARK: Syncing

    /// <summary>One tick at a time; a request during a tick runs another one right after it, and the returned
    /// task completes when both are done.</summary>
    public Task SyncNowAsync(CancellationToken ct = default)
    {
        if (_running is { IsCompleted: false })
        {
            _again = true;
            return _running;
        }
        if (Phase != SyncPhase.SignedIn || _engine is null) return Task.CompletedTask;
        if (RetryAfter is { } until && until > _now()) return Task.CompletedTask;
        return _running = RunTicksAsync(ct);
    }

    private async Task RunTicksAsync(CancellationToken ct)
    {
        _syncing = true;
        Notify();
        try
        {
            do
            {
                _again = false;
                if (_engine is not { } engine) break;
                var report = await engine.TickAsync(ct);
                LastSync = _now();
                Error = null;
                RetryAfter = null;
                Warnings = report.Warnings;
            } while (_again && Phase == SyncPhase.SignedIn);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            HandleSyncFailure(ex);
        }
        finally
        {
            _syncing = false;
            Notify();
        }
    }

    private void HandleSyncFailure(Exception ex)
    {
        Logger?.Invoke("Sync failed: " + ex.Message);
        switch (ex)
        {
            case SyncApiException { Code: "rate_limited" } limited:
                RetryAfter = _now() + (limited.RetryAfter ?? TimeSpan.FromSeconds(60));   // progress is kept; continue later
                break;
            case SyncApiException { Code: "unauthenticated" }:
                SessionEnded();
                break;
            case SyncAccountGoneException:
                SignOutLocally();
                Error = ex.Message;
                break;
            default:
                Error = Friendly(ex);
                break;
        }
    }

    /// <summary>401: ask for the password again. Keys and local data stay, so nothing is lost meanwhile.</summary>
    private void SessionEnded()
    {
        _token = null;
        _keys.Delete(TokenKey);
        Phase = SyncPhase.NeedsSignIn;
        Error = "Your session ended. Enter your password to keep syncing.";
    }

    // MARK: Internals

    private void FinishSignIn(SessionInfo session, byte[] accountKey, byte[] priv)
    {
        var account = session.Account;
        _token = session.Token;
        _keys.Save(TokenKey, session.Token, "Clipboard2 sync – session");
        _keys.Save(AccountKeyKey, Convert.ToBase64String(accountKey), "Clipboard2 sync – account key");
        _keys.Save(IdentityKeyKey, Convert.ToBase64String(priv), "Clipboard2 sync – identity key");
        Uid = account.Uid;
        Email = account.Email.Length > 0 ? account.Email : Email;
        _keys.Save(AccountKey, new JsonObject
        {
            ["uid"] = account.Uid, ["email"] = Email, ["personalSpaceId"] = account.PersonalSpaceId,
            ["publicKey"] = Convert.ToBase64String(account.PublicKey),
        }.ToJsonString(), "Clipboard2 sync – account");
        StartEngine(new SyncIdentity(account.Uid, Email ?? "", new EcKeyPair(priv, account.PublicKey), account.PersonalSpaceId));
        Phase = SyncPhase.SignedIn;
        RetryAfter = null;
        _ = SyncNowAsync();
    }

    private void StartEngine(SyncIdentity identity) =>
        _engine = new SyncEngine(_store, _vault, _api, identity, _now) { Logger = m => Logger?.Invoke(m) };

    private void SignOutLocally()
    {
        _engine = null;
        ResetLocalSync();
        foreach (var key in new[] { TokenKey, AccountKey, AccountKeyKey, IdentityKeyKey }) _keys.Delete(key);
        _token = null;
        Email = null;
        Uid = null;
        LastSync = null;
        Phase = SyncPhase.SignedOut;
        if (_settings.DefaultGroupId is not null)
        {
            _settings.DefaultGroupId = null;
            _settings.Save();
        }
    }

    /// <summary>Group data, sync meta and cursors go; personal history and secrets stay.</summary>
    private void ResetLocalSync()
    {
        foreach (var secret in _vault.Secrets.Where(s => s.SpaceId is not null).ToList()) _vault.Delete(secret);
        _store.ResetSync();
    }

    private static JsonObject? Parse(string? json)
    {
        if (json is null) return null;
        try { return JsonNode.Parse(json) as JsonObject; } catch { return null; }
    }

    /// <summary>Runs an account operation: busy state, friendly errors, one Changed at the start and the end.</summary>
    private async Task<bool> Run(string? busy, Func<CancellationToken, Task> work, bool keepStatus = false)
    {
        IsBusy = busy is not null;
        Status = busy;
        Error = null;
        Notify();
        try
        {
            await work(CancellationToken.None);
            if (!keepStatus) Status = null;
            return true;
        }
        catch (Exception ex)
        {
            Logger?.Invoke("Sync account: " + ex.Message);
            Status = null;
            if (ex is SyncApiException { Code: "unauthenticated" } && Phase == SyncPhase.SignedIn) SessionEnded();
            else Error = Friendly(ex);
            return false;
        }
        finally
        {
            IsBusy = false;
            Notify();
        }
    }

    public static string Friendly(Exception ex) => ex switch
    {
        SyncUserException or SyncAccountGoneException => ex.Message,
        SyncApiException { Code: "invalid_credentials" } => "The email or password is wrong.",
        SyncApiException { Code: "unauthenticated" } => "Your session ended. Enter your password to keep syncing.",
        SyncApiException { Code: "network" } => ex.Message,
        SyncApiException { Code: "quota_exceeded" or "too_large" or "forbidden" or "not_found" or "invalid" } => ex.Message,
        SyncApiException { Code: "rate_limited" } => "Too many attempts right now. Try again in a minute.",
        SyncApiException api => $"The sync server reported a problem: {api.Message}",
        CryptographicException => "Your synced data couldn't be decrypted on this PC.",
        _ => ex.Message,
    };
}

/// <summary>A problem the user can fix; the message is shown as is.</summary>
public sealed class SyncUserException(string message) : Exception(message);
