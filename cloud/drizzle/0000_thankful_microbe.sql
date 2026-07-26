CREATE TABLE "account" (
	"id" text PRIMARY KEY NOT NULL,
	"account_id" text NOT NULL,
	"provider_id" text NOT NULL,
	"user_id" text NOT NULL,
	"access_token" text,
	"refresh_token" text,
	"id_token" text,
	"access_token_expires_at" timestamp,
	"refresh_token_expires_at" timestamp,
	"scope" text,
	"password" text,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL
);
--> statement-breakpoint
CREATE TABLE "geraldine_account_key" (
	"user_id" text PRIMARY KEY NOT NULL,
	"key_version" integer DEFAULT 1 NOT NULL,
	"kdf_algorithm" text NOT NULL,
	"kdf_iterations" integer NOT NULL,
	"kdf_salt" text NOT NULL,
	"wrapped_account_key" text NOT NULL,
	"wrap_nonce" text NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"updated_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "geraldine_audit_log" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text,
	"device_id" uuid,
	"event" text NOT NULL,
	"outcome" text NOT NULL,
	"request_id" text,
	"detail" jsonb,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "geraldine_deletion_barrier" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"dataset" text NOT NULL,
	"barrier_seq" bigint NOT NULL,
	"issued_by_device_id" uuid,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "geraldine_device" (
	"id" uuid PRIMARY KEY DEFAULT gen_random_uuid() NOT NULL,
	"user_id" text NOT NULL,
	"name" text NOT NULL,
	"platform" text DEFAULT 'macos' NOT NULL,
	"public_key" text NOT NULL,
	"last_sequence" bigint DEFAULT 0 NOT NULL,
	"acked_seq" bigint DEFAULT 0 NOT NULL,
	"created_at" timestamp DEFAULT now() NOT NULL,
	"last_seen_at" timestamp DEFAULT now() NOT NULL,
	"revoked_at" timestamp
);
--> statement-breakpoint
CREATE TABLE "geraldine_mutation" (
	"server_seq" bigserial PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"mutation_id" uuid NOT NULL,
	"dataset" text NOT NULL,
	"record_id" text NOT NULL,
	"operation" text NOT NULL,
	"device_id" uuid NOT NULL,
	"device_sequence" bigint NOT NULL,
	"modified_at" timestamp NOT NULL,
	"schema_version" integer DEFAULT 1 NOT NULL,
	"ciphertext" text,
	"created_at" timestamp DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "session" (
	"id" text PRIMARY KEY NOT NULL,
	"expires_at" timestamp NOT NULL,
	"token" text NOT NULL,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	"ip_address" text,
	"user_agent" text,
	"user_id" text NOT NULL,
	CONSTRAINT "session_token_unique" UNIQUE("token")
);
--> statement-breakpoint
CREATE TABLE "user" (
	"id" text PRIMARY KEY NOT NULL,
	"name" text NOT NULL,
	"email" text NOT NULL,
	"email_verified" boolean NOT NULL,
	"image" text,
	"created_at" timestamp NOT NULL,
	"updated_at" timestamp NOT NULL,
	CONSTRAINT "user_email_unique" UNIQUE("email")
);
--> statement-breakpoint
CREATE TABLE "verification" (
	"id" text PRIMARY KEY NOT NULL,
	"identifier" text NOT NULL,
	"value" text NOT NULL,
	"expires_at" timestamp NOT NULL,
	"created_at" timestamp,
	"updated_at" timestamp
);
--> statement-breakpoint
ALTER TABLE "account" ADD CONSTRAINT "account_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_account_key" ADD CONSTRAINT "geraldine_account_key_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_audit_log" ADD CONSTRAINT "geraldine_audit_log_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_deletion_barrier" ADD CONSTRAINT "geraldine_deletion_barrier_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_deletion_barrier" ADD CONSTRAINT "geraldine_deletion_barrier_issued_by_device_id_geraldine_device_id_fk" FOREIGN KEY ("issued_by_device_id") REFERENCES "public"."geraldine_device"("id") ON DELETE set null ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_device" ADD CONSTRAINT "geraldine_device_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_mutation" ADD CONSTRAINT "geraldine_mutation_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "geraldine_mutation" ADD CONSTRAINT "geraldine_mutation_device_id_geraldine_device_id_fk" FOREIGN KEY ("device_id") REFERENCES "public"."geraldine_device"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
ALTER TABLE "session" ADD CONSTRAINT "session_user_id_user_id_fk" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE INDEX "geraldine_audit_log_user_idx" ON "geraldine_audit_log" USING btree ("user_id","created_at");--> statement-breakpoint
CREATE INDEX "geraldine_deletion_barrier_user_idx" ON "geraldine_deletion_barrier" USING btree ("user_id","dataset");--> statement-breakpoint
CREATE INDEX "geraldine_device_user_idx" ON "geraldine_device" USING btree ("user_id");--> statement-breakpoint
CREATE UNIQUE INDEX "geraldine_device_user_public_key_idx" ON "geraldine_device" USING btree ("user_id","public_key");--> statement-breakpoint
CREATE UNIQUE INDEX "geraldine_mutation_idempotency_idx" ON "geraldine_mutation" USING btree ("user_id","mutation_id");--> statement-breakpoint
CREATE UNIQUE INDEX "geraldine_mutation_device_sequence_idx" ON "geraldine_mutation" USING btree ("device_id","device_sequence");--> statement-breakpoint
CREATE INDEX "geraldine_mutation_pull_idx" ON "geraldine_mutation" USING btree ("user_id","server_seq");--> statement-breakpoint
CREATE INDEX "geraldine_mutation_record_idx" ON "geraldine_mutation" USING btree ("user_id","dataset","record_id","server_seq");