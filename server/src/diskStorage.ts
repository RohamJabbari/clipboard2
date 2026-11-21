// Blob storage on the server's own disk, for running the API outside Google Cloud.
//
// It keeps the contract the clients already speak with Cloud Storage: the API hands out a
// short-lived signed URL plus the headers to send, the client PUTs or GETs the bytes there
// without a session token, a create-only upload answers 412 when the object exists. The
// signature is an HMAC over method, path, expiry, size limit and the create-only flag, so a URL
// can't be reused for another object, grown, or turned from a read into a write.
import { createHmac, randomUUID, timingSafeEqual } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { link, mkdir, rename, rm, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { Transform, type Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import type { FastifyInstance } from "fastify";
import type { BlobStorage } from "./services.js";

const TTL_MS = 15 * 60 * 1000;
const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
/** Blob paths are `<space id>/<blob id>`; nothing else ever reaches the file system. */
const PATH = new RegExp(`^${UUID}/${UUID}$`);
const ROUTE = "/blob/:space/:blob";

export interface DiskStorageOptions {
  /** Directory the blobs live in. */
  dir: string;
  /** Address clients reach this server at, without a trailing slash. */
  publicUrl: string;
  /** Secret the URLs are signed with. */
  signingKey: string;
  /** Largest upload the routes accept, whatever a URL says. */
  maxBytes: number;
}

class TooLarge extends Error {}

export function diskStorage(options: DiskStorageOptions): { storage: BlobStorage; routes: (app: FastifyInstance) => Promise<void> } {
  const { dir, signingKey, maxBytes } = options;
  const publicUrl = options.publicUrl.replace(/\/+$/, "");
  if (signingKey.length < 32) throw new Error("BLOB_SIGNING_KEY must be at least 32 characters");

  const sign = (method: "GET" | "PUT", path: string, expiresAt: number, size: number, once: boolean) =>
    createHmac("sha256", signingKey).update([method, path, expiresAt, size, once ? 1 : 0].join("\n")).digest("hex");

  const verified = (method: "GET" | "PUT", path: string, query: Record<string, string | undefined>) => {
    const expiresAt = Number(query.exp);
    const size = Number(query.size ?? 0);
    const once = query.once === "1";
    if (!PATH.test(path) || !Number.isSafeInteger(expiresAt) || !Number.isSafeInteger(size) || size < 0) return undefined;
    const expected = Buffer.from(sign(method, path, expiresAt, size, once));
    const given = Buffer.from(query.sig ?? "");
    if (given.length !== expected.length || !timingSafeEqual(given, expected)) return undefined;
    return { expired: expiresAt < Date.now(), size, once };
  };

  const url = (method: "GET" | "PUT", path: string, expiresAt: number, size: number, once: boolean) => {
    const query = new URLSearchParams({ exp: String(expiresAt), sig: sign(method, path, expiresAt, size, once) });
    if (method === "PUT") {
      query.set("size", String(size));
      query.set("once", once ? "1" : "0");
    }
    return `${publicUrl}/blob/${path}?${query}`;
  };

  const storage: BlobStorage = {
    async signedPutUrl(path, size, { ifGenerationMatch = false } = {}) {
      const expiresAt = Date.now() + TTL_MS;
      // The same header names Cloud Storage uses, so clients need no second code path.
      const headers: Record<string, string> = { "content-type": "application/octet-stream", "x-goog-content-length-range": `0,${size}` };
      if (ifGenerationMatch) headers["x-goog-if-generation-match"] = "0";
      return { url: url("PUT", path, expiresAt, size, ifGenerationMatch), headers, expiresAt };
    },
    async signedGetUrl(path) {
      const expiresAt = Date.now() + TTL_MS;
      return { url: url("GET", path, expiresAt, 0, false), expiresAt };
    },
    async delete(paths) {
      await Promise.all(paths.filter((p) => PATH.test(p)).map((p) => rm(join(dir, p), { force: true })));
    },
  };

  /** Registered outside `/v1/`, so the session check doesn't apply: the signature is the credential. */
  const routes = async (app: FastifyInstance) => {
    await app.register(async (scope) => {
      // Hand the upload through as a stream instead of buffering up to 100 MB in memory.
      scope.removeAllContentTypeParsers();
      scope.addContentTypeParser("*", (_request, payload, done) => done(null, payload));

      type Route = { Params: { space: string; blob: string }; Querystring: Record<string, string | undefined> };
      const refuse = (ticket: ReturnType<typeof verified>) =>
        !ticket ? ([403, "forbidden", "That link isn't valid"] as const) : ticket.expired ? ([403, "expired", "That link has expired"] as const) : undefined;

      scope.put<Route>(ROUTE, { bodyLimit: maxBytes }, async (request, reply) => {
        const path = `${request.params.space}/${request.params.blob}`;
        const ticket = verified("PUT", path, request.query);
        const refused = refuse(ticket);
        if (refused || !ticket) return reply.status(refused![0]).send({ error: refused![1], message: refused![2] });

        const limit = Math.min(ticket.size, maxBytes);
        const tooLarge = () => reply.status(413).send({ error: "too_large", message: "Upload is larger than it was registered as" });
        if (Number(request.headers["content-length"] ?? 0) > limit) return tooLarge();

        const target = join(dir, path);
        const partial = `${target}.${randomUUID()}.part`;
        await mkdir(dirname(target), { recursive: true });
        let received = 0;
        const counted = new Transform({
          transform(chunk: Buffer, _encoding, done) {
            received += chunk.length;
            done(received > limit ? new TooLarge() : null, chunk);
          },
        });
        try {
          await pipeline(request.body as Readable, counted, createWriteStream(partial, { flags: "wx", mode: 0o600 }));
          // A hard link fails when the name exists, which makes "create only" atomic.
          if (ticket.once) await link(partial, target);
          else await rename(partial, target);
        } catch (error) {
          if (error instanceof TooLarge) return tooLarge();
          if ((error as NodeJS.ErrnoException).code === "EEXIST") return reply.status(412).send({ error: "exists", message: "That blob is already uploaded" });
          throw error;
        } finally {
          await rm(partial, { force: true });
        }
        return reply.status(200).send();
      });

      scope.get<Route>(ROUTE, async (request, reply) => {
        const path = `${request.params.space}/${request.params.blob}`;
        const refused = refuse(verified("GET", path, request.query));
        if (refused) return reply.status(refused[0]).send({ error: refused[1], message: refused[2] });
        const target = join(dir, path);
        const info = await stat(target).catch(() => undefined);
        if (!info?.isFile()) return reply.status(404).send({ error: "not_found", message: "Not found" });
        return reply.header("content-type", "application/octet-stream").header("content-length", info.size).send(createReadStream(target));
      });
    });
  };

  return { storage, routes };
}
