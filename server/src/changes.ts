import { EventEmitter } from "node:events";
import type pg from "pg";

/**
 * "Something was written": wakes heads requests that wait for a change (PROTOCOL.md → Heads,
 * `wait`). It says nothing about what changed or for whom; a woken request recomputes its heads
 * and goes back to waiting when its own didn't move.
 */
export interface ChangeFeed {
  publish(): void;
  /** Resolves on the next change, after `ms`, or when `signal` aborts, whichever is first. */
  next(ms: number, signal?: AbortSignal): Promise<void>;
  close(): Promise<void>;
}

/** One process: enough for a single server, and the default in tests. */
export function localChanges(): ChangeFeed & { wake(): void } {
  const events = new EventEmitter();
  events.setMaxListeners(0);
  const wake = () => events.emit("change");
  return {
    wake,
    publish: wake,
    next: (ms, signal) =>
      new Promise<void>((resolve) => {
        if (signal?.aborted) return resolve();
        const done = () => {
          clearTimeout(timer);
          events.off("change", done);
          signal?.removeEventListener("abort", done);
          resolve();
        };
        const timer = setTimeout(done, ms);
        events.on("change", done);
        signal?.addEventListener("abort", done, { once: true });
      }),
    close: async () => {
      events.removeAllListeners();
    },
  };
}

const CHANNEL = "clipboard2_changes";

/**
 * Across instances (Cloud Run can run several): each write is sent with pg_notify and every
 * instance LISTENs on one held connection. While that connection is down, the writing instance
 * wakes its own waiters directly and other instances catch up when their waits time out.
 */
export async function postgresChanges(pool: pg.Pool, log: (error: unknown) => void): Promise<ChangeFeed> {
  const local = localChanges();
  let client: pg.PoolClient | undefined;
  let closed = false;
  let retry: NodeJS.Timeout | undefined;

  const listen = async () => {
    try {
      const c = await pool.connect();
      c.on("notification", () => local.wake());
      c.on("error", (error) => {
        log(error);
        c.release(true);
        if (client === c) client = undefined;
        if (!closed) retry = setTimeout(listen, 5_000);
      });
      await c.query(`LISTEN ${CHANNEL}`);
      client = c;
    } catch (error) {
      log(error);
      if (!closed) retry = setTimeout(listen, 5_000);
    }
  };
  await listen();

  return {
    publish: () => {
      if (!client) local.wake();
      pool.query("SELECT pg_notify($1, '')", [CHANNEL]).catch(log);
    },
    next: local.next,
    close: async () => {
      closed = true;
      clearTimeout(retry);
      client?.release();
      await local.close();
    },
  };
}
