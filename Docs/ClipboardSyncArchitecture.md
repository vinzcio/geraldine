# Geraldine Account and Sync Architecture

## Product contract

Geraldine remains useful while offline. Clipboard capture, search, retention,
pinning, and paste all use the local encrypted vault first. Signing in adds
roaming preferences, widget layout, and cross-device clipboard history without
making the VPS part of the copy/paste hot path.

The server is the synchronization authority, not the plaintext authority.
Clipboard payloads are encrypted on the originating Mac and can only be
decrypted by devices enrolled in the same Geraldine account.

## Data ownership

### Roams between devices

- Clipboard retention and capture preferences
- Clipboard history, except file payloads
- Pinned state and deletions
- Menu bar widget layout
- Calendar presentation and world-clock preferences
- Keep Awake defaults, but never a currently running session
- Power Tools preferences
- Network rate unit
- App presentation preference

### Stays on each Mac

- Accessibility, Full Disk Access, location, and other OS permissions
- Launch-at-login registration
- Active Keep Awake state and timers
- Hardware identity, metrics, charts, scans, and caches
- Clipboard file contents and security-scoped file access
- Local vault key and device private keys

## Authentication — as built

Geraldine owns its identity service outright, implemented with **Better Auth**
on the same Node process that serves the sync API and the website. It is not
OAuth/OIDC; that was the original proposal and was replaced because Geraldine is
its own first-party client and had no third-party relying parties to serve.

1. Email and password, with mandatory email verification. An unverified account
   cannot sign in, enroll a device, or push.
2. Cloudflare Turnstile guards sign-up, sign-in, and password reset.
3. The website authenticates with a session cookie; the Mac app presents
   `Authorization: Bearer` via Better Auth's bearer plugin and declares
   `Origin: geraldine://app`, a trusted origin, because Better Auth rejects
   origin-less state-changing requests as CSRF.
4. The Mac creates a Secure Enclave signing key when available, otherwise a
   non-exportable Keychain key, and registers its public key as a device.
5. Every mutation includes a device ID, monotonic device sequence, timestamp,
   and Ed25519 signature. The server rejects replays and sequence rollback.
6. Devices are revoked individually; a revoked public key can never re-enroll.

Account recovery rotates the account encryption key and explicitly warns that
previously encrypted clipboard payloads are unrecoverable unless a device that
is still signed in completes the re-wrap.

## End-to-end clipboard encryption — as built

Each account owns a random 256-bit account key, wrapped with a key derived from
the user's password on the client. The server stores only the wrapped blob.

The password itself never reaches the server. The client derives:

```
master  = PBKDF2-HMAC-SHA256(password, SHA-256("geraldine-account-v1|" + email), 650_000)
authKey = HKDF-SHA256(master, "geraldine-auth-v1")   -> sent to Better Auth as the password
wrapKey = HKDF-SHA256(master, "geraldine-wrap-v1")   -> never transmitted
```

This is what keeps "one password" honest: Better Auth necessarily receives
whatever is presented as the password, so what is presented is a derived value
from which `wrapKey` cannot be recovered.

The salt is derived locally from the normalized email rather than fetched, which
avoids an unauthenticated endpoint that would confirm whether an address is
registered. PBKDF2 is used over Argon2id because it is native on both WebCrypto
and macOS CommonCrypto; the algorithm name and iteration count are stored per
account so this can move to Argon2id without stranding existing users.

`cloud/src/lib/crypto.ts` is the normative definition. The Swift client must
match it byte for byte.

