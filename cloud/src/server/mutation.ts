import { z } from "zod";

/**
 * The canonical form every mutation is signed over.
 *
 * Both the Mac app and this server build this string byte-for-byte identically;
 * any drift shows up immediately as a signature failure rather than as silent
 * tampering. Fields are newline-separated because none of them may contain a
 * newline, so the encoding is unambiguous without length prefixes.
 */
export function canonicalMutationString(mutation: {
  mutationId: string;
  dataset: string;
  recordId: string;
  operation: string;
  deviceId: string;
  deviceSequence: number;
  modifiedAt: string;
  schemaVersion: number;
  ciphertext: string | null;
}): string {
  return [
    "geraldine-mutation-v1",
    mutation.mutationId,
    mutation.dataset,
    mutation.recordId,
    mutation.operation,
    mutation.deviceId,
    String(mutation.deviceSequence),
    mutation.modifiedAt,
    String(mutation.schemaVersion),
    mutation.ciphertext ?? "",
  ].join("\n");
}

export async function verifyMutationSignature(
  publicKeyBase64: string,
  mutation: Parameters<typeof canonicalMutationString>[0],
  signatureBase64: string,
): Promise<boolean> {
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      decodeBase64(publicKeyBase64),
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    return await crypto.subtle.verify(
      { name: "Ed25519" },
      key,
      decodeBase64(signatureBase64),
      new TextEncoder().encode(canonicalMutationString(mutation)),
    );
  } catch {
    return false;
  }
}

// Deliberately local rather than imported from @/lib/crypto: this module is
// loaded directly by scripts/e2e.ts under plain Node, which cannot resolve the
// "@/" tsconfig alias.
function decodeBase64(value: string): ArrayBuffer {
  const bytes = Buffer.from(value, "base64");
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}

// ---------------------------------------------------------------------------
// Wire schemas
// ---------------------------------------------------------------------------

export const DATASETS = ["clipboard", "preferences", "widget-layout"] as const;

/** 1 MiB of base64 per record; anything larger belongs in object storage. */
const MAX_CIPHERTEXT_CHARS = 1_400_000;
export const MAX_BATCH_SIZE = 200;

const noNewlines = (label: string) =>
  z.string().min(1).max(256).refine((value) => !value.includes("\n"), {
    message: `${label} must not contain a newline`,
  });

export const mutationSchema = z.object({
  mutationId: z.string().uuid(),
  dataset: z.enum(DATASETS),
  recordId: noNewlines("recordId"),
  operation: z.enum(["upsert", "delete"]),
  deviceSequence: z.number().int().positive().max(Number.MAX_SAFE_INTEGER),
  modifiedAt: z.string().datetime({ offset: true }),
  schemaVersion: z.number().int().min(1).max(1000),
  ciphertext: z.string().max(MAX_CIPHERTEXT_CHARS).nullable(),
  signature: z.string().min(1).max(256),
});

export const pushRequestSchema = z.object({
  deviceId: z.string().uuid(),
  mutations: z.array(mutationSchema).min(1).max(MAX_BATCH_SIZE),
});

export type MutationInput = z.infer<typeof mutationSchema>;
