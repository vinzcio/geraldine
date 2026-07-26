import { and, asc, desc, eq, gt, inArray } from "drizzle-orm";
import { NextResponse } from "next/server";

import { db, schema } from "@/db";
import {
  ApiError,
  errorResponse,
  parseCursor,
  requireDevice,
  requireUser,
} from "@/server/context";
import { DATASETS } from "@/server/mutation";

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 500;

/**
 * Returns mutations after `cursor`, ordered by the server sequence.
 *
 * Ordering is entirely server-assigned, so a Mac with a wrong clock can reorder
 * nothing and skip nothing. `hasMore` lets a device that has been offline for a
 * long time drain the log in bounded pages.
 */
export async function GET(request: Request) {
  try {
    const { userId } = await requireUser(request);
    const url = new URL(request.url);

    const deviceId = url.searchParams.get("deviceId");
    if (!deviceId) {
      throw new ApiError(400, "invalid_request", "deviceId is required.");
    }
    const device = await requireDevice(userId, deviceId);

    const cursor = parseCursor(url.searchParams.get("cursor"));
    const limit = Math.min(
      Math.max(Number(url.searchParams.get("limit") ?? DEFAULT_LIMIT) || DEFAULT_LIMIT, 1),
      MAX_LIMIT,
    );
    const datasets = parseDatasets(url.searchParams.get("datasets"));

    // The barrier list depends on nothing the mutation query returns, so the
    // highest-frequency endpoint in the service should not serialize them.
    const [rows, barriers] = await Promise.all([
      db
      .select({
        serverSeq: schema.mutation.serverSeq,
        mutationId: schema.mutation.mutationId,
        dataset: schema.mutation.dataset,
        recordId: schema.mutation.recordId,
        operation: schema.mutation.operation,
        deviceId: schema.mutation.deviceId,
        modifiedAt: schema.mutation.modifiedAt,
        schemaVersion: schema.mutation.schemaVersion,
        ciphertext: schema.mutation.ciphertext,
      })
      .from(schema.mutation)
      .where(
        and(
          eq(schema.mutation.userId, userId),
          gt(schema.mutation.serverSeq, cursor),
          datasets ? inArray(schema.mutation.dataset, datasets) : undefined,
        ),
      )
      .orderBy(asc(schema.mutation.serverSeq))
      .limit(limit + 1),
      // A delete-all issued while this device was offline has to win over
      // whatever it still holds locally, so barriers ride along with the page.
      db
        .select({
          dataset: schema.deletionBarrier.dataset,
          barrierSeq: schema.deletionBarrier.barrierSeq,
          createdAt: schema.deletionBarrier.createdAt,
        })
        .from(schema.deletionBarrier)
        .where(eq(schema.deletionBarrier.userId, userId))
        .orderBy(desc(schema.deletionBarrier.barrierSeq)),
    ]);

    const hasMore = rows.length > limit;
    const page = hasMore ? rows.slice(0, limit) : rows;

    await db
      .update(schema.device)
      .set({ lastSeenAt: new Date() })
      .where(eq(schema.device.id, device.id));

    return NextResponse.json({
      mutations: page.map((row) => ({
        ...row,
        serverSeq: String(row.serverSeq),
        modifiedAt: row.modifiedAt.toISOString(),
      })),
      cursor: String(page.at(-1)?.serverSeq ?? cursor),
      hasMore,
      barriers: barriers.map((barrier) => ({
        dataset: barrier.dataset,
        barrierSeq: String(barrier.barrierSeq),
        createdAt: barrier.createdAt.toISOString(),
      })),
    });
  } catch (error) {
    return errorResponse(error);
  }
}

function parseDatasets(raw: string | null): string[] | undefined {
  if (!raw) return undefined;
  const requested = raw.split(",").map((value) => value.trim()).filter(Boolean);
  const allowed = requested.filter((value) =>
    (DATASETS as readonly string[]).includes(value),
  );
  if (allowed.length !== requested.length) {
    throw new ApiError(400, "invalid_dataset", "Unknown dataset requested.");
  }
  return allowed.length > 0 ? allowed : undefined;
}

export const dynamic = "force-dynamic";
