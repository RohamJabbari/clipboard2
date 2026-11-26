import { buildApp } from "./app.js";
import { config, features, googleClientIds, limits, serverSecret } from "./config.js";
import { migrate, openPool } from "./db.js";
import { gcsStorage } from "./services.js";
import { migrateEmails, serverKeys } from "./keys.js";
import { googleVerifier } from "./google.js";

const c = config();
// Fails before anything listens: emails and recovery escrow shares are encrypted with it.
const keys = serverKeys(serverSecret());
const { pool, close } = await openPool();
const applied = await migrate(pool);
const emails = await migrateEmails(pool, keys);
const app = buildApp({
  pool,
  storage: gcsStorage(c.bucket),
  limits: limits(),
  logger: true,
  keys,
  features: features(),
  google: googleVerifier({ clientIds: googleClientIds() }),
});
if (applied.length) app.log.info({ applied }, "migrations applied");
if (emails) app.log.info({ emails }, "emails encrypted");

const shutdown = async () => {
  await app.close();
  await close();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

await app.listen({ host: "0.0.0.0", port: c.port });
