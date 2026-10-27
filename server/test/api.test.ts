// Integration tests: real Postgres (embedded), fake token verifier and blob storage.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { randomUUID, randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import EmbeddedPostgres from "embedded-postgres";
import pg from "pg";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { limits as defaultLimits, type Limits } from "../src/config.js";
import { migrate } from "../src/db.js";
import { cpSync, writeFileSync } from "node:fs";
import type { BlobStorage } from "../src/services.js";
import { issueSignupCode } from "../src/auth.js";
import { Semaphore } from "../src/rateLimit.js";
import * as cc from "../src/clientCrypto.js";

let embedded: EmbeddedPostgres;
let dataDir: string;
let pool: pg.Pool;
let app: FastifyInstance;
let currentLimits: Limits;
const deletedPaths: string[] = [];

const storage: BlobStorage = {
  async signedPutUrl(path, size, options = {}) {
    const headers: Record<string, string> = { "x-goog-content-length-range": `0,${size}` };
    if (options.ifGenerationMatch) headers["x-goog-if-generation-match"] = "0";
    return { url: `https://storage.test/${path}?put`, headers, expiresAt: Date.now() + 1000 };
  },
  async signedGetUrl(path) {
    return { url: `https://storage.test/${path}?get`, expiresAt: Date.now() + 1000 };
  },
  async delete(paths) {
    deletedPaths.push(...paths);
  },
};

function rebuild(overrides: Partial<Limits> = {}) {
  currentLimits = { ...defaultLimits(), ...overrides };
  app = buildApp({ pool, storage, limits: currentLimits });
}

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "c2-pg-"));
  const port = 15432 + Math.floor(Math.random() * 1000);
  embedded = new EmbeddedPostgres({ databaseDir: dataDir, user: "postgres", password: "postgres", port, persistent: false, onLog: () => {} });
  await embedded.initialise();
  await embedded.start();
  await embedded.createDatabase("c2test");
  pool = new pg.Pool({ connectionString: `postgres://postgres:postgres@localhost:${port}/c2test`, max: 4 });
  expect(await migrate(pool)).toEqual(["001_init.sql", "002_usernames.sql", "003_hardening.sql"]);
  expect(await migrate(pool)).toEqual([]);
}, 120_000);

afterAll(async () => {
  await app?.close();
  await pool?.end();
  await embedded?.stop();
  rmSync(dataDir, { recursive: true, force: true });
});

beforeEach(async () => {
  await pool.query("TRUNCATE users, sessions, spaces, space_members, items, blobs, invites, signup_codes, auth_attempts CASCADE");
  deletedPaths.length = 0;
  rebuild();
});

// MARK: Helpers

interface TestUser {
  uid: string;
  email: string;
  password: string;
  token: string;
  id: cc.KeyPair;
  ak: Buffer;
  personalSpaceId: string;
  personalKey: Buffer;
}

const b64 = (b: Buffer) => b.toString("base64");
const ITERATIONS = 100_000; // the server's floor; keeps tests fast

async function call(user: TestUser | string | null, method: string, url: string, body?: unknown, ip = "10.0.0.1") {
  const token = typeof user === "string" ? user : user?.token;
  const res = await app.inject({
    method: method as "GET",
    url,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "x-forwarded-for": ip },
    ...(body === undefined ? {} : { payload: body as object }),
  });
  return { status: res.statusCode, body: res.body ? res.json() : undefined, headers: res.headers };
}

/** Signs up exactly as a client would: password-derived keys, client-chosen uid, only authKey sent. */
async function signUp(name: string, password = "pw-" + name, extra: Record<string, unknown> = {}): Promise<TestUser> {
  const { res, user } = await trySignUp(name, password, extra);
  expect(res.status).toBe(201);
  expect(res.body.account.email).toBe(user.email);
  return { ...user, token: res.body.token };
}

async function trySignUp(name: string, password = "pw-" + name, extra: Record<string, unknown> = {}) {
  const uid = randomUUID();
  const email = `${name}-${uid.slice(0, 6)}@example.com`;
  const salt = randomBytes(16);
  const keys = cc.passwordKeys(password, salt, ITERATIONS);
  const ak = randomBytes(32);
  const id = cc.keyPair();
  const personalSpaceId = randomUUID();
  const personalKey = randomBytes(32);
  const res = await call(null, "POST", "/v1/auth/signup", {
    email: `  ${email.toUpperCase()} `,
    authKey: b64(keys.authKey),
    kdf: { salt: b64(salt), iterations: ITERATIONS },
    uid,
    wrappedAccountKey: b64(cc.aeadSeal(keys.wrapKey, ak, cc.aad.accountKey(uid))),
    publicKey: b64(id.pub),
    wrappedPrivateKey: b64(cc.aeadSeal(ak, id.priv, cc.aad.privateKey(uid))),
    personalSpace: { id: personalSpaceId, wrappedKey: b64(cc.wrapSpaceKey(personalKey, personalSpaceId, uid, id.pub)) },
    deviceName: "test",
    // Sign-up is invite-only: unless the test brings its own, use a fresh operator code.
    ...("signupCode" in extra || "groupInviteId" in extra ? {} : { signupCode: (await issueSignupCode(pool, null)).code }),
    ...extra,
  });
  return { res, user: { uid, email, password, id, ak, personalSpaceId, personalKey } };
}

/** A second device: prelogin, derive, login. */
async function logIn(email: string, password: string, ip?: string) {
  const pre = await call(null, "POST", "/v1/auth/prelogin", { email }, ip);
  expect(pre.status).toBe(200);
  const keys = cc.passwordKeys(password, Buffer.from(pre.body.kdf.salt, "base64"), pre.body.kdf.iterations);
  return { ...(await call(null, "POST", "/v1/auth/login", { email, authKey: b64(keys.authKey) }, ip)), keys };
}

function sealItem(sk: Buffer, spaceId: string, itemId: string, category: string, payload: object) {
  return b64(cc.aeadSeal(cc.itemKey(sk), Buffer.from(JSON.stringify(payload)), cc.aad.item(spaceId, itemId, category)));
}

async function putItem(
  user: TestUser,
  spaceId: string,
  sk: Buffer,
  opts: { id?: string; category?: string; sortAt?: number; updatedAt?: number; blobIds?: string[]; payload?: object } = {},
) {
  const id = opts.id ?? randomUUID();
  const category = opts.category ?? "history";
  const res = await call(user, "PUT", `/v1/spaces/${spaceId}/items/${id}`, {
    category,
    sortAt: opts.sortAt ?? Date.now(),
    updatedAt: opts.updatedAt ?? Date.now(),
    ciphertext: sealItem(sk, spaceId, id, category, opts.payload ?? { v: 1, type: "clip", kind: "text", text: "hi" }),
    blobIds: opts.blobIds ?? [],
  });
  return { id, ...res };
}

async function createGroup(owner: TestUser, name = "Team") {
  const id = randomUUID();
  const sk = randomBytes(32);
  const res = await call(owner, "POST", "/v1/groups", {
    id,
    encryptedName: b64(cc.aeadSeal(cc.nameKey(sk), Buffer.from(name), cc.aad.name(id))),
    wrappedKey: b64(cc.wrapSpaceKey(sk, id, owner.uid, owner.id.pub)),
  });
  expect(res.status).toBe(201);
  return { id, sk };
}

async function createInvite(owner: TestUser, group: { id: string; sk: Buffer }) {
  const codeBytes = randomBytes(16);
  const res = await call(owner, "POST", `/v1/groups/${group.id}/invites`, {
    inviteId: cc.inviteId(codeBytes),
    sealedKey: b64(cc.aeadSeal(cc.inviteKey(codeBytes), group.sk, cc.inviteAad(group.id))),
  });
  return { code: cc.formatInviteCode(codeBytes), ...res };
}

/** The invitee side: parse the code, fetch, open the space key, wrap it to yourself, accept. */
async function redeem(member: TestUser, code: string) {
  const codeBytes = cc.parseInviteCode(code);
  if (!codeBytes) throw new Error("bad code");
  const fetched = await call(member, "GET", `/v1/invites/${cc.inviteId(codeBytes)}`);
  if (fetched.status !== 200) return fetched;
  const sk = cc.aeadOpen(cc.inviteKey(codeBytes), Buffer.from(fetched.body.sealedKey, "base64"), cc.inviteAad(fetched.body.spaceId));
  return call(member, "POST", `/v1/invites/${cc.inviteId(codeBytes)}/accept`, {
    wrappedKey: b64(cc.wrapSpaceKey(sk, fetched.body.spaceId, member.uid, member.id.pub)),
  });
}

