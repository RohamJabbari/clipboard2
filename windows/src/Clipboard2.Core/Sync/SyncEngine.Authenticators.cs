using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace Clipboard2.Core.Sync;

/// <summary>Authenticators (docs/sync/PROTOCOL.md → Authenticators): the owner's seed syncs as an item of its own
/// space; everyone it's shared with gets sealed batches of pre-computed codes, never the seed.</summary>
public sealed partial class SyncEngine
{
    /// <summary>How often an owner device asks for an authenticator's shares when none looks due for a top-up.</summary>
    public static readonly TimeSpan SharesCheckInterval = TimeSpan.FromMinutes(10);

    private readonly Dictionary<string, DateTime> _sharesCheckedAt = [];
    private readonly Dictionary<string, byte[]> _publicKeys = [];
    /// <summary>The server doesn't know authenticators (an older server): stop asking until the next sign-in.</summary>
    private bool _noAuthenticators;

    private static bool IsQuiet(SyncApiException ex) => ex.Code is not ("unauthenticated" or "rate_limited" or "network");

    /// <summary>Gives every authenticator without a space one (POST /v1/authenticators with a fresh key wrapped to
    /// this user); the push then sends its item. One identical to an authenticator already synced (the same one
    /// added again after signing out and in) is dropped instead.</summary>
    private async Task CreatePendingAuthenticatorsAsync(SyncReport report, CancellationToken ct)
    {
        if (_noAuthenticators) return;
        foreach (var pending in Authenticators.All.Where(a => a.SpaceId is null).ToList())
        {
            ct.ThrowIfCancellationRequested();
            if (Authenticators.All.Any(a => a.SpaceId is not null && a.SameAs(pending)))
            {
                Authenticators.Delete(pending.Id);
                continue;
            }
            var id = Guid.NewGuid().ToString("D");
            var key = SyncCrypto.RandomKey();
            SpaceInfo info;
            try { info = await api.CreateAuthenticatorAsync(id, SyncCrypto.WrapSpaceKey(key, id, Identity.Uid, Identity.Keys.Public), ct); }
            catch (SyncApiException ex) when (ex.Code is "not_found" or "http_404")
            {
                _noAuthenticators = true;
                Logger?.Invoke("The sync server doesn't support authenticators yet");
                return;
            }
            catch (SyncApiException ex) when (ex.Code == "quota_exceeded")
            {
                Note(report, _spaces[Identity.PersonalSpaceId], ex);
                return;
            }
            AddSpace(info, key, "");
            Authenticators.Put(pending with { SpaceId = id });
        }
    }

    // MARK: Owner: shares and top-ups

    private async Task<byte[]> PublicKeyAsync(string uid, CancellationToken ct)
    {
        if (_publicKeys.TryGetValue(uid, out var known)) return known;
        var user = await api.LookupUserByIdAsync(uid, ct);
        return _publicKeys[uid] = user.PublicKey;
    }

    /// <summary>Seals the next 24 h of codes to <paramref name="uid"/> and uploads them (creating the share).</summary>
    private async Task<DateTime> SendCodesAsync(Authenticator a, string uid, CancellationToken ct)
    {
        var (json, until) = OtpCodeBatch.Build(a, _now());
        byte[] sealedCodes;
        try { sealedCodes = SyncCrypto.SealCodes(SyncPayload.Encode(json), a.SpaceId!, uid, await PublicKeyAsync(uid, ct)); }
        catch (CryptographicException) { throw new SyncUserException("The sync server sent an unusable key for that person, so nothing was shared."); }
        await api.PutShareAsync(a.SpaceId!, uid, SyncPayload.Millis(until), sealedCodes, ct);
        return until;
    }

