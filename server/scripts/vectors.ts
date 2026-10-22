// Generates docs/sync/test-vectors.json: fixed inputs (derived from labels) and the exact outputs
// both clients must reproduce. Run: npm run vectors
import { writeFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import {
  aad,
  aeadOpen,
  aeadSeal,
  ecdh,
  formatInviteCode,
  hkdf,
  inviteAad,
  inviteId,
  inviteKey,
  itemKey,
  kek,
  keyPair,
  nameKey,
  parseInviteCode,
  passwordKeys,
  unwrapSpaceKey,
  wrapSpaceKey,
} from "../src/clientCrypto.js";

const fixed = (label: string, length = 32) =>
  createHash("sha256").update(`clipboard2-vector/${label}`).digest().subarray(0, length);
const b64 = (b: Buffer) => b.toString("base64");

const uid = "vHn3bq0ZtWQ2dXo9JpL7cA1sR4e2";
const spaceId = "0b4f6a8e-2d1c-4e7a-9b3f-5c6d7e8f9a0b";
const itemId = "f1e2d3c4-b5a6-4978-8a9b-0c1d2e3f4a5b";
const blobId = "a0b1c2d3-e4f5-4a6b-8c7d-9e0f1a2b3c4d";

const pbkdf2 = [
  { password: "correct horse battery staple", iterations: 1000 },
  { password: "café", iterations: 1000 },
  // Same password as above written decomposed (e + U+0301): NFC must make the keys equal.
  { password: "café", iterations: 1000 },
  { password: "Zürich-🔑-2026", iterations: 600_000 },
].map((v, i) => {
  const salt = fixed(`pbkdf2-salt-${i % 3 === 2 ? 1 : i}`, 16);
  return { ...v, salt: b64(salt), kek: b64(kek(v.password, salt, v.iterations)) };
});

const aeadVectors = [
  { plaintext: Buffer.from("hello clipboard"), aad: "c2/test/v1" },
  { plaintext: Buffer.alloc(0), aad: "" },
  { plaintext: fixed("aead-long", 32), aad: "c2/test/v1/binary" },
].map((v, i) => {
  const key = fixed(`aead-key-${i}`);
  const nonce = fixed(`aead-nonce-${i}`, 12);
  return { key: b64(key), nonce: b64(nonce), aad: v.aad, plaintext: b64(v.plaintext), sealed: b64(aeadSeal(key, v.plaintext, v.aad, nonce)) };
});

const hkdfVectors = [
  { ikm: fixed("hkdf-ikm-0"), salt: Buffer.alloc(0), info: "c2/item/v1" },
  { ikm: fixed("hkdf-ikm-1"), salt: fixed("hkdf-salt-1", 130), info: "c2/space/v1/" + spaceId },
].map((v) => ({ ikm: b64(v.ikm), salt: b64(v.salt), info: v.info, okm: b64(hkdf(v.ikm, v.salt, v.info)) }));

const a = keyPair(fixed("ecdh-a"));
const b = keyPair(fixed("ecdh-b"));
const ecdhVector = { privA: b64(a.priv), pubA: b64(a.pub), privB: b64(b.priv), pubB: b64(b.pub), shared: b64(ecdh(a.priv, b.pub)) };
if (!ecdh(b.priv, a.pub).equals(ecdh(a.priv, b.pub))) throw new Error("ECDH asymmetric");

// Full account bootstrap.
const password = "correct horse battery staple";
const salt = fixed("account-salt", 16);
const keys = passwordKeys(password, salt, 1000);
const accountKek = keys.wrapKey;
const ak = fixed("account-ak");
const id = keyPair(fixed("account-id"));
const account = {
  uid,
  password,
  salt: b64(salt),
  iterations: 1000,
  master: b64(keys.master),
  authKey: b64(keys.authKey),
  wrapKey: b64(keys.wrapKey),
  accountKey: b64(ak),
  akNonce: b64(fixed("account-ak-nonce", 12)),
  wrappedAccountKey: b64(aeadSeal(accountKek, ak, aad.accountKey(uid), fixed("account-ak-nonce", 12))),
  idPriv: b64(id.priv),
  idPub: b64(id.pub),
  privNonce: b64(fixed("account-priv-nonce", 12)),
  wrappedPrivateKey: b64(aeadSeal(ak, id.priv, aad.privateKey(uid), fixed("account-priv-nonce", 12))),
};

const sk = fixed("space-sk");
const eph = keyPair(fixed("space-eph"));
const wrapNonce = fixed("space-wrap-nonce", 12);
const wrapped = wrapSpaceKey(sk, spaceId, uid, id.pub, eph, wrapNonce);
if (!unwrapSpaceKey(wrapped, spaceId, { uid, ...id }).equals(sk)) throw new Error("space unwrap failed");
const spaceWrap = {
  spaceId,
  memberUid: uid,
  memberPriv: b64(id.priv),
  memberPub: b64(id.pub),
  ephPriv: b64(eph.priv),
  ephPub: b64(eph.pub),
  nonce: b64(wrapNonce),
  spaceKey: b64(sk),
  wrappedKey: b64(wrapped),
};

const payload = JSON.stringify({
  v: 1,
  type: "clip",
  kind: "text",
  text: "Grüße aus Wien 👋",
  preview: "Grüße aus Wien 👋",
  sourceId: "com.apple.Safari",
  sourceName: "Safari",
  isPinned: false,
  copyCount: 2,
  createdAt: 1792396800000,
  lastCopiedAt: 1792400400000,
  contentHash: "text:" + createHash("sha256").update("Grüße aus Wien 👋").digest("hex"),
});
const ik = itemKey(sk);
const itemNonce = fixed("item-nonce", 12);
const item = {
  spaceId,
  itemId,
  category: "history",
  spaceKey: b64(sk),
  itemKey: b64(ik),
  nonce: b64(itemNonce),
  payload,
  ciphertext: b64(aeadSeal(ik, Buffer.from(payload, "utf8"), aad.item(spaceId, itemId, "history"), itemNonce)),
};

const blobPlain = fixed("blob-bytes", 32);
const blobNonce = fixed("blob-nonce", 12);
const blob = {
  spaceId,
  blobId,
  nonce: b64(blobNonce),
  plaintext: b64(blobPlain),
  ciphertext: b64(aeadSeal(ik, blobPlain, aad.blob(spaceId, blobId), blobNonce)),
};

const nk = nameKey(sk);
const nameNonce = fixed("name-nonce", 12);
const groupName = {
  spaceId,
  nameKey: b64(nk),
  nonce: b64(nameNonce),
  name: "Team Wien",
  encryptedName: b64(aeadSeal(nk, Buffer.from("Team Wien", "utf8"), aad.name(spaceId), nameNonce)),
};

const codeBytes = fixed("invite-code", 16);
const code = formatInviteCode(codeBytes);
if (!parseInviteCode(code)?.equals(codeBytes)) throw new Error("invite code round trip failed");
const typo = code.toLowerCase().replace(/-/g, " ");
if (!parseInviteCode(typo)?.equals(codeBytes)) throw new Error("lenient parse failed");
const inviteNonce = fixed("invite-nonce", 12);
const invite = {
  codeBytes: b64(codeBytes),
  code,
  typedVariants: [typo, code.replace(/-/g, "")],
  invalidCodes: [code.slice(0, -1), code + "A", code.replace(/^./, "9")],
  inviteId: inviteId(codeBytes),
  inviteKey: b64(inviteKey(codeBytes)),
  spaceId,
  spaceKey: b64(sk),
  nonce: b64(inviteNonce),
  sealedKey: b64(aeadSeal(inviteKey(codeBytes), sk, inviteAad(spaceId), inviteNonce)),
};
for (const bad of invite.invalidCodes) if (parseInviteCode(bad)) throw new Error("accepted invalid code " + bad);

// Self-check every sealed value opens again.
for (const v of aeadVectors) aeadOpen(Buffer.from(v.key, "base64"), Buffer.from(v.sealed, "base64"), v.aad);

const out = {
  description:
    "Clipboard2 sync v1 crypto vectors (docs/sync/PROTOCOL.md). All byte values are base64. " +
    "Clients must reproduce every output from its inputs (sealing with the given nonce) and open every sealed value.",
  pbkdf2,
  aead: aeadVectors,
  hkdf: hkdfVectors,
  ecdh: ecdhVector,
  account,
  spaceWrap,
  item,
  blob,
  groupName,
  invite,
};

const target = fileURLToPath(new URL("../../docs/sync/test-vectors.json", import.meta.url));
writeFileSync(target, JSON.stringify(out, null, 2) + "\n");
console.log("wrote", target);
