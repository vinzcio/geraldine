import { drizzle } from "drizzle-orm/node-postgres";
import { Pool } from "pg";

import * as schema from "./schema";

const connectionString = process.env.DATABASE_URL;
if (!connectionString) {
  throw new Error("DATABASE_URL is not set");
}

// Next dev reloads this module on every edit; without the global the pool leaks
// connections until Postgres refuses new ones.
const globalForDb = globalThis as unknown as { geraldinePool?: Pool };

export const pool =
  globalForDb.geraldinePool ??
  new Pool({
    connectionString,
    max: Number(process.env.DATABASE_POOL_MAX ?? 10),
  });

if (process.env.NODE_ENV !== "production") {
  globalForDb.geraldinePool = pool;
}

export const db = drizzle(pool, { schema });
export { schema };
