// Pure RBAC helpers. UX-level routing only: real enforcement is RLS + SQL
// permissions (see supabase/migrations). Hiding a route is NOT authorization.
export const ROLES = ["admin", "management", "technician", "doctor", "patient"] as const;
export type AppRole = (typeof ROLES)[number];

export function isAppRole(v: unknown): v is AppRole {
  return typeof v === "string" && (ROLES as readonly string[]).includes(v);
}

/** Route prefixes each role may open in the app shell (Phase 1 baseline). */
const ROUTE_ACCESS: Record<string, readonly AppRole[]> = {
  "/dashboard": ROLES,
  "/reset": ROLES,
  "/admin": ["admin"],
  "/management": ["admin", "management"],
  "/technician": ["admin", "technician"],
  "/doctor": ["admin", "doctor"],
  "/patient": ["admin", "patient"],
};

export const PUBLIC_PATHS = ["/login", "/pending", "/", "/forgot", "/auth/callback"] as const;

export function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((p) => pathname === p);
}

export function canAccessPath(role: AppRole, pathname: string): boolean {
  const prefix = Object.keys(ROUTE_ACCESS).find(
    (p) => pathname === p || pathname.startsWith(p + "/"),
  );
  // Unknown protected paths are denied by default.
  return prefix ? ROUTE_ACCESS[prefix].includes(role) : false;
}
