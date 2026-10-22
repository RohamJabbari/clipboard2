// External services behind small interfaces so tests can swap them for fakes.
import { Storage } from "@google-cloud/storage";

export interface BlobStorage {
  signedPutUrl(path: string, size: number): Promise<{ url: string; headers: Record<string, string>; expiresAt: number }>;
  signedGetUrl(path: string): Promise<{ url: string; expiresAt: number }>;
  delete(paths: string[]): Promise<void>;
}

const PUT_TTL_MS = 15 * 60 * 1000;
const GET_TTL_MS = 15 * 60 * 1000;

/** Keyless V4 signing: on Cloud Run the runtime SA signs through IAM Credentials (needs Token Creator on itself). */
export function gcsStorage(bucketName: string): BlobStorage {
  const bucket = new Storage().bucket(bucketName);
  return {
    async signedPutUrl(path, size) {
      const expiresAt = Date.now() + PUT_TTL_MS;
      const headers = { "content-type": "application/octet-stream", "x-goog-content-length-range": `0,${size}` };
      const [url] = await bucket.file(path).getSignedUrl({
        version: "v4",
        action: "write",
        expires: expiresAt,
        contentType: headers["content-type"],
        extensionHeaders: { "x-goog-content-length-range": headers["x-goog-content-length-range"] },
      });
      return { url, headers, expiresAt };
    },
    async signedGetUrl(path) {
      const expiresAt = Date.now() + GET_TTL_MS;
      const [url] = await bucket.file(path).getSignedUrl({ version: "v4", action: "read", expires: expiresAt });
      return { url, expiresAt };
    },
    async delete(paths) {
      await Promise.all(paths.map((p) => bucket.file(p).delete({ ignoreNotFound: true })));
    },
  };
}
