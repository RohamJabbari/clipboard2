// Verifies Google ID tokens (Continue with Google): RS256 signature against Google's published keys,
// issuer, audience (our OAuth client ids), expiry, age and email_verified. Single use is enforced by
// the caller (used_id_tokens), since it needs the database.
import { createPublicKey, verify as verifySignature, type KeyObject, type webcrypto } from "node:crypto";

type JsonWebKey = webcrypto.JsonWebKey;

export const GOOGLE_JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const ISSUERS = new Set(["accounts.google.com", "https://accounts.google.com"]);
/** A token older than this is refused even if Google still considers it valid (1 h). */
export const MAX_ID_TOKEN_AGE_S = 10 * 60;
const CLOCK_SLACK_S = 60;
const JWKS_TTL_MS = 60 * 60 * 1000;
/** An unknown `kid` refetches the keys, at most this often (key rotation, not a DoS lever). */
const REFETCH_MIN_MS = 60 * 1000;

export interface GoogleIdentity {
  sub: string;
  email: string;
  /** Seconds; the caller remembers the token until then. */
  exp: number;
}

export type JwksFetcher = () => Promise<{ keys: (JsonWebKey & { kid?: string })[] }>;

export class IdTokenError extends Error {}

export const fetchGoogleJwks: JwksFetcher = async () => {
  const res = await fetch(GOOGLE_JWKS_URL);
  if (!res.ok) throw new Error(`Google JWKS answered ${res.status}`);
  return (await res.json()) as { keys: (JsonWebKey & { kid?: string })[] };
};

const b64url = (s: string) => Buffer.from(s.replace(/-/g, "+").replace(/_/g, "/"), "base64");

export interface GoogleVerifier {
  verify(idToken: string): Promise<GoogleIdentity>;
}

export function googleVerifier(options: { clientIds: string[]; fetchJwks?: JwksFetcher; now?: () => number }): GoogleVerifier {
  const fetchJwks = options.fetchJwks ?? fetchGoogleJwks;
  const now = options.now ?? (() => Date.now());
  let cache: { keys: Map<string, KeyObject>; at: number } | undefined;

  const load = async () => {
    const jwks = await fetchJwks();
    const keys = new Map<string, KeyObject>();
    for (const jwk of jwks.keys) {
      if (jwk.kid && jwk.kty === "RSA") keys.set(jwk.kid, createPublicKey({ key: jwk, format: "jwk" }));
    }
    cache = { keys, at: now() };
    return keys;
  };

  const keyFor = async (kid: string) => {
    if (!cache || now() - cache.at > JWKS_TTL_MS) await load();
    let key = cache!.keys.get(kid);
    if (!key && now() - cache!.at > REFETCH_MIN_MS) key = (await load()).get(kid);
    if (!key) throw new IdTokenError("unknown signing key");
    return key;
  };

  return {
    async verify(idToken) {
      const parts = idToken.split(".");
      if (parts.length !== 3) throw new IdTokenError("malformed token");
      let header: { alg?: string; kid?: string };
      let claims: Record<string, unknown>;
      try {
        header = JSON.parse(b64url(parts[0]!).toString("utf8"));
        claims = JSON.parse(b64url(parts[1]!).toString("utf8"));
      } catch {
        throw new IdTokenError("malformed token");
      }
      if (header.alg !== "RS256" || typeof header.kid !== "string") throw new IdTokenError("unexpected algorithm");
      const key = await keyFor(header.kid);
      const signed = Buffer.from(`${parts[0]}.${parts[1]}`, "utf8");
      if (!verifySignature("RSA-SHA256", signed, key, b64url(parts[2]!))) throw new IdTokenError("bad signature");

      const nowS = Math.floor(now() / 1000);
      if (!ISSUERS.has(String(claims.iss))) throw new IdTokenError("wrong issuer");
      const aud = claims.aud;
      if (typeof aud !== "string" || !options.clientIds.includes(aud)) throw new IdTokenError("wrong audience");
      const exp = Number(claims.exp);
      const iat = Number(claims.iat);
      if (!Number.isFinite(exp) || exp + CLOCK_SLACK_S < nowS) throw new IdTokenError("expired");
      if (!Number.isFinite(iat) || iat - CLOCK_SLACK_S > nowS || nowS - iat > MAX_ID_TOKEN_AGE_S) throw new IdTokenError("too old");
      if (claims.email_verified !== true && claims.email_verified !== "true") throw new IdTokenError("email not verified");
      if (typeof claims.email !== "string" || typeof claims.sub !== "string") throw new IdTokenError("no email");
      return { sub: claims.sub, email: claims.email.trim().toLowerCase(), exp };
    },
  };
}
