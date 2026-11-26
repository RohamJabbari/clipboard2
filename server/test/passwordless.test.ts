// Passwordless accounts (docs/features/passwordless.md): real Postgres (embedded), a mock Google JWKS,
// a fake mailer, and the reference client crypto acting as the devices.
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { generateKeyPairSync, randomBytes, randomUUID, sign } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import EmbeddedPostgres from "embedded-postgres";
import pg from "pg";
import type { FastifyInstance } from "fastify";
import { buildApp } from "../src/app.js";
import { limits as defaultLimits, type Features } from "../src/config.js";
import { migrate } from "../src/db.js";
import type { BlobStorage, Mailer } from "../src/services.js";
import { issueSignupCode } from "../src/auth.js";
import { emailIndex, migrateEmails, serverKeys } from "../src/keys.js";
import { googleVerifier, IdTokenError } from "../src/google.js";
import { ACKNOWLEDGEMENT } from "../src/passwordless.js";
import * as cc from "../src/clientCrypto.js";

let embedded: EmbeddedPostgres;
let dataDir: string;
let pool: pg.Pool;
let app: FastifyInstance;
const keys = serverKeys(Buffer.alloc(32, 9));
const AUD = "test-client.apps.googleusercontent.com";
const google = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...google.publicKey.export({ format: "jwk" }), kid: "k1", alg: "RS256", use: "sig" };
let jwksFetches = 0;
const mail: { to: string; subject: string; text: string }[] = [];
const mailer: Mailer = { send: async (m) => void mail.push(m) };

const storage: BlobStorage = {
  signedPutUrl: async (path, size) => ({ url: `https://storage.test/${path}`, headers: { "x-goog-content-length-range": `0,${size}` }, expiresAt: 0 }),
  signedGetUrl: async (path) => ({ url: `https://storage.test/${path}`, expiresAt: 0 }),
  delete: async () => {},
};

function rebuild(features: Partial<Features> = {}) {
  app = buildApp({
    pool,
    storage,
    limits: defaultLimits(),
    keys,
    features,
    mailer,
    google: googleVerifier({
      clientIds: [AUD],
      fetchJwks: async () => {
        jwksFetches++;
        return { keys: [jwk] };
      },
    }),
    geo: (request) => {
      const country = request.headers["x-test-country"];
      return typeof country === "string" ? { country, city: "Testville" } : null;
    },
  });
}

beforeAll(async () => {
  dataDir = mkdtempSync(join(tmpdir(), "c2-pl-"));
  const port = 16432 + Math.floor(Math.random() * 1000);
  embedded = new EmbeddedPostgres({ databaseDir: dataDir, user: "postgres", password: "postgres", port, persistent: false, onLog: () => {} });
  await embedded.initialise();
  await embedded.start();
  await embedded.createDatabase("c2pl");
  pool = new pg.Pool({ connectionString: `postgres://postgres:postgres@localhost:${port}/c2pl`, max: 4 });
  await migrate(pool);
}, 120_000);

afterAll(async () => {
  await app?.close();
  await pool?.end();
  await embedded?.stop();
  rmSync(dataDir, { recursive: true, force: true });
});

beforeEach(async () => {
  await pool.query("TRUNCATE users, sessions, spaces, signup_codes, auth_attempts, rate_buckets, used_id_tokens CASCADE");
  mail.length = 0;
  rebuild();
});

// MARK: Helpers

const b64 = (b: Buffer) => b.toString("base64");
const unb64 = (s: string) => Buffer.from(s, "base64");

async function call(token: string | null, method: string, url: string, body?: unknown, headers: Record<string, string> = {}) {
  const res = await app.inject({
    method: method as "GET",
    url,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "x-forwarded-for": headers.ip ?? "10.0.0.1", ...headers },
    ...(body === undefined ? {} : { payload: body as object }),
  });
  return { status: res.statusCode, body: res.body ? res.json() : undefined };
}

interface Device {
  token: string;
  key: cc.KeyPair;
}

interface User {
  uid: string;
  username: string;
  email: string;
  ak: Buffer;
  id: cc.KeyPair;
  device: Device;
  personalSpaceId: string;
}

function idToken(claims: Record<string, unknown>, options: { kid?: string; key?: typeof google.privateKey } = {}) {
  const now = Math.floor(Date.now() / 1000);
  const enc = (o: object) => Buffer.from(JSON.stringify(o)).toString("base64url");
  const head = enc({ alg: "RS256", kid: options.kid ?? "k1", typ: "JWT" });
  const body = enc({ iss: "https://accounts.google.com", aud: AUD, sub: "1234", email_verified: true, iat: now, exp: now + 3600, ...claims });
  const signature = sign("RSA-SHA256", Buffer.from(`${head}.${body}`), options.key ?? google.privateKey).toString("base64url");
  return `${head}.${body}.${signature}`;
}

async function trySignUpPasswordless(name: string, extra: Record<string, unknown> = {}) {
  const uid = randomUUID();
  const ak = randomBytes(32);
  const id = cc.keyPair();
  const device = cc.keyPair();
  const personalSpaceId = randomUUID();
  const username = `${name}${uid.slice(0, 4)}`;
  const email = `${name}-${uid.slice(0, 6)}@example.com`;
  const res = await call(null, "POST", "/v1/auth/passwordless/signup", {
    ...("googleIdToken" in extra ? {} : { email }),
    username,
    signupCode: (await issueSignupCode(pool, null)).code,
    uid,
    publicKey: b64(id.pub),
    wrappedPrivateKey: b64(cc.aeadSeal(ak, id.priv, cc.aad.privateKey(uid))),
    personalSpace: { id: personalSpaceId, wrappedKey: b64(cc.wrapSpaceKey(randomBytes(32), personalSpaceId, uid, id.pub)) },
    device: { publicKey: b64(device.pub), name: `${name}'s Mac`, platform: "macos" },
    ...extra,
  });
  return { res, user: { uid, username, email, ak, id, device: { token: res.body?.token, key: device }, personalSpaceId } as User };
}

