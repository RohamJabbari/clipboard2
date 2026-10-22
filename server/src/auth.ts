// Password-less-on-the-wire auth: clients send authKey = HKDF(PBKDF2(password)), never the password.
// We store scrypt(authKey) and hand out opaque session tokens, keeping only their SHA-256.
import { createHash, createHmac, randomBytes, scrypt as scryptCb, timingSafeEqual, type ScryptOptions } from "node:crypto";
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
