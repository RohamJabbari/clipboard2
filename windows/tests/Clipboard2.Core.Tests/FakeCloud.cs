using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using System.Web;

namespace Clipboard2.Core.Tests;

/// <summary>
/// In-memory clipboard2-api (its own auth, sessions, invites, sign-up codes) and signed-URL storage, following
/// docs/sync/PROTOCOL.md and docs/sync/HARDENING-2026-10.md closely enough to test the Windows sync client without a network.
/// </summary>
internal sealed class FakeCloud : HttpMessageHandler
{
    public const string ApiBase = "https://api.fake";
    private const string Storage = "https://storage.fake";
    private const long SkewLimitMs = 10 * 60 * 1000;

    public int HistoryLimit { get; set; } = 200;
    /// <summary>Behaves like the server before usernames: ignores <c>username</c>, sends no <c>username</c> or
    /// <c>members</c>, and has no PUT /v1/account/username.</summary>
    public bool Legacy { get; set; }
    /// <summary>Sign-up needs a sign-up code or a group invite id (on by default, like the real server).</summary>
    public bool RequireInvite { get; set; } = true;
    /// <summary>Answers 429 to the API once this many more API calls have been made (null = never).</summary>
    public int? RateLimitAfter { get; set; }
    /// <summary>The server's clock, for <c>clock_skew</c>.</summary>
    public Func<long> Clock { get; set; } = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    /// <summary>Live items per space before <c>413 quota_exceeded</c> (5,000 on the real server).</summary>
    public int MaxLiveItems { get; set; } = 5000;
    /// <summary>Item ciphertext bytes before <c>413 too_large</c>.</summary>
    public int MaxItemBytes { get; set; } = 2 * 1024 * 1024;
    /// <summary>The most items a changes page holds, whatever the client asks for.</summary>
    public int PageLimit { get; set; } = 500;
    /// <summary>Every request fails as if the network were down.</summary>
    public bool Offline { get; set; }
    /// <summary>Item ids the change feed leaves out for now (replication lag): writes still see them.</summary>
    public HashSet<string> HiddenFromChanges { get; } = [];
    public List<string> Log { get; } = [];
    public int Count(string prefix) => Log.Count(l => l.StartsWith(prefix));

    private long _seq;
    private readonly Dictionary<string, User> _users = [];               // by email
    private readonly Dictionary<string, Session> _sessions = [];         // by token
    private readonly Dictionary<string, Space> _spaces = [];
    private readonly Dictionary<(string Space, string Blob), Blob> _blobs = [];
    private readonly Dictionary<string, Invite> _invites = [];
    private readonly Dictionary<string, SignupCodeRow> _signupCodes = [];   // by hash of the normalised code

    private sealed class User
    {
        public required string Email;
        public required string AuthKey;
        public required JsonObject Account;
        public string Uid => Account["uid"]!.GetValue<string>();
        public string? Username => Account["username"] is JsonValue u ? u.GetValue<string>() : null;
        /// <summary>The members-list name: the username, or the email's part before @.</summary>
        public string Name => Username ?? Email[..Email.IndexOf('@')];
    }

    private sealed class Session
    {
        public required string Id, Email, DeviceName;
        public long CreatedAt, LastUsedAt;
    }

    private sealed class Blob
    {
        public byte[]? Bytes;
        public bool CreateOnly;
    }

    private sealed class SignupCodeRow
    {
        public required string Id, Hash;
        public string? Owner;
        public long CreatedAt, ExpiresAt;
        public bool Used;
    }

    public string? Username(string email) => _users.GetValueOrDefault(email)?.Username;

    /// <summary>The server's username rule (400 invalid), unique case-insensitively (409 username_taken).</summary>
    private string ValidUsername(JsonNode? node, User? except)
    {
        var name = (node?.GetValue<string>() ?? "").Trim().Normalize(NormalizationForm.FormC);
        if (!System.Text.RegularExpressions.Regex.IsMatch(name, @"^[\p{L}\p{Nd}][\p{L}\p{Nd}_.\-]{2,23}$"))
            throw new HttpError(HttpStatusCode.BadRequest, "invalid");
        if (_users.Values.Any(u => u != except && string.Equals(u.Username, name, StringComparison.OrdinalIgnoreCase)))
            throw new HttpError(HttpStatusCode.Conflict, "username_taken");
        return name;
    }

