import { and, desc, eq } from "drizzle-orm";
import { NextResponse } from "next/server";
import { z } from "zod";

import { db, schema } from "@/db";
import { fromBase64 } from "@/lib/crypto";
import { ApiError, audit, errorResponse, requireUser } from "@/server/context";

const registerSchema = z.object({
  name: z.string().min(1).max(120),
  platform: z.enum(["macos", "web"]).default("macos"),
  /** Base64 raw Ed25519 public key: 32 bytes -> 44 base64 characters. */
  publicKey: z.string().length(44),
});

export async function GET(request: Request) {
  try {
    const { userId } = await requireUser(request);
    const rows = await db
      .select({
        id: schema.device.id,
        name: schema.device.name,
        platform: schema.device.platform,
        createdAt: schema.device.createdAt,
        lastSeenAt: schema.device.lastSeenAt,
        revokedAt: schema.device.revokedAt,
        ackedSeq: schema.device.ackedSeq,
      })
      .from(schema.device)
      .where(eq(schema.device.userId, userId))
      .orderBy(desc(schema.device.lastSeenAt));

    return NextResponse.json({ devices: rows });
  } catch (error) {
    return errorResponse(error);
  }
}

/**
 * Enrolls a Mac. Re-registering the same public key returns the existing device
 * rather than creating a duplicate, so a reinstall that kept its Keychain key
 * keeps its sync cursor.
 */
export async function POST(request: Request) {
  try {
    const { userId, requestId } = await requireUser(request);
    const body = registerSchema.parse(await request.json());

    if (!isValidEd25519Key(body.publicKey)) {
      throw new ApiError(400, "invalid_public_key", "The device key is not a valid Ed25519 key.");
    }

    const [existing] = await db
      .select()
      .from(schema.device)
      .where(
        and(
          eq(schema.device.userId, userId),
          eq(schema.device.publicKey, body.publicKey),
        ),
      )
      .limit(1);

    if (existing) {
      if (existing.revokedAt) {
        await audit({
          userId,
          deviceId: existing.id,
          event: "device.register.revoked",
          outcome: "denied",
          requestId,
        });
        throw new ApiError(
          403,
          "device_revoked",
          "This device was revoked. Generate a new device key to enroll again.",
        );
      }
      const [refreshed] = await db
        .update(schema.device)
        .set({ name: body.name, lastSeenAt: new Date() })
        .where(eq(schema.device.id, existing.id))
        .returning();
      return NextResponse.json({ device: publicView(refreshed) });
    }

    const [created] = await db
      .insert(schema.device)
      .values({
        userId,
        name: body.name,
        platform: body.platform,
        publicKey: body.publicKey,
      })
      .returning();

    await audit({
      userId,
      deviceId: created.id,
      event: "device.registered",
      outcome: "ok",
      requestId,
    });
    return NextResponse.json({ device: publicView(created) }, { status: 201 });
  } catch (error) {
    return errorResponse(error, "The device payload is malformed.");
  }
}

function isValidEd25519Key(base64: string): boolean {
  return fromBase64(base64).length === 32;
}

function publicView(row: typeof schema.device.$inferSelect) {
  return {
    id: row.id,
    name: row.name,
    platform: row.platform,
    createdAt: row.createdAt,
    lastSeenAt: row.lastSeenAt,
    ackedSeq: row.ackedSeq,
  };
}

export const dynamic = "force-dynamic";
