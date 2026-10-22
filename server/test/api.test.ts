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
import * as cc from "../src/clientCrypto.js";

let embedded: EmbeddedPostgres;
let dataDir: string;
let pool: pg.Pool;
let app: FastifyInstance;
let currentLimits: Limits;
const deletedPaths: string[] = [];

const storage: BlobStorage = {
  async signedPutUrl(path, size) {
    return { url: `https://storage.test/${path}?put`, headers: { "x-goog-content-length-range": `0,${size}` }, expiresAt: Date.now() + 1000 };
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
  expect(await migrate(pool)).toEqual(["001_init.sql"]);
  expect(await migrate(pool)).toEqual([]);
}, 120_000);

afterAll(async () => {
  await app?.close();
  await pool?.end();
  await embedded?.stop();
  rmSync(dataDir, { recursive: true, force: true });
});

beforeEach(async () => {
  await pool.query("TRUNCATE users, sessions, spaces, space_members, items, blobs, invites CASCADE");
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
async function signUp(name: string, password = "pw-" + name): Promise<TestUser> {
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
  });
  expect(res.status).toBe(201);
  expect(res.body.account.email).toBe(email);
  return { uid, email, password, token: res.body.token, id, ak, personalSpaceId, personalKey };
}

/** A second device: prelogin, derive, login. */
async function logIn(email: string, password: string, ip?: string) {
  const pre = await call(null, "POST", "/v1/auth/prelogin", { email }, undefined, ip);
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
    };
    expect((await call(null, "POST", "/v1/auth/signup", { ...base, email: alice.email.toUpperCase() })).status).toBe(409);
    const weak = await call(null, "POST", "/v1/auth/signup", { ...base, email: "weak@example.com", kdf: { ...base.kdf, iterations: 1000 } });
    expect(weak.status).toBe(400);
    expect((await call(null, "POST", "/v1/auth/signup", { ...base, email: "not-an-email" })).status).toBe(400);
  });

  it("rate limits auth per email and per IP, and requests per user", async () => {
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

  it("rejects uppercase ids and unknown categories", async () => {
    const alice = await signUp("alice");
    const upper = randomUUID().toUpperCase();
    expect((await call(alice, "PUT", `/v1/spaces/${alice.personalSpaceId}/items/${upper}`, { category: "history", sortAt: 1, updatedAt: 1, ciphertext: "AAAA" })).status).toBe(400);
    expect((await call(alice, "PUT", `/v1/spaces/${alice.personalSpaceId}/items/${randomUUID()}`, { category: "misc", sortAt: 1, updatedAt: 1, ciphertext: "AAAA" })).status).toBe(400);
  });
});
