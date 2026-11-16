# Medical P&O ERP

Next.js + TypeScript + Supabase (Auth, PostgreSQL, RLS). Project documentation lives in the claude.ai Project
"Ottobonm System Development" (PROGRESS, DECISIONS, TESTING, RBAC_MATRIX, ...).

## Local checks
- `npm run test:db` — applies `supabase/migrations` to a throwaway local Postgres and runs RLS tests (`supabase/tests`).
- `npm test`, `npx tsc --noEmit`, `npm run build`.

## Configuration
Copy `.env.example` to `.env.local`. Never commit secrets. The Supabase service-role key is not used by the app.

## Supabase
Migrations in `supabase/migrations` are the single source of schema truth. The test shim
(`supabase/tests/00_supabase_shim.sql`) is for local tests only and must never be applied to Supabase.