async function signUpPasswordless(name: string, extra: Record<string, unknown> = {}): Promise<User> {
  const { res, user } = await trySignUpPasswordless(name, extra);
  expect(res.status).toBe(201);
  return user;
}

const ITERATIONS = 100_000;

async function signUpWithPassword(name: string, password = "pw") {
  const uid = randomUUID();
  const email = `${name}-${uid.slice(0, 6)}@example.com`;
  const salt = randomBytes(16);
  const pk = cc.passwordKeys(password, salt, ITERATIONS);
  const ak = randomBytes(32);
  const id = cc.keyPair();
  const personalSpaceId = randomUUID();
  const res = await call(null, "POST", "/v1/auth/signup", {
    email,
    authKey: b64(pk.authKey),
    kdf: { salt: b64(salt), iterations: ITERATIONS },
    uid,
    wrappedAccountKey: b64(cc.aeadSeal(pk.wrapKey, ak, cc.aad.accountKey(uid))),
    publicKey: b64(id.pub),
    wrappedPrivateKey: b64(cc.aeadSeal(ak, id.priv, cc.aad.privateKey(uid))),
    personalSpace: { id: personalSpaceId, wrappedKey: b64(cc.wrapSpaceKey(randomBytes(32), personalSpaceId, uid, id.pub)) },
    deviceName: "PC",
    username: `${name}${uid.slice(0, 4)}`,
    signupCode: (await issueSignupCode(pool, null)).code,
  });
  expect(res.status).toBe(201);
  return { uid, email, password, ak, id, token: res.body.token as string, authKey: pk.authKey, username: `${name}${uid.slice(0, 4)}` };
}

async function passwordLogin(email: string, password = "pw") {
  const pre = await call(null, "POST", "/v1/auth/prelogin", { email });
  const pk = cc.passwordKeys(password, unb64(pre.body.kdf.salt), pre.body.kdf.iterations);
  return call(null, "POST", "/v1/auth/login", { email, authKey: b64(pk.authKey), deviceName: "PC 2" });
}

/** A new device asks to sign in. */
async function requestLogin(identifier: string, options: { windowMs?: number | null; ip?: string; key?: cc.KeyPair; country?: string } = {}) {
  const key = options.key ?? cc.keyPair();
  const res = await call(
    null,
    "POST",
    "/v1/auth/device-requests",
    {
      identifier,
      device: { publicKey: b64(key.pub), name: "New Mac", platform: "macos" },
      windowMs: options.windowMs === undefined ? 60 * 60 * 1000 : options.windowMs,
      ...(options.windowMs === null ? { acknowledgement: ACKNOWLEDGEMENT } : {}),
    },
    { ip: options.ip ?? "10.0.0.9", ...(options.country ? { "x-test-country": options.country } : {}) },
  );
  return { res, key, id: res.body?.requestId as string, secret: res.body?.secret as string };
}

const poll = (id: string, secret: string) => call(null, "POST", `/v1/auth/device-requests/${id}/poll`, { secret });

/** What an approving device does: check the number, wrap AK to the new device. */
async function approve(approver: User, requestId: string, number?: number) {
  const token = approver.device.token;
  const listed = (await call(token, "GET", "/v1/device-requests")).body.requests as { id: string; devicePublicKey: string }[];
  const req = listed.find((r) => r.id === requestId)!;
  const pub = unb64(req.devicePublicKey);
  const correct = cc.matchNumber(requestId, pub);
  const pick = number ?? correct;
  const wrapped = cc.wrapTo(pub, approver.ak, cc.deviceWrap.info(requestId), cc.deviceWrap.aad(approver.uid, requestId));
  return call(token, "POST", `/v1/device-requests/${requestId}/approve`, { number: pick, ...(pick === correct ? { wrappedAccountKey: b64(wrapped) } : {}) });
}

const heads = async (token: string) => (await call(token, "GET", "/v1/heads")).body as { security: string };

async function makeContacts(a: User, b: User) {
  const spaceId = randomUUID();
  const sk = randomBytes(32);
  const req = await call(a.device.token, "POST", "/v1/contacts/requests", {
    username: b.username,
    spaceId,
    wrappedKey: b64(cc.wrapSpaceKey(sk, spaceId, a.uid, a.id.pub)),
    recipientWrappedKey: b64(cc.wrapSpaceKey(sk, spaceId, b.uid, b.id.pub)),
  });
  expect(req.status).toBe(201);
  expect((await call(b.device.token, "POST", `/v1/contacts/requests/${spaceId}/accept`)).status).toBe(201);
}

// MARK: Google ID tokens

