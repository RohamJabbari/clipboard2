const int = (name: string, fallback: number) => {
  const raw = process.env[name];
  const value = raw === undefined ? fallback : Number(raw);
  if (!Number.isFinite(value)) throw new Error(`${name} must be a number`);
  return value;
};

export interface Limits {
  itemBytes: number;
  blobBytes: number;
  userBytes: number;
  nonHistoryPerSpace: number;
  groupsOwned: number;
  membersPerGroup: number;
  historyPerSpace: number;
  requestsPerMinute: number;
  /** GET /v1/heads, per session (device), outside requestsPerMinute. */
  headsPerMinute: number;
  /** Longest a GET /v1/heads with `wait` is held open waiting for a change. */
  headsWaitSeconds: number;
  authPerMinutePerIp: number;
  authPerMinutePerEmail: number;
  invitesPerMinute: number;
  pendingInvitesPerGroup: number;
  tombstoneDays: number;
  groupBytes: number;
  groupItems: number;
  totalBytes: number;
  signupCodesPerUser: number;
  contactsPerUser: number;
  pendingContactRequests: number;
  contactCodesPerUser: number;
  authenticatorsPerUser: number;
  sharedAuthenticatorsPerUser: number;
  sharesPerAuthenticator: number;
  trustedProxyHops: number;
  scryptConcurrency: number;
  scryptQueue: number;
  /** Passwordless (docs/features/passwordless.md). */
  deviceRequestMinutes: number;
  /** Device requests and recovery starts are counted in fixed windows of this many minutes. */
  requestWindowMinutes: number;
  deviceRequestsPerAccount: number;
  deviceRequestsPerIp: number;
  deviceRequestsPerDeviceKey: number;
  devicePollsPerMinute: number;
  denyBlockDays: number;
  denyPauseMinutes: number;
  recoveryWaitHours: number;
  recoveryPauseHours: number;
  /** How long after its release time a recovery can still be picked up. */
  recoveryPickupDays: number;
  emailCodeMinutes: number;
  emailCodesPerHour: number;
}

export const limits = (): Limits => ({
  itemBytes: int("LIMIT_ITEM_BYTES", 2 * 1024 * 1024),
  blobBytes: int("LIMIT_BLOB_BYTES", 100 * 1024 * 1024),
  userBytes: int("LIMIT_USER_BYTES", 1024 * 1024 * 1024),
  nonHistoryPerSpace: int("LIMIT_NON_HISTORY_PER_SPACE", 5000),
  groupsOwned: int("LIMIT_GROUPS_OWNED", 20),
  membersPerGroup: int("LIMIT_MEMBERS_PER_GROUP", 50),
  historyPerSpace: int("HISTORY_PER_SPACE", 200),
  requestsPerMinute: int("RATE_REQUESTS_PER_MINUTE", 120),
  headsPerMinute: int("RATE_HEADS_PER_MINUTE", 90),
  headsWaitSeconds: int("HEADS_WAIT_SECONDS", 25),
  authPerMinutePerIp: int("RATE_AUTH_PER_MINUTE_PER_IP", 20),
  authPerMinutePerEmail: int("RATE_AUTH_PER_MINUTE_PER_EMAIL", 10),
  invitesPerMinute: int("RATE_INVITES_PER_MINUTE", 20),
  pendingInvitesPerGroup: int("LIMIT_PENDING_INVITES_PER_GROUP", 20),
  tombstoneDays: int("TOMBSTONE_DAYS", 90),
  groupBytes: int("LIMIT_GROUP_BYTES", 2 * 1024 * 1024 * 1024),
  groupItems: int("LIMIT_GROUP_ITEMS", 5000),
  totalBytes: int("LIMIT_TOTAL_BYTES", 20 * 1024 * 1024 * 1024),
  signupCodesPerUser: int("LIMIT_SIGNUP_CODES_PER_USER", 10),
  contactsPerUser: int("LIMIT_CONTACTS_PER_USER", 200),
  pendingContactRequests: int("LIMIT_PENDING_CONTACT_REQUESTS", 50),
  contactCodesPerUser: int("LIMIT_CONTACT_CODES_PER_USER", 20),
  authenticatorsPerUser: int("LIMIT_AUTHENTICATORS_PER_USER", 200),
  sharedAuthenticatorsPerUser: int("LIMIT_SHARED_AUTHENTICATORS_PER_USER", 200),
  sharesPerAuthenticator: int("LIMIT_SHARES_PER_AUTHENTICATOR", 20),
  trustedProxyHops: int("TRUSTED_PROXY_HOPS", 1),
  scryptConcurrency: int("SCRYPT_CONCURRENCY", 2),
  scryptQueue: int("SCRYPT_QUEUE", 8),
  deviceRequestMinutes: int("DEVICE_REQUEST_MINUTES", 5),
  requestWindowMinutes: int("REQUEST_WINDOW_MINUTES", 10),
  deviceRequestsPerAccount: int("RATE_DEVICE_REQUESTS_PER_ACCOUNT", 5),
  deviceRequestsPerIp: int("RATE_DEVICE_REQUESTS_PER_IP", 10),
  deviceRequestsPerDeviceKey: int("RATE_DEVICE_REQUESTS_PER_DEVICE_KEY", 3),
  devicePollsPerMinute: int("RATE_DEVICE_POLLS_PER_MINUTE", 40),
  denyBlockDays: int("DENY_BLOCK_DAYS", 30),
  denyPauseMinutes: int("DENY_PAUSE_MINUTES", 60),
  recoveryWaitHours: int("RECOVERY_WAIT_HOURS", 72),
  recoveryPauseHours: int("RECOVERY_PAUSE_HOURS", 24),
  recoveryPickupDays: int("RECOVERY_PICKUP_DAYS", 7),
  emailCodeMinutes: int("EMAIL_CODE_MINUTES", 15),
  emailCodesPerHour: int("RATE_EMAIL_CODES_PER_HOUR", 5),
});

