using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace Clipboard2.Core.Sync;

// MARK: Wire types (docs/sync/PROTOCOL.md → API)

/// <param name="Username">Null when none was chosen, or the server doesn't know usernames yet.</param>
public sealed record AccountInfo(string Uid, string Email, byte[] Salt, int Iterations, byte[] WrappedAccountKey,
                                 byte[] PublicKey, byte[] WrappedPrivateKey, string PersonalSpaceId, string? Username = null);

/// <param name="Members">Member uid → name (username, or the email's part before @); null from servers without it.</param>
public sealed record SpaceInfo(string Id, string Kind, string Role, string OwnerUid, byte[] WrappedKey, byte[]? EncryptedName,
                               int MemberCount, long CreatedAt, IReadOnlyDictionary<string, string>? Members = null)
{
    public bool IsPersonal => Kind == "personal";
}

public sealed record RemoteItem(string Id, string Category, long Seq, long SortAt, long UpdatedAt, string? Deleted,
                                byte[]? Ciphertext, IReadOnlyList<string> BlobIds, string? AuthorUid);

public sealed record ChangesPage(IReadOnlyList<RemoteItem> Items, long NextSince, bool HasMore, bool ResetRequired);

public sealed record Kdf(byte[] Salt, int Iterations);

public sealed record SessionInfo(string Token, long ExpiresAt, AccountInfo Account);

public sealed record PendingInvite(string InviteId, long CreatedAt, long ExpiresAt);

public sealed record InviteInfo(string SpaceId, byte[] SealedKey, byte[]? EncryptedName, int MemberCount, long ExpiresAt);

public sealed record GroupMember(string Uid, string Email, string Role);

public sealed record BlobUpload(string Url, string Method, IReadOnlyDictionary<string, string> Headers);

public abstract record WriteOutcome
{
    public sealed record Saved(long Seq, IReadOnlyList<string> Trimmed) : WriteOutcome;
    public sealed record Conflict(RemoteItem Current) : WriteOutcome;
}

public sealed class SyncApiException(HttpStatusCode status, string code, string message, TimeSpan? retryAfter = null) : Exception(message)
{
    public HttpStatusCode Status { get; } = status;
    /// <summary>The server's error code (unauthenticated, invalid_credentials, quota_exceeded…) or "network".</summary>
    public string Code { get; } = code;
    public TimeSpan? RetryAfter { get; } = retryAfter;
}

/// <summary>The clipboard2-api client. Authenticated calls send the session token.</summary>
public sealed class SyncApi(Func<string?> token, Func<string> baseUrl, HttpClient? http = null)
{
    private readonly HttpClient _http = http ?? SyncConfig.Http;

    public HttpRequestMessage MakeRequest(HttpMethod method, string path, JsonNode? body, string? token)
    {
        var request = new HttpRequestMessage(method, baseUrl().TrimEnd('/') + path);
        if (token is not null) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (body is not null) request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");
        return request;
    }

    // MARK: Auth and sessions

