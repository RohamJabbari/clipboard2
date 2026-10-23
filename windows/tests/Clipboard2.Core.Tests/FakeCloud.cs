using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using System.Web;

namespace Clipboard2.Core.Tests;

/// <summary>
/// In-memory clipboard2-api (its own auth, sessions, invites) and signed-URL storage, following
/// docs/sync/PROTOCOL.md closely enough to test the Windows sync client without a network.
/// </summary>
internal sealed class FakeCloud : HttpMessageHandler
{
    public const string ApiBase = "https://api.fake";
    private const string Storage = "https://storage.fake";

    public int HistoryLimit { get; set; } = 200;
    /// <summary>Behaves like the server before usernames: ignores <c>username</c>, sends no <c>username</c> or
    /// <c>members</c>, and has no PUT /v1/account/username.</summary>
    public bool Legacy { get; set; }
    /// <summary>Answers 429 to the API once this many more API calls have been made (null = never).</summary>
    public int? RateLimitAfter { get; set; }
    public List<string> Log { get; } = [];
    public int Count(string prefix) => Log.Count(l => l.StartsWith(prefix));

    private long _seq;
    private readonly Dictionary<string, User> _users = [];               // by email
    private readonly Dictionary<string, string> _sessions = [];          // token → email
    private readonly Dictionary<string, Space> _spaces = [];
    private readonly Dictionary<(string Space, string Blob), byte[]?> _blobs = [];
    private readonly Dictionary<string, Invite> _invites = [];

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
        foreach (var t in _sessions.Where(p => p.Value == email).Select(p => p.Key).ToList()) _sessions.Remove(t);
    }

    public int SessionCount(string email) => _sessions.Values.Count(e => e == email);
    public int PendingInvites(string spaceId) => _invites.Values.Count(i => i.SpaceId == spaceId && !i.Used);
    public bool HasAccount(string email) => _users.ContainsKey(email);
    public string? LastAuthKey(string email) => _users.GetValueOrDefault(email)?.AuthKey;

    public IReadOnlyList<Item> Items(string spaceId) => [.. _spaces[spaceId].Items.Values];
    public IReadOnlyList<Item> LiveItems(string spaceId) => [.. _spaces[spaceId].Items.Values.Where(i => i.Deleted is null)];
    public Item ItemById(string spaceId, string id) => _spaces[spaceId].Items[id];
    public int BlobCount(string spaceId) => _blobs.Keys.Count(k => k.Space == spaceId);
    public void ForceReset(string spaceId) => _spaces[spaceId].PurgedSeq = _seq + 1;
    /// <summary>Loses a blob, as garbage collection would.</summary>
    public void DropBlob(string spaceId, string blobId) => _blobs.Remove((spaceId, blobId));

    /// <summary>Simulates a newer write from elsewhere without the client seeing it yet.</summary>
    public void BumpUpdatedAt(string spaceId, string id, long by) => _spaces[spaceId].Items[id].UpdatedAt += by;

    private User? UserByUid(string uid) => _users.Values.FirstOrDefault(u => u.Uid == uid);

    // MARK: Dispatch

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var url = request.RequestUri!;
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
            response = Json(e.Status, new JsonObject { ["error"] = e.Code, ["message"] = e.Code });
        }
        return Task.FromResult(response);
    }

    private sealed class HttpError(HttpStatusCode status, string code) : Exception(code)
    {
        public HttpStatusCode Status { get; } = status;
        public string Code { get; } = code;
    }

    private static HttpResponseMessage Json(HttpStatusCode status, JsonNode? json) =>
        new(status) { Content = new StringContent(json?.ToJsonString() ?? "", Encoding.UTF8, "application/json") };

    private static HttpResponseMessage Ok(JsonNode? json) => Json(HttpStatusCode.OK, json);
    private static HttpResponseMessage NoContent() => new(HttpStatusCode.NoContent);

    // MARK: Auth

    private string NewSession(User user)
    {
        var token = Convert.ToBase64String(Guid.NewGuid().ToByteArray());
        _sessions[token] = user.Email;
        return token;
    }

    private JsonObject SessionJson(User user) => new()
    {
        ["token"] = NewSession(user), ["expiresAt"] = 9_999_999_999_999, ["account"] = user.Account.DeepClone(),
    };

    /// <summary>Unknown emails get a deterministic fake salt, like the real server.</summary>
    private JsonObject Prelogin(string email) => _users.TryGetValue(email, out var user)
        ? new JsonObject { ["kdf"] = user.Account["kdf"]!.DeepClone() }
        : new JsonObject { ["kdf"] = new JsonObject { ["alg"] = "pbkdf2-sha256",
            ["salt"] = Convert.ToBase64String(System.Security.Cryptography.SHA256.HashData(Encoding.UTF8.GetBytes(email))[..16]), ["iterations"] = 600_000 } };

    private HttpResponseMessage Auth(string action, JsonObject body)
    {
        string B(string k) => body[k]!.GetValue<string>();
        var email = B("email");
        if (email != email.Trim().ToLowerInvariant()) throw new HttpError(HttpStatusCode.BadRequest, "invalid");
        switch (action)
        {
            case "prelogin":
                return Ok(Prelogin(email));
            case "signup":
                if (_users.ContainsKey(email)) throw new HttpError(HttpStatusCode.Conflict, "conflict");
                if (body["kdf"]!["iterations"]!.GetValue<int>() < 1000) throw new HttpError(HttpStatusCode.BadRequest, "invalid");
                var username = !Legacy && body["username"] is { } u ? ValidUsername(u, null) : null;
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
                return Json(HttpStatusCode.Created, SessionJson(user));
            case "login":
                if (!_users.TryGetValue(email, out var existing) || existing.AuthKey != B("authKey"))
                    throw new HttpError(HttpStatusCode.Unauthorized, "invalid_credentials");
                return Ok(SessionJson(existing));
            default:
                throw new HttpError(HttpStatusCode.NotFound, "not_found");
        }
    }

    // MARK: Storage

    private HttpResponseMessage StorageRequest(HttpRequestMessage request, Uri url)
    {
        var parts = url.AbsolutePath.Trim('/').Split('/');
        var key = (parts[0], parts[1]);
        if (!_blobs.ContainsKey(key)) return new HttpResponseMessage(HttpStatusCode.NotFound);
        if (request.Method == HttpMethod.Put)
        {
            if (!request.Headers.Contains("x-goog-content-length-range")) return new HttpResponseMessage(HttpStatusCode.BadRequest);
            _blobs[key] = request.Content!.ReadAsByteArrayAsync().GetAwaiter().GetResult();
            return new HttpResponseMessage(HttpStatusCode.OK);
        }
        return _blobs[key] is { } bytes ? new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) } : new HttpResponseMessage(HttpStatusCode.NotFound);
    }

    // MARK: API

    private HttpResponseMessage Api(HttpRequestMessage request, Uri url, string rawBody)
    {
        var path = url.AbsolutePath.Trim('/').Split('/');   // v1, …
        var body = rawBody.Length > 0 ? JsonNode.Parse(rawBody) as JsonObject : null;
        if (path[1] == "auth" && path[2] != "logout") return Auth(path[2], body!);
        var token = request.Headers.Authorization?.Parameter ?? "";
        if (!_sessions.TryGetValue(token, out var callerEmail) || !_users.TryGetValue(callerEmail, out var caller))
            throw new HttpError(HttpStatusCode.Unauthorized, "unauthenticated");
        if (RateLimitAfter is { } left)
        {
            if (left <= 0)
            {
                var limited = Json((HttpStatusCode)429, new JsonObject { ["error"] = "rate_limited", ["message"] = "Too many requests" });
                limited.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(30));
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
                foreach (var t in _sessions.Where(p => p.Value == caller.Email && p.Key != token).Select(p => p.Key).ToList()) _sessions.Remove(t);
                return NoContent();
            case "account" when method == "DELETE":
                if (B("authKey") != caller.AuthKey) throw new HttpError(HttpStatusCode.Unauthorized, "invalid_credentials");
                foreach (var owned in _spaces.Values.Where(s => s.Owner == caller.Uid).ToList()) DropSpace(owned.Id);
                foreach (var s in _spaces.Values) s.Members.Remove(caller.Uid);
                RevokeSessions(caller.Email);
                _users.Remove(caller.Email);
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
                if (method == "GET")
                    return Ok(new JsonObject { ["members"] = new JsonArray([.. grp.Members.Select(m => (JsonNode?)new JsonObject
                        { ["uid"] = m.Key, ["email"] = UserByUid(m.Key)?.Email, ["role"] = m.Value.Role })]) });
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
                return Changes(Member(path[2], caller.Uid), long.Parse(query["since"] ?? "0"), int.Parse(query["limit"] ?? "500"));
            case "spaces" when path[3] == "items" && method == "PUT":
                return Put(Member(path[2], caller.Uid), path[4], body!, caller.Uid);
            case "spaces" when path[3] == "items" && method == "DELETE":
                return Delete(Member(path[2], caller.Uid), path[4], long.Parse(query["updatedAt"] ?? "0"));
            case "spaces" when path[3] == "blobs" && method == "POST":
                var s2 = Member(path[2], caller.Uid);
                var size = body!["size"]!.GetValue<long>();
                _blobs.TryAdd((s2.Id, B("id")), null);
                return Ok(new JsonObject
                {
                    ["url"] = $"{Storage}/{s2.Id}/{B("id")}", ["method"] = "PUT",
                    ["headers"] = new JsonObject { ["x-goog-content-length-range"] = $"0,{size}", ["Content-Type"] = "application/octet-stream" },
                    ["expiresAt"] = 0,
                });
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

    private static HttpResponseMessage Changes(Space space, long since, int limit)
    {
        if (since > 0 && since < space.PurgedSeq)
            return Ok(new JsonObject { ["items"] = new JsonArray(), ["nextSince"] = 0, ["hasMore"] = false, ["resetRequired"] = true });
        var rows = space.Items.Values.Where(i => i.Seq > since).OrderBy(i => i.Seq).Take(limit + 1).ToList();
        var page = rows.Take(limit).ToList();
        return Ok(new JsonObject
        {
            ["items"] = new JsonArray([.. page.Select(i => (JsonNode?)i.Json())]),
            ["nextSince"] = page.Count > 0 ? page[^1].Seq : since,
            ["hasMore"] = rows.Count > limit,
            ["resetRequired"] = false,
        });
    }

    private HttpResponseMessage Put(Space space, string id, JsonObject body, string uid)
    {
        var updatedAt = body["updatedAt"]!.GetValue<long>();
        space.Items.TryGetValue(id, out var existing);
        if (existing is not null && existing.UpdatedAt > updatedAt)
            return Json(HttpStatusCode.Conflict, new JsonObject { ["error"] = "conflict", ["message"] = "newer", ["current"] = existing.Json() });
        var blobIds = (body["blobIds"] as JsonArray ?? []).Select(b => b!.GetValue<string>()).Distinct().ToList();
        if (blobIds.Any(b => !_blobs.ContainsKey((space.Id, b)))) throw new HttpError(HttpStatusCode.BadRequest, "invalid");
        foreach (var dropped in (existing?.BlobIds ?? []).Where(b => !blobIds.Contains(b))) _blobs.Remove((space.Id, dropped));
        var item = new Item
        {
            Id = id, Category = body["category"]!.GetValue<string>(), Seq = ++_seq, SortAt = body["sortAt"]!.GetValue<long>(),
            UpdatedAt = updatedAt, Ciphertext = body["ciphertext"]!.GetValue<string>(), BlobIds = blobIds, Author = uid,
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

    private HttpResponseMessage Delete(Space space, string id, long updatedAt)
    {
        if (!space.Items.TryGetValue(id, out var existing)) return Ok(new JsonObject { ["seq"] = 0 });
        if (existing.Deleted == "user") return Ok(new JsonObject { ["seq"] = existing.Seq });
        if (existing.Deleted is null && existing.UpdatedAt > updatedAt)
            return Json(HttpStatusCode.Conflict, new JsonObject { ["error"] = "conflict", ["message"] = "changed", ["current"] = existing.Json() });
        foreach (var b in existing.BlobIds) _blobs.Remove((space.Id, b));
        existing.Deleted = "user";
        existing.Seq = ++_seq;
        existing.UpdatedAt = Math.Max(existing.UpdatedAt, updatedAt);
        existing.Ciphertext = null;
        existing.BlobIds = [];
        return Ok(new JsonObject { ["seq"] = existing.Seq });
    }
}
