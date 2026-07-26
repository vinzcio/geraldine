import { eq } from "drizzle-orm";
import { NextResponse } from "next/server";
import { z } from "zod";

import { db, schema } from "@/db";
import { KDF_ALGORITHM } from "@/lib/crypto";
import { ApiError, audit, errorResponse, requireUser } from "@/server/context";

const putSchema = z.object({
  kdfAlgorithm: z.literal(KDF_ALGORITHM),
  kdfIterations: z.number().int().min(100_000).max(5_000_000),
  kdfSalt: z.string().min(1).max(128),
  wrappedAccountKey: z.string().min(1).max(512),
  wrapNonce: z.string().min(1).max(64),
});

/** Returns the wrapped account key so a newly signed-in Mac can unwrap it. */
export async function GET(request: Request) {
  try {
    const { userId } = await requireUser(request);
    const [row] = await db
      .select()
      .from(schema.accountKey)
      .where(eq(schema.accountKey.userId, userId))
      .limit(1);

    if (!row) {
      return NextResponse.json({ accountKey: null });
    }
    return NextResponse.json({
      accountKey: {
        keyVersion: row.keyVersion,
        kdfAlgorithm: row.kdfAlgorithm,
        kdfIterations: row.kdfIterations,
        kdfSalt: row.kdfSalt,
        wrappedAccountKey: row.wrappedAccountKey,
        wrapNonce: row.wrapNonce,
      },
    });
  } catch (error) {
    return errorResponse(error);
  }
}

/**
 * Stores the wrapped account key. Write-once: replacing it would orphan every
 * payload already encrypted under the old key, so rotation goes through the
 * dedicated re-key flow instead.
 */
export async function PUT(request: Request) {
  try {
    const { userId, requestId } = await requireUser(request);
    const body = putSchema.parse(await request.json());

    const [existing] = await db
      .select({ keyVersion: schema.accountKey.keyVersion })
      .from(schema.accountKey)
      .where(eq(schema.accountKey.userId, userId))
      .limit(1);

    if (existing) {
      await audit({ userId, event: "account_key.rejected", outcome: "denied", requestId });
      throw new ApiError(
        409,
        "account_key_exists",
        "This account already has an encryption key.",
      );
    }

    await db.insert(schema.accountKey).values({
      userId,
      kdfAlgorithm: body.kdfAlgorithm,
      kdfIterations: body.kdfIterations,
      kdfSalt: body.kdfSalt,
      wrappedAccountKey: body.wrappedAccountKey,
      wrapNonce: body.wrapNonce,
    });

    await audit({ userId, event: "account_key.created", outcome: "ok", requestId });
    return NextResponse.json({ ok: true, keyVersion: 1 }, { status: 201 });
  } catch (error) {
    return errorResponse(error, "The account key payload is malformed.");
  }
}

export const dynamic = "force-dynamic";
