using System.ComponentModel;
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

/// <summary>What the tray and panel indicator show. The names are stable.</summary>
public enum SyncStatus
{
    /// <summary>Signed in and up to date (or waiting out a rate limit).</summary>
    Idle,
    Syncing,
    /// <summary>The last tick couldn't reach the server.</summary>
    Offline,
    /// <summary>Something needs attention: <see cref="SyncAccount.Error"/> says what (a session that ended, a clock
    /// that's off, a group key that changed…).</summary>
    Error,
    SignedOut,
}

/// <summary>An invite code that has been opened: the group it joins and its key, before accepting.</summary>
public sealed record InvitePreview(string InviteId, string SpaceId, string Name, int MemberCount, DateTime ExpiresAt, byte[] SpaceKey);

/// <summary>What the "Invite code" field of the sign-up form holds.</summary>
public abstract record SignupInvite
{
    /// <summary>A sign-up code (16 characters), as normalised for the server.</summary>
    public sealed record Code(string Value) : SignupInvite;
    /// <summary>A group invite code (26 characters): sign up, then join that group.</summary>
    public sealed record Group(byte[] CodeBytes) : SignupInvite
    {
        public string InviteId => SyncCrypto.InviteId(CodeBytes);
    }

    public const int SignupCodeLength = 16;
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    /// <summary>Like invite codes: spaces, dashes and case are ignored and 0/1/8 read as O/I/B. Null if it's neither kind.</summary>
    public static SignupInvite? Parse(string? typed)
    {
        if (typed is null) return null;
        var chars = new string([.. typed.Where(c => !char.IsWhiteSpace(c) && c != '-').Select(char.ToUpperInvariant)
            .Select(c => c switch { '0' => 'O', '1' => 'I', '8' => 'B', _ => c })]);
        if (chars.Length == InviteCode.CharLength) return InviteCode.Parse(chars) is { } bytes ? new Group(bytes) : null;
        return chars.Length == SignupCodeLength && chars.All(Alphabet.Contains) ? new Code(chars) : null;
    }
}

/// <summary>
/// The sync account: sign-up, sign-in, password changes, groups, invite codes, devices and the sync loop around
/// <see cref="SyncEngine"/>. The password never leaves the device: only authKey is sent, and wrapKey unlocks the
/// account key locally. There is no recovery: a forgotten password means the synced data is gone.
/// The session token and keys live in the key store (Credential Manager under <c>Clipboard2/sync/…</c>), never in
/// settings. Use from the UI thread; <see cref="Changed"/> and <see cref="PropertyChanged"/> fire there.
/// </summary>
public sealed partial class SyncAccount : INotifyPropertyChanged
{
    private const string TokenKey = "sync/session-token";
    private const string AccountKey = "sync/account";
    private const string AccountKeyKey = "sync/account-key";
    private const string IdentityKeyKey = "sync/identity-key";
    private const string KdfKeyPrefix = "sync/kdf/";
    public const int MinPasswordLength = 8;

    /// <summary>Polling cadence (HARDENING-2026-10 → Clients).</summary>
    public static readonly TimeSpan PanelPollInterval = TimeSpan.FromSeconds(3), ActivePollInterval = TimeSpan.FromSeconds(15),
        IdlePollInterval = TimeSpan.FromSeconds(60), ActiveWindow = TimeSpan.FromMinutes(5);

    private readonly ClipStore _store;
    private readonly ISecretVault _vault;
    private readonly Settings _settings;
    private readonly IKeyStore _keys;
    private readonly SyncApi _api;
    private readonly SpaceKeyPins _pins;
    private readonly Func<DateTime> _now;
    private readonly int _iterations;
    /// <summary>The lowest KDF cost accepted from a server: the protocol's floor (lower only in tests with cheap accounts).</summary>
    private readonly int _kdfFloor;

    private string? _token;
    private SyncEngine? _engine;
    private bool _syncing, _again, _offline;
    /// <summary>The account was fetched in this session (a username set on another device shows up).</summary>
    private bool _accountFresh;
    private bool _devicesFresh;
    private Task? _running;
    private bool _panelOpen;
    private DateTime _lastActivity = DateTime.MinValue;
    private DateTime? _lastTickStarted;

