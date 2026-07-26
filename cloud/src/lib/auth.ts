import { betterAuth } from "better-auth";
import { drizzleAdapter } from "better-auth/adapters/drizzle";
import { bearer, captcha } from "better-auth/plugins";

import { db, schema } from "@/db";
import { captchaConfig } from "@/lib/captcha-config";
import { sendEmail } from "@/lib/email";

const baseURL = process.env.BETTER_AUTH_URL ?? "http://localhost:4319";

/** Origin the Geraldine Mac app sends, since it has no browser origin. */
export const NATIVE_ORIGIN = "geraldine://app";

/**
 * Turnstile guards sign-up, sign-in, and password reset against scripted abuse.
 * Whether it is on at all is decided by `captchaConfig`, which validates that
 * both halves of the key pair are present. `/api/v1/health` reports the result.
 */
const captchaPlugins = captchaConfig.enabled
  ? [
      captcha({
        provider: "cloudflare-turnstile",
        secretKey: captchaConfig.secretKey!,
        endpoints: ["/sign-up/email", "/sign-in/email", "/request-password-reset"],
        allowedHostnames: hostnamesFor(baseURL),
      }),
    ]
  : [];

export const captchaEnabled = captchaConfig.enabled;

function hostnamesFor(url: string): string[] | undefined {
  try {
    return [new URL(url).hostname];
  } catch {
    return undefined;
  }
}

export const auth = betterAuth({
  appName: "Geraldine",
  baseURL,
  secret: process.env.BETTER_AUTH_SECRET,
  database: drizzleAdapter(db, {
    provider: "pg",
    schema: {
      user: schema.user,
      session: schema.session,
      account: schema.account,
      verification: schema.verification,
    },
  }),
  emailAndPassword: {
    enabled: true,
    // An unverified address cannot sign in, so a bot cannot enroll a Mac or
    // push mutations with a throwaway mailbox it does not control.
    requireEmailVerification: true,
    // Clients send a key derived from the real password, never the password
    // itself, so the value arriving here is already a fixed-length base64url
    // string. See src/lib/crypto.ts.
    minPasswordLength: 32,
    maxPasswordLength: 128,
    sendResetPassword: async ({ user, url }) => {
      await sendEmail({
        to: user.email,
        subject: "Reset your Geraldine password",
        text:
          `Reset your Geraldine password:\n\n${url}\n\n` +
          "Because your clipboard history is encrypted with a key derived from " +
          "your password, resetting it re-keys the account: history already " +
          "synced from your other Macs stays readable only if one of them is " +
          "signed in to complete the re-wrap.\n\n" +
          "If you did not request this, you can ignore this email.",
      });
    },
  },
  emailVerification: {
    sendOnSignUp: true,
    autoSignInAfterVerification: true,
    sendVerificationEmail: async ({ user, url }) => {
      await sendEmail({
        to: user.email,
        subject: "Verify your Geraldine account",
        text: `Confirm your email address to finish setting up Geraldine:\n\n${url}\n`,
      });
    },
  },
  session: {
    expiresIn: 60 * 60 * 24 * 30,
    updateAge: 60 * 60 * 24,
  },
  account: {
    accountLinking: { enabled: false },
  },
  advanced: {
    // The Mac app talks to the same origin over TLS; cookies stay host-only.
    useSecureCookies: process.env.NODE_ENV === "production",
    defaultCookieAttributes: {
      sameSite: "lax",
      httpOnly: true,
    },
  },
  // Better Auth refuses state-changing requests without a trusted Origin. The
  // Mac app has no browser origin, so it declares its own custom scheme rather
  // than impersonating the website — which also keeps native traffic
  // distinguishable in logs and rate limits.
  trustedOrigins: [
    baseURL,
    NATIVE_ORIGIN,
    ...(process.env.TRUSTED_ORIGINS ?? "")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  ],
  rateLimit: {
    enabled: true,
    window: 60,
    max: 60,
  },
  plugins: [
    // The Mac app has no cookie jar; it presents `Authorization: Bearer <token>`.
    bearer(),
    ...captchaPlugins,
  ],
});

export type Session = typeof auth.$Infer.Session;
