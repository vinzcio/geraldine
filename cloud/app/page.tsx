import Link from "next/link";

export default function HomePage() {
  return (
    <>
      <h1>Your clipboard, on every Mac.</h1>
      <p className="lede">
        A Geraldine account syncs clipboard history, pins, and preferences between
        your Macs. Everything is encrypted before it leaves the machine.
      </p>

      <div className="cta">
        <Link href="/sign-up">
          <button className="primary">Create an account</button>
        </Link>
        <Link href="/sign-in">
          <button className="secondary">Sign in</button>
        </Link>
      </div>

      <div className="features">
        <div className="card">
          <h2>Encrypted before it leaves</h2>
          <p>
            Clipboard payloads are sealed with AES-256-GCM under a key this server
            never holds. Sync moves ciphertext and routing metadata, nothing else.
          </p>
        </div>
        <div className="card">
          <h2>One password, derived twice</h2>
          <p>
            Your Mac turns your password into two separate keys. Only the sign-in
            key is sent here — the key that unwraps your history stays local.
          </p>
        </div>
        <div className="card">
          <h2>Works offline</h2>
          <p>
            Copy and paste never wait on the network. Changes queue locally and
            reconcile in order once a connection is back.
          </p>
        </div>
        <div className="card">
          <h2>Per-device control</h2>
          <p>
            Every Mac enrolls with its own signing key. Revoke one and it stops
            receiving changes immediately, without disturbing the others.
          </p>
        </div>
      </div>

      <p className="footnote">
        Because your encryption key comes from your password, we cannot read or
        recover your clipboard history. If you forget your password, synced
        history can only be recovered by a Mac that is still signed in.
      </p>
    </>
  );
}