async function invite(owner: TestUser, group: { id: string; sk: Buffer }, member: TestUser) {
  const created = await createInvite(owner, group);
  expect(created.status).toBe(201);
  return redeem(member, created.code);
}

/** The authKey a client would derive again for a password check (account deletion). */
async function authKeyOf(user: TestUser) {
  const pre = await call(null, "POST", "/v1/auth/prelogin", { email: user.email });
  return b64(cc.passwordKeys(user.password, Buffer.from(pre.body.kdf.salt, "base64"), ITERATIONS).authKey);
}

/** An item of exactly `bytes` ciphertext bytes; the server never looks inside. */
function rawPut(user: TestUser, spaceId: string, bytes: number, opts: { id?: string; category?: string; updatedAt?: number } = {}) {
  const now = Date.now();
  return call(user, "PUT", `/v1/spaces/${spaceId}/items/${opts.id ?? randomUUID()}`, {
    category: opts.category ?? "pinned",
    sortAt: now,
    updatedAt: opts.updatedAt ?? now,
    ciphertext: b64(randomBytes(bytes)),
    blobIds: [],
  });
}

/** Auth limits use fixed one-minute windows in Postgres; don't start a counting test in a window's last 3 s (it takes well under 1 s). */
async function freshAuthWindow() {
  const intoMinute = Date.now() % 60_000;
  if (intoMinute > 57_000) await new Promise((r) => setTimeout(r, 60_000 - intoMinute + 100));
}

/** True once some query in this database waits on a lock, false after ~5 s. */
async function waitForLockWait() {
  for (let i = 0; i < 200; i++) {
    const waiting = await pool.query("SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND datname = current_database()");
    if (waiting.rowCount) return true;
    await new Promise((r) => setTimeout(r, 25));
  }
  return false;
}

// MARK: Tests

describe("migrations", () => {
  const scratchDb = async (name: string) => {
    await pool.query(`DROP DATABASE IF EXISTS ${name}`);
    await pool.query(`CREATE DATABASE ${name}`);
    const url = new URL(pool.options.connectionString!);
    url.pathname = `/${name}`;
    return new pg.Pool({ connectionString: url.toString(), max: 2 });
  };

  it("rolls back a failing migration completely", async () => {
    const db = await scratchDb("c2_migrate_fail");
    const dir = mkdtempSync(join(tmpdir(), "c2-mig-"));
    writeFileSync(join(dir, "001_ok.sql"), "CREATE TABLE a (id int);");
    writeFileSync(join(dir, "002_bad.sql"), "CREATE TABLE b (id int); CREATE SEQUENCE s; CREATE TABLE a (id int);");
    await expect(migrate(db, dir)).rejects.toThrow(/002_bad\.sql failed and was rolled back/);
    const tables = await db.query("SELECT relname FROM pg_class WHERE relname IN ('a', 'b', 's') ORDER BY relname");
    expect(tables.rows.map((r) => r.relname)).toEqual(["a"]);
    expect((await db.query("SELECT name FROM schema_migrations")).rows).toEqual([{ name: "001_ok.sql" }]);
    await db.end();
    rmSync(dir, { recursive: true, force: true });
  });

  it("refuses to start when an applied migration was edited", async () => {
    const db = await scratchDb("c2_migrate_edit");
    const dir = mkdtempSync(join(tmpdir(), "c2-mig-"));
    cpSync(join(import.meta.dirname, "../migrations/001_init.sql"), join(dir, "001_init.sql"));
    expect(await migrate(db, dir)).toEqual(["001_init.sql"]);
    // Rows from before checksums existed adopt the current file rather than failing.
    await db.query("UPDATE schema_migrations SET checksum = NULL");
    expect(await migrate(db, dir)).toEqual([]);
    writeFileSync(join(dir, "001_init.sql"), "-- edited\n", { flag: "a" });
    await expect(migrate(db, dir)).rejects.toThrow(/001_init\.sql was edited after it was applied/);
    await db.end();
    rmSync(dir, { recursive: true, force: true });
  });
});

describe("auth", () => {
  it("rejects missing and unknown session tokens", async () => {
    expect((await call(null, "GET", "/v1/account")).status).toBe(401);
    expect((await call("garbage", "GET", "/v1/account")).body.error).toBe("unauthenticated");
    expect((await call(null, "GET", "/health")).status).toBe(200);
  });

  it("logs in from a second device with only the password and unlocks the keys", async () => {
    const alice = await signUp("alice", "hunter2");
    const res = await logIn(alice.email.toUpperCase(), "hunter2");
    expect(res.status).toBe(200);
    expect(res.body.token).not.toBe(alice.token);
    expect(res.body.expiresAt).toBeGreaterThan(Date.now() + 29 * 86_400_000);
    const account = res.body.account;
    expect(account).toMatchObject({ uid: alice.uid, personalSpaceId: alice.personalSpaceId });

    const ak = cc.aeadOpen(res.keys.wrapKey, Buffer.from(account.wrappedAccountKey, "base64"), cc.aad.accountKey(alice.uid));
    expect(ak.equals(alice.ak)).toBe(true);
    const priv = cc.aeadOpen(ak, Buffer.from(account.wrappedPrivateKey, "base64"), cc.aad.privateKey(alice.uid));
    const personal = (await call(res.body.token, "GET", "/v1/spaces")).body.spaces[0];
    expect(personal).toMatchObject({ kind: "personal", role: "owner", memberCount: 1, encryptedName: null });
    const sk = cc.unwrapSpaceKey(Buffer.from(personal.wrappedKey, "base64"), personal.id, { uid: alice.uid, priv, pub: alice.id.pub });
    expect(sk.equals(alice.personalKey)).toBe(true);

    // The server never stored anything that decrypts the account key.
    const { rows } = await pool.query("SELECT auth_hash, auth_salt FROM users WHERE uid = $1", [alice.uid]);
    expect(rows[0].auth_hash.equals(res.keys.authKey)).toBe(false);
  });

  it("refuses wrong passwords and unknown emails the same way", async () => {
    const alice = await signUp("alice", "right");
    const wrong = await logIn(alice.email, "wrong");
    expect(wrong.status).toBe(401);
    expect(wrong.body.error).toBe("invalid_credentials");
    const unknown = await logIn("nobody@example.com", "whatever");
    expect(unknown.status).toBe(401);
    expect(unknown.body.error).toBe("invalid_credentials");
  });

  it("answers prelogin for unknown emails with a stable fake salt", async () => {
    const alice = await signUp("alice");
    const real = await call(null, "POST", "/v1/auth/prelogin", { email: alice.email });
    expect(real.body.kdf).toMatchObject({ alg: "pbkdf2-sha256", iterations: ITERATIONS });
    const fake1 = await call(null, "POST", "/v1/auth/prelogin", { email: "ghost@example.com" });
    const fake2 = await call(null, "POST", "/v1/auth/prelogin", { email: " GHOST@example.com " });
    const other = await call(null, "POST", "/v1/auth/prelogin", { email: "ghost2@example.com" });
    expect(fake1.body.kdf.iterations).toBe(600_000);
    expect(Buffer.from(fake1.body.kdf.salt, "base64")).toHaveLength(16);
    expect(fake2.body.kdf.salt).toBe(fake1.body.kdf.salt);
    expect(other.body.kdf.salt).not.toBe(fake1.body.kdf.salt);
    // The HMAC key survives a restart.
    rebuild();
    expect((await call(null, "POST", "/v1/auth/prelogin", { email: "ghost@example.com" })).body.kdf.salt).toBe(fake1.body.kdf.salt);
  });

  it("logs out one session only", async () => {
    const alice = await signUp("alice");
    const second = (await logIn(alice.email, alice.password)).body.token;
    expect((await call(alice, "POST", "/v1/auth/logout")).status).toBe(204);
    expect((await call(alice, "GET", "/v1/account")).status).toBe(401);
    expect((await call(second, "GET", "/v1/account")).status).toBe(200);
  });

  it("expires idle sessions and slides active ones", async () => {
    const alice = await signUp("alice");
    await pool.query("UPDATE sessions SET last_used_at = now() - interval '2 hours', expires_at = now() + interval '1 day'");
    expect((await call(alice, "GET", "/v1/account")).status).toBe(200);
    const { rows } = await pool.query<{ days: number }>("SELECT extract(day FROM expires_at - now())::int AS days FROM sessions");
    expect(rows[0]!.days).toBeGreaterThanOrEqual(29);
    await pool.query("UPDATE sessions SET expires_at = now() - interval '1 second'");
    expect((await call(alice, "GET", "/v1/account")).status).toBe(401);
  });

  it("changes the password, re-wraps the account key and revokes other sessions", async () => {
    const alice = await signUp("alice", "old-pass");
    const other = (await logIn(alice.email, "old-pass")).body.token;
    const pre = await call(null, "POST", "/v1/auth/prelogin", { email: alice.email });
    const oldKeys = cc.passwordKeys("old-pass", Buffer.from(pre.body.kdf.salt, "base64"), ITERATIONS);
    const salt = randomBytes(16);
    const newKeys = cc.passwordKeys("new-pass", salt, ITERATIONS);
    const body = {
      authKey: b64(oldKeys.authKey),
      newAuthKey: b64(newKeys.authKey),
      kdf: { salt: b64(salt), iterations: ITERATIONS },
      wrappedAccountKey: b64(cc.aeadSeal(newKeys.wrapKey, alice.ak, cc.aad.accountKey(alice.uid))),
    };
    expect((await call(alice, "PUT", "/v1/account/password", { ...body, authKey: b64(newKeys.authKey) })).status).toBe(401);
    expect((await call(alice, "PUT", "/v1/account/password", body)).status).toBe(204);
    expect((await call(alice, "GET", "/v1/account")).status).toBe(200);
    expect((await call(other, "GET", "/v1/account")).status).toBe(401);
    expect((await logIn(alice.email, "old-pass")).status).toBe(401);
    const fresh = await logIn(alice.email, "new-pass");
    expect(fresh.status).toBe(200);
    const ak = cc.aeadOpen(fresh.keys.wrapKey, Buffer.from(fresh.body.account.wrappedAccountKey, "base64"), cc.aad.accountKey(alice.uid));
    expect(ak.equals(alice.ak)).toBe(true);
  });

  it("refuses a taken email and weak KDF settings", async () => {
    const alice = await signUp("alice");
    const base = {
      authKey: b64(randomBytes(32)),
      kdf: { salt: b64(randomBytes(16)), iterations: ITERATIONS },
      uid: randomUUID(),
      wrappedAccountKey: b64(randomBytes(60)),
      publicKey: b64(cc.keyPair().pub),
      wrappedPrivateKey: b64(randomBytes(61)),
      personalSpace: { id: randomUUID(), wrappedKey: b64(randomBytes(126)) },
      signupCode: (await issueSignupCode(pool, null)).code,
    };
    expect((await call(null, "POST", "/v1/auth/signup", { ...base, email: alice.email.toUpperCase() })).status).toBe(409);
    const weak = await call(null, "POST", "/v1/auth/signup", { ...base, email: "weak@example.com", kdf: { ...base.kdf, iterations: 1000 } });
    expect(weak.status).toBe(400);
    expect((await call(null, "POST", "/v1/auth/signup", { ...base, email: "not-an-email" })).status).toBe(400);
  });

  it("rate limits auth per email and per IP, and requests per user", async () => {
    await freshAuthWindow();
    rebuild({ authPerMinutePerEmail: 3, authPerMinutePerIp: 5 });
    for (let i = 0; i < 3; i++) expect((await call(null, "POST", "/v1/auth/prelogin", { email: "a@example.com" })).status).toBe(200);
    const byEmail = await call(null, "POST", "/v1/auth/prelogin", { email: "a@example.com" }, "10.9.9.9");
    expect(byEmail.status).toBe(429);
    expect(Number(byEmail.headers["retry-after"])).toBeGreaterThan(0);
    for (let i = 0; i < 2; i++) expect((await call(null, "POST", "/v1/auth/prelogin", { email: `b${i}@example.com` })).status).toBe(200);
    expect((await call(null, "POST", "/v1/auth/prelogin", { email: "c@example.com" })).status).toBe(429);
    expect((await call(null, "POST", "/v1/auth/prelogin", { email: "c@example.com" }, "10.0.0.2")).status).toBe(200);

    rebuild({ requestsPerMinute: 3 });
    const alice = await signUp("alice");
    for (let i = 0; i < 3; i++) expect((await call(alice, "GET", "/v1/account")).status).toBe(200);
    expect((await call(alice, "GET", "/v1/account")).status).toBe(429);
  });
});

