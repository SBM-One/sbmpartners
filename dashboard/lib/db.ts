import postgres from "postgres";

// One connection pool for the whole server. Only server code imports this file.
const globalForDb = globalThis as unknown as { sql?: postgres.Sql };

export const sql =
  globalForDb.sql ??
  postgres(process.env.DATABASE_URL ?? "", {
    max: 5,
    prepare: false, // works with Supabase's connection pooler
    idle_timeout: 20,
    types: { numeric: { to: 0, from: [1700], serialize: (x: unknown) => String(x), parse: (x: string) => Number(x) } },
  });

if (process.env.NODE_ENV !== "production") globalForDb.sql = sql;
