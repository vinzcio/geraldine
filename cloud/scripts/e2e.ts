/**
 * End-to-end proof of the account and sync contract, against a running server.
 *
 *   npm run dev
 *   node scripts/e2e.ts
 *
 * Simulates two Macs: one signs up and pushes an encrypted clipboard entry, the
 * other signs in on the same account, unwraps the account key from its own
 * password derivation, pulls the entry, and decrypts it. If the plaintext comes
 * out the other side, the whole chain holds.
 */

import {
  KDF_ALGORITHM,
  KDF_ITERATIONS,
  deriveSecrets,
  fromBase64,
  generateAccountKey,
  toBase64,
  unwrapAccountKey,
  wrapAccountKey,
} from "../src/lib/crypto.ts";
import { canonicalMutationString } from "../src/server/mutation.ts";
import pg from "pg";

const BASE = process.env.BASE_URL ?? "http://localhost:4319";
const email = `e2e-${crypto.randomUUID().slice(0, 8)}@geraldine.test`;
const password = "correct horse battery staple";

let failures = 0;

function check(label: string, condition: boolean, detail?: unknown) {
  if (condition) {
    console.log(`  ✓ ${label}`);
  } else {
    failures += 1;
    console.error(`  ✗ ${label}`, detail ?? "");
  }
}

async function api(
  path: string,
  init: RequestInit & { token?: string } = {},
): Promise<{ status: number; body: any; token?: string }> {
  const headers = new Headers(init.headers);
  // Stand in for the Mac app, which declares this origin.
  headers.set("Origin", "geraldine://app");
  if (init.token) headers.set("Authorization", `Bearer ${init.token}`);
  if (init.body) headers.set("Content-Type", "application/json");

  const response = await fetch(`${BASE}${path}`, { ...init, headers });
  const text = await response.text();
  return {
    status: response.status,
    body: text ? JSON.parse(text) : null,
    token: response.headers.get("set-auth-token") ?? undefined,
  };
}

// ---------------------------------------------------------------------------

console.log(`\nGeraldine cloud end-to-end · ${BASE}\n`);

console.log("Mac A — sign up");
const a = await deriveSecrets(email, password);
check("password never equals the transmitted secret", a.authKey !== password);

const signUp = await api("/api/auth/sign-up/email", {
  method: "POST",
  body: JSON.stringify({ name: "E2E", email, password: a.authKey }),
});
check("account created", signUp.status === 200, signUp.body);
check("sign-up grants no session before verification", !signUp.token);

const blockedSignIn = await api("/api/auth/sign-in/email", {
  method: "POST",
  body: JSON.stringify({ email, password: a.authKey }),
});
check("unverified account cannot sign in", blockedSignIn.status >= 400, blockedSignIn.body);

// Stands in for the user clicking the emailed confirmation link.
await markEmailVerified(email);

const verifiedSignIn = await api("/api/auth/sign-in/email", {
  method: "POST",
  body: JSON.stringify({ email, password: a.authKey }),
});
check("verified account can sign in", verifiedSignIn.status === 200, verifiedSignIn.body);
const tokenA = verifiedSignIn.token!;
check("bearer token issued", Boolean(tokenA));

const accountKey = generateAccountKey();
const wrapped = await wrapAccountKey(accountKey, a.wrapKey);
const keyPut = await api("/api/v1/account/key", {
  method: "PUT",
  token: tokenA,
  body: JSON.stringify({
    kdfAlgorithm: KDF_ALGORITHM,
    kdfIterations: KDF_ITERATIONS,
    kdfSalt: a.salt,
    ...wrapped,
  }),
});
check("wrapped account key stored", keyPut.status === 201, keyPut.body);

const keyReplay = await api("/api/v1/account/key", {
  method: "PUT",
  token: tokenA,
  body: JSON.stringify({
    kdfAlgorithm: KDF_ALGORITHM,
    kdfIterations: KDF_ITERATIONS,
    kdfSalt: a.salt,
    ...wrapped,
  }),
});
check("account key is write-once", keyReplay.status === 409, keyReplay.body);