/** The Mac app's Google OAuth client ("Clipboard2 Mac", Desktop app): the `aud` of its ID tokens. */
export const MAC_GOOGLE_CLIENT_ID = "120641536104-qq1me16vfqkfhh8rmt39pknuv4ulsia9.apps.googleusercontent.com";

const flag = (name: string) => ["1", "true", "yes", "on"].includes((process.env[name] ?? "").toLowerCase());

export interface Features {
  /** Email verification codes and the email recovery method. Off until mail sending exists. */
  emailCodes: boolean;
  /** Trust `x-client-geo-country` / `x-client-geo-city` (only behind a load balancer that sets them). */
  geoHeaders: boolean;
}

export const features = (): Features => ({ emailCodes: flag("FEATURE_EMAIL_CODES"), geoHeaders: flag("GEO_HEADERS") });

/** SERVER_SECRET (base64, ≥ 32 bytes) from Secret Manager. Required: emails and escrow shares are encrypted with it. */
export function serverSecret(): Buffer {
  const raw = process.env.SERVER_SECRET;
  if (!raw) throw new Error("SERVER_SECRET is not set (base64, at least 32 random bytes; see docs/features/passwordless.md)");
  const secret = Buffer.from(raw, "base64");
  if (secret.length < 32) throw new Error("SERVER_SECRET must decode to at least 32 bytes");
  return secret;
}

export const googleClientIds = () =>
  (process.env.GOOGLE_CLIENT_IDS ?? MAC_GOOGLE_CLIENT_ID)
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

export const config = () => ({
  port: int("PORT", 8080),
  databaseUrl: process.env.DATABASE_URL,
  instanceConnectionName: process.env.INSTANCE_CONNECTION_NAME ?? "pjlogistik-platform:europe-west1:pjlogistik-datasource",
  dbUser: process.env.DB_USER ?? "clipboard2@rohams-tools.iam",
  dbName: process.env.DB_NAME ?? "clipboard2-db",
  dbPoolMax: int("DB_POOL_MAX", 4),
  bucket: process.env.BUCKET ?? "clipboard2",
  // Self-hosting: with BLOB_DIR set, blobs are kept on disk and served by this API (diskStorage.ts)
  // instead of a Cloud Storage bucket. PUBLIC_URL is the address clients reach the API at.
  blobDir: process.env.BLOB_DIR,
  publicUrl: process.env.PUBLIC_URL,
  blobSigningKey: process.env.BLOB_SIGNING_KEY,
});
