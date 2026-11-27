// Passwordless accounts (docs/features/passwordless.md, PROTOCOL.md → Passwordless): sign-up without
// a password, device approval with number matching, session windows, email verification and
// recovery. Registered by buildApp, which hands over the helpers it shares with the password routes.
import { createHash, randomBytes, randomInt, randomUUID, timingSafeEqual } from "node:crypto";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import type pg from "pg";
import type { Db } from "./db.js";
import { tx } from "./db.js";
import type { Limits, Features } from "./config.js";
import type { Mailer } from "./services.js";
import type { GoogleVerifier } from "./google.js";
import { IdTokenError } from "./google.js";
import { RateLimiter } from "./rateLimit.js";
import { rateKey } from "./auth.js";
import { decryptEmail, emailIndex, encryptEmail, isP256Point, matchNumber, migrateEmails, openEscrow, sealEscrow, type ServerKeys, wrapTo } from "./keys.js";

type Queryable = Pick<pg.PoolClient, "query">;

export interface Geo {
  country: string | null;
  city: string | null;
}

/** "Indefinitely" is stored as this many years ahead, so every session still has an expiry. */
export const INDEFINITE_YEARS = 100;
export const ACKNOWLEDGEMENT = "I understand the risks and I wish to proceed";
const MIN_WINDOW_MS = 15 * 60 * 1000;
const MAX_WINDOW_MS = 365 * 24 * 60 * 60 * 1000;
const SWEEP_EVERY_MS = 10 * 60 * 1000;

export const SESSION_COLUMNS = "id, device_name, created_at, last_used_at, expires_at, kind, platform, window_ms, country, city";

interface SessionRow {
  id: string;
  device_name: string | null;
  created_at: Date;
  last_used_at: Date;
  expires_at: Date;
  kind: string;
  platform: string | null;
  window_ms: number | null;
  country: string | null;
  city: string | null;
  current?: boolean;
}

/** `expiresAt` is null for a device session kept indefinitely; `windowMs` only on device sessions. */
export const sessionJson = (r: SessionRow) => {
  const indefinite = r.kind === "device" && r.window_ms === null;
  return {
    id: r.id,
    deviceName: r.device_name,
    createdAt: r.created_at.getTime(),
    lastUsedAt: r.last_used_at.getTime(),
    current: r.current ?? false,
    kind: r.kind,
    platform: r.platform,
    windowMs: r.kind === "device" ? r.window_ms : null,
    expiresAt: indefinite ? null : r.expires_at.getTime(),
    country: r.country,
    city: r.city,
  };
};

/**
 * Feeds `security` in GET /v1/heads ($1 = the caller): pending device requests and recoveries of the
 * account, recoveries and invitations where the caller is a recovery contact, the account's recovery
 * setup, and its sessions (devices list and windows).
 */
export const SECURITY_REVISION = `md5(concat_ws('#',
  COALESCE((SELECT string_agg(r.id::text, ';' ORDER BY r.id) FROM device_requests r
            WHERE r.uid = $1 AND r.status = 'pending' AND r.expires_at > now()), ''),
  COALESCE((SELECT string_agg(q.id::text || ':' || (SELECT count(*) FROM recovery_approvals a WHERE a.request_id = q.id), ';' ORDER BY q.id)
            FROM recovery_requests q WHERE q.uid = $1 AND q.status = 'pending' AND q.expires_at > now()), ''),
  COALESCE((SELECT string_agg(q.id::text || ':' || EXISTS (SELECT 1 FROM recovery_approvals a WHERE a.request_id = q.id AND a.contact_uid = $1)::text, ';' ORDER BY q.id)
            FROM recovery_requests q JOIN recovery_contacts c ON c.setup_id = q.setup_id
            WHERE c.contact_uid = $1 AND q.status = 'pending' AND q.expires_at > now()), ''),
  COALESCE((SELECT string_agg(c.setup_id::text || ':' || COALESCE(c.accepted_at::text, '-'), ';' ORDER BY c.setup_id)
            FROM recovery_contacts c WHERE c.contact_uid = $1), ''),
  COALESCE((SELECT s.id::text || ':' || s.broken::text || ':' ||
              COALESCE((SELECT string_agg(c.contact_uid || COALESCE(c.accepted_at::text, '-'), ',' ORDER BY c.contact_uid)
                        FROM recovery_contacts c WHERE c.setup_id = s.id), '')
            FROM recovery_setups s WHERE s.uid = $1), ''),
  COALESCE((SELECT string_agg(x.id::text || ':' || x.kind || ':' || COALESCE(x.window_ms::text, '-'), ';' ORDER BY x.id)
            FROM sessions x WHERE x.uid = $1 AND x.expires_at > now()), '')))`;

/** What buildApp shares with these routes. */
export interface PasswordlessContext {
  pool: Db;
  limits: Limits;
  keys: ServerKeys;
  feature: Features;
  google?: GoogleVerifier;
  mailer?: Mailer;
  /** The server's HMAC key for rate-limit keys (the prelogin key). */
  serverKey: Promise<Buffer>;
  error: (status: number, code: string, message: string, extra?: Record<string, unknown>) => Error;
  geoOf: (request: FastifyRequest) => Geo | null;
  throttleAuth: (request: FastifyRequest, subject: string) => Promise<void>;
  signupInvite: (db: Queryable, body: { signupCode?: string; groupInviteId?: string }) => Promise<{ signupCodeId: string | null }>;
  startSession: (
    db: Queryable,
    uid: string,
    device: string | null | undefined,
    options: { kind?: "password" | "device"; platform?: string | null; devicePublicKey?: Buffer | null; windowMs?: number | null; geo?: Geo | null },
  ) => Promise<{ token: string; expiresAt: number | null; sessionId: string }>;
  accountJson: (row: never) => unknown;
  checkPassword: (uid: string, authKey: Buffer) => Promise<boolean>;
  schemas: {
    uuid: z.ZodType<string>;
    email: z.ZodType<string>;
    username: z.ZodType<string>;
    sealed: z.ZodType<Buffer>;
    publicKey: z.ZodType<Buffer>;
    authKey: z.ZodType<Buffer>;
    inviteId: z.ZodType<string>;
  };
}