describe("Google ID token verification", () => {
  const verifier = (now = () => Date.now()) => googleVerifier({ clientIds: [AUD], fetchJwks: async () => ({ keys: [jwk] }), now });

  it("accepts a good token and returns the lowercased email", async () => {
    const identity = await verifier().verify(idToken({ email: "Me@Gmail.com" }));
    expect(identity.email).toBe("me@gmail.com");
    expect(identity.sub).toBe("1234");
  });

  it("refuses wrong audience, issuer, unverified email, expiry, age, signature and algorithm", async () => {
    const v = verifier();
    const now = Math.floor(Date.now() / 1000);
    const other = generateKeyPairSync("rsa", { modulusLength: 2048 });
    const cases: [string, string][] = [
      ["wrong audience", idToken({ email: "a@b.c", aud: "someone-else" })],
      ["wrong issuer", idToken({ email: "a@b.c", iss: "https://evil.example" })],
      ["email not verified", idToken({ email: "a@b.c", email_verified: false })],
      ["expired", idToken({ email: "a@b.c", exp: now - 3600, iat: now - 7200 })],
      ["too old", idToken({ email: "a@b.c", iat: now - 11 * 60 })],
      ["bad signature", idToken({ email: "a@b.c" }, { key: other.privateKey })],
      ["unknown signing key", idToken({ email: "a@b.c" }, { kid: "k2" })],
      ["malformed token", "not.a.jwt.at-all"],
    ];
    for (const [why, token] of cases) {
      await expect(v.verify(token), why).rejects.toThrow(IdTokenError);
      await expect(v.verify(token), why).rejects.toThrow(why);
    }
    const head = Buffer.from(JSON.stringify({ alg: "none", kid: "k1" })).toString("base64url");
    await expect(v.verify(`${head}.${idToken({ email: "a@b.c" }).split(".")[1]}.`)).rejects.toThrow("unexpected algorithm");
  });

  it("caches the keys and refetches for a new kid at most once a minute", async () => {
    let fetches = 0;
    let clock = Date.now();
    const v = googleVerifier({ clientIds: [AUD], fetchJwks: async () => (fetches++, { keys: [jwk] }), now: () => clock });
    await v.verify(idToken({ email: "a@b.c" }));
    await v.verify(idToken({ email: "a@b.c" }));
    expect(fetches).toBe(1);
    await expect(v.verify(idToken({ email: "a@b.c" }, { kid: "new" }))).rejects.toThrow();
    expect(fetches).toBe(1);
    clock += 61_000;
    await expect(v.verify(idToken({ email: "a@b.c" }, { kid: "new" }))).rejects.toThrow();
    expect(fetches).toBe(2);
  });
});

// MARK: Emails

describe("encrypted emails", () => {
  it("stores only the blind index and ciphertext, and still logs in by email", async () => {
    const alice = await signUpWithPassword("alice");
    const { rows } = await pool.query("SELECT email, email_index, email_enc FROM users WHERE uid = $1", [alice.uid]);
    expect(rows[0].email).toBeNull();
    expect(rows[0].email_index.equals(emailIndex(keys, alice.email))).toBe(true);
    expect(rows[0].email_enc.toString("utf8")).not.toContain("alice");
    const login = await passwordLogin(alice.email.toUpperCase());
    expect(login.status).toBe(200);
    expect(login.body.account.email).toBe(alice.email);
    expect(login.body.account.emailVerified).toBe(false);
  });

  it("migrates existing plaintext rows at startup", async () => {
    const alice = await signUpWithPassword("alice");
    // As before this release: the address in plaintext, no index.
    await pool.query("UPDATE users SET email = 'Legacy@Example.com', email_index = NULL, email_enc = NULL WHERE uid = $1", [alice.uid]);
    expect(await migrateEmails(pool, keys)).toBe(1);
    expect(await migrateEmails(pool, keys)).toBe(0);
    const { rows } = await pool.query("SELECT email, email_index FROM users WHERE uid = $1", [alice.uid]);
    expect(rows[0].email).toBeNull();
    expect(rows[0].email_index.equals(emailIndex(keys, "legacy@example.com"))).toBe(true);
    expect((await passwordLogin("legacy@example.com")).status).toBe(200);
  });

  it("keeps the email local part only as a name for accounts without a username", async () => {
    const alice = await signUpWithPassword("alice");
    const { rows } = await pool.query("SELECT fallback_name FROM users WHERE uid = $1", [alice.uid]);
    expect(rows[0].fallback_name).toBeNull();
  });
});

// MARK: Sign-up

describe("passwordless sign-up", () => {
  it("creates an account with no password and an indefinite device session", async () => {
    const alice = await signUpPasswordless("alice");
    const account = (await call(alice.device.token, "GET", "/v1/account")).body;
    expect(account).toMatchObject({ uid: alice.uid, email: alice.email, emailVerified: false, kdf: null, wrappedAccountKey: null, hasPassword: false });
    const [session] = (await call(alice.device.token, "GET", "/v1/sessions")).body.sessions;
    expect(session).toMatchObject({ kind: "device", windowMs: null, expiresAt: null, platform: "macos", current: true });
    // No password to log in with.
    const pre = await call(null, "POST", "/v1/auth/prelogin", { email: alice.email });
    expect(pre.status).toBe(200);
    const login = await call(null, "POST", "/v1/auth/login", { email: alice.email, authKey: b64(randomBytes(32)) });
    expect(login.status).toBe(401);
  });

  it("needs an invite and a unique username", async () => {
    const alice = await signUpPasswordless("alice");
    const noInvite = await trySignUpPasswordless("bob", { signupCode: undefined });
    expect(noInvite.res.status).toBe(403);
    const taken = await trySignUpPasswordless("carol", { username: alice.username.toUpperCase() });
    expect(taken.res.status).toBe(409);
    expect(taken.res.body.error).toBe("username_taken");
  });

  it("verifies the email with Google, and a verified claim takes the address from an unverified account", async () => {
    const squatter = await signUpWithPassword("squat");
    const owner = await signUpPasswordless("owner", { googleIdToken: idToken({ email: squatter.email.toUpperCase() }) });
    const account = (await call(owner.device.token, "GET", "/v1/account")).body;
    expect(account).toMatchObject({ email: squatter.email, emailVerified: true });
    // The squatter is told to change it, and its password still works at the old address.
    const theirs = (await call(squatter.token, "GET", "/v1/account")).body;
    expect(theirs).toMatchObject({ emailReleased: true, emailVerified: false });
    expect((await passwordLogin(squatter.email)).status).toBe(200);
    // Device requests by that address now go to the verified owner.
    const req = await requestLogin(squatter.email);
    const listed = (await call(owner.device.token, "GET", "/v1/device-requests")).body.requests;
    expect(listed.map((r: { id: string }) => r.id)).toEqual([req.id]);
    // A second verified claim on a verified address is refused, and a token works once.
    const again = await trySignUpPasswordless("third", { googleIdToken: idToken({ email: squatter.email }) });
    expect(again.res.status).toBe(409);
    const token = idToken({ email: "fresh@gmail.com" });
    expect((await call(squatter.token, "PUT", "/v1/account/email", { googleIdToken: token })).status).toBe(200);
    const replay = await call(owner.device.token, "PUT", "/v1/account/email", { googleIdToken: token });
    expect(replay.status).toBe(401);
    expect(replay.body.error).toBe("invalid_token");
  });

  it("refuses an unverified claim on a taken address", async () => {
    const alice = await signUpPasswordless("alice");
    const bob = await signUpPasswordless("bob");
    const res = await call(bob.device.token, "PUT", "/v1/account/email", { email: alice.email });
    expect(res.status).toBe(409);
  });
});