describe("account", () => {
  it("requires the password to delete the account", async () => {
    const alice = await signUp("alice", "pw");
    expect((await call(alice, "DELETE", "/v1/account", { authKey: b64(randomBytes(32)) })).status).toBe(401);
    expect((await call(alice, "GET", "/v1/account")).status).toBe(200);
  });

  it("deletes everything owned, including blobs of owned groups", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const group = await createGroup(alice);
    expect((await invite(alice, group, bob)).status).toBe(201);
    const blobId = randomUUID();
    expect((await call(alice, "POST", `/v1/spaces/${group.id}/blobs`, { id: blobId, size: 10 })).status).toBe(200);
    expect((await putItem(alice, group.id, group.sk, { blobIds: [blobId] })).status).toBe(200);
    const pre = await call(null, "POST", "/v1/auth/prelogin", { email: alice.email });
    const keys = cc.passwordKeys(alice.password, Buffer.from(pre.body.kdf.salt, "base64"), ITERATIONS);
    expect((await call(alice, "DELETE", "/v1/account", { authKey: b64(keys.authKey) })).status).toBe(204);
    expect(deletedPaths).toEqual([`${group.id}/${blobId}`]);
    expect((await call(alice, "GET", "/v1/account")).status).toBe(401);
    expect((await logIn(alice.email, alice.password)).status).toBe(401);
    expect((await call(bob, "GET", "/v1/spaces")).body.spaces).toHaveLength(1);
  });
});

