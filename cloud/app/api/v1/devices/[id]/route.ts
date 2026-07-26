import { and, eq, isNull } from "drizzle-orm";
import { NextResponse } from "next/server";

import { db, schema } from "@/db";
import { ApiError, audit, errorResponse, requireUser } from "@/server/context";

/**
 * Revokes a device. The row is kept rather than deleted so its mutations stay
 * attributable and its public key can never be re-enrolled.
 */
export async function DELETE(
  request: Request,
  context: { params: Promise<{ id: string }> },
) {
  try {
    const { userId, requestId } = await requireUser(request);
    const { id } = await context.params;

    const [revoked] = await db
      .update(schema.device)
      .set({ revokedAt: new Date() })
      .where(
        and(
          eq(schema.device.id, id),
          eq(schema.device.userId, userId),
          isNull(schema.device.revokedAt),
        ),
      )
      .returning({ id: schema.device.id });

    if (!revoked) {
      throw new ApiError(404, "device_not_found", "That device is not enrolled.");
    }

    await audit({
      userId,
      deviceId: revoked.id,
      event: "device.revoked",
      outcome: "ok",
      requestId,
    });
    return NextResponse.json({ ok: true });
  } catch (error) {
    return errorResponse(error);
  }
}

export const dynamic = "force-dynamic";
