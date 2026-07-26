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
import { pushRequestSchema, verifyMutationSignature } from "@/server/mutation";

/**
 * Accepts a batch of encrypted mutations.
 *
 * The batch is all-or-nothing: a single bad signature rejects the whole thing
 * rather than leaving the device guessing which half landed. Re-sending an
 * already-applied batch is safe — `(user_id, mutation_id)` is unique and
 * conflicts are ignored, so a client that loses the response can simply retry.
 */
export async function POST(request: Request) {
  try {
    const { userId, requestId } = await requireUser(request);
    const body = pushRequestSchema.parse(await request.json());
    const device = await requireDevice(userId, body.deviceId);

    // Device sequences must strictly increase: that is what makes a captured
    // batch impossible to replay later.
    let expected = Number(device.lastSequence);
    for (const mutation of body.mutations) {
      if (mutation.deviceSequence <= expected) {
        await audit({
          userId,
          deviceId: device.id,
          event: "sync.push.sequence_rollback",
          outcome: "denied",
          requestId,
          detail: { expectedAbove: expected, received: mutation.deviceSequence },
        });
        throw new ApiError(
          409,
          "sequence_rollback",
          "Device sequence must increase. Pull before pushing again.",
        );
      }
      expected = mutation.deviceSequence;
    }

    const verifications = await Promise.all(
      body.mutations.map((mutation) =>
        verifyMutationSignature(
          device.publicKey,
          { ...mutation, deviceId: device.id },
          mutation.signature,
        ),
      ),
    );
    if (verifications.some((valid) => !valid)) {
      await audit({
        userId,
        deviceId: device.id,
        event: "sync.push.bad_signature",
        outcome: "denied",
        requestId,
      });
      throw new ApiError(400, "invalid_signature", "A mutation signature did not verify.");
    }

    const highestSequence = body.mutations.at(-1)!.deviceSequence;

    const { accepted, head } = await db.transaction(async (tx) => {
      const inserted = await tx
        .insert(schema.mutation)
        .values(
          body.mutations.map((mutation) => ({
            userId,
            mutationId: mutation.mutationId,
            dataset: mutation.dataset,
            recordId: mutation.recordId,
            operation: mutation.operation,
            deviceId: device.id,
            deviceSequence: mutation.deviceSequence,
            modifiedAt: new Date(mutation.modifiedAt),
            schemaVersion: mutation.schemaVersion,
            ciphertext: mutation.operation === "delete" ? null : mutation.ciphertext,
          })),
        )
        // A retried batch must not fail; it just adds nothing.
        .onConflictDoNothing()
        .returning({ serverSeq: schema.mutation.serverSeq });

      await tx
        .update(schema.device)
        .set({
          lastSequence: sql`greatest(${schema.device.lastSequence}, ${highestSequence})`,
          lastSeenAt: new Date(),
        })
        .where(eq(schema.device.id, device.id));

      // Read the head on the same connection: a second checkout after commit
      // would both cost a round trip and see a different snapshot.
      const [{ head: currentHead }] = await tx
        .select({ head: sql<number>`coalesce(max(${schema.mutation.serverSeq}), 0)` })
        .from(schema.mutation)
        .where(eq(schema.mutation.userId, userId));

      return { accepted: inserted, head: currentHead };
    });

    return NextResponse.json({
      accepted: accepted.length,
      duplicates: body.mutations.length - accepted.length,
      cursor: String(head),
    });
  } catch (error) {
    return errorResponse(error, "The push batch is malformed.");
  }
}

export const dynamic = "force-dynamic";
