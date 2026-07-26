"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState } from "react";

import { signOut, useSession } from "@/lib/auth-client";

interface DeviceRow {
  id: string;
  name: string;
  platform: string;
  createdAt: string;
  lastSeenAt: string;
  revokedAt: string | null;
  ackedSeq: number;
}

export default function AccountPage() {
  const router = useRouter();
  const { data: session, isPending } = useSession();
  const [devices, setDevices] = useState<DeviceRow[] | null>(null);
  const [hasKey, setHasKey] = useState<boolean | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [deviceResponse, keyResponse] = await Promise.all([
      fetch("/api/v1/devices"),
      fetch("/api/v1/account/key"),
    ]);
    if (deviceResponse.ok) {
      setDevices((await deviceResponse.json()).devices);
    }
    if (keyResponse.ok) {
      setHasKey(Boolean((await keyResponse.json()).accountKey));
    }
  }, []);

  useEffect(() => {
    if (!isPending && !session) {
      router.replace("/sign-in");
      return;
    }
    if (session) void load();
  }, [isPending, session, router, load]);

  async function revoke(device: DeviceRow) {
    setError(null);
    const response = await fetch(`/api/v1/devices/${device.id}`, { method: "DELETE" });
    if (!response.ok) {
      setError(`Could not revoke ${device.name}.`);
      return;
    }
    await load();
  }

  if (isPending || !session) {
    return <p className="lede">Loading…</p>;
  }

  const active = devices?.filter((device) => !device.revokedAt) ?? [];
  const revoked = devices?.filter((device) => device.revokedAt) ?? [];

  return (
    <>
      <h1>Account</h1>
      <p className="lede">
        {session.user.email}
        {session.user.emailVerified ? "" : " · email not verified"}
      </p>

      <div className="card">
        <h2>Encryption key</h2>
        {hasKey === null ? (
          <p className="hint">Checking…</p>
        ) : hasKey ? (
          <p className="hint">
            Your account key is stored wrapped. This server holds only the sealed
            blob and cannot open it.
          </p>
        ) : (
          <p className="notice">
            No encryption key is stored yet. Sign in from the Geraldine app on a
            Mac to finish setting up sync.
          </p>
        )}
      </div>

      <div className="card" style={{ marginTop: 16 }}>
        <h2>Macs</h2>
        <p className="hint">
          Each Mac enrolls with its own signing key. Revoking one stops it
          receiving changes immediately.
        </p>

        {devices === null ? (
          <p className="hint">Loading…</p>
        ) : active.length === 0 ? (
          <p className="hint" style={{ marginTop: 14 }}>
            No Macs enrolled yet. Open Geraldine → Clipboard → Sign in.
          </p>
        ) : (
          <div className="rows">
            {active.map((device) => (
              <div className="row" key={device.id}>
                <div className="grow">
                  <div>{device.name}</div>
                  <div className="meta">
                    Last seen {new Date(device.lastSeenAt).toLocaleString()}
                  </div>
                </div>
                <button className="link-danger" onClick={() => revoke(device)}>
                  Revoke
                </button>
              </div>
            ))}
          </div>
        )}

        {revoked.length > 0 ? (
          <div className="rows">
            {revoked.map((device) => (
              <div className="row revoked" key={device.id}>
                <div className="grow">
                  <div>{device.name}</div>
                  <div className="meta">
                    Revoked {new Date(device.revokedAt!).toLocaleDateString()}
                  </div>
                </div>
              </div>
            ))}
          </div>
        ) : null}

        {error ? <p className="notice">{error}</p> : null}
      </div>

      <div style={{ marginTop: 24 }}>
        <button
          className="secondary"
          onClick={async () => {
            await signOut();
            router.push("/");
          }}
        >
          Sign out
        </button>
      </div>
    </>
  );
}