    /// <summary>Every owner device: for each own authenticator, asks for its shares (every
    /// <see cref="SharesCheckInterval"/>, or sooner when one looks due) and tops up those with less than 12 h of
    /// codes. <paramref name="force"/> asks for all of them now.</summary>
    public async Task TopUpSharesAsync(SyncReport? report, bool force, CancellationToken ct = default)
    {
        if (_noAuthenticators) return;
        var now = _now();
        foreach (var a in Authenticators.All.Where(a => a.SpaceId is { } s && _spaces.ContainsKey(s)).ToList())
        {
            ct.ThrowIfCancellationRequested();
            var space = a.SpaceId!;
            var due = a.People.Any(p => p.CodesUntil - now < OtpCodeBatch.TopUpBelow);
            if (!force && !due && _sharesCheckedAt.TryGetValue(space, out var at) && now - at < SharesCheckInterval) continue;
            try { await RefreshSharesAsync(a, ct); }
            catch (SyncApiException ex) when (IsQuiet(ex))
            {
                Logger?.Invoke($"Couldn't top up the shares of {space}: {ex.Message}");
                if (report is not null && ex.Code == "forbidden") report.Warnings.Add(ex.Message);
            }
            catch (SyncUserException ex) { report?.Warnings.Add(ex.Message); }
        }
    }

    /// <summary>GET …/shares, tops up the ones due and remembers who it's shared with.</summary>
    private async Task<Authenticator> RefreshSharesAsync(Authenticator a, CancellationToken ct)
    {
        var space = a.SpaceId!;
        var shares = await api.SharesAsync(space, ct);
        var now = _now();
        var people = new List<OtpShare>();
        foreach (var share in shares)
        {
            var until = SyncPayload.FromMillis(share.CodesUntil);
            if (until - now < OtpCodeBatch.TopUpBelow) until = await SendCodesAsync(a, share.Uid, ct);
            people.Add(new OtpShare(share.Uid, share.Name, until));
        }
        _sharesCheckedAt[space] = now;
        var current = Authenticators.Find(a.Id) ?? a;
        var updated = current with { Shares = people };
        if (!SamePeople(current.Shares, people)) Authenticators.Put(updated);
        return updated;
    }

    private static bool SamePeople(IReadOnlyList<OtpShare>? a, IReadOnlyList<OtpShare> b) => a is not null && a.SequenceEqual(b);

    /// <summary>Share…: seals the first batch to them at once.</summary>
    public async Task ShareAuthenticatorAsync(Authenticator a, string uid, CancellationToken ct = default)
    {
        if (a.SpaceId is null) throw new SyncUserException("Sync this authenticator first, then share it.");
        if (uid == Identity.Uid) throw new SyncUserException("That's you.");
        try { await SendCodesAsync(a, uid, ct); }
        catch (SyncApiException ex) when (ex.Code is "not_found" or "forbidden")
        {
            throw new SyncUserException("You can share only with your contacts and people in your groups.");
        }
        catch (SyncApiException ex) when (ex.Code == "quota_exceeded")
        {
            throw new SyncUserException("An authenticator can be shared with at most 20 people.");
        }
        await RefreshSharesAsync(Authenticators.Find(a.Id) ?? a, ct);
    }

    /// <summary>People… ▸ Remove. Their batch goes on the server; codes they already have last until it ends.</summary>
    public async Task<DateTime?> RemoveShareAsync(Authenticator a, string uid, CancellationToken ct = default)
    {
        var until = a.People.FirstOrDefault(p => p.Uid == uid)?.CodesUntil;
        await api.DeleteShareAsync(a.SpaceId!, uid, ct);
        await RefreshSharesAsync(Authenticators.Find(a.Id) ?? a, ct);
        return until;
    }

