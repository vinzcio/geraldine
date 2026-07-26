"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";

import { Turnstile, turnstileSiteKey } from "@/components/Turnstile";
import { signUpWithDerivedKey } from "@/lib/auth-client";

export default function SignUpPage() {
  const router = useRouter();
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [confirm, setConfirm] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [captchaToken, setCaptchaToken] = useState<string | null>(null);
  const [sent, setSent] = useState(false);

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    setError(null);

    if (password !== confirm) {
      setError("Those passwords do not match.");
      return;
    }
    if (password.length < 10) {
      setError("Use at least 10 characters. This password also protects your history.");
      return;
    }

    if (turnstileSiteKey && !captchaToken) {
      setError("Complete the human check first.");
      return;
    }

    setBusy(true);
    // Key derivation is deliberately slow; the button stays busy for a moment.
    const result = await signUpWithDerivedKey({ name, email, password, captchaToken });
    setBusy(false);

    if (result.error) {
      setError(result.error);
      return;
    }
    if (result.needsVerification) {
      setSent(true);
      return;
    }
    router.push("/account");
  }

  if (sent) {
    return (
      <div className="narrow">
        <h1>Check your email</h1>
        <p className="lede">
          We sent a confirmation link to <strong>{email}</strong>. Open it to
          activate your account, then sign in.
        </p>
        <div className="card">
          <p className="hint">
            Nothing arrived? Check spam, then try signing in — you can resend the
            link from there.
          </p>
          <Link href="/sign-in">
            <button className="secondary" style={{ marginTop: 14 }}>
              Go to sign in
            </button>
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="narrow">
      <h1>Create your account</h1>
      <p className="lede">One account, every Mac running Geraldine.</p>

      <form className="card" onSubmit={submit}>
        <label htmlFor="name">Name</label>
        <input
          id="name"
          type="text"
          autoComplete="name"
          required
          value={name}
          onChange={(event) => setName(event.target.value)}
        />

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
          autoComplete="new-password"
          required
          value={password}
          onChange={(event) => setPassword(event.target.value)}
        />
        <p className="hint">
          This password also derives your encryption key. It cannot be reset
          without losing access to already-synced history.
        </p>

        <label htmlFor="confirm">Confirm password</label>
        <input
          id="confirm"
          type="password"
          autoComplete="new-password"
          required
          value={confirm}
          onChange={(event) => setConfirm(event.target.value)}
        />

        <Turnstile action="sign-up" onToken={setCaptchaToken} />

        <button className="primary" type="submit" disabled={busy}>
          {busy ? "Deriving your key…" : "Create account"}
        </button>

        {error ? <p className="notice">{error}</p> : null}
      </form>

      <p className="hint" style={{ textAlign: "center", marginTop: 18 }}>
        Already have an account? <Link href="/sign-in">Sign in</Link>
      </p>
    </div>
  );
}
