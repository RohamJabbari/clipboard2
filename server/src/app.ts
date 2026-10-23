import Fastify, { type FastifyInstance, type FastifyRequest } from "fastify";
import { z } from "zod";
import type pg from "pg";
import type { Db } from "./db.js";
import { tx } from "./db.js";
import type { Limits } from "./config.js";
import type { BlobStorage } from "./services.js";
import { RateLimiter } from "./rateLimit.js";
import {
  burnScrypt,
  FAKE_KDF_ITERATIONS,
  fakeSalt,
  hashAuthKey,
  newSessionToken,
  preloginKey,
  SESSION_DAYS,
  tokenHash,
  verifyAuthKey,
} from "./auth.js";

export interface Caller {
  uid: string;
  email: string;
  tokenHash: Buffer;
}

export interface Deps {
  pool: Db;
  storage: BlobStorage;
  limits: Limits;
  logger?: boolean;
}

declare module "fastify" {
  interface FastifyRequest {
    caller: Caller;
  }
}

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly extra: Record<string, unknown> = {},
  ) {
    super(message);
  }
}

const notFound = () => new ApiError(404, "not_found", "Not found");
const usernameTaken = () => new ApiError(409, "username_taken", "That username is taken");
/** The unique index on lower(username) fired (a race past the explicit check). */
const isUsernameConflict = (error: { code?: string; constraint?: string }) => error.code === "23505" && error.constraint === "users_username";
const forbidden = (message = "Not allowed") => new ApiError(403, "forbidden", message);

// MARK: Schemas

const uuid = z.string().regex(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/, "lowercase UUID");
const b64 = (maxBytes: number) =>
  z
    .string()
    .regex(/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/, "base64")
    .transform((s) => Buffer.from(s, "base64"))
    .refine((b) => b.length <= maxBytes, `at most ${maxBytes} bytes`);
const millis = z.number().int().nonnegative().max(8.64e15);
const category = z.enum(["history", "pinned", "snippet", "secret"]);
const kdf = z.object({ salt: b64(64).refine((b) => b.length >= 16, "salt too short"), iterations: z.number().int().min(100_000).max(10_000_000) });
const sealed = b64(4096);
const publicKey = b64(65).refine((b) => b.length === 65 && b[0] === 0x04, "X9.63 uncompressed P-256 key");

const email = z.string().trim().toLowerCase().pipe(z.email().max(320));
const authKey = b64(32).refine((b) => b.length === 32, "32-byte authKey");
const deviceName = z.string().max(100).optional();
/** 3–24 Unicode letters, digits, `_`, `.` or `-`, starting with a letter or digit. NFC so look-alikes can't dodge uniqueness. */
const username = z
  .string()
  .trim()
  .transform((s) => s.normalize("NFC"))
  .pipe(z.string().regex(/^[\p{L}\p{Nd}][\p{L}\p{Nd}_.-]{2,23}$/u, "3–24 letters, digits, _ . or -, starting with a letter or digit"));
const preloginBody = z.object({ email });
const signupBody = z.object({
  email,
  username: username.optional(),
  authKey,
  kdf,
  uid: uuid,
  wrappedAccountKey: sealed,
  publicKey,
  wrappedPrivateKey: sealed,
  personalSpace: z.object({ id: uuid, wrappedKey: sealed }),
  deviceName,
});
const loginBody = z.object({ email, authKey, deviceName });
const passwordBody = z.object({ authKey, newAuthKey: authKey, kdf, wrappedAccountKey: sealed });
const reauthBody = z.object({ authKey });
const usernameBody = z.object({ username });
const groupBody = z.object({ id: uuid, encryptedName: sealed, wrappedKey: sealed });
const renameBody = z.object({ encryptedName: sealed });
const inviteId = z.string().regex(/^[0-9a-f]{64}$/, "64 hex chars");
const inviteBody = z.object({ inviteId, sealedKey: sealed });
const acceptBody = z.object({ wrappedKey: sealed });
const changesQuery = z.object({
  since: z.coerce.number().int().nonnegative().default(0),
  limit: z.coerce.number().int().min(1).max(500).default(500),
});
const blobBody = z.object({ id: uuid, size: z.number().int().positive() });
const deleteQuery = z.object({ updatedAt: z.coerce.number().int().nonnegative() });

// MARK: Row mapping

interface ItemRow {
  id: string;
  category: string;
  seq: number;
  sort_at: number;
  updated_at: number;
  deleted: string | null;
  ciphertext: Buffer | null;
  blob_ids: string[];
  size: number;
  author_uid: string | null;
}

const itemJson = (r: ItemRow) => ({
  id: r.id,
  category: r.category,
  seq: r.seq,
  sortAt: r.sort_at,
  updatedAt: r.updated_at,
  deleted: r.deleted,
  ciphertext: r.ciphertext ? r.ciphertext.toString("base64") : null,
  blobIds: r.blob_ids,
  authorUid: r.author_uid,
});

const ITEM_COLUMNS = "id, category, seq, sort_at, updated_at, deleted, ciphertext, blob_ids, size, author_uid";

const blobPath = (spaceId: string, blobId: string) => `${spaceId}/${blobId}`;

// MARK: Queries

type Queryable = Pick<pg.PoolClient, "query">;