describe("usernames", () => {
  it("signs up with or without a username and returns it on every account", async () => {
    const plain = await signUp("plain");
    expect((await call(plain, "GET", "/v1/account")).body.username).toBeNull();

    const { res, user } = await trySignUp("named", "pw", { username: "  Jürgen_K.  " });
    expect(res.status).toBe(201);
    expect(res.body.account.username).toBe("Jürgen_K.");
    expect((await call(res.body.token, "GET", "/v1/account")).body.username).toBe("Jürgen_K.");
    expect((await logIn(user.email, "pw")).body.account.username).toBe("Jürgen_K.");
  });

  it("rejects invalid usernames with 400", async () => {
    for (const bad of ["ab", "_alice", ".alice", "-alice", "a".repeat(25), "al ice", "al@ice", "ali😀", "", "   "]) {
      const { res } = await trySignUp("bad", "pw", { username: bad });
      expect(res.status, bad).toBe(400);
      expect(res.body.error).toBe("invalid");
    }
    for (const good of ["abc", "a".repeat(24), "9lives", "名前です", "a-b.c_d"]) {
      expect((await trySignUp("good", "pw", { username: good })).res.status, good).toBe(201);
    }
    const alice = await signUp("alice");
    expect((await call(alice, "PUT", "/v1/account/username", { username: "x" })).status).toBe(400);
    expect((await call(alice, "PUT", "/v1/account/username", {})).status).toBe(400);
  });

  it("refuses a taken username case-insensitively on signup and change", async () => {
    await signUp("alice", "pw", { username: "Alice" });
    const { res } = await trySignUp("alice2", "pw", { username: "aLiCe" });
    expect(res.status).toBe(409);
    expect(res.body).toEqual({ error: "username_taken", message: "That username is taken" });
    expect((await pool.query("SELECT 1 FROM users WHERE email LIKE 'alice2-%'")).rowCount).toBe(0);

    const bob = await signUp("bob");
    const taken = await call(bob, "PUT", "/v1/account/username", { username: "ALICE" });
    expect(taken.status).toBe(409);
    expect(taken.body.error).toBe("username_taken");
    expect((await call(bob, "GET", "/v1/account")).body.username).toBeNull();
  });

  it("maps a racing unique-index hit to username_taken, not the email conflict", async () => {
    // An uncommitted insert of the same name: signup's explicit check can't see it, so its own INSERT
    // waits on the unique index and fails once the other transaction commits.
    const blocker = await pool.connect();
    try {
      await blocker.query("BEGIN");
      await blocker.query(
        `INSERT INTO users (uid, email, username, auth_salt, auth_hash, kdf_salt, kdf_iterations, wrapped_account_key, public_key, wrapped_private_key, personal_space_id)
         VALUES ($1, 'racer@example.com', 'Racer', '\\x00', '\\x00', '\\x00', 1, '\\x00', '\\x00', '\\x00', $2)`,
        [randomUUID(), randomUUID()],
      );
      const pending = trySignUp("carol", "pw", { username: "racer" });
      for (let i = 0; i < 200; i++) {
        const waiting = await pool.query("SELECT 1 FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND query LIKE 'INSERT INTO users%'");
        if (waiting.rowCount) break;
        await new Promise((r) => setTimeout(r, 25));
      }
      await blocker.query("COMMIT");
      const { res } = await pending;
      expect(res.status).toBe(409);
      expect(res.body.error).toBe("username_taken");
    } finally {
      blocker.release();
    }
  });

  it("changes the username and GET /v1/account reflects it", async () => {
    const alice = await signUp("alice", "pw", { username: "alice" });
    const res = await call(alice, "PUT", "/v1/account/username", { username: " Alice.W " });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ username: "Alice.W" });
    expect((await call(alice, "GET", "/v1/account")).body.username).toBe("Alice.W");
    expect((await call(null, "PUT", "/v1/account/username", { username: "nobody" })).status).toBe(401);
    // The old name is free again.
    expect((await trySignUp("other", "pw", { username: "alice" })).res.status).toBe(201);
  });

  it("lists space members by username, falling back to the email's local part", async () => {
    const alice = await signUp("alice", "pw", { username: "Alice" });
    const bob = await signUp("bob");
    const personal = (await call(alice, "GET", "/v1/spaces")).body.spaces;
    expect(personal).toHaveLength(1);
    expect(personal[0].members).toEqual([{ uid: alice.uid, name: "Alice" }]);

    const group = await createGroup(alice);
    const created = await call(alice, "POST", "/v1/groups", { id: randomUUID(), encryptedName: b64(randomBytes(40)), wrappedKey: b64(randomBytes(126)) });
    expect(created.body.members).toEqual([{ uid: alice.uid, name: "Alice" }]);
    const accepted = await invite(alice, group, bob);
    const expected = [
      { uid: alice.uid, name: "Alice" },
      { uid: bob.uid, name: bob.email.split("@")[0] },
    ];
    expect(accepted.body.members).toEqual(expected);
    for (const user of [alice, bob]) {
      const spaces = (await call(user, "GET", "/v1/spaces")).body.spaces;
      expect(spaces.find((s: { id: string }) => s.id === group.id).members).toEqual(expected);
    }
    // Bob's personal space shows only Bob.
    const bobPersonal = (await call(bob, "GET", "/v1/spaces")).body.spaces.find((s: { kind: string }) => s.kind === "personal");
    expect(bobPersonal.members).toEqual([{ uid: bob.uid, name: bob.email.split("@")[0] }]);

    await call(bob, "PUT", "/v1/account/username", { username: "bobby" });
    const after = (await call(alice, "GET", "/v1/spaces")).body.spaces.find((s: { id: string }) => s.id === group.id);
    expect(after.members[1]).toEqual({ uid: bob.uid, name: "bobby" });
  });

  it("lists group members with usernames and names but no emails", async () => {
    const alice = await signUp("alice", "pw", { username: "Alice" });
    const bob = await signUp("bob");
    const group = await createGroup(alice);
    await invite(alice, group, bob);
    const res = await call(bob, "GET", `/v1/groups/${group.id}/members`);
    expect(res.body.members).toEqual([
      { uid: alice.uid, username: "Alice", name: "Alice", role: "owner" },
      { uid: bob.uid, username: null, name: bob.email.split("@")[0], role: "member" },
    ]);
    expect(JSON.stringify(res.body)).not.toContain("@");
  });
});

describe("groups", () => {
  it("shares a space key so another member can read items", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const group = await createGroup(alice, "Wien");
    expect((await invite(alice, group, bob)).status).toBe(201);
    expect((await invite(alice, group, bob)).status).toBe(409);
    const item = await putItem(alice, group.id, group.sk, { payload: { v: 1, type: "clip", kind: "text", text: "shared!" } });
    expect(item.status).toBe(200);

    const bobSpaces = (await call(bob, "GET", "/v1/spaces")).body.spaces;
    const shared = bobSpaces.find((s: { kind: string }) => s.kind === "group");
    expect(shared).toMatchObject({ id: group.id, role: "member", ownerUid: alice.uid, memberCount: 2 });
    const sk = cc.unwrapSpaceKey(Buffer.from(shared.wrappedKey, "base64"), group.id, { uid: bob.uid, ...bob.id });
    expect(cc.aeadOpen(cc.nameKey(sk), Buffer.from(shared.encryptedName, "base64"), cc.aad.name(group.id)).toString()).toBe("Wien");
    const changes = (await call(bob, "GET", `/v1/spaces/${group.id}/changes?since=0`)).body;
    expect(changes.items).toHaveLength(1);
    const plain = cc.aeadOpen(cc.itemKey(sk), Buffer.from(changes.items[0].ciphertext, "base64"), cc.aad.item(group.id, item.id, "history"));
    expect(JSON.parse(plain.toString()).text).toBe("shared!");

    const members = (await call(bob, "GET", `/v1/groups/${group.id}/members`)).body.members;
    expect(members.map((m: { role: string }) => m.role)).toEqual(["owner", "member"]);
  });

  it("enforces owner-only actions, leaving, and access after removal", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const carol = await signUp("carol");
    const group = await createGroup(alice);
    await invite(alice, group, bob);

    expect((await createInvite(bob, group)).status).toBe(403);
    expect((await call(bob, "GET", `/v1/groups/${group.id}/invites`)).status).toBe(403);
    expect((await call(bob, "PATCH", `/v1/groups/${group.id}`, { encryptedName: b64(randomBytes(40)) })).status).toBe(403);
    expect((await call(bob, "DELETE", `/v1/groups/${group.id}`)).status).toBe(403);
    expect((await call(carol, "GET", `/v1/spaces/${group.id}/changes`)).status).toBe(404);
    expect((await call(alice, "DELETE", `/v1/groups/${group.id}/members/${alice.uid}`)).status).toBe(400);

    expect((await call(bob, "DELETE", `/v1/groups/${group.id}/members/${bob.uid}`)).status).toBe(204);
    expect((await call(bob, "GET", `/v1/spaces/${group.id}/changes`)).status).toBe(404);
    expect((await putItem(bob, group.id, group.sk)).status).toBe(404);

    await invite(alice, group, carol);
    expect((await call(alice, "DELETE", `/v1/groups/${group.id}/members/${carol.uid}`)).status).toBe(204);
    expect((await call(carol, "GET", "/v1/spaces")).body.spaces).toHaveLength(1);
  });

  it("can't touch someone else's personal space", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    expect((await call(bob, "GET", `/v1/spaces/${alice.personalSpaceId}/changes`)).status).toBe(404);
    expect((await call(alice, "DELETE", `/v1/groups/${alice.personalSpaceId}`)).status).toBe(404);
    expect((await createInvite(alice, { id: alice.personalSpaceId, sk: alice.personalKey })).status).toBe(404);
    expect((await createInvite(bob, { id: alice.personalSpaceId, sk: alice.personalKey })).status).toBe(404);
  });

  it("limits owned groups and members", async () => {
    rebuild({ groupsOwned: 1, membersPerGroup: 2 });
    const alice = await signUp("alice");
    const group = await createGroup(alice);
    const second = await call(alice, "POST", "/v1/groups", { id: randomUUID(), encryptedName: b64(randomBytes(40)), wrappedKey: b64(randomBytes(126)) });
    expect(second.body.error).toBe("quota_exceeded");
    await invite(alice, group, await signUp("bob"));
    expect((await invite(alice, group, await signUp("carol"))).body.error).toBe("quota_exceeded");
  });

});