    public SyncPhase Phase { get; private set; } = SyncPhase.SignedOut;
    public string? Email { get; private set; }
    public string? Uid { get; private set; }
    /// <summary>Shown to group members on the items this user copies. Null for accounts made before usernames.</summary>
    public string? Username { get; private set; }
    /// <summary>For group badges: who "me" is.</summary>
    public SyncSelf? Self => Uid is { } uid ? new SyncSelf(uid, Username) : null;
    public bool IsBusy { get; private set; }
    /// <summary>What an account operation is doing or did ("Signing in…", "Password changed."); null when nothing to say.</summary>
    public string? Status { get; private set; }
    public string? Error { get; private set; }
    /// <summary>For the tray and panel indicator; <see cref="PropertyChanged"/> reports changes.</summary>
    public SyncStatus CurrentStatus { get; private set; } = SyncStatus.SignedOut;
    public bool IsSyncing => _syncing;
    public DateTime? LastSync { get; private set; }
    public DateTime? RetryAfter { get; private set; }
    public IReadOnlyList<string> Warnings { get; private set; } = [];
    public bool IsSignedIn => Phase == SyncPhase.SignedIn;
    public SyncEngine? Engine => _engine;
    public SyncApi Api => _api;
    /// <summary>This account's signed-in devices, as of the last <see cref="RefreshDevicesAsync"/> (or the session's first sync).</summary>
    public IReadOnlyList<SyncDevice> Devices { get; private set; } = [];
    /// <summary>This PC's session id, once the devices were fetched.</summary>
    public string? CurrentDeviceId { get; private set; }
    public Action<string>? Logger { get; set; }
    public event Action? Changed;
    public event PropertyChangedEventHandler? PropertyChanged;
    /// <summary>Another device sent a clip here: the item (now at the top) and the sender's device name.</summary>
    public event Action<ClipItem, string>? ReceivedFromDevice;

    public SyncAccount(ClipStore store, ISecretVault vault, Settings settings, IKeyStore keys, HttpClient? http = null,
                       Func<DateTime>? clock = null, int kdfIterations = SyncCrypto.KdfIterations,
                       int minKdfIterations = SyncCrypto.MinKdfIterations)
    {
        _store = store;
        _vault = vault;
        _settings = settings;
        _keys = keys;
        _pins = new SpaceKeyPins(keys);
        _now = clock ?? (() => DateTime.UtcNow);
        _iterations = kdfIterations;
        _kdfFloor = minKdfIterations;
        _api = new SyncApi(() => _token, () => SyncConfig.ApiBaseUrl(_settings), http);
    }

