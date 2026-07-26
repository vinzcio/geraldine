"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";

import { Turnstile, turnstileSiteKey } from "@/components/Turnstile";
import { resendVerification, signInWithDerivedKey } from "@/lib/auth-client";

export default function SignInPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [captchaToken, setCaptchaToken] = useState<string | null>(null);
  const [unverified, setUnverified] = useState(false);
  const [resent, setResent] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);
    setResent(false);

    if (turnstileSiteKey && !captchaToken) {
      setError("Complete the human check first.");
      return;
    }

    setBusy(true);
    const result = await signInWithDerivedKey({ email, password, captchaToken });
    setBusy(false);

    setUnverified(Boolean(result.unverified));
    if (result.error) {
      setError(result.error);
      return;
    }
    router.push("/account");
  }

  async function resend() {
    const result = await resendVerification(email);
    setResent(!result.error);
    if (result.error) setError(result.error);
  }

  return (
    <div className="narrow">
      <h1>Sign in</h1>
      <p className="lede">Manage your account and enrolled Macs.</p>

      <form className="card" onSubmit={submit}>
        <label htmlFor="email">Email</label>
        <input
          id="email"
          type="email"
          autoComplete="email"
          required
          value={email}
          onChange={(event) => setEmail(event.target.value)}
        />

        <label htmlFor="password">Password</label>
        <input
          id="password"
          type="password"
          autoComplete="current-password"
          required
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />

        <Turnstile action="sign-in" onToken={setCaptchaToken} />

        <button className="primary" type="submit" disabled={busy}>
          {busy ? "Deriving your key…" : "Sign in"}
        </button>

        {error ? <p className="notice">{error}</p> : null}
        {unverified && !resent ? (
          <button
            className="secondary"
            type="button"
            style={{ marginTop: 12, width: "100%" }}
            onClick={resend}
          >
            Resend confirmation email
          </button>
        ) : null}
        {resent ? <p className="notice ok">Confirmation email sent.</p> : null}
      </form>

      <p className="hint" style={{ textAlign: "center", marginTop: 18 }}>
        No account yet? <Link href="/sign-up">Create one</Link>
      </p>
    </div>
  );
}