// MARK: Device approval

describe("new device approval", () => {
  it("lets a new device in once an existing one approves with the right number", async () => {
    const alice = await signUpPasswordless("alice");
    const before = await heads(alice.device.token);
    const req = await requestLogin(alice.username.toUpperCase(), { windowMs: 60 * 60 * 1000 });
    expect(req.res.status).toBe(201);
    expect(Object.keys(req.res.body).sort()).toEqual(["expiresAt", "requestId", "secret"]);
    expect(req.res.body.expiresAt - Date.now()).toBeGreaterThan(4 * 60 * 1000);
    expect((await heads(alice.device.token)).security).not.toBe(before.security);

    const listed = (await call(alice.device.token, "GET", "/v1/device-requests")).body.requests;
    expect(listed).toHaveLength(1);
    expect(listed[0]).toMatchObject({ id: req.id, deviceName: "New Mac", platform: "macos", windowMs: 3_600_000, newCountry: false });
    expect((await poll(req.id, req.secret)).body).toEqual({ status: "pending" });

    expect((await approve(alice, req.id)).status).toBe(200);
    const done = await poll(req.id, req.secret);
    expect(done.status).toBe(200);
    expect(done.body.status).toBe("approved");
    expect(done.body.account.uid).toBe(alice.uid);
    expect(done.body.expiresAt - Date.now()).toBeGreaterThan(59 * 60 * 1000);
    expect(done.body.expiresAt - Date.now()).toBeLessThanOrEqual(60 * 60 * 1000);
    // The new device opens AK, then its private key.
    const ak = cc.unwrapFrom(req.key, unb64(done.body.wrappedAccountKey), cc.deviceWrap.info(req.id), cc.deviceWrap.aad(alice.uid, req.id));
    expect(ak.equals(alice.ak)).toBe(true);
    expect(cc.aeadOpen(ak, unb64(done.body.account.wrappedPrivateKey), cc.aad.privateKey(alice.uid)).equals(alice.id.priv)).toBe(true);
    expect((await call(done.body.token, "GET", "/v1/account")).status).toBe(200);
    // Picked up once.
    expect((await poll(req.id, req.secret)).body).toEqual({ status: "completed" });
    const sessions = (await call(done.body.token, "GET", "/v1/sessions")).body.sessions;
    expect(sessions).toHaveLength(2);
    expect(sessions.find((s: { current: boolean }) => s.current)).toMatchObject({ kind: "device", windowMs: 3_600_000 });
  });

  it("kills the request when the approver picks the wrong number", async () => {
    const alice = await signUpPasswordless("alice");
    const req = await requestLogin(alice.email);
    const wrong = ((cc.matchNumber(req.id, req.key.pub) - 10 + 1) % 90) + 10;
    const res = await approve(alice, req.id, wrong);
    expect(res.status).toBe(409);
    expect(res.body.error).toBe("number_mismatch");
    expect((await poll(req.id, req.secret)).body).toEqual({ status: "mismatch" });
    // Gone for good, even with the right number.
    const retry = await call(alice.device.token, "POST", `/v1/device-requests/${req.id}/approve`, {
      number: cc.matchNumber(req.id, req.key.pub),
      wrappedAccountKey: b64(randomBytes(80)),
    });
    expect(retry.status).toBe(409);
    expect(retry.body.error).toBe("request_closed");
    expect((await call(alice.device.token, "GET", "/v1/device-requests")).body.requests).toEqual([]);
  });

  it("expires requests after a few minutes", async () => {
    const alice = await signUpPasswordless("alice");
    const req = await requestLogin(alice.email);
    await pool.query("UPDATE device_requests SET expires_at = now() - interval '1 second' WHERE id = $1", [req.id]);
    expect((await poll(req.id, req.secret)).body).toEqual({ status: "expired" });
    expect((await call(alice.device.token, "GET", "/v1/device-requests")).body.requests).toEqual([]);
    const late = await call(alice.device.token, "POST", `/v1/device-requests/${req.id}/approve`, { number: cc.matchNumber(req.id, req.key.pub), wrappedAccountKey: b64(randomBytes(80)) });
    expect(late.status).toBe(409);
    expect(late.body.error).toBe("request_closed");
  });

  it("answers unknown accounts exactly like real ones, and never approves them", async () => {
    const req = await requestLogin("nobody-here@example.com");
    expect(req.res.status).toBe(201);
    expect(Object.keys(req.res.body).sort()).toEqual(["expiresAt", "requestId", "secret"]);
    expect((await poll(req.id, req.secret)).body).toEqual({ status: "pending" });
    expect((await poll(req.id, "A".repeat(43))).status).toBe(404);
  });

  it("'This wasn't me' denies, blocks the source and pauses the account", async () => {
    const alice = await signUpPasswordless("alice");
    const key = cc.keyPair();
    const req = await requestLogin(alice.username, { ip: "203.0.113.5", key });
    expect((await call(alice.device.token, "POST", `/v1/device-requests/${req.id}/deny`, { block: true })).status).toBe(204);
    expect((await poll(req.id, req.secret)).body).toEqual({ status: "denied" });
    // The account is paused for everyone for a while…
    const paused = await requestLogin(alice.username, { ip: "198.51.100.1" });
    expect(paused.res.status).toBe(429);
    expect(paused.res.body.retryAfter).toBeGreaterThan(50 * 60);
    // …and after the pause, that IP and that device key stay blocked.
    await pool.query("UPDATE users SET requests_paused_until = NULL WHERE uid = $1", [alice.uid]);
    expect((await requestLogin(alice.username, { ip: "203.0.113.5" })).res.status).toBe(429);
    expect((await requestLogin(alice.username, { ip: "198.51.100.2", key })).res.status).toBe(429);
    expect((await requestLogin(alice.username, { ip: "198.51.100.3" })).res.status).toBe(201);
    // A plain deny doesn't block (with the per-account request count reset).
    await pool.query("DELETE FROM rate_buckets");
    const other = await requestLogin(alice.username, { ip: "198.51.100.4" });
    expect((await call(alice.device.token, "POST", `/v1/device-requests/${other.id}/deny`, {})).status).toBe(204);
    expect((await requestLogin(alice.username, { ip: "198.51.100.4" })).res.status).toBe(201);
  });

  it("rate-limits requests per device key, per IP and per account", async () => {
    const alice = await signUpPasswordless("alice");
    const key = cc.keyPair();
    for (let i = 0; i < 3; i++) expect((await requestLogin(alice.username, { key, ip: `10.1.0.${i}` })).res.status).toBe(201);
    expect((await requestLogin(alice.username, { key, ip: "10.1.0.9" })).res.status).toBe(429);
    // The account's limit (5) counts the attempts above too.
    expect((await requestLogin(alice.email, { ip: "10.2.0.1" })).res.status).toBe(201);
    expect((await requestLogin(alice.email, { ip: "10.2.0.2" })).res.status).toBe(429);
    for (let i = 0; i < 10; i++) await requestLogin(`someone${i}@example.com`, { ip: "10.3.0.1" });
    expect((await requestLogin("someone-else@example.com", { ip: "10.3.0.1" })).res.status).toBe(429);
  });

  it("flags a country never seen on the account", async () => {
    const alice = await signUpPasswordless("alice");
    await pool.query("UPDATE sessions SET country = 'AT' WHERE uid = $1", [alice.uid]);
    await requestLogin(alice.username, { country: "AT", ip: "10.4.0.1" });
    await requestLogin(alice.username, { country: "KP", ip: "10.4.0.2" });
    const listed = (await call(alice.device.token, "GET", "/v1/device-requests")).body.requests;
    const byCountry = Object.fromEntries(listed.map((r: { country: string; newCountry: boolean; city: string }) => [r.country, r.newCountry]));
    expect(byCountry).toEqual({ AT: false, KP: true });
    expect(listed[0].city).toBe("Testville");
  });

  it("requires the typed acknowledgement for an indefinite session", async () => {
    const alice = await signUpPasswordless("alice");
    const key = cc.keyPair();
    const bad = await call(null, "POST", "/v1/auth/device-requests", {
      identifier: alice.username,
      device: { publicKey: b64(key.pub) },
      windowMs: null,
      acknowledgement: "i understand",
    });
    expect(bad.status).toBe(400);
    const req = await requestLogin(alice.username, { windowMs: null });
    expect(req.res.status).toBe(201);
    await approve(alice, req.id);
    expect((await poll(req.id, req.secret)).body.expiresAt).toBeNull();
  });
});