describe("invites", () => {
  it("are single use, revocable, listed for the owner and never reveal the code", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const carol = await signUp("carol");
    const group = await createGroup(alice, "Wien");
    const created = await createInvite(alice, group);
    expect(created.status).toBe(201);
    expect(created.code).toMatch(/^[A-Z2-7]{4}(-[A-Z2-7]{4}){5}-[A-Z2-7]{2}$/);
    expect(created.body.expiresAt).toBeGreaterThan(Date.now() + 6.9 * 86_400_000);

    const pending = (await call(alice, "GET", `/v1/groups/${group.id}/invites`)).body.invites;
    expect(pending).toHaveLength(1);
    const { rows } = await pool.query("SELECT id FROM invites");
    expect(JSON.stringify(rows)).not.toContain(created.code.replace(/-/g, ""));

    // Typed sloppily: lowercase, spaces instead of dashes.
    expect((await redeem(bob, created.code.toLowerCase().replace(/-/g, " "))).status).toBe(201);
    expect((await redeem(carol, created.code)).status).toBe(404);
    expect((await call(alice, "GET", `/v1/groups/${group.id}/invites`)).body.invites).toHaveLength(0);

    const revoked = await createInvite(alice, group);
    const revokedId = cc.inviteId(cc.parseInviteCode(revoked.code)!);
    expect((await call(alice, "DELETE", `/v1/groups/${group.id}/invites/${revokedId}`)).status).toBe(204);
    expect((await redeem(carol, revoked.code)).status).toBe(404);
  });

  it("expire after 7 days and unknown codes are 404", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const group = await createGroup(alice);
    const created = await createInvite(alice, group);
    await pool.query("UPDATE invites SET expires_at = now() - interval '1 second'");
    expect((await redeem(bob, created.code)).status).toBe(404);
    expect((await call(bob, "GET", `/v1/invites/${"0".repeat(64)}`)).status).toBe(404);
    expect((await call(bob, "GET", "/v1/invites/not-hex")).status).toBe(400);
  });

  it("limits pending invites and invite attempts", async () => {
    rebuild({ pendingInvitesPerGroup: 2, invitesPerMinute: 3 });
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const group = await createGroup(alice);
    await createInvite(alice, group);
    await createInvite(alice, group);
    expect((await createInvite(alice, group)).body.error).toBe("quota_exceeded");
    for (let i = 0; i < 3; i++) expect((await call(bob, "GET", `/v1/invites/${randomBytes(32).toString("hex")}`)).status).toBe(404);
    expect((await call(bob, "GET", `/v1/invites/${randomBytes(32).toString("hex")}`)).status).toBe(429);
  });
});

