/**
 * Turnstile configuration, resolved in one place.
 *
 * The secret is server-only and the site key is public, so they arrive through
 * two unrelated env vars with nothing tying them together. Both half-configured
 * states are silently broken:
 *
 *   site key only  — a challenge renders and nobody verifies it. Security theatre.
 *   secret only    — no widget renders, so no `x-captcha-response` header is sent
 *                    and the plugin rejects *every* sign-up, sign-in, and reset.
 *
 * The second one locks the service out of its own front door, which is exactly
 * what the "skip when unconfigured" behaviour was meant to prevent. So the pair
 * is validated here rather than being re-derived at each call site.
 */

const secretKey = process.env.TURNSTILE_SECRET_KEY?.trim() || undefined;

// Must be a static property access, not a computed lookup: Next inlines
// NEXT_PUBLIC_* at build time only when it can see the literal reference.
const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY?.trim() || undefined;

function resolve(): { enabled: boolean; siteKey?: string; secretKey?: string } {
  if (secretKey && siteKey) {
    return { enabled: true, siteKey, secretKey };
  }
  if (secretKey || siteKey) {
    const missing = secretKey
      ? "NEXT_PUBLIC_TURNSTILE_SITE_KEY"
      : "TURNSTILE_SECRET_KEY";
    const message =
      `Turnstile is half-configured: ${missing} is missing. ` +
      "CAPTCHA is disabled rather than left in a broken state.";

    if (process.env.NODE_ENV === "production") {
      // Failing the boot is kinder than serving unprotected sign-up, or than
      // rejecting every credential request, for however long it goes unnoticed.
      throw new Error(message);
    }
    console.warn(`⚠ ${message}`);
  }
  return { enabled: false };
}

export const captchaConfig = resolve();
