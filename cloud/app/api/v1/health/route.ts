import { sql } from "drizzle-orm";
import { NextResponse } from "next/server";

import { db } from "@/db";
import { captchaEnabled } from "@/lib/auth";

/**
 * Liveness plus a readout of the protections that are actually switched on.
 *
 * A deployment silently missing its CAPTCHA secret or mail provider still
 * serves traffic, so those states have to be visible somewhere other than the
 * logs. Reveals no account data.
 */
export async function GET() {
  const database = await db
    .execute(sql`select 1`)
    .then(() => true, () => false);

  const body = {
    ok: database,
    database,
    captcha: captchaEnabled,
    emailProvider: Boolean(process.env.RESEND_API_KEY),
    emailVerificationRequired: true,
  };

  return NextResponse.json(body, { status: database ? 200 : 503 });
}

export const dynamic = "force-dynamic";