console.log("\nMac A — enroll device");
const keysA = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
  "sign",
  "verify",
])) as CryptoKeyPair;
const publicA = toBase64(
  new Uint8Array(await crypto.subtle.exportKey("raw", keysA.publicKey)),
);
const deviceA = await api("/api/v1/devices", {
  method: "POST",
  token: tokenA,
  body: JSON.stringify({ name: "Mac A", platform: "macos", publicKey: publicA }),
});
check("device enrolled", deviceA.status === 201, deviceA.body);
const deviceIdA: string = deviceA.body.device.id;

console.log("\nMac A — push an encrypted entry");
const secretText = "the eagle lands at dawn";
const recordId = crypto.randomUUID();
const ciphertext = await sealForAccount(accountKey, secretText);

const mutation = {
  mutationId: crypto.randomUUID(),
  dataset: "clipboard" as const,
  recordId,
  operation: "upsert" as const,
  deviceId: deviceIdA,
  deviceSequence: 1,
  modifiedAt: new Date().toISOString(),
  schemaVersion: 1,
  ciphertext,
};
const signature = toBase64(
  new Uint8Array(
    await crypto.subtle.sign(
      { name: "Ed25519" },
      keysA.privateKey,
      new TextEncoder().encode(canonicalMutationString(mutation)),
    ),
  ),
);

const push = await api("/api/v1/sync/push", {
  method: "POST",
  token: tokenA,
  body: JSON.stringify({
    deviceId: deviceIdA,
    mutations: [{ ...mutation, deviceId: undefined, signature }],
  }),
});
check("push accepted", push.status === 200 && push.body.accepted === 1, push.body);

const replay = await api("/api/v1/sync/push", {
  method: "POST",
  token: tokenA,
  body: JSON.stringify({
    deviceId: deviceIdA,
    mutations: [{ ...mutation, deviceId: undefined, signature }],
  }),
});
check("replayed sequence rejected", replay.status === 409, replay.body);

const forged = await api("/api/v1/sync/push", {
  method: "POST",
  token: tokenA,
  body: JSON.stringify({
    deviceId: deviceIdA,
    mutations: [
      {
        ...mutation,
        deviceId: undefined,
        mutationId: crypto.randomUUID(),
        deviceSequence: 2,
        recordId: "tampered",
        signature,
      },
    ],
  }),
});
check("tampered mutation rejected", forged.status === 400, forged.body);

console.log("\nMac B — sign in and pull");
const signIn = await api("/api/auth/sign-in/email", {
  method: "POST",
  body: JSON.stringify({ email, password: a.authKey }),
});
check("second sign-in works", signIn.status === 200, signIn.body);
const tokenB = signIn.token!;

const keyGet = await api("/api/v1/account/key", { token: tokenB });
check("wrapped key retrievable", Boolean(keyGet.body?.accountKey), keyGet.body);

// Mac B knows only the email and password; it re-derives everything else.
const b = await deriveSecrets(email, password, keyGet.body.accountKey.kdfIterations);
const unwrapped = await unwrapAccountKey(
  {
    wrappedAccountKey: keyGet.body.accountKey.wrappedAccountKey,
    wrapNonce: keyGet.body.accountKey.wrapNonce,
  },
  b.wrapKey,
);
check(
  "account key unwrapped from password alone",
  toBase64(unwrapped) === toBase64(accountKey),
);

const keysB = (await crypto.subtle.generateKey({ name: "Ed25519" }, true, [
  "sign",
  "verify",
])) as CryptoKeyPair;
const deviceB = await api("/api/v1/devices", {
  method: "POST",
  token: tokenB,
  body: JSON.stringify({
    name: "Mac B",
    platform: "macos",
    publicKey: toBase64(
      new Uint8Array(await crypto.subtle.exportKey("raw", keysB.publicKey)),
    ),
  }),
});
check("second device enrolled", deviceB.status === 201, deviceB.body);
const deviceIdB: string = deviceB.body.device.id;

