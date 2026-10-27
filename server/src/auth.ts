// Password-less-on-the-wire auth: clients send authKey = HKDF(PBKDF2(password)), never the password.
// We store scrypt(authKey) and hand out opaque session tokens, keeping only their SHA-256.
import { createHash, createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual, type ScryptOptions } from "node:crypto";
import type pg from "pg";
import type { Db } from "./db.js";

const scryptAsync = (key: Buffer, salt: Buffer, length: number, options: ScryptOptions) =>
  new Promise<Buffer>((resolve, reject) => scryptCb(key, salt, length, options, (error, derived) => (error ? reject(error) : resolve(derived))));

// authKey already carries 600k PBKDF2 rounds of work; scrypt here guards a leaked table, not a weak secret.
const SCRYPT = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 } as const;
export const SESSION_DAYS = 30;
export const FAKE_KDF_ITERATIONS = 600_000;

export async function hashAuthKey(authKey: Buffer, salt = randomBytes(16)): Promise<{ salt: Buffer; hash: Buffer }> {
  return { salt, hash: await scryptAsync(authKey, salt, 32, SCRYPT) };
}

export async function verifyAuthKey(authKey: Buffer, salt: Buffer, hash: Buffer): Promise<boolean> {
  const candidate = await scryptAsync(authKey, salt, 32, SCRYPT);
  return candidate.length === hash.length && timingSafeEqual(candidate, hash);
}

/** Burns the same scrypt time for unknown emails so login timing doesn't reveal which accounts exist. */
const dummySalt = randomBytes(16);
export const burnScrypt = (authKey: Buffer) => scryptAsync(authKey, dummySalt, 32, SCRYPT).then(() => undefined);

export const normalizeEmail = (email: string) => email.trim().toLowerCase();

export const newSessionToken = () => randomBytes(32).toString("base64url");
export const tokenHash = (token: string) => createHash("sha256").update(token, "utf8").digest();

/** The prelogin HMAC key, created once and kept in the settings table. */
export async function preloginKey(pool: Db): Promise<Buffer> {
  await pool.query("INSERT INTO settings (name, value) VALUES ('prelogin_hmac_key', $1) ON CONFLICT (name) DO NOTHING", [randomBytes(32)]);
  const { rows } = await pool.query<{ value: Buffer }>("SELECT value FROM settings WHERE name = 'prelogin_hmac_key'");
  return rows[0]!.value;
}

/** Deterministic per email, so repeated prelogins for a non-account look exactly like a real one. */
export const fakeSalt = (key: Buffer, email: string) => createHmac("sha256", key).update(email, "utf8").digest().subarray(0, 16);

/** HMAC of a rate-limit key ("ip:…", "email:…") under the same server key, so the attempts table holds no addresses. */
export const rateKey = (key: Buffer, name: string) => createHmac("sha256", key).update(name, "utf8").digest();

// MARK: Sign-up codes

const CODE_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
export const SIGNUP_CODE_DAYS = 14;

/** 80 random bits in the invite-code alphabet: 16 characters shown as XXXX-XXXX-XXXX-XXXX. */
export function newSignupCode(): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of randomBytes(10)) {
    value = ((value << 8) | byte) & 0xffff;
    bits += 8;
    while (bits >= 5) {
      out += CODE_ALPHABET[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  return out.match(/.{4}/g)!.join("-");
}

/** Forgives spaces, dashes, case and 0/1/8 misreadings like invite codes; null unless exactly 16 code characters remain. */
export function normalizeSignupCode(typed: string): string | null {
  const clean = typed.replace(/[\s-]/g, "").toUpperCase().replace(/0/g, "O").replace(/1/g, "I").replace(/8/g, "B");
  return /^[A-Z2-7]{16}$/.test(clean) ? clean : null;
}

export const signupCodeHash = (normalized: string) => createHash("sha256").update(normalized, "utf8").digest();

/** Stores a new code (only its hash) for `createdBy`, or for nobody when an operator issues it. */
export async function issueSignupCode(db: Pick<pg.PoolClient, "query">, createdBy: string | null) {
  const code = newSignupCode();
  const { rows } = await db.query<{ id: string; expires_at: Date }>(
    `INSERT INTO signup_codes (id, code_hash, created_by, expires_at) VALUES (gen_random_uuid(), $1, $2, now() + make_interval(days => $3))
     RETURNING id, expires_at`,
    [signupCodeHash(normalizeSignupCode(code)!), createdBy, SIGNUP_CODE_DAYS],
  );
  return { id: rows[0]!.id, code, expiresAt: rows[0]!.expires_at.getTime() };
}