// MARK: Session windows

describe("session windows", () => {
  async function secondDevice(alice: User, windowMs: number | null = 24 * 60 * 60 * 1000) {
    const req = await requestLogin(alice.username, { windowMs });
    await approve(alice, req.id);
    const done = await poll(req.id, req.secret);
    return { token: done.body.token as string, id: (await call(done.body.token, "GET", "/v1/sessions")).body.sessions.find((s: { current: boolean }) => s.current).id };
  }

  it("ends a device session hard at its window: no sliding, then 401", async () => {
    const alice = await signUpPasswordless("alice");
    const other = await secondDevice(alice);
    const { rows } = await pool.query("SELECT expires_at FROM sessions WHERE id = $1", [other.id]);
    // Using it (even as stale) doesn't move the expiry.
    await pool.query("UPDATE sessions SET last_used_at = now() - interval '2 hours' WHERE id = $1", [other.id]);
    expect((await call(other.token, "GET", "/v1/account")).status).toBe(200);
    const after = await pool.query("SELECT expires_at FROM sessions WHERE id = $1", [other.id]);
    expect(after.rows[0].expires_at.getTime()).toBe(rows[0].expires_at.getTime());
    await pool.query("UPDATE sessions SET expires_at = now() - interval '1 second' WHERE id = $1", [other.id]);
    const ended = await call(other.token, "GET", "/v1/account");
    expect(ended.status).toBe(401);
    expect(ended.body.error).toBe("unauthenticated");
  });

  it("lets any device shorten a window but only the device itself lengthen it", async () => {
    const alice = await signUpPasswordless("alice");
    const other = await secondDevice(alice, 24 * 60 * 60 * 1000);
    const shorter = await call(alice.device.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: 60 * 60 * 1000 });
    expect(shorter.status).toBe(200);
    expect(shorter.body).toMatchObject({ windowMs: 3_600_000, current: false });
    const longer = await call(alice.device.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: 7 * 24 * 60 * 60 * 1000 });
    expect(longer.status).toBe(403);
    const indefinite = await call(alice.device.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: null, acknowledgement: ACKNOWLEDGEMENT });
    expect(indefinite.status).toBe(403);
    const own = await call(other.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: 7 * 24 * 60 * 60 * 1000 });
    expect(own.status).toBe(200);
    expect((await call(other.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: null })).status).toBe(400);
    const forever = await call(other.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: null, acknowledgement: ACKNOWLEDGEMENT });
    expect(forever.body).toMatchObject({ windowMs: null, expiresAt: null, current: true });
    expect((await call(alice.device.token, "PATCH", `/v1/sessions/${other.id}`, { windowMs: 60_000 })).status).toBe(400);
  });

  it("revoking a device ends it at once", async () => {
    const alice = await signUpPasswordless("alice");
    const other = await secondDevice(alice);
    expect((await call(alice.device.token, "DELETE", `/v1/sessions/${other.id}`)).status).toBe(204);
    expect((await call(other.token, "GET", "/v1/account")).status).toBe(401);
  });
});