Device-to-device key wrapping (a trusted Mac wrapping the account key to a new
device's public key) was the original design and is strictly stronger, but it
cannot enroll a device unless another one is online. It remains the upgrade path
if password-derived wrapping proves too weak a guarantee.

Each clipboard entry is encoded as a bounded canonical envelope and encrypted
with AES-256-GCM using a fresh random nonce. Associated data binds:

- account ID
- entry ID
- schema version
- originating device ID
- creation timestamp
- content kind

The server may see routing metadata needed for synchronization, but never
clipboard previews or payload representations. Search remains local after
decryption. Settings that are not sensitive may use authenticated transport
encryption; using the same encrypted-envelope pipeline keeps the storage model
uniform and limits accidental disclosure.

## Synchronization protocol

All endpoints are under `/v1` and require TLS 1.3, an access token with the
Geraldine audience, device ID, request ID, and device signature.

Routes are served under `/api/v1` rather than a bare `/v1`, because the service
is a Next.js app that also serves the website from the same origin.

### Account and device endpoints

- `GET`/`PUT /api/v1/account/key` reads and write-once stores the wrapped
  account key with its KDF parameters.
- `POST /api/v1/devices` registers a device public key and display name.
- `GET /api/v1/devices` lists enrolled and revoked devices.
- `DELETE /api/v1/devices/{id}` revokes a device.

### Delta endpoints

- `POST /api/v1/sync/push` accepts an idempotent batch of encrypted mutations.
- `GET /api/v1/sync/pull?deviceId=...&cursor=...` returns ordered mutations, a
  new cursor, and any active deletion barriers.
- `POST /api/v1/sync/ack` records the cursor a device has applied.
- `POST /api/v1/sync/purge` raises a delete-all barrier for one dataset.
- `GET /api/v1/health` reports liveness and which protections are active.

A mutation contains:

```json
{
  "mutationID": "uuid",
  "dataset": "clipboard|preferences|widget-layout",
  "recordID": "uuid-or-stable-key",
  "operation": "upsert|delete",
  "deviceID": "uuid",
  "deviceSequence": 42,
  "modifiedAt": "RFC3339",
  "schemaVersion": 1,
  "ciphertext": "base64",
  "signature": "base64"
}
```

The server enforces unique `(account_id, mutation_id)` and
`(device_id, device_sequence)`, caps batch and record sizes, and commits a batch
transactionally. Pull is cursor-based and ordered by a server-assigned sequence,
so clock skew cannot omit changes.

## Merge rules

- Clipboard entries are an add-only set keyed by UUID until a delete tombstone.
- Pin changes are last-writer-wins using server sequence.
- Deletions always beat older updates and remain as tombstones until every
  active device has acknowledged a later cursor or the device has expired.
- Preferences merge by stable key, not as one large blob.
- Widget layout is one versioned document. Concurrent edits use last-writer-wins
  and preserve the losing version briefly for recovery.
- Unknown schema versions are retained but not applied.

## Retention and deletion

Local retention runs immediately and emits tombstones for synchronized entries.
The VPS independently enforces the account's retention policy as a backstop.
Pinned entries are exempt until unpinned. Deleting all history creates an
account-wide deletion barrier so an offline device cannot resurrect old entries.

Revoked devices stop receiving deltas immediately. Account deletion places the
account in a short recovery window, then destroys wrapped account keys and
purges encrypted records, tombstones, refresh tokens, and device registrations.

## Server storage and operations

Recommended production shape:

- PostgreSQL for accounts, devices, refresh-token families, cursors, mutations,
  encrypted settings, and tombstones
- Object storage only for bounded encrypted binary payloads that exceed the
  inline database threshold
- A background retention/compaction worker
- Reverse proxy with automatic certificate renewal and strict transport headers
- Encrypted backups with tested point-in-time recovery

Never log authorization headers, refresh tokens, ciphertext bodies, clipboard
metadata values, or device signatures. Audit logs contain account-scoped hashed
identifiers, endpoint, outcome, request ID, and coarse timing.

Rate-limit by account, device, IP reputation, and endpoint. Alert on replay
failures, token-family reuse, repeated signature failure, abnormal encrypted
payload volume, and retention worker lag.

## Delivery order

1. ~~Ship and prove the local encrypted clipboard workflow.~~ Done.
2. ~~Build the auth/resource service, schema, and website.~~ Done, in `cloud/`,
   proven locally by `cloud/scripts/e2e.ts`.
3. Confirm the VPS host and public API domain, then deploy with Turnstile keys,
   a mail provider, and a verified sender domain.
4. Add Geraldine sign-in and device enrollment to the Mac app, with tokens in
   Keychain and the signing key in the Secure Enclave.
5. Sync preferences and widget layout first, then encrypted clipboard deltas.
6. Add the retention/compaction worker and key recovery.
7. Exercise two real Macs through offline edits, clock skew, revocation,
   retention, delete-all, restore-from-backup, and lost-device scenarios.

### Open design item: native sign-in behind CAPTCHA

Turnstile guards `/sign-in/email`, which the Mac app cannot satisfy — it has no
browser to render the widget. The intended fix is Better Auth's one-time-token
plugin: the Mac opens the website in `ASWebAuthenticationSession`, the user
signs in there (widget and all), and the browser hands back a single-use token
the app exchanges for a session. This must be settled before the Mac client's
sign-in is written; sending credentials straight from the app would either
bypass the CAPTCHA or be blocked by it.