    /// <summary>The account's KDF parameters (a deterministic fake for unknown emails).</summary>
    public async Task<Kdf> PreloginAsync(string email, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Post, "/v1/auth/prelogin", new JsonObject { ["email"] = SyncCrypto.NormalizeEmail(email) }, ct, anonymous: true);
        return KdfFrom(json?["kdf"] as JsonObject);
    }

    public async Task<SessionInfo> SignupAsync(string email, byte[] authKey, Kdf kdf, string uid, byte[] wrappedAccountKey, byte[] publicKey,
                                               byte[] wrappedPrivateKey, string personalSpaceId, byte[] personalWrappedKey,
                                               string? deviceName = null, string? username = null, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["email"] = SyncCrypto.NormalizeEmail(email),
            ["authKey"] = B64(authKey),
            ["kdf"] = new JsonObject { ["salt"] = B64(kdf.Salt), ["iterations"] = kdf.Iterations },
            ["uid"] = uid,
            ["wrappedAccountKey"] = B64(wrappedAccountKey),
            ["publicKey"] = B64(publicKey),
            ["wrappedPrivateKey"] = B64(wrappedPrivateKey),
            ["personalSpace"] = new JsonObject { ["id"] = personalSpaceId, ["wrappedKey"] = B64(personalWrappedKey) },
        };
        if (deviceName is not null) body["deviceName"] = deviceName;
        if (username is not null) body["username"] = username;
        var (_, json) = await SendAsync(HttpMethod.Post, "/v1/auth/signup", body, ct, anonymous: true);
        return Session(json!);
    }

    public async Task<SessionInfo> LoginAsync(string email, byte[] authKey, string? deviceName = null, CancellationToken ct = default)
    {
        var body = new JsonObject { ["email"] = SyncCrypto.NormalizeEmail(email), ["authKey"] = B64(authKey) };
        if (deviceName is not null) body["deviceName"] = deviceName;
        var (_, json) = await SendAsync(HttpMethod.Post, "/v1/auth/login", body, ct, anonymous: true);
        return Session(json!);
    }

    public Task LogoutAsync(CancellationToken ct = default) => SendAsync(HttpMethod.Post, "/v1/auth/logout", null, ct);

    /// <summary>Replaces the password verifier and wrappedAK; every other session is revoked.</summary>
    public Task ChangePasswordAsync(byte[] authKey, byte[] newAuthKey, Kdf kdf, byte[] wrappedAccountKey, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Put, "/v1/account/password", new JsonObject
        {
            ["authKey"] = B64(authKey),
            ["newAuthKey"] = B64(newAuthKey),
            ["kdf"] = new JsonObject { ["salt"] = B64(kdf.Salt), ["iterations"] = kdf.Iterations },
            ["wrappedAccountKey"] = B64(wrappedAccountKey),
        }, ct);

    public async Task<AccountInfo> GetAccountAsync(CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Get, "/v1/account", null, ct);
        return Account(json!);
    }

    /// <summary>Sets or changes the username; returns it as the server stored it (trimmed, NFC).</summary>
    public async Task<string> SetUsernameAsync(string username, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Put, "/v1/account/username", new JsonObject { ["username"] = username }, ct);
        return json?["username"] is JsonValue v ? v.GetValue<string>() : username;
    }

    public Task DeleteAccountAsync(byte[] authKey, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Delete, "/v1/account", new JsonObject { ["authKey"] = B64(authKey) }, ct);

    // MARK: Spaces and groups

    public async Task<List<SpaceInfo>> GetSpacesAsync(CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Get, "/v1/spaces", null, ct);
        return (json?["spaces"] as JsonArray ?? []).OfType<JsonObject>().Select(Space).ToList();
    }

    public async Task<SpaceInfo> CreateGroupAsync(string id, byte[] encryptedName, byte[] wrappedKey, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Post, "/v1/groups",
            new JsonObject { ["id"] = id, ["encryptedName"] = B64(encryptedName), ["wrappedKey"] = B64(wrappedKey) }, ct);
        return Space(json!);
    }

    public Task RenameGroupAsync(string id, byte[] encryptedName, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Patch, $"/v1/groups/{id}", new JsonObject { ["encryptedName"] = B64(encryptedName) }, ct);

    public Task DeleteGroupAsync(string id, CancellationToken ct = default) => SendAsync(HttpMethod.Delete, $"/v1/groups/{id}", null, ct);

    public async Task<List<GroupMember>> MembersAsync(string groupId, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Get, $"/v1/groups/{groupId}/members", null, ct);
        return (json?["members"] as JsonArray ?? []).OfType<JsonObject>()
            .Select(m => new GroupMember(S(m, "uid"), S(m, "email"), S(m, "role"))).ToList();
    }

    public Task RemoveMemberAsync(string groupId, string uid, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Delete, $"/v1/groups/{groupId}/members/{Uri.EscapeDataString(uid)}", null, ct);

    // MARK: Invites

    public async Task<long> CreateInviteAsync(string groupId, string inviteId, byte[] sealedKey, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Post, $"/v1/groups/{groupId}/invites",
            new JsonObject { ["inviteId"] = inviteId, ["sealedKey"] = B64(sealedKey) }, ct);
        return L(json!, "expiresAt");
    }

    public async Task<List<PendingInvite>> InvitesAsync(string groupId, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Get, $"/v1/groups/{groupId}/invites", null, ct);
        return (json?["invites"] as JsonArray ?? []).OfType<JsonObject>()
            .Select(i => new PendingInvite(S(i, "inviteId"), L(i, "createdAt"), L(i, "expiresAt"))).ToList();
    }

    public Task RevokeInviteAsync(string groupId, string inviteId, CancellationToken ct = default) =>
        SendAsync(HttpMethod.Delete, $"/v1/groups/{groupId}/invites/{inviteId}", null, ct);

    /// <summary>Null when the invite is unknown, used or expired.</summary>
    public async Task<InviteInfo?> GetInviteAsync(string inviteId, CancellationToken ct = default)
    {
        var (status, json) = await SendAsync(HttpMethod.Get, $"/v1/invites/{inviteId}", null, ct, allow: [HttpStatusCode.NotFound]);
        if (status == HttpStatusCode.NotFound) return null;
        return new InviteInfo(S(json!, "spaceId"), Bytes(json!, "sealedKey"),
            json!["encryptedName"] is JsonValue ? Bytes(json, "encryptedName") : null, (int)L(json, "memberCount"), L(json, "expiresAt"));
    }

    public async Task<SpaceInfo> AcceptInviteAsync(string inviteId, byte[] wrappedKey, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Post, $"/v1/invites/{inviteId}/accept", new JsonObject { ["wrappedKey"] = B64(wrappedKey) }, ct);
        return Space(json!);
    }

    // MARK: Items

    public async Task<ChangesPage> ChangesAsync(string spaceId, long since, int limit = 500, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Get, $"/v1/spaces/{spaceId}/changes?since={since}&limit={limit}", null, ct);
        return new ChangesPage(
            (json?["items"] as JsonArray ?? []).OfType<JsonObject>().Select(Item).ToList(),
            L(json!, "nextSince"),
            json?["hasMore"]?.GetValue<bool>() ?? false,
            json?["resetRequired"]?.GetValue<bool>() ?? false);
    }

    public async Task<WriteOutcome> PutItemAsync(string spaceId, string itemId, string category, long sortAt, long updatedAt,
                                                 byte[] ciphertext, IReadOnlyList<string> blobIds, CancellationToken ct = default)
    {
        var body = new JsonObject
        {
            ["category"] = category,
            ["sortAt"] = sortAt,
            ["updatedAt"] = updatedAt,
            ["ciphertext"] = B64(ciphertext),
            ["blobIds"] = new JsonArray([.. blobIds.Select(b => (JsonNode?)b)]),
        };
        var (status, json) = await SendAsync(HttpMethod.Put, $"/v1/spaces/{spaceId}/items/{itemId}", body, ct, allow: [HttpStatusCode.Conflict]);
        if (status == HttpStatusCode.Conflict) return new WriteOutcome.Conflict(Item(json!["current"]!.AsObject()));
        return new WriteOutcome.Saved(L(json!, "seq"),
            (json?["trimmed"] as JsonArray ?? []).Select(t => t?.GetValue<string>()).OfType<string>().ToList());
    }

    public async Task<WriteOutcome> DeleteItemAsync(string spaceId, string itemId, long updatedAt, CancellationToken ct = default)
    {
        var (status, json) = await SendAsync(HttpMethod.Delete, $"/v1/spaces/{spaceId}/items/{itemId}?updatedAt={updatedAt}", null, ct,
            allow: [HttpStatusCode.Conflict]);
        if (status == HttpStatusCode.Conflict) return new WriteOutcome.Conflict(Item(json!["current"]!.AsObject()));
        return new WriteOutcome.Saved(L(json!, "seq"), []);
    }

    // MARK: Blobs

    public async Task<BlobUpload> RegisterBlobAsync(string spaceId, string blobId, long size, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Post, $"/v1/spaces/{spaceId}/blobs", new JsonObject { ["id"] = blobId, ["size"] = size }, ct);
        var headers = (json?["headers"] as JsonObject ?? []).ToDictionary(p => p.Key, p => p.Value?.ToString() ?? "");
        return new BlobUpload(S(json!, "url"), json?["method"]?.GetValue<string>() ?? "PUT", headers);
    }

    public async Task<string> BlobUrlAsync(string spaceId, string blobId, CancellationToken ct = default)
    {
        var (_, json) = await SendAsync(HttpMethod.Get, $"/v1/spaces/{spaceId}/blobs/{blobId}", null, ct);
        return S(json!, "url");
    }

    /// <summary>Uploads ciphertext to the signed URL with exactly the headers the server asked for (no bearer token).</summary>
    public async Task UploadBlobAsync(BlobUpload upload, byte[] ciphertext, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(new HttpMethod(upload.Method), upload.Url) { Content = new ByteArrayContent(ciphertext) };
        foreach (var (name, value) in upload.Headers)
        {
            if (name.Equals("content-length", StringComparison.OrdinalIgnoreCase)) continue;   // set from the body
            if (!request.Headers.TryAddWithoutValidation(name, value)) request.Content.Headers.TryAddWithoutValidation(name, value);
        }
        using var response = await Send(request, ct);
        if (!response.IsSuccessStatusCode)
            throw new SyncApiException(response.StatusCode, "upload_failed", $"Uploading an image failed ({(int)response.StatusCode}).");
    }

    public async Task<byte[]> DownloadAsync(string url, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        using var response = await Send(request, ct);
        if (!response.IsSuccessStatusCode)
            throw new SyncApiException(response.StatusCode, "download_failed", $"Downloading an image failed ({(int)response.StatusCode}).");
        return await response.Content.ReadAsByteArrayAsync(ct);
    }

    // MARK: Plumbing

    private async Task<HttpResponseMessage> Send(HttpRequestMessage request, CancellationToken ct)
    {
        try { return await _http.SendAsync(request, ct); }
        catch (HttpRequestException ex) { throw new SyncApiException(0, "network", "Couldn't reach the sync server. (" + ex.Message + ")"); }
        catch (TaskCanceledException) when (!ct.IsCancellationRequested) { throw new SyncApiException(0, "network", "The sync server didn't answer in time."); }
    }

    private async Task<(HttpStatusCode Status, JsonObject? Json)> SendAsync(HttpMethod method, string path, JsonNode? body,
                                                                         CancellationToken ct, HttpStatusCode[]? allow = null, bool anonymous = false)
    {
        string? bearer = null;
        if (!anonymous && (bearer = token()) is null)
            throw new SyncApiException(HttpStatusCode.Unauthorized, "unauthenticated", "Sign in to sync first.");
        using var request = MakeRequest(method, path, body, bearer);
        using var response = await Send(request, ct);
        var text = await response.Content.ReadAsStringAsync(ct);
        JsonObject? json = null;
        try { json = text.Length == 0 ? null : JsonNode.Parse(text) as JsonObject; } catch { }
        if (response.IsSuccessStatusCode || (allow?.Contains(response.StatusCode) ?? false)) return (response.StatusCode, json);
        var code = json?["error"] is JsonValue c ? c.GetValue<string>() : $"http_{(int)response.StatusCode}";
        var message = json?["message"]?.GetValue<string>() ?? $"The sync server answered {(int)response.StatusCode}.";
        TimeSpan? retry = response.Headers.RetryAfter?.Delta;
        throw new SyncApiException(response.StatusCode, code, message, retry);
    }

    private static string B64(byte[] bytes) => Convert.ToBase64String(bytes);
    private static string S(JsonObject json, string key) => json[key]?.GetValue<string>() ?? "";
    private static long L(JsonObject json, string key) => json[key] is JsonValue v && v.TryGetValue<double>(out var d) ? (long)d : 0;
    private static byte[] Bytes(JsonObject json, string key) => json[key] is JsonValue v && v.GetValue<string>() is { } s ? Convert.FromBase64String(s) : [];

    private static Kdf KdfFrom(JsonObject? kdf) =>
        kdf is null ? throw new SyncApiException(0, "invalid_response", "Unexpected answer from the sync server.")
                    : new Kdf(Bytes(kdf, "salt"), (int)L(kdf, "iterations"));

    private static AccountInfo Account(JsonObject j)
    {
        var kdf = KdfFrom(j["kdf"] as JsonObject);
        return new(S(j, "uid"), S(j, "email"), kdf.Salt, kdf.Iterations,
            Bytes(j, "wrappedAccountKey"), Bytes(j, "publicKey"), Bytes(j, "wrappedPrivateKey"), S(j, "personalSpaceId"),
            j["username"] is JsonValue u && u.GetValue<string>() is { Length: > 0 } name ? name : null);
    }

    private static SessionInfo Session(JsonObject j) =>
        new(S(j, "token"), L(j, "expiresAt"), Account(j["account"] as JsonObject ?? throw new SyncApiException(0, "invalid_response", "Unexpected answer from the sync server.")));

    private static SpaceInfo Space(JsonObject j) => new(
        S(j, "id"), S(j, "kind"), S(j, "role"), S(j, "ownerUid"), Bytes(j, "wrappedKey"),
        j["encryptedName"] is JsonValue ? Bytes(j, "encryptedName") : null,
        (int)L(j, "memberCount"), L(j, "createdAt"), Members(j["members"] as JsonArray));

    private static Dictionary<string, string>? Members(JsonArray? members)
    {
        if (members is null) return null;
        var map = new Dictionary<string, string>();
        foreach (var m in members.OfType<JsonObject>())
            if (m["uid"] is JsonValue uid && m["name"] is JsonValue name) map[uid.GetValue<string>()] = name.GetValue<string>();
        return map;
    }

    private static RemoteItem Item(JsonObject j) => new(
        S(j, "id"), S(j, "category"), L(j, "seq"), L(j, "sortAt"), L(j, "updatedAt"),
        j["deleted"] is JsonValue d ? d.GetValue<string>() : null,
        j["ciphertext"] is JsonValue ? Bytes(j, "ciphertext") : null,
        (j["blobIds"] as JsonArray ?? []).Select(b => b?.GetValue<string>()).OfType<string>().ToList(),
        j["authorUid"] is JsonValue a ? a.GetValue<string>() : null);
}
