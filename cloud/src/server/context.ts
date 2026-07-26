import { and, eq, isNull } from "drizzle-orm";
import { NextResponse } from "next/server";
import { z } from "zod";

import { db, schema } from "@/db";
import { auth } from "@/lib/auth";

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
  ) {
    super(message);
  }
}

/**
 * Parses a sync cursor. Pull hands one out and ack sends it back, so both ends
 * of the protocol have to agree on what counts as valid — hence one definition.
 */
export function parseCursor(raw: string | null | undefined): number {
  if (!raw) return 0;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new ApiError(400, "invalid_cursor", "The cursor is not valid.");
  }
  return value;
}

export interface RequestContext {
  userId: string;
  requestId: string;
}

/**
 * Resolves the caller from either the website's session cookie or the Mac app's
 * `Authorization: Bearer` token — Better Auth's bearer plugin accepts both
 * through the same call.
 */
export async function requireUser(request: Request): Promise<RequestContext> {
  const session = await auth.api.getSession({ headers: request.headers });
  if (!session?.user) {
    throw new ApiError(401, "unauthenticated", "Sign in to continue.");
  }
  return {
    userId: session.user.id,
    requestId: request.headers.get("x-request-id") ?? crypto.randomUUID(),
  };
}

/** Resolves a device that belongs to the caller and has not been revoked. */
export async function requireDevice(userId: string, deviceId: string) {
  const [row] = await db
    .select()
    .from(schema.device)
    .where(
      and(
        eq(schema.device.id, deviceId),
        eq(schema.device.userId, userId),
        isNull(schema.device.revokedAt),
      ),
    )
    .limit(1);

  if (!row) {
    // Same response whether the device is unknown, someone else's, or revoked:
    // a revoked Mac must not be able to probe for its own former ID.
    throw new ApiError(403, "device_not_enrolled", "This device is not enrolled.");
  }
  return row;
}

/**
 * The single error sink every route funnels into.
 *
 * ZodError is mapped here rather than at each call site: a handler that forgets
 * the branch turns a malformed request body into a 500 with a stack trace,
 * which is a client bug reported as a server fault.
 */
export function errorResponse(error: unknown, malformedMessage?: string): NextResponse {
  if (error instanceof z.ZodError) {
    return NextResponse.json(
      {
        error: {
          code: "invalid_request",
          message: malformedMessage ?? "The request body is malformed.",
        },
      },
      { status: 400 },
    );
  }
  if (error instanceof ApiError) {
    return NextResponse.json(
      { error: { code: error.code, message: error.message } },
      { status: error.status },
    );
  }
  console.error("unhandled api error", error);
  return NextResponse.json(
    { error: { code: "internal_error", message: "Something went wrong." } },
    { status: 500 },
  );
}

/** Records an audit entry. Deliberately never given ciphertext or tokens. */
export async function audit(entry: {
  userId?: string;
  deviceId?: string;
  event: string;
  outcome: "ok" | "denied" | "error";
  requestId?: string;
  detail?: Record<string, unknown>;
}): Promise<void> {
  try {
    await db.insert(schema.auditLog).values({
      userId: entry.userId ?? null,
      deviceId: entry.deviceId ?? null,
      event: entry.event,
      outcome: entry.outcome,
      requestId: entry.requestId ?? null,
      detail: entry.detail ?? null,
    });
  } catch (error) {
    console.error("audit write failed", error);
  }
}