async function roleIn(db: Queryable, spaceId: string, uid: string, lock = false): Promise<{ role: string; kind: string } | null> {
  const { rows } = await db.query<{ role: string; kind: string }>(
    `SELECT m.role, s.kind FROM space_members m JOIN spaces s ON s.id = m.space_id
     WHERE m.space_id = $1 AND m.uid = $2${lock ? " FOR SHARE OF s" : ""}`,
    [spaceId, uid],
  );
  return rows[0] ?? null;
}

async function requireMember(db: Queryable, spaceId: string, uid: string, lock = false) {
  const membership = await roleIn(db, spaceId, uid, lock);
  // Non-members get 404 so space ids don't leak.
  if (!membership) throw notFound();
  return membership;
}

async function requireGroupOwner(db: Queryable, spaceId: string, uid: string) {
  const membership = await requireMember(db, spaceId, uid);
  if (membership.kind !== "group") throw notFound();
  if (membership.role !== "owner") throw forbidden("Only the group owner can do that");
}

/** Bytes this user currently occupies: live items they wrote plus blobs they registered. */
async function bytesUsed(db: Queryable, uid: string): Promise<number> {
  const { rows } = await db.query<{ total: number }>(
    `SELECT (SELECT COALESCE(SUM(size), 0) FROM items WHERE author_uid = $1 AND deleted IS NULL)
          + (SELECT COALESCE(SUM(size), 0) FROM blobs WHERE owner_uid = $1) AS total`,
    [uid],
  );
  return Number(rows[0]?.total ?? 0);
}

async function blobPathsOfSpaces(db: Queryable, spaceIds: string[]): Promise<string[]> {
  if (spaceIds.length === 0) return [];
  const { rows } = await db.query<{ space_id: string; id: string }>("SELECT space_id, id FROM blobs WHERE space_id = ANY($1::uuid[])", [spaceIds]);
  return rows.map((r) => blobPath(r.space_id, r.id));
}

async function dropBlobs(db: Queryable, spaceId: string, blobIds: string[]): Promise<string[]> {
  if (blobIds.length === 0) return [];
  const { rows } = await db.query<{ id: string }>("DELETE FROM blobs WHERE space_id = $1 AND id = ANY($2::uuid[]) RETURNING id", [spaceId, blobIds]);
  return rows.map((r) => blobPath(spaceId, r.id));
}

// MARK: App

