// Server-held keys and the passwordless constructions the server itself performs
// (docs/features/passwordless.md → Cryptography): blind-indexed and encrypted emails, the encrypted
// recovery escrow share, wrapping a share to a device key, and the number-matching number.
import { createCipheriv, createDecipheriv, createECDH, createHash, createHmac, hkdfSync, randomBytes } from "node:crypto";
import type { Db } from "./db.js";

const AEAD_VERSION = 0x01;

export function seal(key: Buffer, plaintext: Buffer, aad: string): Buffer {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(Buffer.from(aad, "utf8"));
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([Buffer.from([AEAD_VERSION]), nonce, body, cipher.getAuthTag()]);
}

export function open(key: Buffer, sealed: Buffer, aad: string): Buffer {
  if (sealed.length < 29 || sealed[0] !== AEAD_VERSION) throw new Error("bad AEAD envelope");
  const decipher = createDecipheriv("aes-256-gcm", key, sealed.subarray(1, 13));
  decipher.setAAD(Buffer.from(aad, "utf8"));
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  return Buffer.concat([decipher.update(sealed.subarray(13, sealed.length - 16)), decipher.final()]);
}

const hkdf = (ikm: Buffer, info: string, salt: Buffer = Buffer.alloc(0)) => Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from(info, "utf8"), 32));

export interface ServerKeys {
  emailIndex: Buffer;
  emailEnc: Buffer;
  escrow: Buffer;
}

/** All server-side keys come from one secret (Secret Manager → SERVER_SECRET, base64, ≥ 32 bytes). */
export function serverKeys(secret: Buffer): ServerKeys {
  if (secret.length < 32) throw new Error("SERVER_SECRET must be at least 32 bytes");
  return {
    emailIndex: hkdf(secret, "c2/server/email-index"),
    emailEnc: hkdf(secret, "c2/server/email-enc"),
    escrow: hkdf(secret, "c2/server/escrow"),
  };
}

export const emailIndex = (keys: ServerKeys, email: string) => createHmac("sha256", keys.emailIndex).update(email, "utf8").digest();
export const encryptEmail = (keys: ServerKeys, email: string) => seal(keys.emailEnc, Buffer.from(email, "utf8"), "c2/email/v1");
export const decryptEmail = (keys: ServerKeys, sealed: Buffer) => open(keys.emailEnc, sealed, "c2/email/v1").toString("utf8");
export const sealEscrow = (keys: ServerKeys, share: Buffer, setupId: string) => seal(keys.escrow, share, `c2/escrow/v1/${setupId}`);
export const openEscrow = (keys: ServerKeys, sealed: Buffer, setupId: string) => open(keys.escrow, sealed, `c2/escrow/v1/${setupId}`);

/** `eph.pub ‖ AEAD(HKDF(ECDH(eph, pub), eph.pub ‖ pub, info), secret, aad)`, like wrapSpaceKey. */
export function wrapTo(pub: Buffer, secret: Buffer, info: string, aad: string): Buffer {
  const eph = createECDH("prime256v1");
  eph.generateKeys();
  const ephPub = eph.getPublicKey(undefined, "uncompressed");
  const key = hkdf(eph.computeSecret(pub), info, Buffer.concat([ephPub, pub]));
  return Buffer.concat([ephPub, seal(key, secret, aad)]);
}

export function unwrapFrom(priv: Buffer, wrapped: Buffer, info: string, aad: string): Buffer {
  const me = createECDH("prime256v1");
  me.setPrivateKey(priv);
  const ephPub = wrapped.subarray(0, 65);
  const key = hkdf(me.computeSecret(ephPub), info, Buffer.concat([ephPub, me.getPublicKey(undefined, "uncompressed")]));
  return open(key, wrapped.subarray(65), aad);
}

/** The two-digit number both devices derive from the new device's key: 10…99. */
export function matchNumber(requestId: string, devicePublicKey: Buffer): number {
  const digest = createHash("sha256").update("c2/number/v1", "utf8").update(requestId, "utf8").update(devicePublicKey).digest();
  return 10 + (digest.readUInt32BE(0) % 90);
}

/** True for a valid uncompressed P-256 point (createECDH refuses anything else). */
export function isP256Point(pub: Buffer): boolean {
  if (pub.length !== 65 || pub[0] !== 0x04) return false;
  try {
    const probe = createECDH("prime256v1");
    probe.generateKeys();
    probe.computeSecret(pub);
    return true;
  } catch {
    return false;
  }
}

/**
 * Moves plaintext emails into email_index + email_enc, once per row, at startup. Rows are
 * independent, so a crash halfway just leaves the rest for the next start.
 */
export async function migrateEmails(pool: Db, keys: ServerKeys): Promise<number> {
  const { rows } = await pool.query<{ uid: string; email: string }>("SELECT uid, email FROM users WHERE email IS NOT NULL");
  for (const row of rows) {
    const email = row.email.trim().toLowerCase();
    await pool.query("UPDATE users SET email_index = $2, email_enc = $3, email = NULL WHERE uid = $1 AND email IS NOT NULL", [
      row.uid,
      emailIndex(keys, email),
      encryptEmail(keys, email),
    ]);
  }
  return rows.length;
}
