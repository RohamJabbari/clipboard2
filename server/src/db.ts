import { createHash } from "node:crypto";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { join } from "node:path";
import pg from "pg";
import { AuthTypes, Connector, IpAddressTypes } from "@google-cloud/cloud-sql-connector";
import { config } from "./config.js";

// Return int8 as JS numbers: seq values and byte counts stay far below 2^53.
pg.types.setTypeParser(pg.types.builtins.INT8, (value) => Number(value));

export type Db = pg.Pool;

/** Local/test runs use DATABASE_URL; Cloud Run connects through the Cloud SQL connector with IAM auth. */
export async function openPool(): Promise<{ pool: Db; close: () => Promise<void> }> {
  const c = config();
  if (c.databaseUrl) {
    const pool = new pg.Pool({ connectionString: c.databaseUrl, max: c.dbPoolMax });
    return { pool, close: () => pool.end() };
  }
  const connector = new Connector();
  const options = await connector.getOptions({
    instanceConnectionName: c.instanceConnectionName,
    ipType: IpAddressTypes.PUBLIC,
    authType: AuthTypes.IAM,
  });
  const pool = new pg.Pool({ ...options, user: c.dbUser, database: c.dbName, max: c.dbPoolMax, idleTimeoutMillis: 30_000 });
  return {
    pool,
    close: async () => {
      await pool.end();
      connector.close();
    },
  };
}

// src/db.ts under tsx, dist/src/db.js when built: the migrations folder sits at the package root.
const migrationsDir = ["../migrations", "../../migrations"]
  .map((p) => fileURLToPath(new URL(p, import.meta.url)))
  .find((p) => existsSync(p))!;

/**
 * Applies migrations/NNN_*.sql in order, once, under an advisory lock so concurrent instances don't
 * race. Each file and its schema_migrations row commit together or not at all. Applied files are
 * frozen: their SHA-256 is recorded, and startup fails loudly if one was edited afterwards (add a new
 * NNN_ file instead). Rows from before checksums existed adopt the file's current checksum.
 */
export async function migrate(pool: Db, dir = migrationsDir): Promise<string[]> {
  const client = await pool.connect();
  const applied: string[] = [];
  try {
    await client.query("SELECT pg_advisory_lock(727001)");
    await client.query("CREATE TABLE IF NOT EXISTS schema_migrations (name text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())");
    await client.query("ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum text");
    const done = new Map(
      (await client.query<{ name: string; checksum: string | null }>("SELECT name, checksum FROM schema_migrations")).rows.map((r) => [r.name, r.checksum]),
    );
    for (const name of readdirSync(dir).filter((f) => f.endsWith(".sql")).sort()) {
      const sql = readFileSync(join(dir, name), "utf8");
      const checksum = createHash("sha256").update(sql).digest("hex");
      if (done.has(name)) {
        const recorded = done.get(name);
        if (recorded === null) await client.query("UPDATE schema_migrations SET checksum = $2 WHERE name = $1", [name, checksum]);
        else if (recorded !== checksum) throw new Error(`Migration ${name} was edited after it was applied; revert it and add a new migration instead`);
        continue;
      }
      await client.query("BEGIN");
      try {
        await client.query(sql);
        await client.query("INSERT INTO schema_migrations (name, checksum) VALUES ($1, $2)", [name, checksum]);
        await client.query("COMMIT");
        applied.push(name);
      } catch (error) {
        await client.query("ROLLBACK");
        throw new Error(`Migration ${name} failed and was rolled back: ${(error as Error).message}`, { cause: error });
      }
    }
  } finally {
    await client.query("SELECT pg_advisory_unlock(727001)").catch(() => {});
    client.release();
  }
  return applied;
}

/** Runs `fn` in a transaction on one pooled client. */
export async function tx<T>(pool: Db, fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const result = await fn(client);
    await client.query("COMMIT");
    return result;
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}
