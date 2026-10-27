# Clipboard2 backup format (`.clipboard2backup`)

Shared by the Mac and Windows apps: a backup made on one restores on the other.

## File layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `"C2BK"` (ASCII) |
| 4 | 1 | version byte `0x01` |
| 5 | 16 | salt |
| 21 | 4 | PBKDF2-SHA256 iterations, uint32 big-endian (`600000`) |
| 25 | 12 | nonce |
| 37 | … | AES-256-GCM ciphertext, followed by the 16-byte tag |

- The 37-byte header is the AAD.
- Key = PBKDF2-SHA256(passphrase NFC-normalised, salt, iterations, 32 bytes).

## Plaintext

UTF-8 JSON:

```jsonc
{
  "format": "clipboard2-backup",
  "version": 1,
  "createdAt": 0,               // ms
  "app": "mac",                 // "mac" | "windows"
  "clips": [ … ],
  "snippets": [ … ],
  "secrets": [ … ]              // omitted unless the user opted in
}
```

- `clips`: ClipPayload as in [sync/PROTOCOL.md](sync/PROTOCOL.md), plus:
  - `"id"`
  - `"image"`: base64 PNG
  - `"thumb"`: base64 PNG
  - `"files"`: only names, no contents
- `snippets`: SnippetPayload + `"id"`.
- `secrets`: SecretPayload + `"id"`, omitted unless the user opted in.

## Import

Import merges without duplicates:

- clips by `contentHash`;
- snippets by (`name`, `body`);
- secrets by (`name`, `value`).
