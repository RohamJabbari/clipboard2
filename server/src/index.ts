import { buildApp } from "./app.js";
import { config, limits } from "./config.js";
import { migrate, openPool } from "./db.js";
import { gcsStorage } from "./services.js";

const c = config();
const { pool, close } = await openPool();
const applied = await migrate(pool);
const app = buildApp({
  pool,
  storage: gcsStorage(c.bucket),
  limits: limits(),
  logger: true,
});
if (applied.length) app.log.info({ applied }, "migrations applied");

const shutdown = async () => {
  await app.close();
  await close();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

await app.listen({ host: "0.0.0.0", port: c.port });
