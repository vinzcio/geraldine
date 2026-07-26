import { eq, sql } from "drizzle-orm";
import { NextResponse } from "next/server";
import { z } from "zod";

import { db, schema } from "@/db";
import {
  ApiError,
  audit,
  errorResponse,
  requireDevice,
  requireUser,
} from "@/server/context";
import { DATASETS } from "@/server/mutation";

const purgeSchema = z.object({
  deviceId: z.string().uuid(),
  dataset: z.enum(DATASETS),
});

/**
 * "Delete all history" for one dataset.
 *
 * Emitting a tombstone per entry would race an offline Mac that still holds
 * thousands of them, so instead this records a barrier at the current head.
 * Every device treats records at or below the barrier as dead, which means an
 * offline device cannot resurrect anything when it reconnects.
 */
export async function POST(request: Request) {
  try {
    const { userId, requestId } = await requireUser(request);
    const body = purgeSchema.parse(await request.json());
    const device = await requireDevice(userId, body.deviceId);

    const result = await db.transaction(async (tx) => {
      const [{ head }] = await tx
        .select({ head: sql<number>`coalesce(max(${schema.mutation.serverSeq}), 0)` })
        .from(schema.mutation)
        .where(eq(schema.mutation.userId, userId));

      const [barrier] = await tx
        .insert(schema.deletionBarrier)
        .values({
          userId,
          dataset: body.dataset,
          barrierSeq: head,
          issuedByDeviceId: device.id,
        })
        .returning();

      // The payloads are what matter; the log rows below the barrier are dead
      // weight, so drop their ciphertext now rather than waiting for the
      // compaction worker.
      const cleared = await tx
        .update(schema.mutation)
        .set({ ciphertext: null, operation: "delete" })
        .where(
          sql`${schema.mutation.userId} = ${userId}
              and ${schema.mutation.dataset} = ${body.dataset}
              and ${schema.mutation.serverSeq} <= ${head}
              and ${schema.mutation.ciphertext} is not null`,
        )
        .returning({ serverSeq: schema.mutation.serverSeq });

      return { barrier, clearedCount: cleared.length };
    });

    await audit({
      userId,
      deviceId: device.id,
      event: "sync.purge",
      outcome: "ok",
      requestId,
      detail: { dataset: body.dataset, clearedCount: result.clearedCount },
    });

    return NextResponse.json({
      barrierSeq: String(result.barrier.barrierSeq),
      cleared: result.clearedCount,
    });
  } catch (error) {
    return errorResponse(error, "The purge request is malformed.");
  }
}

export const dynamic = "force-dynamic";
