import { eq, sql } from "drizzle-orm";
import { NextResponse } from "next/server";
import { z } from "zod";

import { db, schema } from "@/db";
import {
  errorResponse,
  parseCursor,
  requireDevice,
  requireUser,
} from "@/server/context";

const ackSchema = z.object({
  deviceId: z.string().uuid(),
  cursor: z.string().regex(/^\d+$/),
});

/**
 * Records how far a device has applied. Compaction may only discard tombstones
 * below the *minimum* acked cursor across live devices, so this is what stops a
 * long-offline Mac from resurrecting deleted entries when it returns.
 */
export async function POST(request: Request) {
  try {
    const { userId } = await requireUser(request);
    const body = ackSchema.parse(await request.json());
    const device = await requireDevice(userId, body.deviceId);

    const cursor = parseCursor(body.cursor);

    const [updated] = await db
      .update(schema.device)
      // Never move an ack backwards: a stale retry must not widen the window.
      .set({
        ackedSeq: sql`greatest(${schema.device.ackedSeq}, ${cursor})`,
        lastSeenAt: new Date(),
      })
      .where(eq(schema.device.id, device.id))
      .returning({ ackedSeq: schema.device.ackedSeq });

    return NextResponse.json({ ackedSeq: String(updated.ackedSeq) });
  } catch (error) {
    return errorResponse(error, "The ack is malformed.");
  }
}

export const dynamic = "force-dynamic";
