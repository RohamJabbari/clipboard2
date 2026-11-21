// The self-hosted blob store: signed URLs, create-only uploads, size limits, path safety.
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import Fastify, { type FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { diskStorage } from "../src/diskStorage.js";

const space = "11111111-1111-4111-8111-111111111111";
const blob = "22222222-2222-4222-8222-222222222222";
const path = `${space}/${blob}`;
const base = "https://sync.test";

let dir: string;
let app: FastifyInstance;
let store: ReturnType<typeof diskStorage>;

beforeAll(async () => {
  dir = await mkdtemp(join(tmpdir(), "clipboard2-blobs-"));
  store = diskStorage({ dir, publicUrl: `${base}/`, signingKey: "k".repeat(32), maxBytes: 1024 });
  app = Fastify();
  await store.routes(app);
});

afterAll(async () => {
  await app.close();
  await rm(dir, { recursive: true, force: true });
});

const local = (url: string) => url.slice(base.length);
const put = (url: string, body: Buffer) => app.inject({ method: "PUT", url: local(url), headers: { "content-type": "application/octet-stream" }, payload: body });

describe("disk blob storage", () => {
  it("stores an upload and serves it back through signed URLs", async () => {
    const ticket = await store.storage.signedPutUrl(path, 16);
    expect(ticket.url.startsWith(`${base}/blob/${path}?`)).toBe(true);
    expect(ticket.headers["x-goog-content-length-range"]).toBe("0,16");
    expect((await put(ticket.url, Buffer.from("hello"))).statusCode).toBe(200);

    const read = await app.inject({ method: "GET", url: local((await store.storage.signedGetUrl(path)).url) });
    expect(read.statusCode).toBe(200);
    expect(read.body).toBe("hello");
  });

  it("answers 412 when a create-only upload already exists, and leaves the first copy", async () => {
    const ticket = await store.storage.signedPutUrl(path, 16, { ifGenerationMatch: true });
    expect(ticket.headers["x-goog-if-generation-match"]).toBe("0");
    expect((await put(ticket.url, Buffer.from("other"))).statusCode).toBe(412);
    const read = await app.inject({ method: "GET", url: local((await store.storage.signedGetUrl(path)).url) });
    expect(read.body).toBe("hello");
  });

  it("refuses uploads larger than the URL was signed for", async () => {
    const ticket = await store.storage.signedPutUrl(path, 4);
    expect((await put(ticket.url, Buffer.from("too long"))).statusCode).toBe(413);
  });

  it("refuses a tampered, borrowed or expired link", async () => {
    const write = (await store.storage.signedPutUrl(path, 16)).url;
    const read = (await store.storage.signedGetUrl(path)).url;
    // A bigger size, another blob, a read link used to write, and no signature at all.
    expect((await put(write.replace("size=16", "size=999"), Buffer.from("x"))).statusCode).toBe(403);
    expect((await put(write.replace(blob, space), Buffer.from("x"))).statusCode).toBe(403);
    expect((await put(read, Buffer.from("x"))).statusCode).toBe(403);
    expect((await app.inject({ method: "GET", url: `/blob/${path}` })).statusCode).toBe(403);
    expect((await app.inject({ method: "GET", url: local(read).replace(/exp=\d+/, "exp=1") })).statusCode).toBe(403);
  });

  it("never touches paths outside the blob directory", async () => {
    expect((await app.inject({ method: "GET", url: "/blob/..%2F..%2Fetc/passwd?exp=1&sig=x" })).statusCode).toBe(403);
    await expect(store.storage.delete(["../outside", path])).resolves.toBeUndefined();
    expect((await app.inject({ method: "GET", url: local((await store.storage.signedGetUrl(path)).url) })).statusCode).toBe(404);
  });
});
