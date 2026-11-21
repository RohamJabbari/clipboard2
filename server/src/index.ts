import { buildApp } from "./app.js";
import { config, limits } from "./config.js";
import { migrate, openPool } from "./db.js";
import { diskStorage } from "./diskStorage.js";
import { gcsStorage } from "./services.js";

const c = config();
const l = limits();
const { pool, close } = await openPool();
const applied = await migrate(pool);

// Cloud Run keeps blobs in a bucket; a self-hosted server keeps them on its own disk.
const disk = c.blobDir ? diskStorage({ dir: c.blobDir, publicUrl: required("PUBLIC_URL", c.publicUrl), signingKey: required("BLOB_SIGNING_KEY", c.blobSigningKey), maxBytes: l.blobBytes }) : undefined;
const app = buildApp({
  pool,
  storage: disk?.storage ?? gcsStorage(c.bucket),
  limits: l,
  logger: true,
});
await disk?.routes(app);
if (applied.length) app.log.info({ applied }, "migrations applied");

const shutdown = async () => {
  await app.close();
  await close();
  process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

await app.listen({ host: "0.0.0.0", port: c.port });

function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`${name} must be set when BLOB_DIR is`);
  return value;
}