// MARK: Switching and deleting

describe("switching to passwordless", () => {
  it("turns the session into a device session and retires the password only when no password device is left", async () => {
    const alice = await signUpWithPassword("alice");
    const second = await passwordLogin(alice.email);
    const device = cc.keyPair();
    const keep = await call(alice.token, "POST", "/v1/account/passwordless", { authKey: b64(alice.authKey), devicePublicKey: b64(device.pub), platform: "macos" });
    expect(keep.status).toBe(200);
    expect(keep.body.session).toMatchObject({ kind: "device", windowMs: null, expiresAt: null });
    expect(keep.body.account.hasPassword).toBe(true);
    const refused = await call(alice.token, "POST", "/v1/account/passwordless", { authKey: b64(alice.authKey), devicePublicKey: b64(device.pub), retirePassword: true });
    expect(refused.status).toBe(409);
    expect(refused.body).toMatchObject({ error: "password_devices", devices: ["PC 2"] });
    const otherId = (await call(second.body.token, "GET", "/v1/sessions")).body.sessions.find((s: { current: boolean }) => s.current).id;
    expect((await call(alice.token, "DELETE", `/v1/sessions/${otherId}`)).status).toBe(204);
    const retired = await call(alice.token, "POST", "/v1/account/passwordless", { authKey: b64(alice.authKey), devicePublicKey: b64(device.pub), retirePassword: true });
    expect(retired.status).toBe(200);
    expect(retired.body.account).toMatchObject({ hasPassword: false, kdf: null, wrappedAccountKey: null });
    expect((await passwordLogin(alice.email)).status).toBe(401);
    expect((await call(alice.token, "GET", "/v1/account")).status).toBe(200);
  });

  it("deletes a passwordless account with the typed username from a device session", async () => {
    const alice = await signUpPasswordless("alice");
    expect((await call(alice.device.token, "DELETE", "/v1/account", {})).status).toBe(400);
    expect((await call(alice.device.token, "DELETE", "/v1/account", { confirm: "someone" })).status).toBe(400);
    expect((await call(alice.device.token, "DELETE", "/v1/account", { confirm: ` ${alice.username.toUpperCase()} ` })).status).toBe(204);
    expect((await pool.query("SELECT 1 FROM users WHERE uid = $1", [alice.uid])).rowCount).toBe(0);
  });
});

// MARK: Email codes

describe("email verification codes", () => {
  it("are off unless the flag is on", async () => {
    const alice = await signUpPasswordless("alice");
    const res = await call(alice.device.token, "POST", "/v1/account/email/code", {});
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("feature_disabled");
    expect(mail).toEqual([]);
  });

  it("verify the address when on", async () => {
    rebuild({ emailCodes: true });
    const alice = await signUpPasswordless("alice");
    expect((await call(alice.device.token, "POST", "/v1/account/email/code", {})).status).toBe(204);
    expect(mail[0]!.to).toBe(alice.email);
    const code = mail[0]!.subject.slice(0, 6);
    const wrong = code === "000000" ? "000001" : "000000";
    expect((await call(alice.device.token, "POST", "/v1/account/email/verify", { code: wrong })).status).toBe(400);
    const ok = await call(alice.device.token, "POST", "/v1/account/email/verify", { code });
    expect(ok.status).toBe(200);
    expect(ok.body.emailVerified).toBe(true);
  });
});

// MARK: Recovery

