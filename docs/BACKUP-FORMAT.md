# Encrypted backup format (`.clipboard2backup`), version 1

One file holds a user's history, pinned items, snippets and, if they opt in, secrets, encrypted with a
passphrase. The Mac and Windows apps write and read the same bytes, so a backup made on one opens on the
other.

## File layout

All integers are big-endian. The header is 37 bytes.

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 4 | magic | ASCII `C2BK` (`43 32 42 4B`) |
| 4 | 1 | version | `0x01` |
| 5 | 16 | salt | random, new for every export |
| 21 | 4 | iterations | PBKDF2 iteration count, uint32. Writers use 600 000 |
| 25 | 12 | nonce | random, new for every export |
| 37 | n | ciphertext | AES-256-GCM ciphertext of the plaintext below |
| 37 + n | 16 | tag | the GCM tag |

```
key        = PBKDF2-HMAC-SHA256(utf8(NFC(passphrase)), salt, iterations, 32 bytes)
ciphertext ‖ tag = AES-256-GCM(key, nonce, plaintext, aad = header[0..37])
```

- The passphrase is Unicode-normalised to NFC before UTF-8 encoding. It isn't trimmed.
- The whole 37-byte header is the AAD, so changing the version, salt, iteration count or nonce makes
  decryption fail.
- **Readers** refuse a file that is shorter than 53 bytes (header + tag) or has the wrong magic ("not a Clipboard2 backup"),
  a version other than 1 ("made by a newer version"), or iterations outside 600 000–10 000 000 (the same
  bounds as sync's KDF). A failed GCM check means the passphrase is wrong or the file is damaged; the two
  can't be told apart.

## Plaintext

UTF-8 JSON, one object:

```jsonc
{
  "format": "clipboard2-backup",
  "version": 1,
  "createdAt": 1793000000000,          // ms since the Unix epoch
  "app": "mac",                        // "mac" or "windows": who wrote it
  "clips":    [ /* ClipPayload + extras, below */ ],
  "snippets": [ /* SnippetPayload + "id" */ ],
  "secrets":  [ /* SecretPayload + "id" */ ]   // omitted unless the user opted in
}
```

Readers check `format` and that `version` is 1, ignore unknown fields, and treat a missing array as empty.

### `clips`

Each entry is a clip payload exactly as in [sync/PROTOCOL.md → Item payloads](sync/PROTOCOL.md#item-payloads)
(`"v":1,"type":"clip","kind",…,"contentHash"`), plus:

| Field | Meaning |
|---|---|
| `id` | the item's id on the exporting device (lowercase hyphenated UUID) |
| `image` | image items: the full PNG, standard base64 with padding |
| `thumb` | image items: the thumbnail PNG, standard base64. Optional: without it the reader makes one or uses the image |
| `files` | file items: the file URLs as in ClipPayload (`file:///…`). Only names/paths, never contents |

Sync-only fields are left out: `imageBlob`, `thumbBlob`, `fileBlobs` and `rev`. Readers ignore them if they're
present. `isPinned`, `pinnedAt` and `label` carry pins and labels, so pinned items need no separate list.
Writers include every item of the **personal** space (history and pinned). Items of sync groups belong to
the group and aren't exported.

### `snippets`

A snippet payload (`"v":1,"type":"snippet","name","keyword","body","createdAt","updatedAt"`) plus `"id"`.
Personal snippets only.

### `secrets`

Only present when the user ticked "Include secrets" and confirmed with Touch ID or Windows Hello. Each
entry is a secret payload (`"v":1,"type":"secret","name","value","createdAt"`) plus `"id"`. Personal
secrets only. The values are in the plaintext, protected only by the passphrase.

## Import

Import merges into the personal space and never deletes or overwrites anything:

- **Clips:** skipped when the personal space already has an item with the same `contentHash`, or an earlier
  entry in the same file had it. Otherwise inserted with a **new** local id (the backup's `id` is informational),
  keeping `createdAt`, `lastCopiedAt`, `copyCount`, pin and label. Images are written from `image`/`thumb`;
  an image entry without a decodable `image` is skipped.
- **Snippets:** skipped when one with the same `(name, body)` exists. Otherwise inserted with a new id.
- **Secrets:** skipped when one with the same `(name, value)` exists. Otherwise added as a new secret.
- The usual rules then apply: retention (pinned items exempt), and a history item whose text equals a saved
  secret is removed.

The app reports what was added and what was skipped as duplicates, e.g. "Imported 120 items, 3 snippets.
Skipped 14 duplicates."

## Test vector

Both apps check this in their tests (Windows: `BackupTests.KnownVectorMatchesAnIndependentPbkdf2AndRoundTrips`;
the key was cross-checked with Python's `hashlib.pbkdf2_hmac`, and the file opens with CryptoKit's `AES.GCM`).

| Input | Value |
|---|---|
| passphrase | `"Café au lait"` (decomposed é; NFC gives `"Café au lait"`, and either spelling must open the file) |
| salt | `000102030405060708090a0b0c0d0e0f` |
| iterations | 600000 |
| nonce | `6465666768696a6b6c6d6e6f` |
| plaintext | `{"format":"clipboard2-backup","version":1,"createdAt":1793000000000,"app":"windows","clips":[],"snippets":[]}` (UTF-8, no trailing newline) |
| key | `52af8dbc9bc46ea3202e6d4bb4bbc39e03dba6ea450508f2a6ae2c9384f869e7` |

The whole file, hex:

```
4332424b01000102030405060708090a0b0c0d0e0f000927c06465666768696a6b6c6d6e6f
4575ea611c9565db9a2d81ac903b4a6d006ef7eb18f72d336234d8b490f47cbeb6efce54b328ce2dfef844f1cb7c9630
db80fb98b2d549bf9badd65eedcfd4b5da33604c5113e1c34a31b8b85d887790471d2560145cecec18e8259cfbd24e50
1d4db673457d60367dc74e47098ec46650d735ff39451841825200f278
```

(The first line is the 37-byte header; the last 16 bytes are the tag.)

## Example

A Windows export with one text clip, one image and no secrets (pretty-printed; real files are compact):

```json
{"format":"clipboard2-backup","version":1,"createdAt":1793000000000,"app":"windows",
 "clips":[
  {"v":1,"type":"clip","kind":"text","text":"hello","preview":"hello","byteCount":5,"isPinned":false,
   "copyCount":1,"createdAt":1792990000000,"lastCopiedAt":1792990000000,"contentHash":"text:…","id":"6f1c…"},
  {"v":1,"type":"clip","kind":"image","text":"","preview":"Image 640×480","imageWidth":640,"imageHeight":480,
   "byteCount":81234,"isPinned":true,"pinnedAt":1792995000000,"copyCount":2,"createdAt":1792980000000,
   "lastCopiedAt":1792995000000,"contentHash":"image:…","id":"a07e…","image":"iVBORw0KGgo…","thumb":"iVBORw0KGgo…"}],
 "snippets":[{"v":1,"type":"snippet","name":"Sig","keyword":";sig","body":"Best, R.","createdAt":1792000000000,
   "updatedAt":1792000000000,"id":"0c9d…"}]}
```