const pull = await api(`/api/v1/sync/pull?deviceId=${deviceIdB}&cursor=0`, {
  token: tokenB,
});
check("pull returned the entry", pull.body?.mutations?.length === 1, pull.body);

const received = pull.body.mutations[0];
const plaintext = await openForAccount(unwrapped, received.ciphertext);
check("clipboard text survived the round trip", plaintext === secretText, plaintext);
check("record id preserved", received.recordId === recordId);

const ack = await api("/api/v1/sync/ack", {
  method: "POST",
  token: tokenB,
  body: JSON.stringify({ deviceId: deviceIdB, cursor: pull.body.cursor }),
});
check("ack recorded", ack.status === 200 && ack.body.ackedSeq === pull.body.cursor, ack.body);

console.log("\nIsolation");
const otherEmail = `e2e-${crypto.randomUUID().slice(0, 8)}@geraldine.test`;
const other = await deriveSecrets(otherEmail, password);
await api("/api/auth/sign-up/email", {
  method: "POST",
  body: JSON.stringify({ name: "Other", email: otherEmail, password: other.authKey }),
});
await markEmailVerified(otherEmail);
const otherSignIn = await api("/api/auth/sign-in/email", {
  method: "POST",
  body: JSON.stringify({ email: otherEmail, password: other.authKey }),
});
const otherPull = await api(`/api/v1/sync/pull?deviceId=${deviceIdB}&cursor=0`, {
  token: otherSignIn.token,
});
check("another account cannot use this device id", otherPull.status === 403, otherPull.body);

const anonymous = await api(`/api/v1/sync/pull?deviceId=${deviceIdB}&cursor=0`);
check("unauthenticated pull rejected", anonymous.status === 401, anonymous.body);

console.log("\nRevocation");
const revoke = await api(`/api/v1/devices/${deviceIdB}`, {
  method: "DELETE",
  token: tokenB,
});
check("device revoked", revoke.status === 200, revoke.body);
const afterRevoke = await api(`/api/v1/sync/pull?deviceId=${deviceIdB}&cursor=0`, {
  token: tokenB,
});
check("revoked device cannot pull", afterRevoke.status === 403, afterRevoke.body);

console.log(
  failures === 0 ? "\nAll checks passed.\n" : `\n${failures} check(s) failed.\n`,
);
process.exit(failures === 0 ? 0 : 1);

// ---------------------------------------------------------------------------

/** Flips the verification flag, standing in for the emailed link being opened. */
async function markEmailVerified(address: string): Promise<void> {
  const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
  try {
    await pool.query(`update "user" set email_verified = true where email = $1`, [
      address,
    ]);
  } finally {
    await pool.end();
  }
}

async function sealForAccount(accountKey: Uint8Array, text: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    accountKey.buffer.slice(0) as ArrayBuffer,
    "AES-GCM",
    false,
    ["encrypt"],
  );
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: nonce.buffer.slice(0) as ArrayBuffer },
      key,
      new TextEncoder().encode(text),
    ),
  );
  const envelope = new Uint8Array(nonce.length + sealed.length);
  envelope.set(nonce);
  envelope.set(sealed, nonce.length);
  return toBase64(envelope);
}

async function openForAccount(accountKey: Uint8Array, envelope: string): Promise<string> {
  const bytes = fromBase64(envelope);
  const key = await crypto.subtle.importKey(
    "raw",
    accountKey.buffer.slice(0) as ArrayBuffer,
    "AES-GCM",
    false,
    ["decrypt"],
  );
  const opened = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytes.slice(0, 12).buffer.slice(0) as ArrayBuffer },
    key,
    bytes.slice(12).buffer.slice(0) as ArrayBuffer,
  );
  return new TextDecoder().decode(opened);
}
