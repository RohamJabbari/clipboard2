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
  authPerMinutePerIp: number;
  authPerMinutePerEmail: number;
  invitesPerMinute: number;
  pendingInvitesPerGroup: number;
  tombstoneDays: number;
  groupBytes: number;
  groupItems: number;
  totalBytes: number;
  signupCodesPerUser: number;
  scryptConcurrency: number;
  scryptQueue: number;
}

export const limits = (): Limits => ({
  itemBytes: int("LIMIT_ITEM_BYTES", 2 * 1024 * 1024),
  blobBytes: int("LIMIT_BLOB_BYTES", 25 * 1024 * 1024),
  userBytes: int("LIMIT_USER_BYTES", 1024 * 1024 * 1024),
  nonHistoryPerSpace: int("LIMIT_NON_HISTORY_PER_SPACE", 5000),
  groupsOwned: int("LIMIT_GROUPS_OWNED", 20),
  membersPerGroup: int("LIMIT_MEMBERS_PER_GROUP", 50),
  historyPerSpace: int("HISTORY_PER_SPACE", 200),
  requestsPerMinute: int("RATE_REQUESTS_PER_MINUTE", 120),
  authPerMinutePerIp: int("RATE_AUTH_PER_MINUTE_PER_IP", 20),
  authPerMinutePerEmail: int("RATE_AUTH_PER_MINUTE_PER_EMAIL", 10),
  invitesPerMinute: int("RATE_INVITES_PER_MINUTE", 20),
  pendingInvitesPerGroup: int("LIMIT_PENDING_INVITES_PER_GROUP", 20),
  tombstoneDays: int("TOMBSTONE_DAYS", 90),
  groupBytes: int("LIMIT_GROUP_BYTES", 2 * 1024 * 1024 * 1024),
  groupItems: int("LIMIT_GROUP_ITEMS", 5000),
  totalBytes: int("LIMIT_TOTAL_BYTES", 20 * 1024 * 1024 * 1024),
  signupCodesPerUser: int("LIMIT_SIGNUP_CODES_PER_USER", 10),
  scryptConcurrency: int("SCRYPT_CONCURRENCY", 2),
  scryptQueue: int("SCRYPT_QUEUE", 8),
});

export const config = () => ({
  port: int("PORT", 8080),
  databaseUrl: process.env.DATABASE_URL,
  instanceConnectionName: process.env.INSTANCE_CONNECTION_NAME ?? "pjlogistik-platform:europe-west1:pjlogistik-datasource",
  dbUser: process.env.DB_USER ?? "clipboard2@rohams-tools.iam",
  dbName: process.env.DB_NAME ?? "clipboard2-db",
  dbPoolMax: int("DB_POOL_MAX", 4),
  bucket: process.env.BUCKET ?? "clipboard2",
});
