import Link from "next/link";

export default function VerifiedPage() {
  return (
    <div className="narrow">
      <h1>Email confirmed</h1>
      <p className="lede">Your Geraldine account is active.</p>
      <div className="card">
        <p className="hint">
          Sign in here to manage enrolled Macs, or open Geraldine on your Mac and
          sign in from Clipboard → Sync to start syncing.
        </p>
        <Link href="/sign-in">
          <button className="primary">Sign in</button>
        </Link>
      </div>
    </div>
  );
}
