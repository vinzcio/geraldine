import {
  bigserial,
  bigint,
  boolean,
  index,
  integer,
  jsonb,
  pgTable,
  text,
  timestamp,
  uniqueIndex,
  uuid,
} from "drizzle-orm/pg-core";

// ---------------------------------------------------------------------------
// Better Auth core tables
//
// Names and columns are fixed by Better Auth's Drizzle adapter. Do not rename
// them; add Geraldine concerns to the tables below instead.
// ---------------------------------------------------------------------------

export const user = pgTable("user", {
  id: text("id").primaryKey(),
  name: text("name").notNull(),
  email: text("email").notNull().unique(),
  emailVerified: boolean("email_verified")
    .$defaultFn(() => false)
    .notNull(),
  image: text("image"),
  createdAt: timestamp("created_at")
    .$defaultFn(() => new Date())
    .notNull(),
  updatedAt: timestamp("updated_at")
    .$defaultFn(() => new Date())
    .notNull(),
});

export const session = pgTable("session", {
  id: text("id").primaryKey(),
  expiresAt: timestamp("expires_at").notNull(),
  token: text("token").notNull().unique(),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
  ipAddress: text("ip_address"),
  userAgent: text("user_agent"),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
});

export const account = pgTable("account", {
  id: text("id").primaryKey(),
  accountId: text("account_id").notNull(),
  providerId: text("provider_id").notNull(),
  userId: text("user_id")
    .notNull()
    .references(() => user.id, { onDelete: "cascade" }),
  accessToken: text("access_token"),
  refreshToken: text("refresh_token"),
  idToken: text("id_token"),
  accessTokenExpiresAt: timestamp("access_token_expires_at"),
  refreshTokenExpiresAt: timestamp("refresh_token_expires_at"),
  scope: text("scope"),
  password: text("password"),
  createdAt: timestamp("created_at").notNull(),
  updatedAt: timestamp("updated_at").notNull(),
});

export const verification = pgTable("verification", {
  id: text("id").primaryKey(),
  identifier: text("identifier").notNull(),
  value: text("value").notNull(),
  expiresAt: timestamp("expires_at").notNull(),
  createdAt: timestamp("created_at").$defaultFn(() => new Date()),
  updatedAt: timestamp("updated_at").$defaultFn(() => new Date()),
});

// ---------------------------------------------------------------------------
// Geraldine account key
//
// The account key itself is generated on a client, wrapped with a key derived
// from the user's password, and only ever stored here wrapped. The server holds
// the KDF parameters so any client can reproduce the same derivation, but never
// the password, the derived key, or the account key.
// ---------------------------------------------------------------------------

export const accountKey = pgTable("geraldine_account_key", {
  userId: text("user_id")
    .primaryKey()
    .references(() => user.id, { onDelete: "cascade" }),
  /// Bumped whenever the wrapped key is replaced, so clients can spot a rotation.
  keyVersion: integer("key_version").notNull().default(1),
  kdfAlgorithm: text("kdf_algorithm").notNull(),
  kdfIterations: integer("kdf_iterations").notNull(),
  /// Base64. Not secret — it only provides domain separation per account.
  kdfSalt: text("kdf_salt").notNull(),
  /// Base64 AES-256-GCM ciphertext of the 32-byte account key.
  wrappedAccountKey: text("wrapped_account_key").notNull(),
  /// Base64 nonce used for the wrap.
  wrapNonce: text("wrap_nonce").notNull(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

export const device = pgTable(
  "geraldine_device",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    name: text("name").notNull(),
    platform: text("platform").notNull().default("macos"),
    /// Base64 raw Ed25519 public key used to sign mutations.
    publicKey: text("public_key").notNull(),
    /// Highest device sequence accepted, used to reject replay and rollback.
    lastSequence: bigint("last_sequence", { mode: "number" })
      .notNull()
      .default(0),
    /// Highest server sequence this device has confirmed it has applied.
    ackedSeq: bigint("acked_seq", { mode: "number" }).notNull().default(0),
    createdAt: timestamp("created_at").notNull().defaultNow(),
    lastSeenAt: timestamp("last_seen_at").notNull().defaultNow(),
    revokedAt: timestamp("revoked_at"),
  },
  (table) => [
    index("geraldine_device_user_idx").on(table.userId),
    uniqueIndex("geraldine_device_user_public_key_idx").on(
      table.userId,
      table.publicKey,
    ),
  ],
);

// ---------------------------------------------------------------------------
// Mutations
//
// The ordered log every device pulls from. `serverSeq` is the only ordering
// authority, so device clock skew can never hide a change.
// ---------------------------------------------------------------------------

export const mutation = pgTable(
  "geraldine_mutation",
  {
    serverSeq: bigserial("server_seq", { mode: "number" }).primaryKey(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    mutationId: uuid("mutation_id").notNull(),
    dataset: text("dataset").notNull(),
    recordId: text("record_id").notNull(),
    operation: text("operation").notNull(),
    deviceId: uuid("device_id")
      .notNull()
      .references(() => device.id, { onDelete: "cascade" }),
    deviceSequence: bigint("device_sequence", { mode: "number" }).notNull(),
    modifiedAt: timestamp("modified_at").notNull(),
    schemaVersion: integer("schema_version").notNull().default(1),
    /// Base64 AES-256-GCM envelope. Null for deletes, which carry no payload.
    ciphertext: text("ciphertext"),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  },
  (table) => [
    uniqueIndex("geraldine_mutation_idempotency_idx").on(
      table.userId,
      table.mutationId,
    ),
    uniqueIndex("geraldine_mutation_device_sequence_idx").on(
      table.deviceId,
      table.deviceSequence,
    ),
    index("geraldine_mutation_pull_idx").on(table.userId, table.serverSeq),
    // Compaction reads by record to collapse superseded upserts.
    index("geraldine_mutation_record_idx").on(
      table.userId,
      table.dataset,
      table.recordId,
      table.serverSeq,
    ),
  ],
);

// ---------------------------------------------------------------------------
// Delete-all barrier
//
// "Delete all history" has to beat an offline device that still holds old
// entries, so it is recorded as a point in the log rather than N tombstones.
// ---------------------------------------------------------------------------

export const deletionBarrier = pgTable(
  "geraldine_deletion_barrier",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: text("user_id")
      .notNull()
      .references(() => user.id, { onDelete: "cascade" }),
    dataset: text("dataset").notNull(),
    /// Everything at or below this server sequence is dead for this dataset.
    barrierSeq: bigint("barrier_seq", { mode: "number" }).notNull(),
    issuedByDeviceId: uuid("issued_by_device_id").references(() => device.id, {
      onDelete: "set null",
    }),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  },
  (table) => [
    index("geraldine_deletion_barrier_user_idx").on(table.userId, table.dataset),
  ],
);

// ---------------------------------------------------------------------------
// Audit
//
// Deliberately holds no ciphertext, no clipboard metadata, and no tokens.
// ---------------------------------------------------------------------------

export const auditLog = pgTable(
  "geraldine_audit_log",
  {
    id: uuid("id").primaryKey().defaultRandom(),
    userId: text("user_id").references(() => user.id, { onDelete: "cascade" }),
    deviceId: uuid("device_id"),
    event: text("event").notNull(),
    outcome: text("outcome").notNull(),
    requestId: text("request_id"),
    detail: jsonb("detail"),
    createdAt: timestamp("created_at").notNull().defaultNow(),
  },
  (table) => [index("geraldine_audit_log_user_idx").on(table.userId, table.createdAt)],
);