describe("items", () => {
  it("pages changes in seq order and resumes from a cursor", async () => {
    const alice = await signUp("alice");
    const ids: string[] = [];
    for (let i = 0; i < 5; i++) ids.push((await putItem(alice, alice.personalSpaceId, alice.personalKey, { sortAt: i })).id);
    const first = (await call(alice, "GET", `/v1/spaces/${alice.personalSpaceId}/changes?since=0&limit=2`)).body;
    expect(first.items.map((i: { id: string }) => i.id)).toEqual(ids.slice(0, 2));
    expect(first.hasMore).toBe(true);
    const rest = (await call(alice, "GET", `/v1/spaces/${alice.personalSpaceId}/changes?since=${first.nextSince}`)).body;
    expect(rest.items.map((i: { id: string }) => i.id)).toEqual(ids.slice(2));
    expect(rest.hasMore).toBe(false);
    const none = (await call(alice, "GET", `/v1/spaces/${alice.personalSpaceId}/changes?since=${rest.nextSince}`)).body;
    expect(none).toMatchObject({ items: [], nextSince: rest.nextSince, hasMore: false, resetRequired: false });
  });

  it("is last-write-wins on updatedAt and re-sequences changes", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const item = await putItem(alice, space, alice.personalKey, { updatedAt: 1000 });
    const older = await putItem(alice, space, alice.personalKey, { id: item.id, updatedAt: 999 });
    expect(older.status).toBe(409);
    expect(older.body.current).toMatchObject({ id: item.id, updatedAt: 1000, deleted: null });
    const same = await putItem(alice, space, alice.personalKey, { id: item.id, updatedAt: 1000, category: "pinned" });
    expect(same.status).toBe(200);
    expect(same.body.seq).toBeGreaterThan(item.body.seq);
    const changes = (await call(alice, "GET", `/v1/spaces/${space}/changes`)).body.items;
    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ category: "pinned", authorUid: alice.uid });
  });

  it("writes tombstones, refuses stale deletes and is idempotent", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const item = await putItem(alice, space, alice.personalKey, { updatedAt: 2000 });
    const stale = await call(alice, "DELETE", `/v1/spaces/${space}/items/${item.id}?updatedAt=1000`);
    expect(stale.status).toBe(409);
    const gone = await call(alice, "DELETE", `/v1/spaces/${space}/items/${item.id}?updatedAt=3000`);
    expect(gone.status).toBe(200);
    expect((await call(alice, "DELETE", `/v1/spaces/${space}/items/${item.id}?updatedAt=3000`)).body.seq).toBe(gone.body.seq);
    expect((await call(alice, "DELETE", `/v1/spaces/${space}/items/${randomUUID()}?updatedAt=1`)).body.seq).toBe(0);
    const [tomb] = (await call(alice, "GET", `/v1/spaces/${space}/changes`)).body.items;
    expect(tomb).toMatchObject({ id: item.id, deleted: "user", ciphertext: null, updatedAt: 3000 });
    // An older write can't resurrect it; a newer one can.
    expect((await putItem(alice, space, alice.personalKey, { id: item.id, updatedAt: 2500 })).status).toBe(409);
    expect((await putItem(alice, space, alice.personalKey, { id: item.id, updatedAt: 3500 })).status).toBe(200);
  });

  it("keeps the newest 200 history items, trims the rest with their blobs, and leaves pinned alone", async () => {
    rebuild({ historyPerSpace: 5 });
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const blobId = randomUUID();
    await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: blobId, size: 100 });
    const oldest = await putItem(alice, space, alice.personalKey, { sortAt: 1, blobIds: [blobId] });
    const pinned = await putItem(alice, space, alice.personalKey, { sortAt: 0, category: "pinned" });
    for (let i = 2; i <= 5; i++) expect((await putItem(alice, space, alice.personalKey, { sortAt: i })).body.trimmed).toEqual([]);
    const sixth = await putItem(alice, space, alice.personalKey, { sortAt: 6 });
    expect(sixth.body.trimmed).toEqual([oldest.id]);
    expect(deletedPaths).toEqual([`${space}/${blobId}`]);
    const items = (await call(alice, "GET", `/v1/spaces/${space}/changes`)).body.items;
    expect(items.find((i: { id: string }) => i.id === oldest.id)).toMatchObject({ deleted: "trimmed", blobIds: [] });
    expect(items.find((i: { id: string }) => i.id === pinned.id).deleted).toBeNull();
    // Something older than everything kept is trimmed straight away.
    expect((await putItem(alice, space, alice.personalKey, { sortAt: 0 })).body.trimmed).toHaveLength(1);
    const blobs = await pool.query("SELECT 1 FROM blobs");
    expect(blobs.rowCount).toBe(0);
  });

  it("enforces item size, storage and non-history quotas", async () => {
    rebuild({ itemBytes: 1000, userBytes: 2000, nonHistoryPerSpace: 2 });
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const big = await call(alice, "PUT", `/v1/spaces/${space}/items/${randomUUID()}`, {
      category: "history",
      sortAt: 1,
      updatedAt: 1,
      ciphertext: b64(randomBytes(1500)),
      blobIds: [],
    });
    expect(big.status).toBe(400);

    await putItem(alice, space, alice.personalKey, { category: "snippet" });
    const secret = await putItem(alice, space, alice.personalKey, { category: "secret" });
    expect((await putItem(alice, space, alice.personalKey, { category: "pinned" })).body.error).toBe("quota_exceeded");
    // Updating an existing non-history item doesn't count twice.
    expect((await putItem(alice, space, alice.personalKey, { id: secret.id, category: "secret" })).status).toBe(200);

    const blob = await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: randomUUID(), size: 1900 });
    expect(blob.body.error).toBe("quota_exceeded");
    expect((await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: randomUUID(), size: 10 ** 9 })).status).toBe(413);
  });

  it("requires blobs to be registered in the same space", async () => {
    const alice = await signUp("alice");
    const group = await createGroup(alice);
    const blobId = randomUUID();
    const reg = await call(alice, "POST", `/v1/spaces/${group.id}/blobs`, { id: blobId, size: 50 });
    expect(reg.body).toMatchObject({ method: "PUT", headers: { "x-goog-content-length-range": "0,50" } });
    expect((await call(alice, "POST", `/v1/spaces/${group.id}/blobs`, { id: blobId, size: 50 })).status).toBe(200);
    expect((await call(alice, "POST", `/v1/spaces/${group.id}/blobs`, { id: blobId, size: 51 })).status).toBe(409);
    expect((await putItem(alice, alice.personalSpaceId, alice.personalKey, { blobIds: [blobId] })).status).toBe(400);
    expect((await putItem(alice, group.id, group.sk, { blobIds: [blobId] })).status).toBe(200);
    expect((await call(alice, "GET", `/v1/spaces/${group.id}/blobs/${blobId}`)).body.url).toContain(`${group.id}/${blobId}`);
    expect((await call(alice, "GET", `/v1/spaces/${group.id}/blobs/${randomUUID()}`)).status).toBe(404);
  });

  it("asks clients behind the purge horizon to reset", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const item = await putItem(alice, space, alice.personalKey);
    await call(alice, "DELETE", `/v1/spaces/${space}/items/${item.id}?updatedAt=${Date.now() + 1}`);
    await pool.query("UPDATE items SET deleted_at = now() - interval '100 days'");
    const cursor = item.body.seq;
    rebuild(); // fresh purge throttle
    const res = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=${cursor}`)).body;
    expect(res.resetRequired).toBe(true);
    const full = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=0`)).body;
    expect(full).toMatchObject({ items: [], resetRequired: false });
  });

  it("lets a full re-walk page past the purge horizon", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const first = await putItem(alice, space, alice.personalKey);
    await putItem(alice, space, alice.personalKey);
    const gone = await putItem(alice, space, alice.personalKey);
    await call(alice, "DELETE", `/v1/spaces/${space}/items/${gone.id}?updatedAt=${Date.now() + 1}`);
    await pool.query("UPDATE items SET deleted_at = now() - interval '100 days' WHERE deleted IS NOT NULL");
    rebuild(); // fresh purge throttle
    // A client paging from 0 sits below the horizon after its first page: without `full` it would be sent back to 0.
    const behind = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=${first.body.seq}`)).body;
    expect(behind.resetRequired).toBe(true);
    const page = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=${first.body.seq}&full=1`)).body;
    expect(page.resetRequired).toBe(false);
    expect(page.items).toHaveLength(1);
  });

  it("rejects uppercase ids and unknown categories", async () => {
    const alice = await signUp("alice");
    const upper = randomUUID().toUpperCase();
    expect((await call(alice, "PUT", `/v1/spaces/${alice.personalSpaceId}/items/${upper}`, { category: "history", sortAt: 1, updatedAt: 1, ciphertext: "AAAA" })).status).toBe(400);
    expect((await call(alice, "PUT", `/v1/spaces/${alice.personalSpaceId}/items/${randomUUID()}`, { category: "misc", sortAt: 1, updatedAt: 1, ciphertext: "AAAA" })).status).toBe(400);
  });

  it("accepts up to 12 blob ids", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const blobIds: string[] = [];
    for (let i = 0; i < 13; i++) {
      const id = randomUUID();
      expect((await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id, size: 10 })).status).toBe(200);
      blobIds.push(id);
    }
    expect((await putItem(alice, space, alice.personalKey, { blobIds })).status).toBe(400);
    const twelve = await putItem(alice, space, alice.personalKey, { blobIds: blobIds.slice(0, 12) });
    expect(twelve.status).toBe(200);
    expect((await call(alice, "GET", `/v1/spaces/${space}/changes`)).body.items[0].blobIds).toHaveLength(12);
  });

  it("refuses times more than 10 minutes ahead with clock_skew", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const ahead = Date.now() + 11 * 60_000;
    for (const times of [{ updatedAt: ahead }, { sortAt: ahead }, { updatedAt: 9999 * 365 * 86_400_000 }]) {
      const res = await putItem(alice, space, alice.personalKey, times);
      expect(res.status).toBe(400);
      expect(res.body.error).toBe("clock_skew");
    }
    const slightlyAhead = await putItem(alice, space, alice.personalKey, { updatedAt: Date.now() + 5 * 60_000, sortAt: Date.now() + 5 * 60_000 });
    expect(slightlyAhead.status).toBe(200);
    const del = await call(alice, "DELETE", `/v1/spaces/${space}/items/${slightlyAhead.id}?updatedAt=${ahead}`);
    expect(del.status).toBe(400);
    expect(del.body.error).toBe("clock_skew");
    expect((await call(alice, "DELETE", `/v1/spaces/${space}/items/${slightlyAhead.id}?updatedAt=${Date.now() + 6 * 60_000}`)).status).toBe(200);
  });

  it("lets only the author or the group owner overwrite or delete a group item", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const carol = await signUp("carol");
    const group = await createGroup(alice);
    await invite(alice, group, bob);
    await invite(alice, group, carol);
    const item = await putItem(bob, group.id, group.sk, { updatedAt: 1000 });
    expect(item.status).toBe(200);

    const overwrite = await putItem(carol, group.id, group.sk, { id: item.id, updatedAt: 2000 });
    expect(overwrite.status).toBe(403);
    expect(overwrite.body.error).toBe("forbidden");
    const remove = await call(carol, "DELETE", `/v1/spaces/${group.id}/items/${item.id}?updatedAt=2000`);
    expect(remove.status).toBe(403);
    expect(remove.body.error).toBe("forbidden");
    // New items are anyone's to create.
    expect((await putItem(carol, group.id, group.sk)).status).toBe(200);

    // The author and the owner can.
    expect((await putItem(bob, group.id, group.sk, { id: item.id, updatedAt: 1500 })).status).toBe(200);
    expect((await putItem(alice, group.id, group.sk, { id: item.id, updatedAt: 1600 })).status).toBe(200);
    expect((await call(alice, "DELETE", `/v1/spaces/${group.id}/items/${item.id}?updatedAt=1800`)).status).toBe(200);
    // A tombstone isn't up for grabs either, though deleting it again is a harmless no-op.
    expect((await putItem(carol, group.id, group.sk, { id: item.id, updatedAt: 3000 })).status).toBe(403);
    expect((await call(carol, "DELETE", `/v1/spaces/${group.id}/items/${item.id}?updatedAt=3000`)).status).toBe(200);

    const own = await putItem(bob, group.id, group.sk);
    expect((await call(bob, "DELETE", `/v1/spaces/${group.id}/items/${own.id}?updatedAt=${Date.now()}`)).status).toBe(200);
  });

  it("never lets a cursor pass a write that commits later", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    await putItem(alice, space, alice.personalKey);
    const cursor = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=0`)).body.nextSince;

    // A second instance whose item INSERT stops right after its nextval, transaction still open.
    const slowPool = new pg.Pool({ connectionString: pool.options.connectionString, max: 2 });
    let release!: () => void;
    const gate = new Promise<void>((resolve) => (release = resolve));
    let reached!: () => void;
    const paused = new Promise<void>((resolve) => (reached = resolve));
    let armed = true;
    slowPool.on("connect", (client) => {
      const query = client.query.bind(client) as (...args: unknown[]) => unknown;
      (client as unknown as { query: (...args: unknown[]) => unknown }).query = (...args: unknown[]) => {
        const result = query(...args);
        if (!armed || typeof args[0] !== "string" || !args[0].startsWith("INSERT INTO items")) return result;
        armed = false;
        return (result as Promise<unknown>).then(async (res) => {
          reached();
          await gate;
          return res;
        });
      };
    });
    const slowApp = buildApp({ pool: slowPool, storage, limits: currentLimits });
    try {
      const firstId = randomUUID();
      const first = slowApp.inject({
        method: "PUT",
        url: `/v1/spaces/${space}/items/${firstId}`,
        headers: { authorization: `Bearer ${alice.token}` },
        payload: { category: "history", sortAt: Date.now(), updatedAt: Date.now(), ciphertext: b64(randomBytes(40)), blobIds: [] },
      });
      await paused;
      // T2 starts after T1 took its seq. Without the space lock it would commit first with a higher seq.
      const second = putItem(alice, space, alice.personalKey);
      await Promise.race([second, waitForLockWait()]);
      const mid = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=${cursor}`)).body;
      release();
      const [t1, t2] = await Promise.all([first, second]);
      expect(t1.statusCode).toBe(200);
      expect(t2.status).toBe(200);
      const rest = (await call(alice, "GET", `/v1/spaces/${space}/changes?since=${mid.nextSince}`)).body;
      const seen = [...mid.items, ...rest.items].map((i: { id: string }) => i.id);
      expect(seen).toContain(firstId);
      expect(seen).toContain(t2.id);
    } finally {
      release();
      await slowApp.close();
      await slowPool.end();
    }
  });
});

