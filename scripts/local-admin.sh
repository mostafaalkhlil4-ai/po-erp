#!/usr/bin/env bash
# Promotes the FIRST admin on the LOCAL database, after that person signed up at /login.
# Works only while no active admin exists (same guard as supabase/bundle/first_admin.sql).
set -euo pipefail
cd "$(dirname "$0")/.."
email="${1:-}"
if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then echo "usage: npm run local:admin -- you@example.com" >&2; exit 2; fi
sed "s/REPLACE_WITH_YOUR_EMAIL/${email}/" supabase/bundle/first_admin.sql \
  | docker exec -i supabase_db_po-erp psql -U postgres -v ON_ERROR_STOP=1 -q
echo "OK: ${email} is now admin. Sign out and sign in again."