export function buildApp(deps: Deps): FastifyInstance {
  const { pool, storage, limits } = deps;
  // Base64 adds a third; leave room for the JSON envelope. Cloud Run sits behind Google's front end,
  // so the client IP comes from X-Forwarded-For.
  const app = Fastify({ logger: deps.logger ?? false, bodyLimit: Math.ceil(limits.itemBytes * 1.4) + 64 * 1024, trustProxy: true });
  const requests = new RateLimiter(limits.requestsPerMinute);
  const authByIp = new RateLimiter(limits.authPerMinutePerIp);
  const authByEmail = new RateLimiter(limits.authPerMinutePerEmail);
  const inviteLookups = new RateLimiter(limits.invitesPerMinute);
  const serverKey = preloginKey(pool);
  serverKey.catch(() => {}); // surfaced on first prelogin instead of as an unhandled rejection
  const lastPurge = new Map<string, number>();
  const lastBlobSweep = new Map<string, number>();

  /** Deletes GCS objects after the transaction that dropped their rows committed. Failures only leak storage. */
  const deleteObjects = async (paths: string[], request: FastifyRequest) => {
    if (paths.length === 0) return;
    await storage.delete(paths).catch((error) => request.log.warn({ error, count: paths.length }, "blob delete failed"));
  };

  app.setErrorHandler((error, request, reply) => {
    if (error instanceof ApiError) {
      if (error.status === 429) reply.header("Retry-After", String(error.extra.retryAfter ?? 60));
      return reply.status(error.status).send({ error: error.code, message: error.message, ...error.extra });
    }
    if (error instanceof z.ZodError) {
      return reply.status(400).send({ error: "invalid", message: error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ") });
    }
    const status = (error as { statusCode?: number }).statusCode;
    if (status === 413) return reply.status(413).send({ error: "too_large", message: "Request body too large" });
    if (status && status >= 400 && status < 500) return reply.status(status).send({ error: "invalid", message: (error as Error).message });
    request.log.error(error);
    return reply.status(500).send({ error: "internal", message: "Something went wrong" });
  });

  // Not /healthz: Cloud Run's front end reserves that path and answers it with its own 404.
  app.get("/health", async () => ({ ok: true }));

  const PUBLIC_ROUTES = new Set(["/v1/auth/prelogin", "/v1/auth/signup", "/v1/auth/login"]);

  app.addHook("onRequest", async (request) => {
    if (!request.url.startsWith("/v1/") || PUBLIC_ROUTES.has(request.url.split("?")[0]!)) return;
    const header = request.headers.authorization ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
    if (!token) throw new ApiError(401, "unauthenticated", "Sign in first");
    const hash = tokenHash(token);
    const { rows } = await pool.query<{ uid: string; email: string; stale: boolean }>(
      `SELECT s.uid, u.email, s.last_used_at < now() - interval '1 hour' AS stale
       FROM sessions s JOIN users u ON u.uid = s.uid WHERE s.token_hash = $1 AND s.expires_at > now()`,
      [hash],
    );
    const session = rows[0];
    if (!session) throw new ApiError(401, "unauthenticated", "Your session ended; sign in again");
    const wait = requests.take(session.uid);
    if (wait > 0) throw new ApiError(429, "rate_limited", "Too many requests", { retryAfter: wait });
    if (session.stale) {
      await pool.query(`UPDATE sessions SET last_used_at = now(), expires_at = now() + make_interval(days => $2) WHERE token_hash = $1`, [hash, SESSION_DAYS]);
    }
    request.caller = { uid: session.uid, email: session.email, tokenHash: hash };
  });

  /** Shared per-IP and per-email throttle for prelogin, signup and login. */
  const throttleAuth = (request: FastifyRequest, emailAddress: string) => {
    const wait = Math.max(authByIp.take(`ip:${request.ip}`), authByEmail.take(`email:${emailAddress}`));
    if (wait > 0) throw new ApiError(429, "rate_limited", "Too many attempts; wait a moment", { retryAfter: wait });
  };

  const startSession = async (db: Queryable, uid: string, device: string | undefined) => {
    const token = newSessionToken();
    const { rows } = await db.query<{ expires_at: Date }>(
      `INSERT INTO sessions (token_hash, uid, device_name, expires_at) VALUES ($1, $2, $3, now() + make_interval(days => $4)) RETURNING expires_at`,
      [tokenHash(token), uid, device ?? null, SESSION_DAYS],
    );
    return { token, expiresAt: rows[0]!.expires_at.getTime() };
  };

  /** Checks authKey against the stored scrypt hash; false for unknown users after the same work. */
  const checkAuthKey = async (db: Queryable, where: { uid?: string; email?: string }, key: Buffer) => {
    const { rows } = await db.query<{ uid: string; auth_salt: Buffer; auth_hash: Buffer }>(
      where.uid ? "SELECT uid, auth_salt, auth_hash FROM users WHERE uid = $1" : "SELECT uid, auth_salt, auth_hash FROM users WHERE lower(email) = $1",
      [where.uid ?? where.email],
    );
    const user = rows[0];
    if (!user) {
      await burnScrypt(key);
      return null;
    }
    return (await verifyAuthKey(key, user.auth_salt, user.auth_hash)) ? user.uid : null;
  };

  // MARK: Account

  const accountJson = (r: {
    uid: string;
    email: string;
    username: string | null;
    kdf_salt: Buffer;
    kdf_iterations: number;
    wrapped_account_key: Buffer;
    public_key: Buffer;
    wrapped_private_key: Buffer;
    personal_space_id: string;
  }) => ({
    uid: r.uid,
    email: r.email,
    username: r.username,
    kdf: { alg: "pbkdf2-sha256", salt: r.kdf_salt.toString("base64"), iterations: r.kdf_iterations },
    wrappedAccountKey: r.wrapped_account_key.toString("base64"),
    publicKey: r.public_key.toString("base64"),
    wrappedPrivateKey: r.wrapped_private_key.toString("base64"),
    personalSpaceId: r.personal_space_id,
  });

  app.post("/v1/auth/prelogin", async (request) => {
    const body = preloginBody.parse(request.body);
    throttleAuth(request, body.email);
    const { rows } = await pool.query<{ kdf_salt: Buffer; kdf_iterations: number }>(
      "SELECT kdf_salt, kdf_iterations FROM users WHERE lower(email) = $1",
      [body.email],
    );
    const user = rows[0];
    const salt = user ? user.kdf_salt : fakeSalt(await serverKey, body.email);
    return { kdf: { alg: "pbkdf2-sha256", salt: salt.toString("base64"), iterations: user?.kdf_iterations ?? FAKE_KDF_ITERATIONS } };
  });

  app.post("/v1/auth/signup", async (request, reply) => {
    const body = signupBody.parse(request.body);
    throttleAuth(request, body.email);
    const verifier = await hashAuthKey(body.authKey);
    const result = await tx(pool, async (db) => {
      const existing = await db.query("SELECT 1 FROM users WHERE lower(email) = $1", [body.email]);
      if (existing.rowCount) throw new ApiError(409, "conflict", "An account with that email already exists");
      if (body.username) {
        const taken = await db.query("SELECT 1 FROM users WHERE lower(username) = lower($1)", [body.username]);
        if (taken.rowCount) throw usernameTaken();
      }
      const { rows } = await db.query(
        `INSERT INTO users (uid, email, username, auth_salt, auth_hash, kdf_salt, kdf_iterations, wrapped_account_key, public_key, wrapped_private_key, personal_space_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *`,
        [
          body.uid,
          body.email,
          body.username ?? null,
          verifier.salt,
          verifier.hash,
          body.kdf.salt,
          body.kdf.iterations,
          body.wrappedAccountKey,
          body.publicKey,
          body.wrappedPrivateKey,
          body.personalSpace.id,
        ],
      );
      await db.query("INSERT INTO spaces (id, kind, owner_uid) VALUES ($1, 'personal', $2)", [body.personalSpace.id, body.uid]);
      await db.query("INSERT INTO space_members (space_id, uid, role, wrapped_key) VALUES ($1, $2, 'owner', $3)", [
        body.personalSpace.id,
        body.uid,
        body.personalSpace.wrappedKey,
      ]);
      return { ...(await startSession(db, body.uid, body.deviceName)), account: accountJson(rows[0]) };
    }).catch((error: { code?: string; constraint?: string }) => {
      if (isUsernameConflict(error)) throw usernameTaken();
      if (error.code === "23505") throw new ApiError(409, "conflict", "An account with that email already exists");
      throw error;
    });
    return reply.status(201).send(result);
  });

  app.post("/v1/auth/login", async (request) => {
    const body = loginBody.parse(request.body);
    throttleAuth(request, body.email);
    const uid = await checkAuthKey(pool, { email: body.email }, body.authKey);
    if (!uid) throw new ApiError(401, "invalid_credentials", "Wrong email or password");
    const { rows } = await pool.query("SELECT * FROM users WHERE uid = $1", [uid]);
    return { ...(await startSession(pool, uid, body.deviceName)), account: accountJson(rows[0]) };
  });

  app.post("/v1/auth/logout", async (request, reply) => {
    await pool.query("DELETE FROM sessions WHERE token_hash = $1", [request.caller.tokenHash]);
    return reply.status(204).send();
  });

  app.get("/v1/account", async (request) => {
    const { rows } = await pool.query("SELECT * FROM users WHERE uid = $1", [request.caller.uid]);
    if (!rows[0]) throw new ApiError(404, "no_account", "No sync account");
    return accountJson(rows[0]);
  });

  app.put("/v1/account/username", async (request) => {
    const body = usernameBody.parse(request.body);
    const { rows } = await pool
      .query<{ username: string }>("UPDATE users SET username = $2 WHERE uid = $1 RETURNING username", [request.caller.uid, body.username])
      .catch((error: { code?: string; constraint?: string }) => {
        if (isUsernameConflict(error)) throw usernameTaken();
        throw error;
      });
    if (!rows[0]) throw new ApiError(404, "no_account", "No sync account");
    return { username: rows[0].username };
  });

  app.put("/v1/account/password", async (request, reply) => {
    const body = passwordBody.parse(request.body);
    const { uid, tokenHash: current } = request.caller;
    throttleAuth(request, request.caller.email);
    if (!(await checkAuthKey(pool, { uid }, body.authKey))) throw new ApiError(401, "invalid_credentials", "Your current password is wrong");
    const verifier = await hashAuthKey(body.newAuthKey);
    await tx(pool, async (db) => {
      await db.query(
        "UPDATE users SET auth_salt = $2, auth_hash = $3, kdf_salt = $4, kdf_iterations = $5, wrapped_account_key = $6 WHERE uid = $1",
        [uid, verifier.salt, verifier.hash, body.kdf.salt, body.kdf.iterations, body.wrappedAccountKey],
      );
      await db.query("DELETE FROM sessions WHERE uid = $1 AND token_hash <> $2", [uid, current]);
    });
    return reply.status(204).send();
  });

  app.delete("/v1/account", async (request, reply) => {
    const body = reauthBody.parse(request.body);
    const { uid } = request.caller;
    throttleAuth(request, request.caller.email);
    if (!(await checkAuthKey(pool, { uid }, body.authKey))) throw new ApiError(401, "invalid_credentials", "Wrong password");
    const paths = await tx(pool, async (db) => {
      const owned = await db.query<{ id: string }>("SELECT id FROM spaces WHERE owner_uid = $1", [uid]);
      const paths = await blobPathsOfSpaces(
        db,
        owned.rows.map((r) => r.id),
      );
      // Cascades to sessions, owned spaces (items, blobs, members, invites) and memberships elsewhere.
      await db.query("DELETE FROM users WHERE uid = $1", [uid]);
      return paths;
    });
    await deleteObjects(paths, request);
    return reply.status(204).send();
  });

  // MARK: Spaces and groups

  const spaceJson = (r: {
    id: string;
    kind: string;
    role: string;
    owner_uid: string;
    wrapped_key: Buffer;
    encrypted_name: Buffer | null;
    member_count: number;
    members: { uid: string; name: string }[];
    created_at: Date;
  }) => ({
    id: r.id,
    kind: r.kind,
    role: r.role,
    ownerUid: r.owner_uid,
    wrappedKey: r.wrapped_key.toString("base64"),
    encryptedName: r.encrypted_name ? r.encrypted_name.toString("base64") : null,
    memberCount: Number(r.member_count),
    members: r.members,
    createdAt: r.created_at.getTime(),
  });

  // members: display name is the username, else the email's local part. Owner first, then by join order.
  const SPACE_SELECT = `SELECT s.id, s.kind, m.role, s.owner_uid, m.wrapped_key, s.encrypted_name, s.created_at,
      (SELECT count(*) FROM space_members x WHERE x.space_id = s.id) AS member_count,
      (SELECT COALESCE(json_agg(json_build_object('uid', x.uid, 'name', COALESCE(u.username, split_part(u.email, '@', 1)))
                                ORDER BY x.role DESC, x.added_at, x.uid), '[]'::json)
         FROM space_members x JOIN users u ON u.uid = x.uid WHERE x.space_id = s.id) AS members
    FROM space_members m JOIN spaces s ON s.id = m.space_id`;

  app.get("/v1/spaces", async (request) => {
    const { rows } = await pool.query(`${SPACE_SELECT} WHERE m.uid = $1 ORDER BY s.kind DESC, s.created_at`, [request.caller.uid]);
    return { spaces: rows.map(spaceJson) };
  });

  app.post("/v1/groups", async (request, reply) => {
    const body = groupBody.parse(request.body);
    const { uid } = request.caller;
    const row = await tx(pool, async (db) => {
      const user = await db.query("SELECT 1 FROM users WHERE uid = $1 FOR UPDATE", [uid]);
      if (!user.rowCount) throw new ApiError(404, "no_account", "No sync account yet");
      const owned = await db.query<{ n: number }>("SELECT count(*)::int AS n FROM spaces WHERE owner_uid = $1 AND kind = 'group'", [uid]);
      if ((owned.rows[0]?.n ?? 0) >= limits.groupsOwned) throw new ApiError(403, "quota_exceeded", `You can own at most ${limits.groupsOwned} groups`);
      await db.query("INSERT INTO spaces (id, kind, owner_uid, encrypted_name) VALUES ($1, 'group', $2, $3)", [body.id, uid, body.encryptedName]);
      await db.query("INSERT INTO space_members (space_id, uid, role, wrapped_key) VALUES ($1, $2, 'owner', $3)", [body.id, uid, body.wrappedKey]);
      const { rows } = await db.query(`${SPACE_SELECT} WHERE m.uid = $1 AND s.id = $2`, [uid, body.id]);
      return rows[0];
    }).catch((error: { code?: string }) => {
      if (error.code === "23505") throw new ApiError(409, "conflict", "That id is already taken");
      throw error;
    });
    return reply.status(201).send(spaceJson(row));
  });

  app.patch<{ Params: { id: string } }>("/v1/groups/:id", async (request, reply) => {
    const id = uuid.parse(request.params.id);
    const body = renameBody.parse(request.body);
    await requireGroupOwner(pool, id, request.caller.uid);
    await pool.query("UPDATE spaces SET encrypted_name = $2 WHERE id = $1", [id, body.encryptedName]);
    return reply.status(204).send();
  });

  app.delete<{ Params: { id: string } }>("/v1/groups/:id", async (request, reply) => {
    const id = uuid.parse(request.params.id);
    const paths = await tx(pool, async (db) => {
      await requireGroupOwner(db, id, request.caller.uid);
      const paths = await blobPathsOfSpaces(db, [id]);
      await db.query("DELETE FROM spaces WHERE id = $1", [id]);
      return paths;
    });
    await deleteObjects(paths, request);
    return reply.status(204).send();
  });

  app.get<{ Params: { id: string } }>("/v1/groups/:id/members", async (request) => {
    const id = uuid.parse(request.params.id);
    const membership = await requireMember(pool, id, request.caller.uid);
    if (membership.kind !== "group") throw notFound();
    const { rows } = await pool.query<{ uid: string; email: string; username: string | null; role: string }>(
      "SELECT m.uid, u.email, u.username, m.role FROM space_members m JOIN users u ON u.uid = m.uid WHERE m.space_id = $1 ORDER BY m.role DESC, u.email",
      [id],
    );
    return { members: rows };
  });

  // MARK: Invites

  app.post<{ Params: { id: string } }>("/v1/groups/:id/invites", async (request, reply) => {
    const id = uuid.parse(request.params.id);
    const body = inviteBody.parse(request.body);
    const expiresAt = await tx(pool, async (db) => {
      await requireGroupOwner(db, id, request.caller.uid);
      await db.query("SELECT 1 FROM spaces WHERE id = $1 FOR UPDATE", [id]);
      await db.query("DELETE FROM invites WHERE space_id = $1 AND expires_at <= now()", [id]);
      const pending = await db.query<{ n: number }>("SELECT count(*)::int AS n FROM invites WHERE space_id = $1", [id]);
      if ((pending.rows[0]?.n ?? 0) >= limits.pendingInvitesPerGroup) {
        throw new ApiError(403, "quota_exceeded", `A group can have at most ${limits.pendingInvitesPerGroup} open invites`);
      }
      const { rows } = await db.query<{ expires_at: Date }>(
        `INSERT INTO invites (id, space_id, sealed_key, created_by, expires_at) VALUES ($1, $2, $3, $4, now() + interval '7 days')
         ON CONFLICT (id) DO NOTHING RETURNING expires_at`,
        [body.inviteId, id, body.sealedKey, request.caller.uid],
      );
      if (!rows[0]) throw new ApiError(409, "conflict", "That invite already exists");
      return rows[0].expires_at.getTime();
    });
    return reply.status(201).send({ inviteId: body.inviteId, expiresAt });
  });

  app.get<{ Params: { id: string } }>("/v1/groups/:id/invites", async (request) => {
    const id = uuid.parse(request.params.id);
    await requireGroupOwner(pool, id, request.caller.uid);
    const { rows } = await pool.query<{ id: string; created_at: Date; expires_at: Date }>(
      "SELECT id, created_at, expires_at FROM invites WHERE space_id = $1 AND expires_at > now() ORDER BY created_at",
      [id],
    );
    return { invites: rows.map((r) => ({ inviteId: r.id, createdAt: r.created_at.getTime(), expiresAt: r.expires_at.getTime() })) };
  });

  app.delete<{ Params: { id: string; inviteId: string } }>("/v1/groups/:id/invites/:inviteId", async (request, reply) => {
    const id = uuid.parse(request.params.id);
    const invite = inviteId.parse(request.params.inviteId);
    await requireGroupOwner(pool, id, request.caller.uid);
    const result = await pool.query("DELETE FROM invites WHERE id = $1 AND space_id = $2", [invite, id]);
    if (!result.rowCount) throw notFound();
    return reply.status(204).send();
  });

  const throttleInvites = (request: FastifyRequest) => {
    const wait = inviteLookups.take(request.caller.uid);
    if (wait > 0) throw new ApiError(429, "rate_limited", "Too many invite attempts; wait a moment", { retryAfter: wait });
  };

  app.get<{ Params: { inviteId: string } }>("/v1/invites/:inviteId", async (request) => {
    const invite = inviteId.parse(request.params.inviteId);
    throttleInvites(request);
    const { rows } = await pool.query<{ space_id: string; sealed_key: Buffer; encrypted_name: Buffer | null; member_count: number; expires_at: Date }>(
      `SELECT i.space_id, i.sealed_key, s.encrypted_name, i.expires_at,
         (SELECT count(*)::int FROM space_members m WHERE m.space_id = i.space_id) AS member_count
       FROM invites i JOIN spaces s ON s.id = i.space_id WHERE i.id = $1 AND i.expires_at > now()`,
      [invite],
    );
    const row = rows[0];
    if (!row) throw new ApiError(404, "not_found", "That invite code is unknown, used or expired");
    return {
      spaceId: row.space_id,
      sealedKey: row.sealed_key.toString("base64"),
      encryptedName: row.encrypted_name ? row.encrypted_name.toString("base64") : null,
      memberCount: row.member_count,
      expiresAt: row.expires_at.getTime(),
    };
  });

  app.post<{ Params: { inviteId: string } }>("/v1/invites/:inviteId/accept", async (request, reply) => {
    const invite = inviteId.parse(request.params.inviteId);
    const body = acceptBody.parse(request.body);
    const { uid } = request.caller;
    throttleInvites(request);
    const row = await tx(pool, async (db) => {
      const { rows } = await db.query<{ space_id: string }>("SELECT space_id FROM invites WHERE id = $1 AND expires_at > now() FOR UPDATE", [invite]);
      const spaceId = rows[0]?.space_id;
      if (!spaceId) throw new ApiError(404, "not_found", "That invite code is unknown, used or expired");
      await db.query("SELECT 1 FROM spaces WHERE id = $1 FOR UPDATE", [spaceId]);
      if (await roleIn(db, spaceId, uid)) throw new ApiError(409, "conflict", "You're already in this group");
      const count = await db.query<{ n: number }>("SELECT count(*)::int AS n FROM space_members WHERE space_id = $1", [spaceId]);
      if ((count.rows[0]?.n ?? 0) >= limits.membersPerGroup) throw new ApiError(403, "quota_exceeded", `A group can have at most ${limits.membersPerGroup} members`);
      await db.query("INSERT INTO space_members (space_id, uid, role, wrapped_key) VALUES ($1, $2, 'member', $3)", [spaceId, uid, body.wrappedKey]);
      await db.query("DELETE FROM invites WHERE id = $1", [invite]);
      const { rows: spaces } = await db.query(`${SPACE_SELECT} WHERE m.uid = $1 AND s.id = $2`, [uid, spaceId]);
      return spaces[0];
    });
    return reply.status(201).send(spaceJson(row));
  });

  app.delete<{ Params: { id: string; uid: string } }>("/v1/groups/:id/members/:uid", async (request, reply) => {
    const id = uuid.parse(request.params.id);
    const target = request.params.uid;
    const me = request.caller.uid;
    const membership = await requireMember(pool, id, me);
    if (membership.kind !== "group") throw notFound();
    if (target === me) {
      if (membership.role === "owner") throw new ApiError(400, "invalid", "The owner can't leave; delete the group instead");
    } else if (membership.role !== "owner") {
      throw forbidden("Only the group owner can remove members");
    }
    const result = await pool.query("DELETE FROM space_members WHERE space_id = $1 AND uid = $2 AND role = 'member'", [id, target]);
    if (!result.rowCount) throw notFound();
    return reply.status(204).send();
  });

  // MARK: Items

  /** Drops tombstones older than the retention window, at most hourly per space, and raises the reset horizon. */
  const purgeTombstones = async (spaceId: string) => {
    const now = Date.now();
    if (now - (lastPurge.get(spaceId) ?? 0) < 3_600_000) return;
    lastPurge.set(spaceId, now);
    await pool.query(
      `WITH gone AS (
         DELETE FROM items WHERE space_id = $1 AND deleted IS NOT NULL AND deleted_at < now() - make_interval(days => $2)
         RETURNING seq)
       UPDATE spaces SET purged_seq = GREATEST(purged_seq, (SELECT max(seq) FROM gone)) WHERE id = $1 AND EXISTS (SELECT 1 FROM gone)`,
      [spaceId, limits.tombstoneDays],
    );
  };

  app.get<{ Params: { id: string } }>("/v1/spaces/:id/changes", async (request) => {
    const id = uuid.parse(request.params.id);
    const query = changesQuery.parse(request.query);
    await requireMember(pool, id, request.caller.uid);
    await purgeTombstones(id);
    const space = await pool.query<{ purged_seq: number }>("SELECT purged_seq FROM spaces WHERE id = $1", [id]);
    if (query.since > 0 && query.since < (space.rows[0]?.purged_seq ?? 0)) {
      return { items: [], nextSince: 0, hasMore: false, resetRequired: true };
    }
    const { rows } = await pool.query<ItemRow>(
      `SELECT ${ITEM_COLUMNS} FROM items WHERE space_id = $1 AND seq > $2 ORDER BY seq LIMIT $3`,
      [id, query.since, query.limit + 1],
    );
    const hasMore = rows.length > query.limit;
    const page = rows.slice(0, query.limit);
    return { items: page.map(itemJson), nextSince: page.at(-1)?.seq ?? query.since, hasMore, resetRequired: false };
  });

  app.put<{ Params: { id: string; itemId: string } }>("/v1/spaces/:id/items/:itemId", async (request, reply) => {
    const spaceId = uuid.parse(request.params.id);
    const itemId = uuid.parse(request.params.itemId);
    const body = z
      .object({ category, sortAt: millis, updatedAt: millis, ciphertext: b64(limits.itemBytes), blobIds: z.array(uuid).max(8).default([]) })
      .parse(request.body);
    const uid = request.caller.uid;
    if (body.ciphertext.length === 0) throw new ApiError(400, "invalid", "ciphertext is empty");

    const outcome = await tx(pool, async (db) => {
      await requireMember(db, spaceId, uid, true);
      const { rows: current } = await db.query<ItemRow>(`SELECT ${ITEM_COLUMNS} FROM items WHERE space_id = $1 AND id = $2 FOR UPDATE`, [spaceId, itemId]);
      const existing = current[0];
      if (existing && existing.updated_at > body.updatedAt) return { conflict: existing };

      const blobIds = [...new Set(body.blobIds)];
      if (blobIds.length) {
        const found = await db.query("SELECT id FROM blobs WHERE space_id = $1 AND id = ANY($2::uuid[])", [spaceId, blobIds]);
        if (found.rowCount !== blobIds.length) throw new ApiError(400, "invalid", "Upload the item's blobs first");
      }

      const wasLiveNonHistory = existing && !existing.deleted && existing.category !== "history";
      if (body.category !== "history" && !wasLiveNonHistory) {
        const count = await db.query<{ n: number }>(
          "SELECT count(*)::int AS n FROM items WHERE space_id = $1 AND deleted IS NULL AND category <> 'history'",
          [spaceId],
        );
        if ((count.rows[0]?.n ?? 0) >= limits.nonHistoryPerSpace) {
          throw new ApiError(403, "quota_exceeded", `A space can hold at most ${limits.nonHistoryPerSpace} pinned items, snippets and secrets`);
        }
      }

      const reclaimed = existing && !existing.deleted && existing.author_uid === uid ? existing.size : 0;
      if ((await bytesUsed(db, uid)) - reclaimed + body.ciphertext.length > limits.userBytes) {
        throw new ApiError(403, "quota_exceeded", "Your sync storage is full");
      }

      const { rows: saved } = await db.query<{ seq: number }>(
        `INSERT INTO items (space_id, id, category, sort_at, updated_at, ciphertext, blob_ids, size, author_uid)
         VALUES ($1, $2, $3, $4, $5, $6, $7::uuid[], $8, $9)
         ON CONFLICT (space_id, id) DO UPDATE SET
           seq = nextval('item_seq'), category = EXCLUDED.category, sort_at = EXCLUDED.sort_at, updated_at = EXCLUDED.updated_at,
           deleted = NULL, deleted_at = NULL, ciphertext = EXCLUDED.ciphertext, blob_ids = EXCLUDED.blob_ids,
           size = EXCLUDED.size, author_uid = EXCLUDED.author_uid
         RETURNING seq`,
        [spaceId, itemId, body.category, body.sortAt, body.updatedAt, body.ciphertext, blobIds, body.ciphertext.length, uid],
      );

      const dropped = (existing?.blob_ids ?? []).filter((b) => !blobIds.includes(b));
      const paths = await dropBlobs(db, spaceId, dropped);

      let trimmed: string[] = [];
      if (body.category === "history") {
        const { rows: doomed } = await db.query<{ id: string; blob_ids: string[] }>(
          `WITH doomed AS (
             SELECT id, blob_ids FROM items
             WHERE space_id = $1 AND category = 'history' AND deleted IS NULL
             ORDER BY sort_at DESC, id DESC OFFSET $2 FOR UPDATE),
           gone AS (
             UPDATE items i SET seq = nextval('item_seq'), deleted = 'trimmed', deleted_at = now(),
               ciphertext = NULL, blob_ids = '{}', size = 0
             FROM doomed d WHERE i.space_id = $1 AND i.id = d.id)
           SELECT id, blob_ids FROM doomed`,
          [spaceId, limits.historyPerSpace],
        );
        trimmed = doomed.map((d) => d.id);
        paths.push(
          ...(await dropBlobs(
            db,
            spaceId,
            doomed.flatMap((d) => d.blob_ids),
          )),
        );
      }
      return { seq: saved[0]!.seq, trimmed, paths };
    });

    if ("conflict" in outcome) {
      return reply.status(409).send({ error: "conflict", message: "A newer version exists", current: itemJson(outcome.conflict!) });
    }
    await deleteObjects(outcome.paths, request);
    return { seq: outcome.seq, trimmed: outcome.trimmed };
  });

  app.delete<{ Params: { id: string; itemId: string } }>("/v1/spaces/:id/items/:itemId", async (request, reply) => {
    const spaceId = uuid.parse(request.params.id);
    const itemId = uuid.parse(request.params.itemId);
    const { updatedAt } = deleteQuery.parse(request.query);
    const outcome = await tx(pool, async (db) => {
      await requireMember(db, spaceId, request.caller.uid, true);
      const { rows } = await db.query<ItemRow>(`SELECT ${ITEM_COLUMNS} FROM items WHERE space_id = $1 AND id = $2 FOR UPDATE`, [spaceId, itemId]);
      const existing = rows[0];
      if (!existing) return { seq: 0, paths: [] as string[] };
      if (existing.deleted === "user") return { seq: existing.seq, paths: [] as string[] };
      if (!existing.deleted && existing.updated_at > updatedAt) return { conflict: existing };
      const { rows: saved } = await db.query<{ seq: number }>(
        `UPDATE items SET seq = nextval('item_seq'), deleted = 'user', deleted_at = now(), updated_at = GREATEST(updated_at, $3),
           ciphertext = NULL, blob_ids = '{}', size = 0
         WHERE space_id = $1 AND id = $2 RETURNING seq`,
        [spaceId, itemId, updatedAt],
      );
      return { seq: saved[0]!.seq, paths: await dropBlobs(db, spaceId, existing.blob_ids) };
    });
    if ("conflict" in outcome) {
      return reply.status(409).send({ error: "conflict", message: "The item changed after you deleted it", current: itemJson(outcome.conflict!) });
    }
    await deleteObjects(outcome.paths, request);
    return { seq: outcome.seq };
  });

  // MARK: Blobs

  /** Drops this user's blobs that no live item references a day after upload, at most hourly per user. */
  const sweepUnusedBlobs = async (uid: string, request: FastifyRequest) => {
    const now = Date.now();
    if (now - (lastBlobSweep.get(uid) ?? 0) < 3_600_000) return;
    lastBlobSweep.set(uid, now);
    const { rows } = await pool.query<{ space_id: string; id: string }>(
      `DELETE FROM blobs b WHERE b.owner_uid = $1 AND b.created_at < now() - interval '24 hours'
         AND NOT EXISTS (SELECT 1 FROM items i WHERE i.space_id = b.space_id AND b.id = ANY(i.blob_ids) AND i.deleted IS NULL)
       RETURNING b.space_id, b.id`,
      [uid],
    );
    await deleteObjects(
      rows.map((r) => blobPath(r.space_id, r.id)),
      request,
    );
  };

  app.post<{ Params: { id: string } }>("/v1/spaces/:id/blobs", async (request) => {
    const spaceId = uuid.parse(request.params.id);
    const body = blobBody.parse(request.body);
    const uid = request.caller.uid;
    if (body.size > limits.blobBytes) throw new ApiError(413, "too_large", `Blobs can be at most ${limits.blobBytes} bytes`);
    await sweepUnusedBlobs(uid, request);
    await tx(pool, async (db) => {
      await requireMember(db, spaceId, uid, true);
      const { rows } = await db.query<{ size: number; owner_uid: string | null }>("SELECT size, owner_uid FROM blobs WHERE space_id = $1 AND id = $2", [
        spaceId,
        body.id,
      ]);
      const existing = rows[0];
      // Re-requesting the URL for your own pending upload is fine (e.g. after a failed PUT).
      if (existing) {
        if (existing.owner_uid !== uid || existing.size !== body.size) throw new ApiError(409, "conflict", "That blob id is taken");
        return;
      }
      if ((await bytesUsed(db, uid)) + body.size > limits.userBytes) throw new ApiError(403, "quota_exceeded", "Your sync storage is full");
      await db.query("INSERT INTO blobs (space_id, id, size, owner_uid) VALUES ($1, $2, $3, $4)", [spaceId, body.id, body.size, uid]);
    });
    const signed = await storage.signedPutUrl(blobPath(spaceId, body.id), body.size);
    return { url: signed.url, method: "PUT", headers: signed.headers, expiresAt: signed.expiresAt };
  });

  app.get<{ Params: { id: string; blobId: string } }>("/v1/spaces/:id/blobs/:blobId", async (request) => {
    const spaceId = uuid.parse(request.params.id);
    const blobId = uuid.parse(request.params.blobId);
    await requireMember(pool, spaceId, request.caller.uid);
    const found = await pool.query("SELECT 1 FROM blobs WHERE space_id = $1 AND id = $2", [spaceId, blobId]);
    if (!found.rowCount) throw notFound();
    return storage.signedGetUrl(blobPath(spaceId, blobId));
  });

  return app;
}