describe("sign-up invites", () => {
  it("needs a sign-up code or an open group invite", async () => {
    const none = await trySignUp("nobody", "pw", { signupCode: undefined });
    expect(none.res.status).toBe(403);
    expect(none.res.body.error).toBe("invite_required");
    for (const bad of ["AAAA-AAAA-AAAA-AAAA", "not a code", ""]) {
      const res = (await trySignUp("guess", "pw", { signupCode: bad })).res;
      expect(res.status, bad).toBe(403);
      expect(res.body.error).toBe("invite_invalid");
    }
    expect((await trySignUp("guess", "pw", { groupInviteId: "0".repeat(64) })).res.body.error).toBe("invite_invalid");
    expect((await pool.query("SELECT 1 FROM users")).rowCount).toBe(0);
  });

  it("consumes a sign-up code, typed sloppily, exactly once", async () => {
    const alice = await signUp("alice");
    const created = await call(alice, "POST", "/v1/signup-codes");
    const sloppy = created.body.code.toLowerCase().replace(/-/g, " ").replace(/O/gi, "0");
    const { res, user } = await trySignUp("bob", "pw", { signupCode: sloppy });
    expect(res.status).toBe(201);
    const used = await trySignUp("carol", "pw", { signupCode: created.body.code });
    expect(used.res.status).toBe(403);
    expect(used.res.body.error).toBe("invite_invalid");
    const { rows } = await pool.query("SELECT used_by FROM signup_codes WHERE id = $1", [created.body.id]);
    expect(rows[0].used_by).toBe(user.uid);
  });

  it("refuses expired codes, and a failed sign-up doesn't use the code up", async () => {
    const alice = await signUp("alice");
    const code = (await call(alice, "POST", "/v1/signup-codes")).body.code;
    expect((await trySignUp("taken", "pw", { signupCode: code, email: alice.email })).res.status).toBe(409);
    expect((await call(alice, "GET", "/v1/signup-codes")).body.codes).toHaveLength(1);
    await pool.query("UPDATE signup_codes SET expires_at = now() - interval '1 second'");
    expect((await trySignUp("late", "pw", { signupCode: code })).res.body.error).toBe("invite_invalid");
  });

  it("accepts an open group invite without consuming it, so the new account can join", async () => {
    const alice = await signUp("alice");
    const group = await createGroup(alice);
    const created = await createInvite(alice, group);
    const id = cc.inviteId(cc.parseInviteCode(created.code)!);
    const { res, user } = await trySignUp("bob", "pw", { groupInviteId: id });
    expect(res.status).toBe(201);
    const bob = { ...user, token: res.body.token };
    expect((await redeem(bob, created.code)).status).toBe(201);
    // Joined, so the invite is gone and can't let anyone else in.
    expect((await trySignUp("carol", "pw", { groupInviteId: id })).res.body.error).toBe("invite_invalid");
    await createInvite(alice, group);
    await pool.query("UPDATE invites SET expires_at = now() - interval '1 second'");
    const expired = (await pool.query<{ id: string }>("SELECT id FROM invites")).rows[0]!.id;
    expect((await trySignUp("dave", "pw", { groupInviteId: expired })).res.body.error).toBe("invite_invalid");
  });
});

describe("sign-up codes", () => {
  it("creates, lists and revokes codes, storing only a hash", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const created = await call(alice, "POST", "/v1/signup-codes");
    expect(created.status).toBe(201);
    expect(created.body.code).toMatch(/^[A-Z2-7]{4}(-[A-Z2-7]{4}){3}$/);
    expect(created.body.expiresAt).toBeGreaterThan(Date.now() + 13.9 * 86_400_000);
    expect(created.body.expiresAt).toBeLessThan(Date.now() + 14.1 * 86_400_000);
    const stored = await pool.query("SELECT * FROM signup_codes WHERE id = $1", [created.body.id]);
    expect(JSON.stringify(stored.rows)).not.toContain(created.body.code.replace(/-/g, ""));

    const listed = (await call(alice, "GET", "/v1/signup-codes")).body.codes;
    expect(listed).toEqual([{ id: created.body.id, createdAt: expect.any(Number), expiresAt: created.body.expiresAt }]);
    expect((await call(bob, "GET", "/v1/signup-codes")).body.codes).toEqual([]);

    expect((await call(bob, "DELETE", `/v1/signup-codes/${created.body.id}`)).status).toBe(404);
    expect((await call(alice, "DELETE", `/v1/signup-codes/${created.body.id}`)).status).toBe(204);
    expect((await call(alice, "DELETE", `/v1/signup-codes/${created.body.id}`)).status).toBe(404);
    expect((await call(alice, "GET", "/v1/signup-codes")).body.codes).toEqual([]);
    expect((await trySignUp("late", "pw", { signupCode: created.body.code })).res.body.error).toBe("invite_invalid");
  });

  it("allows at most 10 open codes per user", async () => {
    const alice = await signUp("alice");
    const codes: string[] = [];
    for (let i = 0; i < 10; i++) {
      const res = await call(alice, "POST", "/v1/signup-codes");
      expect(res.status).toBe(201);
      codes.push(res.body.code);
    }
    const eleventh = await call(alice, "POST", "/v1/signup-codes");
    expect(eleventh.status).toBe(429);
    expect(eleventh.body.error).toBe("too_many_codes");
    // A used code no longer counts, and neither does an expired one.
    expect((await trySignUp("bob", "pw", { signupCode: codes[0] })).res.status).toBe(201);
    expect((await call(alice, "GET", "/v1/signup-codes")).body.codes).toHaveLength(9);
    expect((await call(alice, "POST", "/v1/signup-codes")).status).toBe(201);
    await pool.query(
      "UPDATE signup_codes SET expires_at = now() - interval '1 second' WHERE id = (SELECT id FROM signup_codes WHERE created_by = $1 AND used_at IS NULL LIMIT 1)",
      [alice.uid],
    );
    expect((await call(alice, "POST", "/v1/signup-codes")).status).toBe(201);
    expect((await call(alice, "POST", "/v1/signup-codes")).status).toBe(429);
  });
});

describe("sessions", () => {
  it("lists devices and revokes others or the current one", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const second = await logIn(alice.email, alice.password);
    await call(second.body.token, "GET", "/v1/account");
    const listed = (await call(alice, "GET", "/v1/sessions")).body.sessions;
    expect(listed).toHaveLength(2);
    for (const s of listed) {
      expect(Object.keys(s).sort()).toEqual(["createdAt", "current", "deviceName", "id", "lastUsedAt"]);
      expect(s.id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
    }
    const mine = listed.find((s: { current: boolean }) => s.current);
    const other = listed.find((s: { current: boolean }) => !s.current);
    expect(mine.deviceName).toBe("test");
    expect(other.deviceName).toBeNull();

    // Someone else's session id is unknown to you.
    expect((await call(bob, "DELETE", `/v1/sessions/${other.id}`)).status).toBe(404);
    expect((await call(alice, "DELETE", `/v1/sessions/${randomUUID()}`)).status).toBe(404);
    expect((await call(alice, "DELETE", `/v1/sessions/${other.id}`)).status).toBe(204);
    expect((await call(second.body.token, "GET", "/v1/account")).status).toBe(401);
    expect((await call(alice, "GET", "/v1/sessions")).body.sessions).toHaveLength(1);
    expect((await call(alice, "DELETE", `/v1/sessions/${mine.id}`)).status).toBe(204);
    expect((await call(alice, "GET", "/v1/account")).status).toBe(401);
    expect((await call(bob, "GET", "/v1/sessions")).body.sessions).toHaveLength(1);
  });
});

describe("quotas", () => {
  it("caps a group's bytes, with scope group", async () => {
    rebuild({ groupBytes: 1000 });
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const group = await createGroup(alice);
    await invite(alice, group, bob);
    const first = randomUUID();
    expect((await rawPut(bob, group.id, 600, { id: first })).status).toBe(200);
    const over = await rawPut(alice, group.id, 500);
    expect(over.status).toBe(413);
    expect(over.body).toMatchObject({ error: "quota_exceeded", scope: "group" });
    const blob = await call(alice, "POST", `/v1/spaces/${group.id}/blobs`, { id: randomUUID(), size: 500 });
    expect(blob.status).toBe(413);
    expect(blob.body.scope).toBe("group");
    // Replacing an item only counts the difference; personal spaces aren't group-limited.
    expect((await rawPut(bob, group.id, 900, { id: first })).status).toBe(200);
    expect((await rawPut(alice, alice.personalSpaceId, 1500)).status).toBe(200);
  });

  it("caps a group's live items, counting history after the trim", async () => {
    rebuild({ groupItems: 3, historyPerSpace: 2 });
    const alice = await signUp("alice");
    const group = await createGroup(alice);
    for (let i = 0; i < 2; i++) expect((await putItem(alice, group.id, group.sk, { sortAt: i + 1 })).status).toBe(200);
    const pinned = await putItem(alice, group.id, group.sk, { category: "pinned" });
    expect(pinned.status).toBe(200);
    const over = await putItem(alice, group.id, group.sk, { category: "snippet" });
    expect(over.status).toBe(413);
    expect(over.body).toMatchObject({ error: "quota_exceeded", scope: "group" });
    // History still flows: the oldest is trimmed, so the count stays at 3.
    expect((await putItem(alice, group.id, group.sk, { sortAt: 10 })).body.trimmed).toHaveLength(1);
    // Updating a live item is fine; after a deletion there's room again.
    expect((await putItem(alice, group.id, group.sk, { id: pinned.id, category: "pinned" })).status).toBe(200);
    await call(alice, "DELETE", `/v1/spaces/${group.id}/items/${pinned.id}?updatedAt=${Date.now() + 1000}`);
    expect((await putItem(alice, group.id, group.sk, { category: "snippet" })).status).toBe(200);
    for (let i = 0; i < 4; i++) expect((await putItem(alice, alice.personalSpaceId, alice.personalKey, { category: "pinned" })).status).toBe(200);
  });

  it("caps the whole server, with scope server", async () => {
    rebuild({ totalBytes: 1000 });
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    expect((await rawPut(alice, alice.personalSpaceId, 600)).status).toBe(200);
    const over = await rawPut(bob, bob.personalSpaceId, 500);
    expect(over.status).toBe(413);
    expect(over.body).toMatchObject({ error: "quota_exceeded", scope: "server" });
    const blob = await call(bob, "POST", `/v1/spaces/${bob.personalSpaceId}/blobs`, { id: randomUUID(), size: 500 });
    expect(blob.status).toBe(413);
    expect(blob.body.scope).toBe("server");
    expect((await rawPut(bob, bob.personalSpaceId, 300)).status).toBe(200);
  });
});

