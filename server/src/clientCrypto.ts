// Reference implementation of the client-side crypto in docs/sync/PROTOCOL.md. The server never
// calls this at runtime; it generates the test vectors and lets the tests act as a real client.
import {
  createCipheriv,
  createDecipheriv,
  createECDH,
  createHash,
  hkdfSync,
  pbkdf2Sync,
  randomBytes,
} from "node:crypto";

export const AEAD_VERSION = 0x01;
export const KDF_ITERATIONS = 600_000;

const BASE32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

export function aeadSeal(key: Buffer, plaintext: Buffer, aad: string, nonce: Buffer = randomBytes(12)): Buffer {
  const cipher = createCipheriv("aes-256-gcm", key, nonce);
  cipher.setAAD(Buffer.from(aad, "utf8"));
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([Buffer.from([AEAD_VERSION]), nonce, body, cipher.getAuthTag()]);
}

export function aeadOpen(key: Buffer, sealed: Buffer, aad: string): Buffer {
  if (sealed.length < 29 || sealed[0] !== AEAD_VERSION) throw new Error("bad AEAD envelope");
  const nonce = sealed.subarray(1, 13);
  const tag = sealed.subarray(sealed.length - 16);
  const decipher = createDecipheriv("aes-256-gcm", key, nonce);
  decipher.setAAD(Buffer.from(aad, "utf8"));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(sealed.subarray(13, sealed.length - 16)), decipher.final()]);
}

export function hkdf(ikm: Buffer, salt: Buffer, info: string): Buffer {
  return Buffer.from(hkdfSync("sha256", ikm, salt, Buffer.from(info, "utf8"), 32));
}

export function kek(password: string, salt: Buffer, iterations: number): Buffer {
  return pbkdf2Sync(Buffer.from(password.normalize("NFC"), "utf8"), salt, iterations, 32, "sha256");
}

/** master = PBKDF2(password); authKey goes to the server, wrapKey never leaves the device. */
export function passwordKeys(password: string, salt: Buffer, iterations: number) {
  const master = kek(password, salt, iterations);
  return { master, authKey: hkdf(master, Buffer.alloc(0), "clipboard2 auth"), wrapKey: hkdf(master, Buffer.alloc(0), "clipboard2 wrap") };
}

export interface KeyPair {
  priv: Buffer; // 32-byte scalar
  pub: Buffer; // 65-byte X9.63 uncompressed
}

export function keyPair(priv?: Buffer): KeyPair {
  const ecdh = createECDH("prime256v1");
  if (priv) ecdh.setPrivateKey(priv);
  else ecdh.generateKeys();
  return { priv: ecdh.getPrivateKey(), pub: ecdh.getPublicKey(undefined, "uncompressed") };
}

export function ecdh(priv: Buffer, pub: Buffer): Buffer {
  const e = createECDH("prime256v1");
  e.setPrivateKey(priv);
  return e.computeSecret(pub);
}

export const aad = {
  accountKey: (uid: string) => `c2/ak/v1/${uid}`,
  privateKey: (uid: string) => `c2/priv/v1/${uid}`,
  spaceKey: (spaceId: string, memberUid: string) => `c2/space/v1/${spaceId}/${memberUid}`,
  item: (spaceId: string, itemId: string, category: string) => `c2/item/v1/${spaceId}/${itemId}/${category}`,
  blob: (spaceId: string, blobId: string) => `c2/blob/v1/${spaceId}/${blobId}`,
  name: (spaceId: string) => `c2/name/v1/${spaceId}`,
};

export function wrapSpaceKey(
  sk: Buffer,
  spaceId: string,
  memberUid: string,
  memberPub: Buffer,
  eph: KeyPair = keyPair(),
  nonce?: Buffer,
): Buffer {
  const wk = hkdf(ecdh(eph.priv, memberPub), Buffer.concat([eph.pub, memberPub]), `c2/space/v1/${spaceId}`);
  return Buffer.concat([eph.pub, aeadSeal(wk, sk, aad.spaceKey(spaceId, memberUid), nonce)]);
}

export function unwrapSpaceKey(wrapped: Buffer, spaceId: string, me: { uid: string } & KeyPair): Buffer {
  const ephPub = wrapped.subarray(0, 65);
  const wk = hkdf(ecdh(me.priv, ephPub), Buffer.concat([ephPub, me.pub]), `c2/space/v1/${spaceId}`);
  return aeadOpen(wk, wrapped.subarray(65), aad.spaceKey(spaceId, me.uid));
}

export const itemKey = (sk: Buffer) => hkdf(sk, Buffer.alloc(0), "c2/item/v1");
export const nameKey = (sk: Buffer) => hkdf(sk, Buffer.alloc(0), "c2/name/v1");

export const sha256Hex = (data: Buffer | string) => createHash("sha256").update(data).digest("hex");

// MARK: Invite codes

export function base32(bytes: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = "";
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += BASE32[(value << (5 - bits)) & 31];
  return out;
}

/** 16 code bytes -> "XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XX". */
export const formatInviteCode = (codeBytes: Buffer) => base32(codeBytes).match(/.{1,4}/g)!.join("-");

/** Inverse of formatInviteCode, forgiving spaces, dashes, case and 0/1/8 misreadings; null when invalid. */
export function parseInviteCode(typed: string): Buffer | null {
  const clean = typed.replace(/[\s-]/g, "").toUpperCase().replace(/0/g, "O").replace(/1/g, "I").replace(/8/g, "B");
  if (clean.length !== 26) return null;
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const index = BASE32.indexOf(ch);
    if (index < 0) return null;
    value = ((value << 5) | index) & 0xffff;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  if ((value & ((1 << bits) - 1)) !== 0) return null;
  return Buffer.from(out);
}

export const inviteId = (codeBytes: Buffer) => sha256Hex(codeBytes);
export const inviteKey = (codeBytes: Buffer) => hkdf(codeBytes, Buffer.alloc(0), "clipboard2 invite");
export const inviteAad = (spaceId: string) => `c2/invite/v1/${spaceId}`;