export function registerPasswordless(app: FastifyInstance, ctx: PasswordlessContext) {
  const { pool, limits, keys, feature, schemas: s } = ctx;
  const err = ctx.error;
  const notFound = () => err(404, "not_found", "Not found");
  const disabled = () => err(403, "feature_disabled", "That isn't available yet");
  const polls = new RateLimiter(limits.devicePollsPerMinute);
  let lastSweep = 0;

  // MARK: Schemas

  const devicePublicKey = s.publicKey.refine(isP256Point, "a P-256 point");
  const device = z.object({
    publicKey: devicePublicKey,
    name: z.string().max(100).optional(),
    platform: z.string().trim().max(20).optional(),
  });
  /** windowMs null = indefinitely, which needs the typed acknowledgement. */
  const windowFields = {
    windowMs: z.number().int().min(MIN_WINDOW_MS).max(MAX_WINDOW_MS).nullable(),
    acknowledgement: z.string().max(200).optional(),
  };
  const acknowledged = (b: { windowMs: number | null; acknowledgement?: string }) => b.windowMs !== null || b.acknowledgement?.trim() === ACKNOWLEDGEMENT;
  const ackMessage = { message: `Keeping a device signed in indefinitely needs the acknowledgement “${ACKNOWLEDGEMENT}”`, path: ["acknowledgement"] };
  const identifier = z.string().trim().min(1).max(320);
  const secret = z.string().regex(/^[A-Za-z0-9_-]{43}$/, "request secret");
  const idToken = z.string().min(20).max(8192);

  const signupBody = z
    .object({
      email: s.email.optional(),
      googleIdToken: idToken.optional(),
      username: s.username,
      signupCode: z.string().max(64).optional(),
      groupInviteId: s.inviteId.optional(),
      uid: s.uuid,
      publicKey: s.publicKey,
      wrappedPrivateKey: s.sealed,
      personalSpace: z.object({ id: s.uuid, wrappedKey: s.sealed }),
      device,
    })
    .refine((b) => (b.email === undefined) !== (b.googleIdToken === undefined), "email or googleIdToken, not both");
  const deviceRequestBody = z.object({ identifier, device, ...windowFields }).refine(acknowledged, ackMessage);
  const secretBody = z.object({ secret });
  const approveBody = z.object({ number: z.number().int().min(0).max(999), wrappedAccountKey: s.sealed.optional() });
  const denyBody = z.object({ block: z.boolean().optional() });
  const windowBody = z.object(windowFields).refine(acknowledged, ackMessage);
  const switchBody = z.object({ authKey: s.authKey, devicePublicKey, platform: z.string().trim().max(20).optional(), retirePassword: z.boolean().optional() });
  const emailBody = z
    .object({ email: s.email.optional(), googleIdToken: idToken.optional() })
    .refine((b) => (b.email === undefined) !== (b.googleIdToken === undefined), "email or googleIdToken");
  const codeBody = z.object({ code: z.string().regex(/^\d{6}$/, "6 digits") });
  const share = z.string().regex(/^[A-Za-z0-9+/]{43}=$/, "32 bytes").transform((v) => Buffer.from(v, "base64"));
  const recoveryBody = z.discriminatedUnion("method", [
    z.object({
      method: z.literal("contacts"),
      setupId: s.uuid,
      contacts: z.array(z.object({ uid: s.uuid, wrappedShare: s.sealed })).min(1).max(2),
      escrowShare: share,
    }),
    z.object({
      method: z.literal("email"),
      setupId: s.uuid,
      escrowShare: share,
      wrappedSecret: s.sealed,
      /** Mailed once, then forgotten. */
      code: z.string().min(16).max(64),
    }),
  ]);
  const recoveryStartBody = z
    .object({ identifier, method: z.enum(["contacts", "email"]), device, ...windowFields })
    .refine(acknowledged, ackMessage);
  const recoveryApproveBody = z.object({ number: z.number().int().min(0).max(999), wrappedShare: s.sealed.optional() });

  // MARK: Helpers

  const newSecret = () => randomBytes(32).toString("base64url");
  const secretHash = (value: string) => createHash("sha256").update(value, "utf8").digest();
  const hmac = async (name: string) => rateKey(await ctx.serverKey, name);
  const pubKeyName = (pub: Buffer) => `dev:${createHash("sha256").update(pub).digest("hex")}`;

  /** Counts each key once in its fixed window; over any limit is 429 with the wait. */
  const bucket = async (entries: { name: string; limit: number }[], windowMinutes: number) => {
    const windowSeconds = windowMinutes * 60;
    const keyed = await Promise.all(entries.map(async (e) => ({ ...e, key: await hmac(`bucket:${windowMinutes}:${e.name}`) })));
    const { rows } = await pool.query<{ key: Buffer; hits: number; wait: number }>(
      `INSERT INTO rate_buckets (key, window_start, hits, expires_at)
       SELECT k, to_timestamp(floor(extract(epoch FROM now()) / $2) * $2), 1, to_timestamp(floor(extract(epoch FROM now()) / $2) * $2 + $2)
       FROM unnest($1::bytea[]) AS k
       ON CONFLICT (key, window_start) DO UPDATE SET hits = rate_buckets.hits + 1
       RETURNING key, hits, ceil(extract(epoch FROM expires_at - now()))::int AS wait`,
      [keyed.map((k) => k.key), windowSeconds],
    );
    const over = rows.filter((r) => r.hits > (keyed.find((k) => k.key.equals(r.key))?.limit ?? 0));
    if (over.length) {
      throw err(429, "rate_limited", "Too many requests; wait a moment", { retryAfter: Math.max(1, ...over.map((r) => r.wait)) });
    }
  };

  /** Removes what has run out; at most every 10 minutes per instance, never in the request's way. */
  const sweep = () => {
    if (Date.now() - lastSweep < SWEEP_EVERY_MS) return;
    lastSweep = Date.now();
    pool
      .query(
        `WITH a AS (DELETE FROM sessions WHERE expires_at < now() RETURNING 1),
              b AS (DELETE FROM device_requests WHERE expires_at < now() - interval '1 day' RETURNING 1),
              c AS (DELETE FROM rate_buckets WHERE expires_at < now() RETURNING 1),
              d AS (DELETE FROM used_id_tokens WHERE expires_at < now() RETURNING 1),
              e AS (DELETE FROM device_blocks WHERE until < now() RETURNING 1),
              f AS (DELETE FROM recovery_requests WHERE expires_at < now() - interval '1 day' RETURNING 1),
              g AS (DELETE FROM email_codes WHERE expires_at < now() RETURNING 1)
         SELECT 1`,
      )
      .catch(() => {});
    // Rows an older instance wrote with a plaintext email during a rollout.
    migrateEmails(pool, keys).catch(() => {});
  };

  // Any request may run the sweep (after answering), at most every 10 minutes per instance.
  app.addHook("onResponse", async () => sweep());

  /** An email (has @) or a username, to the account's uid; null when nobody has it. */
  const resolve = async (raw: string): Promise<string | null> => {
    if (raw.includes("@")) {
      const parsed = s.email.safeParse(raw);
      if (!parsed.success) return null;
      const { rows } = await pool.query<{ uid: string }>("SELECT uid FROM users WHERE email_index = $1", [emailIndex(keys, parsed.data)]);
      return rows[0]?.uid ?? null;
    }
    const parsed = s.username.safeParse(raw);
    if (!parsed.success) return null;
    const { rows } = await pool.query<{ uid: string }>("SELECT uid FROM users WHERE lower(username) = lower($1)", [parsed.data]);
    return rows[0]?.uid ?? null;
  };

  /** The limits every unauthenticated request for an account shares (device requests, recoveries). */
  const throttleRequest = async (request: FastifyRequest, kind: string, account: string, pub: Buffer) => {
    await bucket(
      [
        { name: `${kind}:acct:${account}`, limit: limits.deviceRequestsPerAccount },
        { name: `${kind}:ip:${request.ip}`, limit: limits.deviceRequestsPerIp },
        { name: `${kind}:${pubKeyName(pub)}`, limit: limits.deviceRequestsPerDeviceKey },
      ],
      limits.requestWindowMinutes,
    );
  };

  const refusePausedOrBlocked = async (uid: string, request: FastifyRequest, pub: Buffer, column: "requests_paused_until" | "recovery_paused_until") => {
    const ipKey = await hmac(`ip:${request.ip}`);
    const devKey = await hmac(pubKeyName(pub));
    const { rows } = await pool.query<{ wait: number | null }>(
      `SELECT GREATEST(
         (SELECT extract(epoch FROM ${column} - now()) FROM users WHERE uid = $1 AND ${column} > now()),
         (SELECT max(extract(epoch FROM until - now())) FROM device_blocks WHERE uid = $1 AND key = ANY($2::bytea[]) AND until > now())
       ) AS wait`,
      [uid, [ipKey, devKey]],
    );
    const wait = rows[0]?.wait;
    if (wait && wait > 0) throw err(429, "rate_limited", "Sign-in requests for this account are paused; try again later", { retryAfter: Math.ceil(wait) });
    return ipKey;
  };

  /** Verifies a Google ID token once: a replay is refused. */
  const verifyGoogle = async (db: Queryable, token: string) => {
    if (!ctx.google) throw disabled();
    let identity;
    try {
      identity = await ctx.google.verify(token);
    } catch (error) {
      if (error instanceof IdTokenError) throw err(401, "invalid_token", `Google sign-in didn't verify: ${error.message}`);
      throw err(503, "unavailable", "Can't check Google sign-in right now; try again");
    }
    const used = await db.query("INSERT INTO used_id_tokens (hash, expires_at) VALUES ($1, to_timestamp($2) + interval '1 hour') ON CONFLICT DO NOTHING", [
      secretHash(token),
      identity.exp,
    ]);
    if (!used.rowCount) throw err(401, "invalid_token", "That Google sign-in was already used; sign in again");
    return identity;
  };

  /**
   * Gives `uid` this address. A verified claim takes it from an account holding it unverified (which
   * keeps finding it for password login, and is told to change it); a verified holder is a conflict,
   * and so is any holder for an unverified claim.
   */
  const claimEmail = async (db: Queryable, uid: string, address: string, verified: boolean) => {
    const index = emailIndex(keys, address);
    const { rows } = await db.query<{ uid: string; email_verified: boolean }>("SELECT uid, email_verified FROM users WHERE email_index = $1 FOR UPDATE", [index]);
    const holder = rows[0];
    if (holder && holder.uid !== uid) {
      if (holder.email_verified || !verified) throw err(409, "conflict", "An account with that email already exists");
      await db.query("UPDATE users SET email_released_index = email_index, email_index = NULL, email_verified = false WHERE uid = $1", [holder.uid]);
    }
    await db.query("UPDATE users SET email_index = $2, email_enc = $3, email_verified = $4, email_released_index = NULL WHERE uid = $1", [
      uid,
      index,
      encryptEmail(keys, address),
      verified || (holder?.uid === uid && holder.email_verified),
    ]);
  };

  const userRow = async (db: Queryable, uid: string) => (await db.query("SELECT * FROM users WHERE uid = $1", [uid])).rows[0] as never;

  const isCurrentRequest = (r: { status: string; expires_at: Date }) => r.status === "pending" && r.expires_at.getTime() > Date.now();

  const requestLookup = async <T extends { secret_hash: Buffer }>(table: "device_requests" | "recovery_requests", id: string, given: string) => {
    const { rows } = await pool.query<T>(`SELECT * FROM ${table} WHERE id = $1`, [id]);
    const row = rows[0];
    if (!row) throw notFound();
    const hash = secretHash(given);
    if (!timingSafeEqual(hash, row.secret_hash)) throw notFound();
    return row;
  };

  // MARK: Sign up

  app.post("/v1/auth/passwordless/signup", async (request, reply) => {
    const body = signupBody.parse(request.body);
    await ctx.throttleAuth(request, body.email ?? `username:${body.username.toLowerCase()}`);
    await ctx.signupInvite(pool, body);
    const result = await tx(pool, async (db) => {
      const address = body.googleIdToken ? (await verifyGoogle(db, body.googleIdToken)).email : body.email!;
      const taken = await db.query("SELECT 1 FROM users WHERE lower(username) = lower($1)", [body.username]);
      if (taken.rowCount) throw err(409, "username_taken", "That username is taken");
      const invite = await ctx.signupInvite(db, body);
      await db.query(
        `INSERT INTO users (uid, username, public_key, wrapped_private_key, personal_space_id) VALUES ($1, $2, $3, $4, $5)`,
        [body.uid, body.username, body.publicKey, body.wrappedPrivateKey, body.personalSpace.id],
      );
      await claimEmail(db, body.uid, address, Boolean(body.googleIdToken));
      await db.query("INSERT INTO spaces (id, kind, owner_uid) VALUES ($1, 'personal', $2)", [body.personalSpace.id, body.uid]);
      await db.query("INSERT INTO space_members (space_id, uid, role, wrapped_key) VALUES ($1, $2, 'owner', $3)", [
        body.personalSpace.id,
        body.uid,
        body.personalSpace.wrappedKey,
      ]);
      if (invite.signupCodeId) {
        const used = await db.query("UPDATE signup_codes SET used_at = now(), used_by = $2 WHERE id = $1 AND used_at IS NULL AND expires_at > now()", [
          invite.signupCodeId,
          body.uid,
        ]);
        if (!used.rowCount) throw err(403, "invite_invalid", "That invite code is unknown, used or expired");
      }
      // The first device is trusted indefinitely.
      const session = await ctx.startSession(db, body.uid, body.device.name, {
        kind: "device",
        platform: body.device.platform ?? null,
        devicePublicKey: body.device.publicKey,
        windowMs: null,
        geo: ctx.geoOf(request),
      });
      return { token: session.token, expiresAt: session.expiresAt, account: ctx.accountJson(await userRow(db, body.uid)) };
    }).catch((error: { code?: string; constraint?: string }) => {
      if (error.code === "23505" && error.constraint === "users_username") throw err(409, "username_taken", "That username is taken");
      if (error.code === "23505") throw err(409, "conflict", "That account already exists");
      throw error;
    });
    return reply.status(201).send(result);
  });

  // MARK: New device requests

  app.post("/v1/auth/device-requests", async (request, reply) => {
    const body = deviceRequestBody.parse(request.body);
    const pub = body.device.publicKey;
    const uid = await resolve(body.identifier);
    await throttleRequest(request, "device", uid ?? `id:${body.identifier.toLowerCase()}`, pub);
    const ipKey = uid ? await refusePausedOrBlocked(uid, request, pub, "requests_paused_until") : await hmac(`ip:${request.ip}`);
    const geo = ctx.geoOf(request);
    let newCountry = false;
    if (uid && geo?.country) {
      const { rows } = await pool.query<{ known: boolean; any: boolean }>(
        `SELECT bool_or(country = $2) AS known, bool_or(country IS NOT NULL) AS any FROM sessions WHERE uid = $1 AND expires_at > now()`,
        [uid, geo.country],
      );
      newCountry = rows[0]?.any === true && rows[0]?.known !== true;
    }
    const id = randomUUID();
    const value = newSecret();
    // An unknown identifier gets a request too (uid NULL): it looks the same and simply never gets approved.
    const { rows } = await pool.query<{ expires_at: Date }>(
      `INSERT INTO device_requests (id, uid, secret_hash, device_public_key, device_name, platform, country, city, new_country, ip_key, window_ms, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, now() + make_interval(mins => $12)) RETURNING expires_at`,
      [
        id,
        uid,
        secretHash(value),
        pub,
        body.device.name ?? null,
        body.device.platform ?? null,
        geo?.country ?? null,
        geo?.city ?? null,
        newCountry,
        ipKey,
        body.windowMs,
        limits.deviceRequestMinutes,
      ],
    );
    return reply.status(201).send({ requestId: id, secret: value, expiresAt: rows[0]!.expires_at.getTime() });
  });

  interface DeviceRequestRow {
    id: string;
    uid: string | null;
    secret_hash: Buffer;
    device_public_key: Buffer;
    device_name: string | null;
    platform: string | null;
    country: string | null;
    city: string | null;
    new_country: boolean;
    window_ms: number | null;
    status: string;
    wrapped_account_key: Buffer | null;
    created_at: Date;
    expires_at: Date;
  }

  app.post<{ Params: { id: string } }>("/v1/auth/device-requests/:id/poll", async (request) => {
    const id = s.uuid.parse(request.params.id);
    const body = secretBody.parse(request.body);
    const wait = polls.take(id);
    if (wait > 0) throw err(429, "rate_limited", "Polling too fast", { retryAfter: wait });
    const row = await requestLookup<DeviceRequestRow>("device_requests", id, body.secret);
    if (row.status === "pending" && row.expires_at.getTime() <= Date.now()) return { status: "expired" };
    if (row.status !== "approved" || !row.uid) return { status: row.status };
    const uid = row.uid;
    return tx(pool, async (db) => {
      const locked = await db.query("UPDATE device_requests SET status = 'completed' WHERE id = $1 AND status = 'approved' RETURNING 1", [id]);
      if (!locked.rowCount) return { status: "completed" };
      const session = await ctx.startSession(db, uid, row.device_name, {
        kind: "device",
        platform: row.platform,
        devicePublicKey: row.device_public_key,
        windowMs: row.window_ms,
        geo: { country: row.country, city: row.city },
      });
      return {
        status: "approved",
        token: session.token,
        expiresAt: session.expiresAt,
        account: ctx.accountJson(await userRow(db, uid)),
        wrappedAccountKey: row.wrapped_account_key!.toString("base64"),
      };
    });
  });

  app.post<{ Params: { id: string } }>("/v1/auth/device-requests/:id/cancel", async (request, reply) => {
    const id = s.uuid.parse(request.params.id);
    const body = secretBody.parse(request.body);
    await requestLookup<DeviceRequestRow>("device_requests", id, body.secret);
    await pool.query("UPDATE device_requests SET status = 'cancelled' WHERE id = $1 AND status = 'pending'", [id]);
    return reply.status(204).send();
  });

  const deviceRequestJson = (r: DeviceRequestRow) => ({
    id: r.id,
    deviceName: r.device_name,
    platform: r.platform,
    country: r.country,
    city: r.city,
    newCountry: r.new_country,
    windowMs: r.window_ms,
    devicePublicKey: r.device_public_key.toString("base64"),
    createdAt: r.created_at.getTime(),
    expiresAt: r.expires_at.getTime(),
  });

  app.get("/v1/device-requests", async (request) => {
    const { rows } = await pool.query<DeviceRequestRow>(
      "SELECT * FROM device_requests WHERE uid = $1 AND status = 'pending' AND expires_at > now() ORDER BY created_at DESC",
      [request.caller.uid],
    );
    return { requests: rows.map(deviceRequestJson) };
  });

  app.post<{ Params: { id: string } }>("/v1/device-requests/:id/approve", async (request) => {
    const id = s.uuid.parse(request.params.id);
    const body = approveBody.parse(request.body);
    const outcome = await tx(pool, async (db) => {
      const { rows } = await db.query<DeviceRequestRow>("SELECT * FROM device_requests WHERE id = $1 AND uid = $2 FOR UPDATE", [id, request.caller.uid]);
      const row = rows[0];
      if (!row) throw notFound();
      if (!isCurrentRequest(row)) throw err(409, "request_closed", "This request was already answered or has expired");
      if (body.number !== matchNumber(id, row.device_public_key)) {
        // Committed before answering: a wrong pick ends the request for good.
        await db.query("UPDATE device_requests SET status = 'mismatch', decided_by = $2 WHERE id = $1", [id, request.caller.sessionId]);
        return "mismatch";
      }
      if (!body.wrappedAccountKey) throw err(400, "invalid", "wrappedAccountKey: required");
      await db.query("UPDATE device_requests SET status = 'approved', wrapped_account_key = $2, decided_by = $3 WHERE id = $1", [
        id,
        body.wrappedAccountKey,
        request.caller.sessionId,
      ]);
      return "approved";
    });
    if (outcome === "mismatch") throw err(409, "number_mismatch", "That isn't the number on the new device, so it wasn't let in");
    return {};
  });

  app.post<{ Params: { id: string } }>("/v1/device-requests/:id/deny", async (request, reply) => {
    const id = s.uuid.parse(request.params.id);
    const body = denyBody.parse(request.body ?? {});
    await tx(pool, async (db) => {
      const { rows } = await db.query<DeviceRequestRow & { ip_key: Buffer }>("SELECT * FROM device_requests WHERE id = $1 AND uid = $2 FOR UPDATE", [
        id,
        request.caller.uid,
      ]);
      const row = rows[0];
      if (!row) throw notFound();
      if (row.status === "pending") await db.query("UPDATE device_requests SET status = 'denied', decided_by = $2 WHERE id = $1", [id, request.caller.sessionId]);
      if (body.block) {
        // "This wasn't me": that IP and that device key stay out, and the account takes a break from requests.
        const devKey = await hmac(pubKeyName(row.device_public_key));
        await db.query(
          `INSERT INTO device_blocks (uid, key, until) SELECT $1, k, now() + make_interval(days => $3) FROM unnest($2::bytea[]) AS k
           ON CONFLICT (uid, key) DO UPDATE SET until = EXCLUDED.until`,
          [request.caller.uid, [row.ip_key, devKey], limits.denyBlockDays],
        );
        await db.query("UPDATE users SET requests_paused_until = now() + make_interval(mins => $2) WHERE uid = $1", [request.caller.uid, limits.denyPauseMinutes]);
        // Anything else still pending from there goes too.
        await db.query("UPDATE device_requests SET status = 'denied' WHERE uid = $1 AND status = 'pending' AND (ip_key = $2 OR device_public_key = $3)", [
          request.caller.uid,
          row.ip_key,
          row.device_public_key,
        ]);
      }
    });
    return reply.status(204).send();
  });

  // MARK: Session windows and switching

  app.patch<{ Params: { id: string } }>("/v1/sessions/:id", async (request) => {
    const id = s.uuid.parse(request.params.id);
    const body = windowBody.parse(request.body);
    return tx(pool, async (db) => {
      const { rows } = await db.query<SessionRow>(`SELECT ${SESSION_COLUMNS} FROM sessions WHERE id = $1 AND uid = $2 AND expires_at > now() FOR UPDATE`, [
        id,
        request.caller.uid,
      ]);
      const target = rows[0];
      if (!target) throw notFound();
      if (target.kind !== "device") throw err(400, "invalid", "Only passwordless devices have a session window");
      const ends = body.windowMs === null ? Date.now() + INDEFINITE_YEARS * 365.25 * 86_400_000 : Date.now() + body.windowMs;
      if (id !== request.caller.sessionId && ends > target.expires_at.getTime()) {
        throw err(403, "forbidden", "Only that device can keep itself signed in longer");
      }
      const { rows: updated } = await db.query<SessionRow>(
        `UPDATE sessions SET window_ms = $2,
           expires_at = CASE WHEN $2::bigint IS NULL THEN now() + make_interval(years => $3) ELSE now() + make_interval(secs => $2::bigint / 1000.0) END
         WHERE id = $1 RETURNING ${SESSION_COLUMNS}`,
        [id, body.windowMs, INDEFINITE_YEARS],
      );
      return sessionJson({ ...updated[0]!, current: id === request.caller.sessionId });
    });
  });

  app.post("/v1/account/passwordless", async (request) => {
    const body = switchBody.parse(request.body);
    const { uid, sessionId } = request.caller;
    await ctx.throttleAuth(request, `uid:${uid}`);
    if (!(await ctx.checkPassword(uid, body.authKey))) throw err(401, "invalid_credentials", "Wrong password");
    return tx(pool, async (db) => {
      await db.query("SELECT 1 FROM users WHERE uid = $1 FOR UPDATE", [uid]);
      if (body.retirePassword) {
        const { rows } = await db.query<{ device_name: string | null }>(
          "SELECT device_name FROM sessions WHERE uid = $1 AND id <> $2 AND kind = 'password' AND expires_at > now()",
          [uid, sessionId],
        );
        if (rows.length) {
          throw err(409, "password_devices", "Other devices still sign in with the password; sign them out first", {
            devices: rows.map((r) => r.device_name ?? "Unnamed device"),
          });
        }
      }
      const { rows: session } = await db.query<SessionRow>(
        `UPDATE sessions SET kind = 'device', device_public_key = $2, platform = COALESCE($3, platform), window_ms = NULL,
           expires_at = now() + make_interval(years => $4)
         WHERE id = $1 RETURNING ${SESSION_COLUMNS}`,
        [sessionId, body.devicePublicKey, body.platform ?? null, INDEFINITE_YEARS],
      );
      if (body.retirePassword) {
        await db.query(
          "UPDATE users SET auth_salt = NULL, auth_hash = NULL, kdf_salt = NULL, kdf_iterations = NULL, wrapped_account_key = NULL WHERE uid = $1",
          [uid],
        );
      }
      return { account: ctx.accountJson(await userRow(db, uid)), session: sessionJson({ ...session[0]!, current: true }) };
    });
  });

  // MARK: Email

  app.put("/v1/account/email", async (request) => {
    const body = emailBody.parse(request.body);
    const { uid } = request.caller;
    return tx(pool, async (db) => {
      await db.query("SELECT 1 FROM users WHERE uid = $1 FOR UPDATE", [uid]);
      if (body.googleIdToken) {
        await claimEmail(db, uid, (await verifyGoogle(db, body.googleIdToken)).email, true);
      } else {
        const { rows } = await db.query<{ email_index: Buffer | null }>("SELECT email_index FROM users WHERE uid = $1", [uid]);
        // The same address again keeps its verification.
        if (!rows[0]?.email_index?.equals(emailIndex(keys, body.email!))) await claimEmail(db, uid, body.email!, false);
      }
      return ctx.accountJson(await userRow(db, uid));
    });
  });

  const emailCodesOn = () => feature.emailCodes && ctx.mailer !== undefined;
  const codeHash = (uid: string, code: string) => createHash("sha256").update(`${uid}:${code}`, "utf8").digest();

  app.post("/v1/account/email/code", async (request, reply) => {
    if (!emailCodesOn()) throw disabled();
    const { uid } = request.caller;
    await bucket([{ name: `emailcode:${uid}`, limit: limits.emailCodesPerHour }], 60);
    const { rows } = await pool.query<{ email_enc: Buffer | null }>("SELECT email_enc FROM users WHERE uid = $1 AND email_index IS NOT NULL", [uid]);
    if (!rows[0]?.email_enc) throw err(400, "invalid", "Set an email address first");
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    await pool.query(
      `INSERT INTO email_codes (uid, code_hash, attempts, expires_at) VALUES ($1, $2, 0, now() + make_interval(mins => $3))
       ON CONFLICT (uid) DO UPDATE SET code_hash = EXCLUDED.code_hash, attempts = 0, expires_at = EXCLUDED.expires_at`,
      [uid, codeHash(uid, code), limits.emailCodeMinutes],
    );
    await ctx.mailer!.send({
      to: decryptEmail(keys, rows[0].email_enc),
      subject: `${code} is your Clipboard2 code`,
      text: `Your Clipboard2 verification code is ${code}. It expires in ${limits.emailCodeMinutes} minutes. If you didn't ask for it, ignore this email.`,
    });
    return reply.status(204).send();
  });

  app.post("/v1/account/email/verify", async (request) => {
    if (!emailCodesOn()) throw disabled();
    const body = codeBody.parse(request.body);
    const { uid } = request.caller;
    const outcome = await tx(pool, async (db) => {
      const { rows } = await db.query<{ code_hash: Buffer; attempts: number; live: boolean }>(
        "SELECT code_hash, attempts, expires_at > now() AS live FROM email_codes WHERE uid = $1 FOR UPDATE",
        [uid],
      );
      const row = rows[0];
      if (!row || !row.live || row.attempts >= 5) throw err(400, "code_invalid", "That code expired; ask for a new one");
      if (!timingSafeEqual(row.code_hash, codeHash(uid, body.code))) {
        // Counted (committed) before answering, so guesses run out.
        await db.query("UPDATE email_codes SET attempts = attempts + 1 WHERE uid = $1", [uid]);
        return null;
      }
      await db.query("DELETE FROM email_codes WHERE uid = $1", [uid]);
      const { rows: me } = await db.query<{ email_enc: Buffer }>("SELECT email_enc FROM users WHERE uid = $1", [uid]);
      await claimEmail(db, uid, decryptEmail(keys, me[0]!.email_enc), true);
      return ctx.accountJson(await userRow(db, uid));
    });
    if (outcome === null) throw err(400, "code_invalid", "That code is wrong");
    return outcome;
  });

  // MARK: Recovery setup

  interface SetupRow {
    id: string;
    uid: string;
    method: string;
    escrow_share: Buffer;
    wrapped_secret: Buffer | null;
    contacts_needed: number;
    broken: boolean;
    created_at: Date;
  }

  const nameSql = "COALESCE(u.username, u.fallback_name, '')";

  const setupJson = async (db: Queryable, setup: SetupRow) => {
    const { rows } = await db.query<{ uid: string; name: string; accepted_at: Date | null }>(
      `SELECT c.contact_uid AS uid, ${nameSql} AS name, c.accepted_at FROM recovery_contacts c JOIN users u ON u.uid = c.contact_uid
       WHERE c.setup_id = $1 ORDER BY c.contact_uid`,
      [setup.id],
    );
    const broken = setup.broken || rows.length < setup.contacts_needed;
    return {
      id: setup.id,
      method: setup.method,
      status: broken ? "broken" : rows.every((r) => r.accepted_at) ? "active" : "pending",
      createdAt: setup.created_at.getTime(),
      contacts: rows.map((r) => ({ uid: r.uid, name: r.name, accepted: r.accepted_at !== null })),
    };
  };

  /** An established contact: a direct space with both of them in it. */
  const isContact = async (db: Queryable, a: string, b: string) => {
    const [low, high] = a < b ? [a, b] : [b, a];
    const { rows } = await db.query<{ ok: boolean }>(
      `SELECT EXISTS (SELECT 1 FROM direct_pairs p WHERE p.uid_low = $1 AND p.uid_high = $2
         AND (SELECT count(*) FROM space_members m WHERE m.space_id = p.space_id) = 2) AS ok`,
      [low, high],
    );
    return rows[0]?.ok === true;
  };

  app.get("/v1/account/recovery", async (request) => {
    const { rows } = await pool.query<SetupRow>("SELECT * FROM recovery_setups WHERE uid = $1", [request.caller.uid]);
    return { setup: rows[0] ? await setupJson(pool, rows[0]) : null };
  });

  app.put("/v1/account/recovery", async (request) => {
    const body = recoveryBody.parse(request.body);
    const { uid } = request.caller;
    if (body.method === "email" && !emailCodesOn()) throw disabled();
    const result = await tx(pool, async (db) => {
      const { rows: me } = await db.query<{ email_enc: Buffer | null; email_verified: boolean }>(
        "SELECT email_enc, email_verified FROM users WHERE uid = $1 FOR UPDATE",
        [uid],
      );
      if (body.method === "contacts") {
        const uids = body.contacts.map((c) => c.uid);
        if (new Set(uids).size !== uids.length || uids.includes(uid)) throw err(400, "invalid", "Pick different people, not yourself");
        for (const contact of uids) {
          if (!(await isContact(db, uid, contact))) throw err(400, "invalid", "Recovery contacts must be your contacts");
        }
      } else if (!me[0]?.email_verified) {
        throw err(400, "invalid", "Verify your email address first");
      }
      // A new setup replaces the old one; deleting the old escrow share is what retires old contact shares.
      await db.query("DELETE FROM recovery_setups WHERE uid = $1", [uid]);
      const { rows } = await db.query<SetupRow>(
        `INSERT INTO recovery_setups (id, uid, method, escrow_share, wrapped_secret, contacts_needed) VALUES ($1, $2, $3, $4, $5, $6) RETURNING *`,
        [
          body.setupId,
          uid,
          body.method,
          sealEscrow(keys, body.escrowShare, body.setupId),
          body.method === "email" ? body.wrappedSecret : null,
          body.method === "contacts" ? body.contacts.length : 0,
        ],
      );
      if (body.method === "contacts") {
        for (const contact of body.contacts) {
          await db.query("INSERT INTO recovery_contacts (setup_id, contact_uid, wrapped_share) VALUES ($1, $2, $3)", [body.setupId, contact.uid, contact.wrappedShare]);
        }
      }
      return { setup: await setupJson(db, rows[0]!), mailTo: me[0]?.email_enc ? decryptEmail(keys, me[0].email_enc) : null };
    }).catch((error: { code?: string }) => {
      if (error.code === "23505") throw err(409, "conflict", "That id is already taken");
      throw error;
    });
    if (body.method === "email" && result.mailTo) {
      // The code passes through here once and isn't kept.
      await ctx.mailer!.send({
        to: result.mailTo,
        subject: "Your Clipboard2 recovery code",
        text: `Your Clipboard2 recovery code is ${body.code}. Keep this email private: with it, someone could recover your account after a 72-hour wait that your devices can cancel. Clipboard2 will never ask you for it.`,
      });
    }
    return { setup: result.setup };
  });

  app.delete("/v1/account/recovery", async (request, reply) => {
    const result = await pool.query("DELETE FROM recovery_setups WHERE uid = $1", [request.caller.uid]);
    if (!result.rowCount) throw notFound();
    return reply.status(204).send();
  });

  app.get("/v1/recovery/invitations", async (request) => {
    const { rows } = await pool.query<{ setup_id: string; uid: string; name: string; accepted_at: Date | null; created_at: Date }>(
      `SELECT c.setup_id, s.uid, ${nameSql} AS name, c.accepted_at, s.created_at
       FROM recovery_contacts c JOIN recovery_setups s ON s.id = c.setup_id JOIN users u ON u.uid = s.uid
       WHERE c.contact_uid = $1 ORDER BY s.created_at DESC`,
      [request.caller.uid],
    );
    return {
      invitations: rows.map((r) => ({ setupId: r.setup_id, uid: r.uid, name: r.name, accepted: r.accepted_at !== null, createdAt: r.created_at.getTime() })),
    };
  });

  app.post<{ Params: { setupId: string } }>("/v1/recovery/invitations/:setupId/accept", async (request, reply) => {
    const setupId = s.uuid.parse(request.params.setupId);
    const result = await pool.query("UPDATE recovery_contacts SET accepted_at = COALESCE(accepted_at, now()) WHERE setup_id = $1 AND contact_uid = $2", [
      setupId,
      request.caller.uid,
    ]);
    if (!result.rowCount) throw notFound();
    return reply.status(204).send();
  });

  /** Declining or stepping down: the setup can't recover any more, and its owner sees it as broken. */
  app.delete<{ Params: { setupId: string } }>("/v1/recovery/invitations/:setupId", async (request, reply) => {
    const setupId = s.uuid.parse(request.params.setupId);
    const removed = await tx(pool, async (db) => {
      const result = await db.query("DELETE FROM recovery_contacts WHERE setup_id = $1 AND contact_uid = $2", [setupId, request.caller.uid]);
      if (result.rowCount) await db.query("UPDATE recovery_setups SET broken = true WHERE id = $1", [setupId]);
      return result.rowCount;
    });
    if (!removed) throw notFound();
    return reply.status(204).send();
  });

  // MARK: Recovering

  interface RecoveryRow {
    id: string;
    uid: string | null;
    setup_id: string | null;
    method: string;
    secret_hash: Buffer;
    device_public_key: Buffer;
    device_name: string | null;
    platform: string | null;
    country: string | null;
    city: string | null;
    window_ms: number | null;
    status: string;
    created_at: Date;
    release_at: Date;
    expires_at: Date;
  }

  /** Approvals so far and the contacts still to approve (none for the email method). */
  const approvalState = async (db: Queryable, row: RecoveryRow) => {
    if (!row.setup_id) return { approved: false, approvals: 0, needed: 1 };
    const { rows } = await db.query<{ needed: number; approvals: number; holders: number }>(
      `SELECT s.contacts_needed AS needed,
         (SELECT count(*)::int FROM recovery_approvals a WHERE a.request_id = $1) AS approvals,
         (SELECT count(*)::int FROM recovery_contacts c WHERE c.setup_id = s.id AND c.accepted_at IS NOT NULL) AS holders
       FROM recovery_setups s WHERE s.id = $2 AND NOT s.broken`,
      [row.id, row.setup_id],
    );
    const state = rows[0];
    if (!state || state.holders < state.needed) return { approved: false, approvals: state?.approvals ?? 0, needed: state?.needed ?? 1 };
    return { approved: state.approvals >= state.needed, approvals: state.approvals, needed: state.needed };
  };

  app.post("/v1/auth/recovery", async (request, reply) => {
    const body = recoveryStartBody.parse(request.body);
    if (body.method === "email" && !emailCodesOn()) throw disabled();
    const pub = body.device.publicKey;
    const uid = await resolve(body.identifier);
    await throttleRequest(request, "recovery", uid ?? `id:${body.identifier.toLowerCase()}`, pub);
    const ipKey = uid ? await refusePausedOrBlocked(uid, request, pub, "recovery_paused_until") : await hmac(`ip:${request.ip}`);
    // Only a working setup of the asked method counts; anything else gets a request that never completes.
    let setupId: string | null = null;
    if (uid) {
      const { rows } = await pool.query<{ id: string }>(
        `SELECT s.id FROM recovery_setups s WHERE s.uid = $1 AND s.method = $2 AND NOT s.broken
           AND (SELECT count(*) FROM recovery_contacts c WHERE c.setup_id = s.id AND c.accepted_at IS NOT NULL) >= s.contacts_needed`,
        [uid, body.method],
      );
      setupId = rows[0]?.id ?? null;
    }
    const geo = ctx.geoOf(request);
    const id = randomUUID();
    const value = newSecret();
    const { rows } = await pool.query<{ release_at: Date; expires_at: Date }>(
      `INSERT INTO recovery_requests (id, uid, setup_id, method, secret_hash, device_public_key, device_name, platform, country, city, ip_key, window_ms,
         release_at, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12,
         now() + make_interval(hours => $13), now() + make_interval(hours => $13) + make_interval(days => $14))
       RETURNING release_at, expires_at`,
      [
        id,
        setupId ? uid : null,
        setupId,
        body.method,
        secretHash(value),
        pub,
        body.device.name ?? null,
        body.device.platform ?? null,
        geo?.country ?? null,
        geo?.city ?? null,
        ipKey,
        body.windowMs,
        limits.recoveryWaitHours,
        limits.recoveryPickupDays,
      ],
    );
    return reply.status(201).send({ recoveryId: id, secret: value, releaseAt: rows[0]!.release_at.getTime(), expiresAt: rows[0]!.expires_at.getTime() });
  });

  app.post<{ Params: { id: string } }>("/v1/auth/recovery/:id/poll", async (request) => {
    const id = s.uuid.parse(request.params.id);
    const body = secretBody.parse(request.body);
    const wait = polls.take(`rec:${id}`);
    if (wait > 0) throw err(429, "rate_limited", "Polling too fast", { retryAfter: wait });
    const row = await requestLookup<RecoveryRow>("recovery_requests", id, body.secret);
    if (row.status === "pending" && row.expires_at.getTime() <= Date.now()) return { status: "expired" };
    if (row.status !== "pending") return { status: row.status };
    const state = await approvalState(pool, row);
    if (!state.approved || row.release_at.getTime() > Date.now() || !row.uid || !row.setup_id) {
      return { status: "waiting", releaseAt: row.release_at.getTime(), approvals: state.approvals, needed: state.needed };
    }
    const uid = row.uid;
    const setupId = row.setup_id;
    return tx(pool, async (db) => {
      const done = await db.query("UPDATE recovery_requests SET status = 'completed' WHERE id = $1 AND status = 'pending' RETURNING 1", [id]);
      if (!done.rowCount) return { status: "completed" };
      const { rows: setups } = await db.query<SetupRow>("SELECT * FROM recovery_setups WHERE id = $1", [setupId]);
      const setup = setups[0]!;
      const { rows: approvals } = await db.query<{ contact_uid: string; wrapped_share: Buffer }>(
        "SELECT contact_uid, wrapped_share FROM recovery_approvals WHERE request_id = $1 ORDER BY contact_uid",
        [id],
      );
      // The server's share goes to the new device's key, like every other share.
      const escrow = wrapTo(row.device_public_key, openEscrow(keys, setup.escrow_share, setupId), `c2/recdev/v1/${id}`, `c2/recdev/v1/${id}/server`);
      const session = await ctx.startSession(db, uid, row.device_name, {
        kind: "device",
        platform: row.platform,
        devicePublicKey: row.device_public_key,
        windowMs: row.window_ms,
        geo: { country: row.country, city: row.city },
      });
      return {
        status: "ready",
        token: session.token,
        expiresAt: session.expiresAt,
        account: ctx.accountJson(await userRow(db, uid)),
        method: setup.method,
        setupId,
        shares: approvals.map((a) => ({ uid: a.contact_uid, wrappedShare: a.wrapped_share.toString("base64") })),
        escrowShare: escrow.toString("base64"),
        wrappedSecret: setup.wrapped_secret ? setup.wrapped_secret.toString("base64") : null,
      };
    });
  });

  app.post<{ Params: { id: string } }>("/v1/auth/recovery/:id/cancel", async (request, reply) => {
    const id = s.uuid.parse(request.params.id);
    const body = secretBody.parse(request.body);
    await requestLookup<RecoveryRow>("recovery_requests", id, body.secret);
    await pool.query("UPDATE recovery_requests SET status = 'cancelled' WHERE id = $1 AND status = 'pending'", [id]);
    return reply.status(204).send();
  });

  // Contacts' side: recoveries they're asked to help with.
  app.get("/v1/recovery/requests", async (request) => {
    const me = request.caller.uid;
    const { rows } = await pool.query<RecoveryRow & { name: string; wrapped_share: Buffer }>(
      `SELECT q.*, ${nameSql} AS name, c.wrapped_share FROM recovery_requests q
       JOIN recovery_contacts c ON c.setup_id = q.setup_id AND c.contact_uid = $1 AND c.accepted_at IS NOT NULL
       JOIN users u ON u.uid = q.uid
       WHERE q.status = 'pending' AND q.expires_at > now()
         AND NOT EXISTS (SELECT 1 FROM recovery_approvals a WHERE a.request_id = q.id AND a.contact_uid = $1)
       ORDER BY q.created_at DESC`,
      [me],
    );
    return {
      requests: rows.map((r) => ({
        id: r.id,
        uid: r.uid,
        name: r.name,
        setupId: r.setup_id,
        deviceName: r.device_name,
        platform: r.platform,
        country: r.country,
        city: r.city,
        devicePublicKey: r.device_public_key.toString("base64"),
        wrappedShare: r.wrapped_share.toString("base64"),
        createdAt: r.created_at.getTime(),
        releaseAt: r.release_at.getTime(),
        expiresAt: r.expires_at.getTime(),
      })),
    };
  });

  const contactRecovery = async (db: Queryable, id: string, me: string) => {
    const { rows } = await db.query<RecoveryRow>(
      `SELECT q.* FROM recovery_requests q JOIN recovery_contacts c ON c.setup_id = q.setup_id AND c.contact_uid = $2 AND c.accepted_at IS NOT NULL
       WHERE q.id = $1 FOR UPDATE OF q`,
      [id, me],
    );
    const row = rows[0];
    if (!row) throw notFound();
    if (!isCurrentRequest(row)) throw err(409, "request_closed", "This recovery was already answered or has expired");
    return row;
  };

  app.post<{ Params: { id: string } }>("/v1/recovery/requests/:id/approve", async (request) => {
    const id = s.uuid.parse(request.params.id);
    const body = recoveryApproveBody.parse(request.body);
    const me = request.caller.uid;
    const outcome = await tx(pool, async (db) => {
      const row = await contactRecovery(db, id, me);
      if (body.number !== matchNumber(id, row.device_public_key)) {
        // Committed before answering: a wrong pick stops this recovery for good.
        await db.query("UPDATE recovery_requests SET status = 'mismatch' WHERE id = $1", [id]);
        return "mismatch";
      }
      if (!body.wrappedShare) throw err(400, "invalid", "wrappedShare: required");
      await db.query("INSERT INTO recovery_approvals (request_id, contact_uid, wrapped_share) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING", [
        id,
        me,
        body.wrappedShare,
      ]);
      return "approved";
    });
    if (outcome === "mismatch") throw err(409, "number_mismatch", "That isn't the number on their new device, so the recovery was stopped");
    return {};
  });

  app.post<{ Params: { id: string } }>("/v1/recovery/requests/:id/deny", async (request, reply) => {
    const id = s.uuid.parse(request.params.id);
    await tx(pool, async (db) => {
      await contactRecovery(db, id, request.caller.uid);
      await db.query("UPDATE recovery_requests SET status = 'denied' WHERE id = $1", [id]);
    });
    return reply.status(204).send();
  });

  // The account's side: recoveries of this account in progress, which any of its devices can stop.
  app.get("/v1/account/recoveries", async (request) => {
    const { rows } = await pool.query<RecoveryRow>(
      "SELECT * FROM recovery_requests WHERE uid = $1 AND status = 'pending' AND expires_at > now() ORDER BY created_at DESC",
      [request.caller.uid],
    );
    const recoveries = [];
    for (const r of rows) {
      const state = await approvalState(pool, r);
      recoveries.push({
        id: r.id,
        method: r.method,
        deviceName: r.device_name,
        platform: r.platform,
        country: r.country,
        city: r.city,
        createdAt: r.created_at.getTime(),
        releaseAt: r.release_at.getTime(),
        approvals: state.approvals,
        needed: state.needed,
      });
    }
    return { recoveries };
  });

  app.post<{ Params: { id: string } }>("/v1/account/recoveries/:id/cancel", async (request, reply) => {
    const id = s.uuid.parse(request.params.id);
    const { uid } = request.caller;
    const result = await tx(pool, async (db) => {
      const updated = await db.query("UPDATE recovery_requests SET status = 'cancelled' WHERE id = $1 AND uid = $2 AND status = 'pending'", [id, uid]);
      if (updated.rowCount) {
        await db.query("UPDATE users SET recovery_paused_until = now() + make_interval(hours => $2) WHERE uid = $1", [uid, limits.recoveryPauseHours]);
      }
      return updated.rowCount;
    });
    if (!result) throw notFound();
    return reply.status(204).send();
  });
}