    private void Notify()
    {
        var status = Phase switch
        {
            SyncPhase.SignedOut => SyncStatus.SignedOut,
            SyncPhase.NeedsSignIn => SyncStatus.Error,
            _ when _syncing => SyncStatus.Syncing,
            _ when _offline => SyncStatus.Offline,
            _ when Error is not null => SyncStatus.Error,
            _ => SyncStatus.Idle,
        };
        if (status != CurrentStatus)
        {
            CurrentStatus = status;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CurrentStatus)));
        }
        Changed?.Invoke();
    }

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
        Username = account?["username"] is JsonValue username ? username.GetValue<string>() : null;
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

    // MARK: KDF bounds

    private static string KdfKey(string email) => KdfKeyPrefix + SyncCrypto.Sha256Hex(Encoding.UTF8.GetBytes(email))[..32];

    /// <summary>Refuses KDF parameters a hostile server could use to weaken the password's protection (or to tie the
    /// PC up), before the password is used: outside 600,000–10,000,000 iterations, or lower than last time.</summary>
    private void CheckKdf(string email, Kdf kdf)
    {
        if (kdf.Iterations < _kdfFloor || kdf.Iterations > SyncCrypto.MaxKdfIterations || kdf.Salt.Length < SyncCrypto.SaltSize)
            throw new SyncUserException("The sync server asked for unusual password settings, so your password wasn't used. Try again later.");
        if (_keys.Read(KdfKey(email)) is { } known && int.TryParse(known, out var iterations) && kdf.Iterations < iterations)
            throw new SyncUserException("The sync server asked for weaker password settings than before, so your password wasn't used.");
    }

    /// <summary>Kept per email (and through sign-out): a later prelogin may not lower it.</summary>
    private void RememberKdf(string email, int iterations)
    {
        if (_keys.Read(KdfKey(email)) is { } known && int.TryParse(known, out var old) && old >= iterations) return;
        _keys.Save(KdfKey(email), iterations.ToString(System.Globalization.CultureInfo.InvariantCulture), "Clipboard2 sync – password settings");
    }

    // MARK: Account flows

    /// <summary>Creates the keys on this PC and the account on the server. Sign-up is invite-only: <paramref name="inviteCode"/>
    /// is a sign-up code or a group invite code; with a group code the new account joins that group right away.
    /// There is no password recovery.</summary>
    public Task<bool> CreateAccountAsync(string email, string username, string password, string confirmation, string? inviteCode = null) =>
        Run("Creating your account…", async ct =>
    {
        email = SyncCrypto.NormalizeEmail(email);
        if (!email.Contains('@')) throw new SyncUserException("Enter your email address.");
        username = NormalizeUsername(username);
        if (UsernameProblem(username) is { } problem) throw new SyncUserException(problem);
        if (password.Length < MinPasswordLength) throw new SyncUserException($"Use at least {MinPasswordLength} characters for the password.");
        if (password != confirmation) throw new SyncUserException("The passwords don't match.");
        if (string.IsNullOrWhiteSpace(inviteCode))
            throw new SyncUserException("Enter your invite code. Sync is invite-only: ask someone who uses Clipboard2 to invite you.");
        var invite = SignupInvite.Parse(inviteCode)
            ?? throw new SyncUserException("That doesn't look like an invite code. It's 16 or 26 letters and digits, like ABCD-EFGH-….");
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
                m.spaceId, m.PersonalKey, deviceName: DeviceName, username: username,
                signupCode: (invite as SignupInvite.Code)?.Value, groupInviteId: (invite as SignupInvite.Group)?.InviteId, ct: ct);
        }
        catch (SyncApiException ex) when (ex.Code == "conflict")
        {
            throw new SyncUserException("An account with this email already exists. Sign in instead.");
        }
        RememberKdf(email, m.kdf.Iterations);
        ResetLocalSync();
        FinishSignIn(session, m.accountKey, m.identity.Private);
        Status = null;
        if (invite is SignupInvite.Group group)
        {
            try
            {
                var preview = await OpenInviteAsync(group.CodeBytes, ct);
                await AcceptAsync(preview, ct);
                Status = $"Welcome! You joined {preview.Name}.";
            }
            catch (Exception ex) when (ex is SyncUserException or SyncApiException { Code: not "unauthenticated" })
            {
                Status = "Your account was created, but joining the group didn't work: " + Friendly(ex);
            }
        }
    }, keepStatus: true);

    /// <summary>prelogin → derive keys → login. Also used to continue after the session ended.</summary>
    public Task<bool> SignInAsync(string email, string password) => Run("Signing in…", async ct =>
    {
        email = SyncCrypto.NormalizeEmail(email);
        var kdf = await _api.PreloginAsync(email, ct);
        CheckKdf(email, kdf);
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
        RememberKdf(email, kdf.Iterations);
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
        CheckKdf(Email, kdf);
        var (oldKeys, newKdf, newKeys) = await Task.Run(() =>
        {
            var next = new Kdf(SyncCrypto.RandomSalt(), Math.Max(_iterations, kdf.Iterations));
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
        RememberKdf(Email, newKdf.Iterations);
        Status = "Password changed. Other devices will ask for the new password.";
    }, keepStatus: true);

    // MARK: Username

    public const int MinUsernameLength = 3, MaxUsernameLength = 24;
    public const string UsernameRule = "A username has 3–24 letters, digits, _ . or -, and starts with a letter or digit.";

    [System.Text.RegularExpressions.GeneratedRegex(@"^[\p{L}\p{Nd}][\p{L}\p{Nd}_.\-]{2,23}$")]
    private static partial System.Text.RegularExpressions.Regex UsernamePattern();

    /// <summary>Trimmed and NFC-normalized, as the server stores it.</summary>
    public static string NormalizeUsername(string username) => username.Trim().Normalize(NormalizationForm.FormC);

    /// <summary>Why a (normalized) username can't be used, or null when it can. Uniqueness is the server's call.</summary>
    public static string? UsernameProblem(string username) =>
        username.Length == 0 ? "Choose a username. It's shown to people in your groups."
        : UsernamePattern().IsMatch(username) ? null : UsernameRule;

    /// <summary>Sets or changes the username; the server's spelling is kept.</summary>
    public Task<bool> ChangeUsernameAsync(string username) => Run("Saving your username…", async ct =>
    {
        username = NormalizeUsername(username);
        if (UsernameProblem(username) is { } problem) throw new SyncUserException(problem);
        if (Phase != SyncPhase.SignedIn) throw new SyncUserException("Sign in to sync first.");
        try { SaveUsername(await _api.SetUsernameAsync(username, ct)); }
        catch (SyncApiException ex) when (ex.Code == "invalid")
        {
            throw new SyncUserException(UsernameRule);
        }
        catch (SyncApiException ex) when (ex.Code is "not_found" or "http_404")
        {
            throw new SyncUserException("The sync server doesn't support usernames yet.");
        }
        Status = $"Your username is now {Username}.";
    }, keepStatus: true);

    private void SaveUsername(string? username)
    {
        Username = username;
        if (Parse(_keys.Read(AccountKey)) is { } account)
        {
            account["username"] = username;
            _keys.Save(AccountKey, account.ToJsonString(), "Clipboard2 sync – account");
        }
    }

    /// <summary>Once per session after a restart: picks up a username set on another device. Failures wait for next time.</summary>
    private async Task RefreshAccountAsync(CancellationToken ct)
    {
        try
        {
            var account = await _api.GetAccountAsync(ct);
            _accountFresh = true;
            if (account.Uid == Uid && account.Username != Username) SaveUsername(account.Username);
        }
        catch (SyncApiException ex) when (ex.Code != "unauthenticated")
        {
            Logger?.Invoke("Couldn't refresh the account: " + ex.Message);
        }
    }

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
        CheckKdf(Email, kdf);
        var keys = await Task.Run(() => SyncCrypto.DerivePasswordKeys(password, kdf.Salt, kdf.Iterations), ct);
        try { await _api.DeleteAccountAsync(keys.AuthKey, ct); }
        catch (SyncApiException ex) when (ex.Code is "invalid_credentials" or "forbidden")
        {
            throw new SyncUserException("The password is wrong.");
        }
        SignOutLocally();
        Status = "Your sync account was deleted.";
    }, keepStatus: true);

    // MARK: Inviting people to Clipboard2 (sign-up codes)

    /// <summary>Creates a sign-up code (valid 14 days) and returns it formatted, shown once.</summary>
    public async Task<string?> CreateSignupCodeAsync()
    {
        string? code = null;
        await Run("Creating an invite…", async ct =>
        {
            RequireEngine();
            code = (await _api.CreateSignupCodeAsync(ct)).Code;
        });
        return code;
    }

    /// <summary>The open sign-up codes this user made (their codes aren't shown again).</summary>
    public async Task<List<OpenSignupCode>> SignupCodesAsync()
    {
        try { return await _api.SignupCodesAsync(); }
        catch (SyncApiException ex)
        {
            Error = Friendly(ex);
            Notify();
            return [];
        }
    }

    public Task<bool> RevokeSignupCodeAsync(string id) => Run("Revoking…", ct => _api.RevokeSignupCodeAsync(id, ct));

    // MARK: Devices

    /// <summary>Fetches the signed-in devices; also learns this PC's session id.</summary>
    public async Task RefreshDevicesAsync(CancellationToken ct = default)
    {
        try { ApplyDevices(await _api.SessionsAsync(ct)); }
        catch (SyncApiException ex) when (ex.Code != "unauthenticated")
        {
            Logger?.Invoke("Couldn't list devices: " + ex.Message);   // e.g. a server without /v1/sessions
        }
        Notify();
    }

    private void ApplyDevices(List<SyncDevice> devices)
    {
        Devices = [.. devices.OrderByDescending(d => d.IsCurrent).ThenByDescending(d => d.LastUsedAt)];
        _devicesFresh = true;
        CurrentDeviceId = devices.FirstOrDefault(d => d.IsCurrent)?.Id ?? CurrentDeviceId;
        if (_engine is not null) _engine.DeviceId = CurrentDeviceId;
    }

    /// <summary>Signs a device out. Signing out this PC works like <see cref="SignOutAsync"/>.</summary>
    public Task<bool> SignOutDeviceAsync(string deviceId) => Run("Signing out the device…", async ct =>
    {
        RequireEngine();
        await _api.RevokeSessionAsync(deviceId, ct);
        if (deviceId == CurrentDeviceId)
        {
            SignOutLocally();
            return;
        }
        Devices = [.. Devices.Where(d => d.Id != deviceId)];
    });

    /// <summary>Sends a clip to one of this account's other devices: it lands at the top there with a "Sent from"
    /// notice (and in the personal history everywhere).</summary>
    public Task<bool> SendToDeviceAsync(ClipItem item, string deviceId) => Run("Sending…", async ct =>
    {
        var engine = RequireEngine();
        if (deviceId == CurrentDeviceId) throw new SyncUserException("That's this PC.");
        var name = Devices.FirstOrDefault(d => d.Id == deviceId)?.Name;
        if (_running is { IsCompleted: false } running) await running;   // one writer at a time
        if (engine.Space(engine.Identity.PersonalSpaceId) is null) await engine.RefreshSpacesAsync(ct);
        if (!await engine.SendToDeviceAsync(item, deviceId, DeviceName, ct))
            throw new SyncUserException("It changed on another device meanwhile. Try again.");
        Status = name is null ? "Sent." : $"Sent to {name}.";
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
            preview = await OpenInviteAsync(bytes, ct);
        });
        return preview;
    }

    private async Task<InvitePreview> OpenInviteAsync(byte[] bytes, CancellationToken ct)
    {
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
        return new InvitePreview(inviteId, invite.SpaceId, name, invite.MemberCount, SyncPayload.FromMillis(invite.ExpiresAt), key);
    }

    /// <summary>Accepts an opened invite: the group key is wrapped to this account's own public key.</summary>
    public Task<bool> JoinAsync(InvitePreview invite) => Run($"Joining {invite.Name}…", async ct =>
    {
        await AcceptAsync(invite, ct);
        Status = $"You joined {invite.Name}.";
    }, keepStatus: true);

    private async Task AcceptAsync(InvitePreview invite, CancellationToken ct)
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
        _ = SyncNowAsync();
    }

    /// <summary>Leaving (or deleting) a group also forgets its key pin, so joining it again starts fresh.</summary>
    private void ForgetGroup(string id)
    {
        RequireEngine().RemoveGroupLocally(id);
        _pins.Remove(id);
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

    // MARK: Polling

    /// <summary>A copy, paste, panel or menu: the user is around, so other devices' changes should arrive quickly.</summary>
    public void ReportActivity() => _lastActivity = _now();

    /// <summary>The quick panel opened or closed. Opening it always syncs once.</summary>
    public void SetPanelOpen(bool open)
    {
        _panelOpen = open;
        if (!open) return;
        ReportActivity();
        _ = SyncNowAsync();
    }

    /// <summary>3 s while the panel is open, 15 s within 5 minutes of activity, otherwise 60 s.</summary>
    public TimeSpan PollInterval =>
        _panelOpen ? PanelPollInterval : _now() - _lastActivity < ActiveWindow ? ActivePollInterval : IdlePollInterval;

    /// <summary>Call often (every second): starts a tick when <see cref="PollInterval"/> has passed since the last one.
    /// True when it started one.</summary>
    public bool PollIfDue()
    {
        if (Phase != SyncPhase.SignedIn || _engine is null || _running is { IsCompleted: false }) return false;
        if (RetryAfter is { } until && until > _now()) return false;
        if (_lastTickStarted is { } last && _now() - last < PollInterval) return false;
        _ = SyncNowAsync();
        return true;
    }

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
                _lastTickStarted = _now();
                if (_engine is not { } engine) break;
                if (!_accountFresh) await RefreshAccountAsync(ct);
                if (!_devicesFresh) await RefreshDevicesQuietlyAsync(ct);
                var report = await engine.TickAsync(ct);
                LastSync = _now();
                _offline = false;
                RetryAfter = null;
                Warnings = report.Warnings;
                Error = report.ClockSkew
                    ? "Your clock is off, so the sync server refused some changes. Turn on “Set time automatically” in Windows Settings → Time & language."
                    : engine.KeyChangedSpaces.Count > 0 ? KeyChangedMessage(engine) : null;
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

    private async Task RefreshDevicesQuietlyAsync(CancellationToken ct)
    {
        try { ApplyDevices(await _api.SessionsAsync(ct)); }
        catch (SyncApiException ex) when (ex.Code is not ("unauthenticated" or "rate_limited" or "network"))
        {
            _devicesFresh = true;   // a server without /v1/sessions: don't ask on every tick
            Logger?.Invoke("Couldn't list devices: " + ex.Message);
        }
    }

    private string KeyChangedMessage(SyncEngine engine)
    {
        var names = engine.KeyChangedSpaces
            .Select(id => id == engine.Identity.PersonalSpaceId ? "your personal space" : _store.SyncSpaces().FirstOrDefault(s => s.Id == id)?.DisplayName ?? "a group")
            .ToList();
        return names.Count == 1 && names[0] == "your personal space"
            ? "The key of your personal space changed unexpectedly, so it isn't syncing. Sign out and in again; if this keeps happening, don't trust the sync server."
            : $"This group's key changed unexpectedly ({string.Join(", ", names)}), so it isn't syncing. Leave the group and join again with a new invite code.";
    }

    private void HandleSyncFailure(Exception ex)
    {
        Logger?.Invoke("Sync failed: " + ex.Message);
        _offline = ex is SyncApiException { Code: "network" };
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
        Username = account.Username;
        _accountFresh = true;
        _keys.Save(AccountKey, new JsonObject
        {
            ["uid"] = account.Uid, ["email"] = Email, ["personalSpaceId"] = account.PersonalSpaceId,
            ["publicKey"] = Convert.ToBase64String(account.PublicKey), ["username"] = Username,
        }.ToJsonString(), "Clipboard2 sync – account");
        StartEngine(new SyncIdentity(account.Uid, Email ?? "", new EcKeyPair(priv, account.PublicKey), account.PersonalSpaceId));
        Phase = SyncPhase.SignedIn;
        RetryAfter = null;
        _offline = false;
        _ = SyncNowAsync();
    }

    private void StartEngine(SyncIdentity identity)
    {
        // A new session has a new id: learn it (and the device list) on the first tick.
        _devicesFresh = false;
        CurrentDeviceId = null;
        Devices = [];
        _engine = new SyncEngine(_store, _vault, _api, identity, _now, _pins) { Logger = m => Logger?.Invoke(m) };
        _engine.ReceivedFromDevice += (item, from) => ReceivedFromDevice?.Invoke(item, from);
    }

    private void SignOutLocally()
    {
        if (_engine is { } engine)
        {
            foreach (var id in engine.Spaces.Select(s => s.Id).Concat(engine.KeyChangedSpaces).Append(engine.Identity.PersonalSpaceId).ToList())
                _pins.Remove(id);
        }
        foreach (var record in _store.SyncSpaces()) _pins.Remove(record.Id);
        _engine = null;
        ResetLocalSync();
        foreach (var key in new[] { TokenKey, AccountKey, AccountKeyKey, IdentityKeyKey }) _keys.Delete(key);
        _token = null;
        Email = null;
        Uid = null;
        Username = null;
        LastSync = null;
        Devices = [];
        CurrentDeviceId = null;
        _offline = false;
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
        SyncApiException { Code: "username_taken" } => "That username is taken. Try another one.",
        SyncApiException { Code: "unauthenticated" } => "Your session ended. Enter your password to keep syncing.",
        SyncApiException { Code: "invite_required" } => "Enter your invite code. Sync is invite-only: ask someone who uses Clipboard2 to invite you.",
        SyncApiException { Code: "invite_invalid" } => "That invite code is unknown, already used or expired. Ask for a new one.",
        SyncApiException { Code: "too_many_codes" } => "You already have 10 open invites. Revoke one you don't need first.",
        SyncApiException { Code: "clock_skew" } => "Your clock is off. Turn on “Set time automatically” in Windows Settings → Time & language.",
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
