#!/usr/bin/env bash
# Starts a LOCAL Supabase (database + auth + storage in Docker), applies all migrations and writes .env.local.
# Nothing here touches any cloud project. Requires Docker running and Node 22.
set -euo pipefail
cd "$(dirname "$0")/.."
npx --yes supabase start
eval "$(npx --yes supabase status -o env | grep -E '^(API_URL|ANON_KEY)=')"
cat > .env.local <<ENV
NEXT_PUBLIC_SUPABASE_URL=${API_URL}
NEXT_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}
ENV
echo "Wrote .env.local for the local stack. Next: npm install && npm run dev  (http://localhost:3000)"
echo "Then sign up at /login and run: npm run local:admin -- you@example.com"
