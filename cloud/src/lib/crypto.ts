/**
 * Geraldine key derivation — the contract shared by the website and the Mac app.
 *
 * You type one password. The client turns it into two independent secrets:
 *
 *   master   = PBKDF2-HMAC-SHA256(password, salt, ITERATIONS, 32)
 *   authKey  = HKDF-SHA256(master, info = "geraldine-auth-v1")   -> sent to the server
 *   wrapKey  = HKDF-SHA256(master, info = "geraldine-wrap-v1")   -> never leaves the client
 *
 * Better Auth receives `authKey`, not the password, so the server cannot
 * reproduce `wrapKey` and therefore cannot unwrap the account key or read any
 * clipboard payload. That property is the whole reason for the extra hop; do
 * not "simplify" this by sending the raw password.
 *
 * The salt is derived from the normalized email rather than fetched from the
 * server. It is not a secret — its only job is to stop one rainbow table from
 * covering every account — and deriving it locally avoids an unauthenticated
 * endpoint that would confirm whether an address is registered.
 *
 * PBKDF2 is used rather than Argon2id because it is available natively on both
 * sides (WebCrypto, and CommonCrypto on macOS) with no vendored C. The KDF name
 * and iteration count are stored per account so this can move to Argon2id later
 * without stranding existing users.
 */

export const KDF_ALGORITHM = "PBKDF2-HMAC-SHA256";
export const KDF_ITERATIONS = 650_000;
const KEY_BYTES = 32;

const AUTH_INFO = "geraldine-auth-v1";
const WRAP_INFO = "geraldine-wrap-v1";
const SALT_PREFIX = "geraldine-account-v1|";

export interface DerivedSecrets {
  /** Base64url. Sent to Better Auth in place of the password. */
  authKey: string;
  /** Raw 32 bytes. Wraps the account key. Must never be transmitted. */
  wrapKey: Uint8Array;
  /** Base64. Stored alongside the account so clients can reproduce derivation. */
  salt: string;
}

export function normalizeEmail(email: string): string {
  return email.trim().toLowerCase();
}

export async function deriveSalt(email: string): Promise<Uint8Array> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    encodeToBuffer(SALT_PREFIX + normalizeEmail(email)),
  );
  return new Uint8Array(digest);
}

export async function deriveSecrets(
  email: string,
  password: string,
  iterations: number = KDF_ITERATIONS,
): Promise<DerivedSecrets> {
  const salt = await deriveSalt(email);

  const passwordKey = await crypto.subtle.importKey(
    "raw",
    encodeToBuffer(password),
    "PBKDF2",
    false,
    ["deriveBits"],
  );
  const masterBits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt: toBufferSource(salt), iterations, hash: "SHA-256" },
    passwordKey,
    KEY_BYTES * 8,
  );

  const master = await crypto.subtle.importKey(
    "raw",
    masterBits,
    "HKDF",
    false,
    ["deriveBits"],
  );
  const [authBits, wrapBits] = await Promise.all([
    hkdf(master, AUTH_INFO),
    hkdf(master, WRAP_INFO),
  ]);

  return {
    authKey: toBase64Url(new Uint8Array(authBits)),
    wrapKey: new Uint8Array(wrapBits),
    salt: toBase64(salt),
  };
}

async function hkdf(master: CryptoKey, info: string): Promise<ArrayBuffer> {
  return crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      // The PBKDF2 salt already bound this to the account; HKDF only needs to
      // separate the two outputs, which `info` does.
      salt: new ArrayBuffer(0),
      info: encodeToBuffer(info),
    },
    master,
    KEY_BYTES * 8,
  );
}

// ---------------------------------------------------------------------------
// Account key
// ---------------------------------------------------------------------------

export interface WrappedAccountKey {
  wrappedAccountKey: string;
  wrapNonce: string;
}

export function generateAccountKey(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(KEY_BYTES));
}

export async function wrapAccountKey(
  accountKey: Uint8Array,
  wrapKey: Uint8Array,
): Promise<WrappedAccountKey> {
  const key = await importAesKey(wrapKey, ["encrypt"]);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const sealed = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: toBufferSource(nonce) },
    key,
    toBufferSource(accountKey),
  );
  return {
    wrappedAccountKey: toBase64(new Uint8Array(sealed)),
    wrapNonce: toBase64(nonce),
  };
}

export async function unwrapAccountKey(
  wrapped: WrappedAccountKey,
  wrapKey: Uint8Array,
): Promise<Uint8Array> {
  const key = await importAesKey(wrapKey, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: toBufferSource(fromBase64(wrapped.wrapNonce)) },
    key,
    toBufferSource(fromBase64(wrapped.wrappedAccountKey)),
  );
  return new Uint8Array(plaintext);
}

function importAesKey(
  raw: Uint8Array,
  usages: KeyUsage[],
): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", toBufferSource(raw), "AES-GCM", false, usages);
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

function encodeToBuffer(value: string): ArrayBuffer {
  return toBufferSource(new TextEncoder().encode(value));
}

/** Narrows to a plain ArrayBuffer, which the WebCrypto types insist on. */
function toBufferSource(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function fromBase64(value: string): Uint8Array {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
