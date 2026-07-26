"use client";

import { createAuthClient } from "better-auth/react";

import {
  KDF_ALGORITHM,
  KDF_ITERATIONS,
  deriveSecrets,
  generateAccountKey,
  normalizeEmail,
  wrapAccountKey,
} from "@/lib/crypto";

export const authClient = createAuthClient({
  baseURL: process.env.NEXT_PUBLIC_APP_URL ?? undefined,
});

export const { useSession, signOut } = authClient;

/**
 * Creates the account and its encryption key in one step.
 *
 * The password never leaves this function. What Better Auth receives is
 * `authKey`, derived from it; the sibling `wrapKey` stays here and is used to
 * wrap a fresh random account key that the server only ever sees wrapped.
 */
export async function signUpWithDerivedKey(input: {
  name: string;
  email: string;
  password: string;
  captchaToken?: string | null;
}): Promise<{ error?: string; needsVerification?: boolean }> {
  const { authKey, wrapKey, salt } = await deriveSecrets(input.email, input.password);

  // Signing up while another account is still signed in would send the new
  // user's wrapped key to the old user's account, because the request carries
  // the old session cookie. Clear it first.
  await authClient.signOut().catch(() => undefined);

  const signUp = await authClient.signUp.email({
    name: input.name,
    email: normalizeEmail(input.email),
    password: authKey,
    callbackURL: "/verified",
    fetchOptions: captchaHeaders(input.captchaToken),
  });
  if (signUp.error) {
    return { error: signUp.error.message ?? "Could not create the account." };
  }

  // With verification required, sign-up opens no session, so the key is stored
  // on the first sign-in instead. Never write it against a session belonging to
  // someone else.
  const session = await authClient.getSession();
  if (normalizeEmail(session.data?.user.email ?? "") !== normalizeEmail(input.email)) {
    return { needsVerification: true };
  }

  return (await ensureAccountKey(salt, wrapKey))
    ? {}
    : {
        error:
          "The account was created but its encryption key could not be stored. " +
          "Sign in and try again before adding a Mac.",
      };
}

export async function signInWithDerivedKey(input: {
  email: string;
  password: string;
  captchaToken?: string | null;
}): Promise<{ error?: string; unverified?: boolean }> {
  const { authKey, wrapKey, salt } = await deriveSecrets(input.email, input.password);
  const result = await authClient.signIn.email({
    email: normalizeEmail(input.email),
    password: authKey,
    fetchOptions: captchaHeaders(input.captchaToken),
  });

  if (result.error) {
    const unverified =
      result.error.status === 403 ||
      /verif/i.test(result.error.message ?? "") ||
      result.error.code === "EMAIL_NOT_VERIFIED";
    return {
      error: unverified
        ? "Confirm your email address first — check your inbox for the link."
        : (result.error.message ?? "Incorrect email or password."),
      unverified,
    };
  }

  await ensureAccountKey(salt, wrapKey);
  return {};
}

/**
 * Creates the account key only if the account has none. Returns false only when
 * the account is left without a usable key.
 *
 * This is the single writer for that endpoint. Sign-up and sign-in both route
 * through it so there is one encoding of the body — which is a wire contract
 * with `putSchema` — and one concurrency policy. Checking before writing
 * matters: minting a fresh key unconditionally would race a second Mac signing
 * in at the same moment, and the loser would hold a key that no longer matches
 * the stored one.
 */
async function ensureAccountKey(salt: string, wrapKey: Uint8Array): Promise<boolean> {
  try {
    const existing = await fetch("/api/v1/account/key");
    if (existing.ok && (await existing.json()).accountKey) return true;

    const response = await fetch("/api/v1/account/key", {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        kdfAlgorithm: KDF_ALGORITHM,
        kdfIterations: KDF_ITERATIONS,
        kdfSalt: salt,
        ...(await wrapAccountKey(generateAccountKey(), wrapKey)),
      }),
    });
    // 409 means another device won the race, which is a success for us.
    return response.ok || response.status === 409;
  } catch {
    // Offline: the Mac app retries this on its next sync.
    return false;
  }
}

export async function resendVerification(email: string): Promise<{ error?: string }> {
  const result = await authClient.sendVerificationEmail({
    email: normalizeEmail(email),
    callbackURL: "/verified",
  });
  if (result.error) {
    return { error: result.error.message ?? "Could not send the email." };
  }
  return {};
}

function captchaHeaders(token: string | null | undefined) {
  return token ? { headers: { "x-captcha-response": token } } : undefined;
}