    private sealed class Invite
    {
        public required string Id, SpaceId, SealedKey;
        public long CreatedAt, ExpiresAt;
        public bool Used;
    }

    private sealed class Space
    {
        public required string Id, Kind, Owner;
        public string? Name;
        public long CreatedAt;
        public long PurgedSeq;
        public Dictionary<string, (string Role, string Key)> Members { get; } = [];
        public Dictionary<string, Item> Items { get; } = [];
    }

    public sealed class Item
    {
        public required string Id, Category;
        public long Seq, SortAt, UpdatedAt;
        public string? Deleted, Ciphertext, Author;
        public List<string> BlobIds = [];
        /// <summary>Earlier versions (ciphertext, updatedAt), oldest first: for replay and rollback attacks.</summary>
        public List<(string Ciphertext, long UpdatedAt)> Earlier = [];

        public JsonObject Json() => new()
        {
            ["id"] = Id, ["category"] = Category, ["seq"] = Seq, ["sortAt"] = SortAt, ["updatedAt"] = UpdatedAt,
            ["deleted"] = Deleted, ["ciphertext"] = Ciphertext, ["blobIds"] = new JsonArray([.. BlobIds.Select(b => (JsonNode?)b)]),
            ["authorUid"] = Author,
        };
    }

    // MARK: Test controls

    /// <summary>Ends every session of a user, as a password change elsewhere or expiry would.</summary>
    public void RevokeSessions(string email)
    {
        foreach (var t in _sessions.Where(p => p.Value.Email == email).Select(p => p.Key).ToList()) _sessions.Remove(t);
    }

    public int SessionCount(string email) => _sessions.Values.Count(s => s.Email == email);
    public int PendingInvites(string spaceId) => _invites.Values.Count(i => i.SpaceId == spaceId && !i.Used);
    public bool HasAccount(string email) => _users.ContainsKey(email);
    public string? LastAuthKey(string email) => _users.GetValueOrDefault(email)?.AuthKey;
    public byte[] PublicKey(string email) => Convert.FromBase64String(_users[email].Account["publicKey"]!.GetValue<string>());
    public int OpenSignupCodes => _signupCodes.Values.Count(c => !c.Used);
    /// <summary>Changes the KDF iterations prelogin reports for an account (a hostile or broken server).</summary>
    public void SetIterations(string email, int iterations) => _users[email].Account["kdf"]!["iterations"] = iterations;

    /// <summary>A sign-up code made by the operator (for the first users), formatted XXXX-XXXX-XXXX-XXXX.</summary>
    public string IssueSignupCode(string? owner = null) => NewSignupCode(owner).Code;

    public IReadOnlyList<Item> Items(string spaceId) => [.. _spaces[spaceId].Items.Values];
    public IReadOnlyList<Item> LiveItems(string spaceId) => [.. _spaces[spaceId].Items.Values.Where(i => i.Deleted is null)];
    public Item ItemById(string spaceId, string id) => _spaces[spaceId].Items[id];
    public int BlobCount(string spaceId) => _blobs.Keys.Count(k => k.Space == spaceId);
    public void ForceReset(string spaceId) => _spaces[spaceId].PurgedSeq = _seq + 1;
    /// <summary>Purges a tombstone, like the 90-day cleanup: it's forgotten and the purge horizon moves up to its seq.</summary>
    public void Purge(string spaceId, string id)
    {
        var space = _spaces[spaceId];
        space.PurgedSeq = Math.Max(space.PurgedSeq, space.Items[id].Seq);
        space.Items.Remove(id);
    }
    /// <summary>Loses a blob, as garbage collection would.</summary>
    public void DropBlob(string spaceId, string blobId) => _blobs.Remove((spaceId, blobId));

    /// <summary>Simulates a newer write from elsewhere without the client seeing it yet.</summary>
    public void BumpUpdatedAt(string spaceId, string id, long by) => _spaces[spaceId].Items[id].UpdatedAt += by;

    /// <summary>A hostile server serves an item's previous ciphertext again as a new change: under a new updatedAt
    /// (a replay), or under its own old updatedAt (a rollback).</summary>
    public void ServePrevious(string spaceId, string id, bool rollback)
    {
        var item = _spaces[spaceId].Items[id];
        var (ciphertext, updatedAt) = item.Earlier[^1];
        item.Ciphertext = ciphertext;
        item.UpdatedAt = rollback ? updatedAt : item.UpdatedAt + 1;
        item.Seq = ++_seq;
    }

