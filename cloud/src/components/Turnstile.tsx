"use client";

import { useEffect, useRef } from "react";

import { captchaConfig } from "@/lib/captcha-config";

declare global {
  interface Window {
    turnstile?: {
      render: (
        element: HTMLElement,
        options: {
          sitekey: string;
          callback: (token: string) => void;
          "expired-callback"?: () => void;
          "error-callback"?: () => void;
          theme?: "auto" | "light" | "dark";
          action?: string;
        },
      ) => string;
      reset: (widgetId: string) => void;
      remove: (widgetId: string) => void;
    };
  }
}

const SCRIPT_SRC =
  "https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit";

export const turnstileSiteKey = captchaConfig.enabled ? captchaConfig.siteKey : undefined;

/**
 * Cloudflare Turnstile widget.
 *
 * Renders nothing when no site key is configured, so a local checkout without
 * Cloudflare credentials still has a working sign-up form. The server side is
 * gated on the same condition.
 */
export function Turnstile({
  action,
  onToken,
}: {
  action: string;
  onToken: (token: string | null) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const widgetIdRef = useRef<string | null>(null);

  useEffect(() => {
    if (!turnstileSiteKey) return;
    let cancelled = false;

    async function render() {
      await loadScript();
      if (cancelled || !containerRef.current || !window.turnstile) return;
      if (widgetIdRef.current !== null) return;

      widgetIdRef.current = window.turnstile.render(containerRef.current, {
        sitekey: turnstileSiteKey!,
        action,
        theme: "auto",
        callback: (token) => onToken(token),
        // A stale token is worse than none: it would fail verification server
        // side and read to the user as a wrong password.
        "expired-callback": () => onToken(null),
        "error-callback": () => onToken(null),
      });
    }

    void render();
    return () => {
      cancelled = true;
      if (widgetIdRef.current !== null && window.turnstile) {
        window.turnstile.remove(widgetIdRef.current);
        widgetIdRef.current = null;
      }
    };
  }, [action, onToken]);

  if (!turnstileSiteKey) return null;
  return <div ref={containerRef} style={{ marginTop: 18 }} />;
}

let scriptPromise: Promise<void> | null = null;

function loadScript(): Promise<void> {
  if (typeof window === "undefined") return Promise.resolve();
  if (window.turnstile) return Promise.resolve();
  if (scriptPromise) return scriptPromise;

  scriptPromise = new Promise<void>((resolve, reject) => {
    const script = document.createElement("script");
    script.src = SCRIPT_SRC;
    script.async = true;
    script.defer = true;
    script.onload = () => resolve();
    script.onerror = () => {
      scriptPromise = null;
      reject(new Error("Turnstile failed to load"));
    };
    document.head.appendChild(script);
  });
  return scriptPromise;
}