    /// <summary>Transfer Ownership…: the space key is wrapped to them and they own it; this user then gets codes like
    /// everyone else, so the seed is deleted here.</summary>
    public async Task TransferAuthenticatorAsync(Authenticator a, string uid, CancellationToken ct = default)
    {
        if (a.SpaceId is not { } spaceId || Space(spaceId) is not { } space) throw new SyncUserException("Sync this authenticator first.");
        if (a.People.All(p => p.Uid != uid)) throw new SyncUserException("Share it with them first, then transfer it.");
        byte[] wrapped;
        try { wrapped = SyncCrypto.WrapSpaceKey(space.Key, spaceId, uid, await PublicKeyAsync(uid, ct)); }
        catch (CryptographicException) { throw new SyncUserException("The sync server sent an unusable key for that person, so nothing was transferred."); }
        await api.TransferAuthenticatorAsync(spaceId, uid, wrapped, ct);
        pins?.Remove(spaceId);
        RemoveGroupLocally(spaceId);
        store.SaveSyncSpaces(_spaces.Values.Select(s => s.Record));
        await ReceiveSharedCodesAsync(ct);
    }

    /// <summary>Delete: removes it for everyone (an authenticator never synced is only here).</summary>
    public async Task DeleteAuthenticatorAsync(Authenticator a, CancellationToken ct = default)
    {
        if (a.SpaceId is { } spaceId)
        {
            try { await api.DeleteAuthenticatorAsync(spaceId, ct); }
            catch (SyncApiException ex) when (ex.Code == "not_found") { }   // already gone
            pins?.Remove(spaceId);
            RemoveGroupLocally(spaceId);
            store.SaveSyncSpaces(_spaces.Values.Select(s => s.Record));
        }
        Authenticators.Delete(a.Id);
    }

    // MARK: Recipient

    /// <summary>GET /v1/shared-codes: opens each new batch with this user's identity key and keeps it; drops the
    /// ones no longer shared.</summary>
    public async Task ReceiveSharedCodesAsync(CancellationToken ct = default)
    {
        if (_noAuthenticators) return;
        List<SharedCodes> shared;
        try { shared = await api.SharedCodesAsync(ct); }
        catch (SyncApiException ex) when (ex.Code is "not_found" or "http_404")
        {
            _noAuthenticators = true;
            return;
        }
        var listed = new HashSet<string>();
        foreach (var s in shared)
        {
            if (Authenticators.InSpace(s.SpaceId) is not null) continue;   // this user owns it (just transferred to them)
            listed.Add(s.SpaceId);
            var received = SyncPayload.FromMillis(s.UpdatedAt);
            var existing = Authenticators.FindShared(s.SpaceId);
            if (existing is not null && existing.ReceivedAt == received && existing.OwnerName == s.OwnerName) continue;
            SharedAuthenticator? opened = null;
            if (s.SealedCodes is { Length: > 0 } sealedCodes)
            {
                try
                {
                    var plaintext = SyncCrypto.OpenCodes(sealedCodes, s.SpaceId, Identity.Uid, Identity.Keys);
                    if (JsonNode.Parse(plaintext) is JsonObject json) opened = OtpCodeBatch.Parse(json, s.SpaceId, s.OwnerUid, s.OwnerName, received);
                }
                catch (Exception ex) when (ex is CryptographicException or System.Text.Json.JsonException)
                {
                    Logger?.Invoke($"Couldn't open the codes shared in {s.SpaceId}: {ex.Message}");
                }
            }
            // Nothing (yet, or unreadable): keep what's here, or show it without codes.
            opened ??= existing is null ? OtpCodeBatch.Empty(s.SpaceId, s.OwnerUid, s.OwnerName, received) : existing with { OwnerName = s.OwnerName };
            Authenticators.PutShared(opened);
        }
        foreach (var gone in Authenticators.Shared.Where(s => !listed.Contains(s.SpaceId)).ToList()) Authenticators.DeleteShared(gone.SpaceId);
    }

    /// <summary>Leave: stops getting codes from it.</summary>
    public async Task LeaveSharedAsync(SharedAuthenticator shared, CancellationToken ct = default)
    {
        try { await api.DeleteShareAsync(shared.SpaceId, Identity.Uid, ct); }
        catch (SyncApiException ex) when (ex.Code == "not_found") { }
        Authenticators.DeleteShared(shared.SpaceId);
    }
}
