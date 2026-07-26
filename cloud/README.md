# Geraldine Cloud

Account service, website, and sync API for Geraldine. Next.js + Better Auth +
Drizzle + PostgreSQL, deployed as one Node process.

## What it does

- Email/password accounts with mandatory email verification (Better Auth)
- Cloudflare Turnstile on sign-up, sign-in, and password reset
- Per-device enrollment with Ed25519 signing keys
- An ordered, idempotent mutation log that Macs push to and pull from
- Stores only ciphertext: it cannot read clipboard contents (see below)

## The encryption boundary

One password, but the server never receives it. The client derives:

```
master  = PBKDF2-HMAC-SHA256(password, SHA-256("geraldine-account-v1|" + email), 650_000)
authKey = HKDF-SHA256(master, "geraldine-auth-v1")   -> sent to Better Auth as the password
wrapKey = HKDF-SHA256(master, "geraldine-wrap-v1")   -> never transmitted
```

A random 256-bit account key is wrapped with `wrapKey` and stored here sealed.
Clipboard payloads are AES-256-GCM under the account key. The server holds
routing metadata (record id, dataset, timestamps, sequence) and nothing else.

`src/lib/crypto.ts` is the normative definition. The Swift client must match it
byte for byte, so treat any change there as a protocol change.

**Consequence:** a forgotten password cannot be recovered by us. Password reset
re-keys the account; already-synced history stays readable only if a signed-in
Mac completes the re-wrap.

## Local development

```bash
createdb geraldine_dev
cp .env.example .env.local          # then set BETTER_AUTH_SECRET
npm install
npm run db:migrate
npm run dev                          # http://localhost:4319
```

With no `RESEND_API_KEY`, verification and reset emails print to the server log —
copy the URL from there. With no Turnstile keys, CAPTCHA is skipped rather than
failing closed, so sign-up still works on a fresh checkout.

### End-to-end check

```bash
node scripts/e2e.ts
```

Drives two simulated Macs through sign-up, verification, key wrap, device
enrollment, push, pull, decrypt, ack, cross-account isolation, and revocation.
It talks to whatever `BASE_URL` points at, so it doubles as a smoke test against
a deployed instance.

## Configuration

| Variable | Required | Purpose |
| --- | --- | --- |
| `DATABASE_URL` | yes | PostgreSQL connection string |
| `BETTER_AUTH_URL` | yes | Public origin; must match what the Mac app targets |
| `BETTER_AUTH_SECRET` | yes | `openssl rand -base64 48` |
| `TRUSTED_ORIGINS` | no | Extra allowed origins, comma-separated |
| `TURNSTILE_SECRET_KEY` | prod | Cloudflare Turnstile secret |
| `NEXT_PUBLIC_TURNSTILE_SITE_KEY` | prod | Cloudflare Turnstile site key |
| `RESEND_API_KEY` | prod | Transactional email |
| `EMAIL_FROM` | prod | Sender identity on a verified domain |

`GET /api/v1/health` reports which of these are actually active, so a
deployment that is quietly missing its CAPTCHA secret or mail provider is
visible without reading logs.

## API

All routes require a Better Auth session — cookie from the website, or
`Authorization: Bearer` from the Mac app. Native clients must also send
`Origin: geraldine://app`, which is a trusted origin; Better Auth rejects
origin-less state-changing requests as CSRF.

| Method | Path | Purpose |
| --- | --- | --- |
| `GET`/`PUT` | `/api/v1/account/key` | Wrapped account key. `PUT` is write-once. |
| `GET`/`POST` | `/api/v1/devices` | List / enroll a device |
| `DELETE` | `/api/v1/devices/{id}` | Revoke a device |
| `POST` | `/api/v1/sync/push` | Signed, idempotent batch of mutations |
| `GET` | `/api/v1/sync/pull` | Ordered deltas after a cursor |
| `POST` | `/api/v1/sync/ack` | Record applied cursor |
| `POST` | `/api/v1/sync/purge` | Delete-all barrier for one dataset |
| `GET` | `/api/v1/health` | Liveness and active protections |

### Push guarantees

- `(user_id, mutation_id)` unique, conflicts ignored — safe to retry a batch
- `(device_id, device_sequence)` unique and strictly increasing — replay is
  rejected with `409 sequence_rollback`
- Every mutation carries an Ed25519 signature over the canonical string in
  `src/server/mutation.ts`; one bad signature rejects the whole batch
- Ordering is by server-assigned `server_seq`, so device clock skew cannot
  reorder or hide changes

## Deployment

Not yet deployed. Before the first deploy, decide the public domain and set
`BETTER_AUTH_URL` to it; the Mac app pins the same origin.

Production shape:

1. PostgreSQL with encrypted backups and tested point-in-time recovery
2. `npm run build && npm run start` behind a reverse proxy terminating TLS 1.3
3. `npm run db:migrate` as a release step, before traffic
4. Turnstile keys, Resend key, and a verified sender domain configured
5. `GET /api/v1/health` as the readiness probe

Never log authorization headers, verification or reset URLs, ciphertext, or
device signatures. `src/server/context.ts` writes audit rows that deliberately
carry none of those.
