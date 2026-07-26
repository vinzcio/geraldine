import type { Metadata } from "next";
import Link from "next/link";

import "./globals.css";

export const metadata: Metadata = {
  title: "Geraldine Account",
  description:
    "Sign in to sync Geraldine's encrypted clipboard history and preferences across your Macs.",
  robots: { index: false, follow: false },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <div className="shell">
          <header className="topbar">
            <Link className="wordmark" href="/">
              <span className="mark" aria-hidden>
                G
              </span>
              Geraldine
            </Link>
            <nav className="cta">
              <Link href="/account">Account</Link>
            </nav>
          </header>
          <main>{children}</main>
        </div>
      </body>
    </html>
  );
}