    /// <summary>A hostile server hands a member a different space key.</summary>
    public void ReplaceWrappedKey(string spaceId, string uid, byte[] wrappedKey)
    {
        var space = _spaces[spaceId];
        space.Members[uid] = (space.Members[uid].Role, Convert.ToBase64String(wrappedKey));
    }

    private User? UserByUid(string uid) => _users.Values.FirstOrDefault(u => u.Uid == uid);

    // MARK: Dispatch

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var url = request.RequestUri!;
        if (Offline) throw new HttpRequestException("No route to host");
        var body = request.Content?.ReadAsStringAsync(cancellationToken).GetAwaiter().GetResult() ?? "";
        Log.Add($"{request.Method} {url.Host}{url.AbsolutePath}");
        HttpResponseMessage response;
        try
        {
            response = url.Host switch
            {
                "storage.fake" => StorageRequest(request, url),
                _ => Api(request, url, body),
            };
        }
        catch (HttpError e)
        {
            var json = new JsonObject { ["error"] = e.Code, ["message"] = e.Code };
            if (e.Scope is not null) json["scope"] = e.Scope;
            response = Json(e.Status, json);
        }
        return Task.FromResult(response);
    }

    private sealed class HttpError(HttpStatusCode status, string code, string? scope = null) : Exception(code)
    {
        public HttpStatusCode Status { get; } = status;
        public string Code { get; } = code;
        public string? Scope { get; } = scope;
    }

    private static HttpResponseMessage Json(HttpStatusCode status, JsonNode? json) =>
        new(status) { Content = new StringContent(json?.ToJsonString() ?? "", Encoding.UTF8, "application/json") };

    private static HttpResponseMessage Ok(JsonNode? json) => Json(HttpStatusCode.OK, json);
    private static HttpResponseMessage NoContent() => new(HttpStatusCode.NoContent);

    // MARK: Auth

    private string NewSession(User user, string? deviceName)
    {
        var token = Convert.ToBase64String(Guid.NewGuid().ToByteArray());
        var now = Clock();
        _sessions[token] = new Session { Id = Guid.NewGuid().ToString("D"), Email = user.Email, DeviceName = deviceName ?? "Unknown", CreatedAt = now, LastUsedAt = now };
        return token;
    }

    private JsonObject SessionJson(User user, string? deviceName) => new()
    {
        ["token"] = NewSession(user, deviceName), ["expiresAt"] = 9_999_999_999_999, ["account"] = user.Account.DeepClone(),
    };

    /// <summary>Unknown emails get a deterministic fake salt, like the real server.</summary>
    private JsonObject Prelogin(string email) => _users.TryGetValue(email, out var user)
        ? new JsonObject { ["kdf"] = user.Account["kdf"]!.DeepClone() }
        : new JsonObject { ["kdf"] = new JsonObject { ["alg"] = "pbkdf2-sha256",
            ["salt"] = Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(email))[..16]), ["iterations"] = 600_000 } };

    // Sign-up codes: 80 random bits in the invite-code alphabet, 4 groups of 4; only the hash of the normalised code is kept.
    private const string Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

    private static string Normalise(string code) => new([.. code.Where(c => !char.IsWhiteSpace(c) && c != '-').Select(char.ToUpperInvariant)
        .Select(c => c switch { '0' => 'O', '1' => 'I', '8' => 'B', _ => c })]);

    private static string Hash(string code) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(Normalise(code))));

    private (SignupCodeRow Row, string Code) NewSignupCode(string? owner)
    {
        var plain = new string([.. System.Security.Cryptography.RandomNumberGenerator.GetBytes(16).Select(b => Alphabet[b & 31])]);
        var code = string.Join("-", Enumerable.Range(0, 4).Select(i => plain.Substring(i * 4, 4)));
        var row = new SignupCodeRow { Id = Guid.NewGuid().ToString("D"), Hash = Hash(code), Owner = owner, CreatedAt = ++_seq, ExpiresAt = Clock() + 14L * 86_400_000 };
        _signupCodes[row.Hash] = row;
        return (row, code);
    }

    private HttpResponseMessage Auth(string action, JsonObject body)
    {
        string B(string k) => body[k]!.GetValue<string>();
        var email = B("email");
        if (email != email.Trim().ToLowerInvariant()) throw new HttpError(HttpStatusCode.BadRequest, "invalid");
        var device = body["deviceName"]?.GetValue<string>();
        switch (action)
        {
            case "prelogin":
                return Ok(Prelogin(email));
            case "signup":
                SignupCodeRow? code = null;
                if (RequireInvite)
                {
                    if (body["signupCode"] is JsonValue c)
                    {
                        if (!_signupCodes.TryGetValue(Hash(c.GetValue<string>()), out code) || code.Used || code.ExpiresAt < Clock())
                            throw new HttpError(HttpStatusCode.Forbidden, "invite_invalid");
                    }
                    else if (body["groupInviteId"] is JsonValue g)
                    {
                        if (!_invites.TryGetValue(g.GetValue<string>(), out var invite) || invite.Used || invite.ExpiresAt < Clock())
                            throw new HttpError(HttpStatusCode.Forbidden, "invite_invalid");
                    }
                    else throw new HttpError(HttpStatusCode.Forbidden, "invite_required");
                }
                if (_users.ContainsKey(email)) throw new HttpError(HttpStatusCode.Conflict, "conflict");
                if (body["kdf"]!["iterations"]!.GetValue<int>() < 1000) throw new HttpError(HttpStatusCode.BadRequest, "invalid");
                var username = !Legacy && body["username"] is { } u ? ValidUsername(u, null) : null;
                if (code is not null) code.Used = true;   // consumed with the sign-up
                var personal = body["personalSpace"]!.AsObject();
                var spaceId = personal["id"]!.GetValue<string>();
                var user = new User
                {
                    Email = email, AuthKey = B("authKey"),
                    Account = new JsonObject
                    {
                        ["uid"] = B("uid"), ["email"] = email,
                        ["kdf"] = new JsonObject { ["alg"] = "pbkdf2-sha256", ["salt"] = body["kdf"]!["salt"]!.GetValue<string>(), ["iterations"] = body["kdf"]!["iterations"]!.GetValue<int>() },
                        ["wrappedAccountKey"] = B("wrappedAccountKey"), ["publicKey"] = B("publicKey"), ["wrappedPrivateKey"] = B("wrappedPrivateKey"),
                        ["personalSpaceId"] = spaceId,
                    },
                };
                if (!Legacy) user.Account["username"] = username;
                _users[email] = user;
                var space = new Space { Id = spaceId, Kind = "personal", Owner = user.Uid, CreatedAt = _seq };
                space.Members[user.Uid] = ("owner", personal["wrappedKey"]!.GetValue<string>());
                _spaces[spaceId] = space;
                return Json(HttpStatusCode.Created, SessionJson(user, device));
            case "login":
                if (!_users.TryGetValue(email, out var existing) || existing.AuthKey != B("authKey"))
                    throw new HttpError(HttpStatusCode.Unauthorized, "invalid_credentials");
                return Ok(SessionJson(existing, device));
            default:
                throw new HttpError(HttpStatusCode.NotFound, "not_found");
        }
    }

    // MARK: Storage

    private HttpResponseMessage StorageRequest(HttpRequestMessage request, Uri url)
    {
        var parts = url.AbsolutePath.Trim('/').Split('/');
        var key = (parts[0], parts[1]);
        if (!_blobs.TryGetValue(key, out var blob)) return new HttpResponseMessage(HttpStatusCode.NotFound);
        if (request.Method == HttpMethod.Put)
        {
            if (!request.Headers.Contains("x-goog-content-length-range")) return new HttpResponseMessage(HttpStatusCode.BadRequest);
            if (blob.CreateOnly)
            {
                // The signed URL requires x-goog-if-generation-match: 0, so an existing object is never overwritten.
                if (!request.Headers.TryGetValues("x-goog-if-generation-match", out var values) || values.Single() != "0")
                    return new HttpResponseMessage(HttpStatusCode.Forbidden);
                if (blob.Bytes is not null) return new HttpResponseMessage(HttpStatusCode.PreconditionFailed);
            }
            blob.Bytes = request.Content!.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
        return blob.Bytes is { } bytes ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) } : new HttpResponseMessage(HttpStatusCode.NotFound);
    }

    // MARK: API

    private HttpResponseMessage Api(HttpRequestMessage request, Uri url, string rawBody)
    {
        var path = url.AbsolutePath.Trim('/').Split('/');   // v1, …
        var body = rawBody.Length > 0 ? JsonNode.Parse(rawBody) as JsonObject : null;
        if (path[1] == "auth" && path[2] != "logout") return Auth(path[2], body!);
        var token = request.Headers.Authorization?.Parameter ?? "";
        if (!_sessions.TryGetValue(token, out var session) || !_users.TryGetValue(session.Email, out var caller))
            throw new HttpError(HttpStatusCode.Unauthorized, "unauthenticated");
        session.LastUsedAt = Clock();
        if (RateLimitAfter is { } left)
        {
            if (left <= 0)
            {
                var limited = Json((HttpStatusCode)429, new JsonObject { ["error"] = "rate_limited", ["message"] = "Too many requests", ["retryAfter"] = 30 });
                return limited;
            }
            RateLimitAfter = left - 1;
        }
        var query = HttpUtility.ParseQueryString(url.Query);
        var method = request.Method.Method;
        string B(string k) => body![k]!.GetValue<string>();

        switch (path[1])
        {
            case "auth":   // logout
                _sessions.Remove(token);
                return NoContent();
            case "account" when path.Length == 2 && method == "GET":
                return Ok(caller.Account.DeepClone());
            case "account" when path.Length == 3 && path[2] == "username" && method == "PUT" && !Legacy:
                caller.Account["username"] = ValidUsername(body!["username"], caller);
                return Ok(new JsonObject { ["username"] = caller.Username });
            case "account" when path.Length == 3 && path[2] == "username":
                throw new HttpError(HttpStatusCode.NotFound, "not_found");
            case "account" when path.Length == 3 && method == "PUT":
                if (B("authKey") != caller.AuthKey) throw new HttpError(HttpStatusCode.Unauthorized, "invalid_credentials");
                caller.AuthKey = B("newAuthKey");
                caller.Account["kdf"] = new JsonObject { ["alg"] = "pbkdf2-sha256", ["salt"] = body!["kdf"]!["salt"]!.GetValue<string>(), ["iterations"] = body["kdf"]!["iterations"]!.GetValue<int>() };
                caller.Account["wrappedAccountKey"] = B("wrappedAccountKey");
                foreach (var t in _sessions.Where(p => p.Value.Email == caller.Email && p.Key != token).Select(p => p.Key).ToList()) _sessions.Remove(t);
                return NoContent();
            case "account" when method == "DELETE":
                if (B("authKey") != caller.AuthKey) throw new HttpError(HttpStatusCode.Unauthorized, "invalid_credentials");
                foreach (var owned in _spaces.Values.Where(s => s.Owner == caller.Uid).ToList()) DropSpace(owned.Id);
                foreach (var s in _spaces.Values) s.Members.Remove(caller.Uid);
                RevokeSessions(caller.Email);
                _users.Remove(caller.Email);
                return NoContent();
            case "sessions" when path.Length == 2:
                return Ok(new JsonObject { ["sessions"] = new JsonArray([.. _sessions.Where(p => p.Value.Email == caller.Email).Select(p => (JsonNode?)new JsonObject
                {
                    ["id"] = p.Value.Id, ["deviceName"] = p.Value.DeviceName, ["createdAt"] = p.Value.CreatedAt, ["lastUsedAt"] = p.Value.LastUsedAt,
                    ["current"] = p.Key == token,
                })]) });
            case "sessions" when method == "DELETE":
                var revoked = _sessions.FirstOrDefault(p => p.Value.Email == caller.Email && p.Value.Id == path[2]);
                if (revoked.Key is null) throw new HttpError(HttpStatusCode.NotFound, "not_found");
                _sessions.Remove(revoked.Key);
                return NoContent();
            case "signup-codes" when path.Length == 2 && method == "POST":
                if (_signupCodes.Values.Count(c => c.Owner == caller.Uid && !c.Used) >= 10) throw new HttpError((HttpStatusCode)429, "too_many_codes");
                var (row, code) = NewSignupCode(caller.Uid);
                return Json(HttpStatusCode.Created, new JsonObject { ["id"] = row.Id, ["code"] = code, ["expiresAt"] = row.ExpiresAt });
            case "signup-codes" when path.Length == 2:
                return Ok(new JsonObject { ["codes"] = new JsonArray([.. _signupCodes.Values.Where(c => c.Owner == caller.Uid && !c.Used)
                    .Select(c => (JsonNode?)new JsonObject { ["id"] = c.Id, ["createdAt"] = c.CreatedAt, ["expiresAt"] = c.ExpiresAt })]) });
            case "signup-codes" when method == "DELETE":
                var mine = _signupCodes.Values.FirstOrDefault(c => c.Owner == caller.Uid && c.Id == path[2]) ?? throw new HttpError(HttpStatusCode.NotFound, "not_found");
                _signupCodes.Remove(mine.Hash);
                return NoContent();
            case "spaces" when path.Length == 2:
                return Ok(new JsonObject { ["spaces"] = new JsonArray([.. _spaces.Values.Where(s => s.Members.ContainsKey(caller.Uid))
                    .OrderByDescending(s => s.Kind).ThenBy(s => s.CreatedAt).Select(s => (JsonNode?)SpaceJson(s, caller.Uid))]) });
            case "groups" when path.Length == 2 && method == "POST":
                var group = new Space { Id = B("id"), Kind = "group", Owner = caller.Uid, Name = B("encryptedName"), CreatedAt = ++_seq };
                group.Members[caller.Uid] = ("owner", B("wrappedKey"));
                _spaces[group.Id] = group;
                return Json(HttpStatusCode.Created, SpaceJson(group, caller.Uid));
            case "groups" when path.Length == 3:
                var g = Member(path[2], caller.Uid);
                if (g.Owner != caller.Uid) throw new HttpError(HttpStatusCode.Forbidden, "forbidden");
                if (method == "PATCH") g.Name = B("encryptedName");
                else DropSpace(g.Id);
                return NoContent();
            case "groups" when path.Length >= 4 && path[3] == "invites":
                var owned2 = Member(path[2], caller.Uid);
                if (owned2.Owner != caller.Uid) throw new HttpError(HttpStatusCode.Forbidden, "forbidden");
                if (method == "POST")
                {
                    var invite = new Invite { Id = B("inviteId"), SpaceId = owned2.Id, SealedKey = B("sealedKey"), CreatedAt = ++_seq, ExpiresAt = 9_999_999_999_999 };
                    _invites[invite.Id] = invite;
                    return Json(HttpStatusCode.Created, new JsonObject { ["inviteId"] = invite.Id, ["expiresAt"] = invite.ExpiresAt });
                }
                if (method == "GET")
                    return Ok(new JsonObject { ["invites"] = new JsonArray([.. _invites.Values.Where(i => i.SpaceId == owned2.Id && !i.Used)
                        .Select(i => (JsonNode?)new JsonObject { ["inviteId"] = i.Id, ["createdAt"] = i.CreatedAt, ["expiresAt"] = i.ExpiresAt })]) });
                _invites.Remove(path[4]);
                return NoContent();
            case "groups" when path.Length >= 4:
                var grp = Member(path[2], caller.Uid);
                if (method == "GET")   // no emails (privacy)
                    return Ok(new JsonObject { ["members"] = new JsonArray([.. grp.Members.Select(m => UserByUid(m.Key) is { } u
                        ? (JsonNode?)new JsonObject { ["uid"] = m.Key, ["username"] = u.Username, ["name"] = u.Name, ["role"] = m.Value.Role }
                        : null).OfType<JsonNode>()]) });
                var target = path[4];
                if (target == caller.Uid ? grp.Owner == caller.Uid : grp.Owner != caller.Uid) throw new HttpError(HttpStatusCode.Forbidden, "forbidden");
                grp.Members.Remove(target);
                return NoContent();
            case "invites":
                if (!_invites.TryGetValue(path[2], out var inv) || inv.Used || !_spaces.TryGetValue(inv.SpaceId, out var invSpace))
                    throw new HttpError(HttpStatusCode.NotFound, "not_found");
                if (method == "GET")
                    return Ok(new JsonObject { ["spaceId"] = inv.SpaceId, ["sealedKey"] = inv.SealedKey, ["encryptedName"] = invSpace.Name,
                        ["memberCount"] = invSpace.Members.Count, ["expiresAt"] = inv.ExpiresAt });
                if (invSpace.Members.ContainsKey(caller.Uid)) throw new HttpError(HttpStatusCode.Conflict, "conflict");
                inv.Used = true;
                invSpace.Members[caller.Uid] = ("member", B("wrappedKey"));
                return Json(HttpStatusCode.Created, SpaceJson(invSpace, caller.Uid));
            case "spaces" when path[3] == "changes":
                return Changes(Member(path[2], caller.Uid), long.Parse(query["since"] ?? "0"), Math.Min(PageLimit, int.Parse(query["limit"] ?? "500")));
            case "spaces" when path[3] == "items" && method == "PUT":
                return Put(Member(path[2], caller.Uid), path[4], body!, caller.Uid);
            case "spaces" when path[3] == "items" && method == "DELETE":
                return Delete(Member(path[2], caller.Uid), path[4], long.Parse(query["updatedAt"] ?? "0"), caller.Uid);
            case "spaces" when path[3] == "blobs" && method == "POST":
                var s2 = Member(path[2], caller.Uid);
                var size = body!["size"]!.GetValue<long>();
                var blobId = B("id");
                if (s2.Items.Values.Any(i => i.BlobIds.Contains(blobId))) throw new HttpError(HttpStatusCode.Conflict, "conflict");
                var createOnly = body["ifGenerationMatch"] is JsonValue m && m.GetValue<bool>();
                if (!_blobs.ContainsKey((s2.Id, blobId))) _blobs[(s2.Id, blobId)] = new Blob { CreateOnly = createOnly };
                // Like the real server, the create-only header is signed but not listed: clients add it themselves.
                var headers = new JsonObject { ["x-goog-content-length-range"] = $"0,{size}", ["Content-Type"] = "application/octet-stream" };
                return Ok(new JsonObject { ["url"] = $"{Storage}/{s2.Id}/{blobId}", ["method"] = "PUT", ["headers"] = headers, ["expiresAt"] = 0 });
            case "spaces" when path[3] == "blobs" && method == "GET":
                var s3 = Member(path[2], caller.Uid);
                if (!_blobs.ContainsKey((s3.Id, path[4]))) throw new HttpError(HttpStatusCode.NotFound, "not_found");
                return Ok(new JsonObject { ["url"] = $"{Storage}/{s3.Id}/{path[4]}", ["expiresAt"] = 0 });
        }
        throw new HttpError(HttpStatusCode.NotFound, "not_found");
    }

    private Space Member(string spaceId, string uid) =>
        _spaces.TryGetValue(spaceId, out var s) && s.Members.ContainsKey(uid) ? s : throw new HttpError(HttpStatusCode.NotFound, "not_found");

    private void DropSpace(string id)
    {
        _spaces.Remove(id);
        foreach (var invite in _invites.Values.Where(i => i.SpaceId == id).ToList()) _invites.Remove(invite.Id);
        foreach (var key in _blobs.Keys.Where(k => k.Space == id).ToList()) _blobs.Remove(key);
    }

    private JsonObject SpaceJson(Space s, string uid)
    {
        var json = new JsonObject
        {
            ["id"] = s.Id, ["kind"] = s.Kind, ["role"] = s.Members[uid].Role, ["ownerUid"] = s.Owner, ["wrappedKey"] = s.Members[uid].Key,
            ["encryptedName"] = s.Name, ["memberCount"] = s.Members.Count, ["createdAt"] = s.CreatedAt,
        };
        if (!Legacy)
            json["members"] = new JsonArray([.. s.Members.Keys.Select(m => UserByUid(m)).OfType<User>()
                .Select(u => (JsonNode?)new JsonObject { ["uid"] = u.Uid, ["name"] = u.Name })]);
        return json;
    }

    private HttpResponseMessage Changes(Space space, long since, int limit)
    {
        if (since > 0 && since < space.PurgedSeq)
            return Ok(new JsonObject { ["items"] = new JsonArray(), ["nextSince"] = 0, ["hasMore"] = false, ["resetRequired"] = true });
        var rows = space.Items.Values.Where(i => i.Seq > since && !HiddenFromChanges.Contains(i.Id)).OrderBy(i => i.Seq).Take(limit + 1).ToList();
        var page = rows.Take(limit).ToList();
        return Ok(new JsonObject
        {
            ["items"] = new JsonArray([.. page.Select(i => (JsonNode?)i.Json())]),
            ["nextSince"] = page.Count > 0 ? page[^1].Seq : since,
            ["hasMore"] = rows.Count > limit,
            ["resetRequired"] = false,
        });
    }

    /// <summary>In a group only the author or the owner may overwrite or delete a live item.</summary>
    private static void RequireWriter(Space space, Item? existing, string uid)
    {
        if (space.Kind == "group" && existing is { Deleted: null } && existing.Author != uid && space.Owner != uid)
            throw new HttpError(HttpStatusCode.Forbidden, "forbidden");
    }

    private HttpResponseMessage Put(Space space, string id, JsonObject body, string uid)
    {
        var updatedAt = body["updatedAt"]!.GetValue<long>();
        if (updatedAt > Clock() + SkewLimitMs || body["sortAt"]!.GetValue<long>() > Clock() + SkewLimitMs) throw new HttpError(HttpStatusCode.BadRequest, "clock_skew");
        space.Items.TryGetValue(id, out var existing);
        if (existing is not null && existing.UpdatedAt > updatedAt)
            return Json(HttpStatusCode.Conflict, new JsonObject { ["error"] = "conflict", ["message"] = "newer", ["current"] = existing.Json() });
        RequireWriter(space, existing, uid);
        var ciphertext = body["ciphertext"]!.GetValue<string>();
        if (Convert.FromBase64String(ciphertext).Length > MaxItemBytes) throw new HttpError(HttpStatusCode.RequestEntityTooLarge, "too_large");
        var blobIds = (body["blobIds"] as JsonArray ?? []).Select(b => b!.GetValue<string>()).Distinct().ToList();
        if (blobIds.Count > 12 || blobIds.Any(b => !_blobs.ContainsKey((space.Id, b)))) throw new HttpError(HttpStatusCode.BadRequest, "invalid");
        if (existing is not { Deleted: null } && space.Items.Values.Count(i => i.Deleted is null) >= MaxLiveItems)
            throw new HttpError(HttpStatusCode.RequestEntityTooLarge, "quota_exceeded", space.Kind == "group" ? "group" : "server");
        foreach (var dropped in (existing?.BlobIds ?? []).Where(b => !blobIds.Contains(b))) _blobs.Remove((space.Id, dropped));
        var item = new Item
        {
            Id = id, Category = body["category"]!.GetValue<string>(), Seq = ++_seq, SortAt = body["sortAt"]!.GetValue<long>(),
            UpdatedAt = updatedAt, Ciphertext = ciphertext, BlobIds = blobIds,
            Author = existing is { Deleted: null } ? existing.Author : uid,
            Earlier = existing is { Ciphertext: { } old } ? [.. existing.Earlier, (old, existing.UpdatedAt)] : existing?.Earlier ?? [],
        };
        space.Items[id] = item;
        var trimmed = new List<string>();
        if (item.Category == "history")
        {
            foreach (var doomed in space.Items.Values.Where(i => i.Category == "history" && i.Deleted is null)
                         .OrderByDescending(i => i.SortAt).ThenByDescending(i => i.Id, StringComparer.Ordinal).Skip(HistoryLimit).ToList())
            {
                foreach (var b in doomed.BlobIds) _blobs.Remove((space.Id, b));
                doomed.Deleted = "trimmed";
                doomed.Seq = ++_seq;
                doomed.Ciphertext = null;
                doomed.BlobIds = [];
                trimmed.Add(doomed.Id);
            }
        }
        return Ok(new JsonObject { ["seq"] = item.Seq, ["trimmed"] = new JsonArray([.. trimmed.Select(t => (JsonNode?)t)]) });
    }

    private HttpResponseMessage Delete(Space space, string id, long updatedAt, string uid)
    {
        if (updatedAt > Clock() + SkewLimitMs) throw new HttpError(HttpStatusCode.BadRequest, "clock_skew");
        if (!space.Items.TryGetValue(id, out var existing)) return Ok(new JsonObject { ["seq"] = 0 });
        if (existing.Deleted == "user") return Ok(new JsonObject { ["seq"] = existing.Seq });
        if (existing.Deleted is null && existing.UpdatedAt > updatedAt)
            return Json(HttpStatusCode.Conflict, new JsonObject { ["error"] = "conflict", ["message"] = "changed", ["current"] = existing.Json() });
        RequireWriter(space, existing, uid);
        foreach (var b in existing.BlobIds) _blobs.Remove((space.Id, b));
        existing.Deleted = "user";
        existing.Seq = ++_seq;
        existing.UpdatedAt = Math.Max(existing.UpdatedAt, updatedAt);
        existing.Ciphertext = null;
        existing.BlobIds = [];
        return Ok(new JsonObject { ["seq"] = existing.Seq });
    }
}