describe("account deletion in groups", () => {
  it("tombstones items the user wrote in other people's groups and drops their blobs", async () => {
    const alice = await signUp("alice");
    const bob = await signUp("bob");
    const group = await createGroup(alice);
    await invite(alice, group, bob);
    const used = randomUUID();
    const pending = randomUUID();
    await call(bob, "POST", `/v1/spaces/${group.id}/blobs`, { id: used, size: 10 });
    await call(bob, "POST", `/v1/spaces/${group.id}/blobs`, { id: pending, size: 10 });
    const bobs = await putItem(bob, group.id, group.sk, { blobIds: [used], updatedAt: 1000 });
    const alices = await putItem(alice, group.id, group.sk);
    const before = (await call(alice, "GET", `/v1/spaces/${group.id}/changes`)).body.nextSince;

    expect((await call(bob, "DELETE", "/v1/account", { authKey: await authKeyOf(bob) })).status).toBe(204);
    expect(deletedPaths.sort()).toEqual([`${group.id}/${used}`, `${group.id}/${pending}`].sort());
    const changes = (await call(alice, "GET", `/v1/spaces/${group.id}/changes?since=${before}`)).body.items;
    expect(changes).toHaveLength(1);
    expect(changes[0]).toMatchObject({ id: bobs.id, deleted: "user", ciphertext: null, blobIds: [], authorUid: null });
    expect(changes[0].updatedAt).toBeGreaterThan(1000);
    const live = await pool.query("SELECT id FROM items WHERE space_id = $1 AND deleted IS NULL", [group.id]);
    expect(live.rows.map((r) => r.id)).toEqual([alices.id]);
    expect((await pool.query("SELECT 1 FROM blobs")).rowCount).toBe(0);
    // A stale client can't bring it back with its old version.
    expect((await putItem(alice, group.id, group.sk, { id: bobs.id, updatedAt: 1000 })).status).toBe(409);
  });
});

describe("blob upload URLs", () => {
  it("adds the create-only header on request and won't re-issue a URL for a blob in use", async () => {
    const alice = await signUp("alice");
    const space = alice.personalSpaceId;
    const plain = await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: randomUUID(), size: 10 });
    expect(plain.body.headers).not.toHaveProperty("x-goog-if-generation-match");
    const blobId = randomUUID();
    const guarded = await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: blobId, size: 10, ifGenerationMatch: true });
    expect(guarded.body.headers).toMatchObject({ "x-goog-if-generation-match": "0", "x-goog-content-length-range": "0,10" });
    // Still pending: asking again is fine.
    expect((await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: blobId, size: 10, ifGenerationMatch: true })).status).toBe(200);
    expect((await putItem(alice, space, alice.personalKey, { blobIds: [blobId] })).status).toBe(200);
    const again = await call(alice, "POST", `/v1/spaces/${space}/blobs`, { id: blobId, size: 10, ifGenerationMatch: true });
    expect(again.status).toBe(409);
    expect(again.body.error).toBe("conflict");
  });
});

describe("client IPs, auth limits and logs", () => {
  it("uses the last X-Forwarded-For hop, so a client can't spoof its IP", async () => {
    await freshAuthWindow();
    rebuild({ authPerMinutePerIp: 2 });
    for (const [i, spoof] of ["1.1.1.1", "2.2.2.2"].entries()) {
      expect((await call(null, "POST", "/v1/auth/prelogin", { email: `s${i}@example.com` }, `${spoof}, 10.0.0.7`)).status).toBe(200);
    }
    expect((await call(null, "POST", "/v1/auth/prelogin", { email: "s3@example.com" }, "3.3.3.3, 10.0.0.7")).status).toBe(429);
    expect((await call(null, "POST", "/v1/auth/prelogin", { email: "s4@example.com" }, "10.0.0.7, 10.0.0.8")).status).toBe(200);
  });

  it("counts auth attempts across instances, keyed by HMAC", async () => {
    await freshAuthWindow();
    rebuild({ authPerMinutePerEmail: 2 });
    const other = buildApp({ pool, storage, limits: currentLimits });
    try {
      expect((await call(null, "POST", "/v1/auth/prelogin", { email: "x@example.com" })).status).toBe(200);
      const res = await other.inject({ method: "POST", url: "/v1/auth/prelogin", payload: { email: "x@example.com" }, headers: { "x-forwarded-for": "10.1.1.1" } });
      expect(res.statusCode).toBe(200);
      const third = await call(null, "POST", "/v1/auth/prelogin", { email: "x@example.com" }, "10.2.2.2");
      expect(third.status).toBe(429);
      expect(third.body.retryAfter).toBeGreaterThan(0);
      expect(third.body.retryAfter).toBeLessThanOrEqual(60);
    } finally {
      await other.close();
    }
    const stored = await pool.query<{ key: Buffer }>("SELECT key FROM auth_attempts");
    expect(stored.rows.length).toBeGreaterThan(0);
    expect(stored.rows.map((r) => r.key.toString("latin1")).join()).not.toMatch(/example\.com|10\.0\.0\.1/);
  });

  it("runs scrypt a few at a time and turns away the overflow", async () => {
    const alice = await signUp("alice");
    rebuild({ scryptConcurrency: 1, scryptQueue: 1 });
    const pre = await call(null, "POST", "/v1/auth/prelogin", { email: alice.email });
    const authKey = b64(cc.passwordKeys(alice.password, Buffer.from(pre.body.kdf.salt, "base64"), ITERATIONS).authKey);
    const results = await Promise.all(
      Array.from({ length: 6 }, (_, i) => call(null, "POST", "/v1/auth/login", { email: alice.email, authKey }, `10.3.0.${i}`)),
    );
    const statuses = results.map((r) => r.status);
    expect(statuses.filter((s) => s === 200).length).toBeGreaterThanOrEqual(2);
    const busy = results.filter((r) => r.status === 429);
    expect(busy.length).toBeGreaterThan(0);
    expect(busy[0]!.body.error).toBe("rate_limited");
    expect(Number(busy[0]!.headers["retry-after"])).toBeGreaterThan(0);
  });

  it("queues semaphore work in order and refuses beyond the queue", async () => {
    const gate = new Semaphore(1, 1);
    const order: number[] = [];
    let open!: () => void;
    const first = gate.run(() => new Promise<void>((resolve) => (open = resolve)).then(() => order.push(1)));
    const second = gate.run(async () => order.push(2));
    expect(first).not.toBeNull();
    expect(second).not.toBeNull();
    expect(gate.run(async () => order.push(3))).toBeNull();
    open();
    await Promise.all([first, second]);
    expect(order).toEqual([1, 2]);
    expect(await gate.run(async () => "free again")).toBe("free again");
  });

  it("keeps IPs and emails out of request logs", async () => {
    const lines: string[] = [];
    app = buildApp({ pool, storage, limits: currentLimits, logger: true, logStream: { write: (line) => lines.push(line) } });
    const alice = await signUp("alice");
    await logIn(alice.email, alice.password, "10.4.4.4");
    await call(alice, "GET", "/v1/account");
    const log = lines.join("");
    expect(log).toContain("/v1/auth/login");
    expect(log).not.toContain("10.4.4.4");
    expect(log).not.toContain("10.0.0.1");
    expect(log).not.toContain("127.0.0.1");
    expect(log).not.toContain("example.com");
  });
});