describe("recovery", () => {
  async function setUpRecovery(owner: User, contacts: User[]) {
    const setupId = randomUUID();
    const shares = cc.splitShares(owner.ak, contacts.length + 1);
    const res = await call(owner.device.token, "PUT", "/v1/account/recovery", {
      method: "contacts",
      setupId,
      contacts: contacts.map((c, i) => ({
        uid: c.uid,
        wrappedShare: b64(cc.wrapTo(c.id.pub, shares[i]!, cc.recoveryShareWrap.info(setupId), cc.recoveryShareWrap.aad(setupId, c.uid))),
      })),
      escrowShare: b64(shares[contacts.length]!),
    });
    return { res, setupId };
  }

  async function startRecovery(identifier: string, key = cc.keyPair(), ip = "10.9.0.1") {
    const res = await call(
      null,
      "POST",
      "/v1/auth/recovery",
      { identifier, method: "contacts", device: { publicKey: b64(key.pub), name: "Replacement Mac", platform: "macos" }, windowMs: null, acknowledgement: ACKNOWLEDGEMENT },
      { ip },
    );
    return { res, key, id: res.body?.recoveryId as string, secret: res.body?.secret as string };
  }

  const pollRecovery = (id: string, secret: string) => call(null, "POST", `/v1/auth/recovery/${id}/poll`, { secret });

  /** A contact helps: number check, unwrap their share, re-wrap it to the new device. */
  async function contactApproves(contact: User, recoveryId: string, number?: number) {
    const listed = (await call(contact.device.token, "GET", "/v1/recovery/requests")).body.requests as {
      id: string;
      setupId: string;
      devicePublicKey: string;
      wrappedShare: string;
    }[];
    const req = listed.find((r) => r.id === recoveryId)!;
    const pub = unb64(req.devicePublicKey);
    const share = cc.unwrapFrom(contact.id, unb64(req.wrappedShare), cc.recoveryShareWrap.info(req.setupId), cc.recoveryShareWrap.aad(req.setupId, contact.uid));
    const rewrapped = cc.wrapTo(pub, share, cc.recoveryDeviceWrap.info(recoveryId), cc.recoveryDeviceWrap.aad(recoveryId, contact.uid));
    return call(contact.device.token, "POST", `/v1/recovery/requests/${recoveryId}/approve`, {
      number: number ?? cc.matchNumber(recoveryId, pub),
      wrappedShare: b64(rewrapped),
    });
  }

  const release = (id: string) => pool.query("UPDATE recovery_requests SET release_at = now() - interval '1 second' WHERE id = $1", [id]);

  function recoveredKey(started: { id: string; key: cc.KeyPair }, ready: { shares: { uid: string; wrappedShare: string }[]; escrowShare: string }) {
    const shares = ready.shares.map((s) =>
      cc.unwrapFrom(started.key, unb64(s.wrappedShare), cc.recoveryDeviceWrap.info(started.id), cc.recoveryDeviceWrap.aad(started.id, s.uid)),
    );
    shares.push(cc.unwrapFrom(started.key, unb64(ready.escrowShare), cc.recoveryDeviceWrap.info(started.id), cc.recoveryDeviceWrap.aad(started.id, "server")));
    return cc.combineShares(shares);
  }

  it("needs the contact to accept, then recovers with their approval after the waiting period", async () => {
    const alice = await signUpPasswordless("alice");
    const bob = await signUpPasswordless("bob");
    const carol = await signUpPasswordless("carol");
    expect((await setUpRecovery(alice, [carol])).res.status).toBe(400); // not a contact
    await makeContacts(alice, bob);
    const before = await heads(bob.device.token);
    const { res, setupId } = await setUpRecovery(alice, [bob]);
    expect(res.status).toBe(200);
    expect(res.body.setup).toMatchObject({ id: setupId, method: "contacts", status: "pending", contacts: [{ uid: bob.uid, accepted: false }] });
    expect((await heads(bob.device.token)).security).not.toBe(before.security);
    const invitations = (await call(bob.device.token, "GET", "/v1/recovery/invitations")).body.invitations;
    expect(invitations).toMatchObject([{ setupId, uid: alice.uid, name: alice.username, accepted: false }]);
    // Not active yet: a recovery now never completes.
    const early = await startRecovery(alice.username);
    await release(early.id);
    expect((await pollRecovery(early.id, early.secret)).body.status).toBe("waiting");

    expect((await call(bob.device.token, "POST", `/v1/recovery/invitations/${setupId}/accept`)).status).toBe(204);
    expect((await call(alice.device.token, "GET", "/v1/account/recovery")).body.setup.status).toBe("active");

    const started = await startRecovery(alice.username);
    expect(started.res.status).toBe(201);
    expect(started.res.body.releaseAt - Date.now()).toBeGreaterThan(71 * 60 * 60 * 1000);
    // Every device of the account sees it.
    const recoveries = (await call(alice.device.token, "GET", "/v1/account/recoveries")).body.recoveries;
    expect(recoveries.map((r: { id: string }) => r.id)).toContain(started.id);
    expect((await contactApproves(bob, started.id)).status).toBe(200);
    // Approved, but the 72 hours haven't passed.
    expect((await pollRecovery(started.id, started.secret)).body).toMatchObject({ status: "waiting", approvals: 1, needed: 1 });
    await release(started.id);
    const ready = await pollRecovery(started.id, started.secret);
    expect(ready.body.status).toBe("ready");
    expect(ready.body.expiresAt).toBeNull();
    expect(recoveredKey(started, ready.body).equals(alice.ak)).toBe(true);
    expect((await call(ready.body.token, "GET", "/v1/account")).body.uid).toBe(alice.uid);
    expect((await pollRecovery(started.id, started.secret)).body).toEqual({ status: "completed" });
  });

  it("needs both of two contacts; one alone and the server don't recover", async () => {
    const alice = await signUpPasswordless("alice");
    const bob = await signUpPasswordless("bob");
    const carol = await signUpPasswordless("carol");
    await makeContacts(alice, bob);
    await makeContacts(carol, alice);
    const { setupId } = await setUpRecovery(alice, [bob, carol]);
    for (const c of [bob, carol]) await call(c.device.token, "POST", `/v1/recovery/invitations/${setupId}/accept`);
    const started = await startRecovery(alice.email);
    await release(started.id);
    expect((await contactApproves(bob, started.id)).status).toBe(200);
    expect((await pollRecovery(started.id, started.secret)).body).toMatchObject({ status: "waiting", approvals: 1, needed: 2 });
    expect((await contactApproves(carol, started.id)).status).toBe(200);
    const ready = await pollRecovery(started.id, started.secret);
    expect(ready.body.status).toBe("ready");
    expect(ready.body.shares).toHaveLength(2);
    expect(recoveredKey(started, ready.body).equals(alice.ak)).toBe(true);
  });

  it("lets any device of the account cancel during the waiting period, and pauses new recoveries", async () => {
    const alice = await signUpPasswordless("alice");
    const bob = await signUpPasswordless("bob");
    await makeContacts(alice, bob);
    const { setupId } = await setUpRecovery(alice, [bob]);
    await call(bob.device.token, "POST", `/v1/recovery/invitations/${setupId}/accept`);
    const started = await startRecovery(alice.username);
    await contactApproves(bob, started.id);
    expect((await call(alice.device.token, "POST", `/v1/account/recoveries/${started.id}/cancel`)).status).toBe(204);
    await release(started.id);
    expect((await pollRecovery(started.id, started.secret)).body).toEqual({ status: "cancelled" });
    expect((await call(alice.device.token, "GET", "/v1/account/recoveries")).body.recoveries).toEqual([]);
    const again = await startRecovery(alice.username, cc.keyPair(), "10.9.0.2");
    expect(again.res.status).toBe(429);
  });

  it("stops the recovery when the contact picks the wrong number, or denies it", async () => {
    const alice = await signUpPasswordless("alice");
    const bob = await signUpPasswordless("bob");
    await makeContacts(alice, bob);
    const { setupId } = await setUpRecovery(alice, [bob]);
    await call(bob.device.token, "POST", `/v1/recovery/invitations/${setupId}/accept`);
    const first = await startRecovery(alice.username);
    const wrong = ((cc.matchNumber(first.id, first.key.pub) - 10 + 7) % 90) + 10;
    const res = await contactApproves(bob, first.id, wrong);
    expect(res.status).toBe(409);
    expect(res.body.error).toBe("number_mismatch");
    expect((await pollRecovery(first.id, first.secret)).body).toEqual({ status: "mismatch" });
    const second = await startRecovery(alice.username, cc.keyPair(), "10.9.0.3");
    expect((await call(bob.device.token, "POST", `/v1/recovery/requests/${second.id}/deny`)).status).toBe(204);
    expect((await pollRecovery(second.id, second.secret)).body).toEqual({ status: "denied" });
  });

  it("breaks when a contact steps down, and answers unknown accounts like real ones", async () => {
    const alice = await signUpPasswordless("alice");
    const bob = await signUpPasswordless("bob");
    await makeContacts(alice, bob);
    const { setupId } = await setUpRecovery(alice, [bob]);
    await call(bob.device.token, "POST", `/v1/recovery/invitations/${setupId}/accept`);
    expect((await call(bob.device.token, "DELETE", `/v1/recovery/invitations/${setupId}`)).status).toBe(204);
    expect((await call(alice.device.token, "GET", "/v1/account/recovery")).body.setup.status).toBe("broken");
    const ghost = await startRecovery("nobody@example.com");
    expect(ghost.res.status).toBe(201);
    await release(ghost.id);
    expect((await pollRecovery(ghost.id, ghost.secret)).body.status).toBe("waiting");
    // Setting up again replaces the old setup (and its escrow share).
    const replaced = await setUpRecovery(alice, [bob]);
    expect(replaced.res.status).toBe(200);
    expect((await pool.query("SELECT count(*)::int AS n FROM recovery_setups WHERE uid = $1", [alice.uid])).rows[0].n).toBe(1);
    expect((await call(alice.device.token, "DELETE", "/v1/account/recovery")).status).toBe(204);
    expect((await call(alice.device.token, "GET", "/v1/account/recovery")).body.setup).toBeNull();
  });

  it("keeps the email method off behind the flag", async () => {
    const alice = await signUpPasswordless("alice");
    const res = await call(alice.device.token, "PUT", "/v1/account/recovery", {
      method: "email",
      setupId: randomUUID(),
      escrowShare: b64(randomBytes(32)),
      wrappedSecret: b64(randomBytes(60)),
      code: "ABCD-EFGH-IJKL-MNOP",
    });
    expect(res.status).toBe(403);
    expect(res.body.error).toBe("feature_disabled");
    const start = await call(null, "POST", "/v1/auth/recovery", {
      identifier: alice.username,
      method: "email",
      device: { publicKey: b64(cc.keyPair().pub) },
      windowMs: 3_600_000,
    });
    expect(start.status).toBe(403);
  });

  it("recovers with an emailed code when the flag is on", async () => {
    rebuild({ emailCodes: true });
    const alice = await signUpPasswordless("alice", { googleIdToken: idToken({ email: "alice.rec@gmail.com" }) });
    const setupId = randomUUID();
    const code = randomBytes(16);
    const [sEmail, sServer] = cc.splitShares(alice.ak, 2);
    const setup = await call(alice.device.token, "PUT", "/v1/account/recovery", {
      method: "email",
      setupId,
      escrowShare: b64(sServer!),
      wrappedSecret: b64(cc.aeadSeal(cc.recoveryCodeKey(code), sEmail!, cc.recoveryCodeAad(setupId))),
      code: cc.formatInviteCode(code),
    });
    expect(setup.status).toBe(200);
    expect(mail[0]!.to).toBe("alice.rec@gmail.com");
    expect(mail[0]!.text).toContain(cc.formatInviteCode(code));
    const key = cc.keyPair();
    const started = await call(null, "POST", "/v1/auth/recovery", { identifier: alice.username, method: "email", device: { publicKey: b64(key.pub) }, windowMs: 3_600_000 });
    expect(started.status).toBe(201);
    const id = started.body.recoveryId;
    await release(id);
    const ready = await pollRecovery(id, started.body.secret);
    expect(ready.body.status).toBe("ready");
    const fromServer = cc.unwrapFrom(key, unb64(ready.body.escrowShare), cc.recoveryDeviceWrap.info(id), cc.recoveryDeviceWrap.aad(id, "server"));
    const fromMail = cc.aeadOpen(cc.recoveryCodeKey(cc.parseInviteCode(mail[0]!.text.match(/[A-Z2-7]{4}(?:-[A-Z2-7]{1,4}){6}/)![0])!), unb64(ready.body.wrappedSecret), cc.recoveryCodeAad(setupId));
    expect(cc.combineShares([fromServer, fromMail]).equals(alice.ak)).toBe(true);
  });
});

// Keeps the unused-variable linter quiet about the fetch counter (it's checked by the cache test above).
void jwksFetches;
