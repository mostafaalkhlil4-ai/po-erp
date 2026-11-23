import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { canAccessPath, isAppRole, isPublicPath } from "@/lib/rbac";
import { isBackendConfigured } from "@/lib/env";
import { isDemoEnabled, isDemoPath } from "@/lib/demo";

// Session refresh + UX-level route guard. Authorization of DATA is enforced by RLS.
export async function proxy(request: NextRequest) {
  let response = NextResponse.next({ request });
  const { pathname } = request.nextUrl;
  if (!isBackendConfigured()) {
    const open = ["/", "/login"].includes(pathname) || (isDemoEnabled() && isDemoPath(pathname));
    return open ? response : NextResponse.redirect(new URL("/", request.url));
  }

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (list) => {
          list.forEach(({ name, value }) => request.cookies.set(name, value));
          response = NextResponse.next({ request });
          list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
        },
      },
    },
  );

  // getUser() validates the JWT with the auth server (never trust getSession()).
  const { data: { user } } = await supabase.auth.getUser();
  const redirect = (to: string) => {
    const r = NextResponse.redirect(new URL(to, request.url));
    response.cookies.getAll().forEach((c) => r.cookies.set(c));
    return r;
  };

  if (!user) return isPublicPath(pathname) ? response : redirect("/login");

  const { data: profile } = await supabase
    .from("profiles").select("role,is_active").eq("id", user.id).maybeSingle();

  if (!profile || !profile.is_active || !isAppRole(profile.role)) {
    return pathname === "/pending" ? response : redirect("/pending");
  }
  if (["/login", "/pending", "/", "/forgot"].includes(pathname)) return redirect("/dashboard");
  if (!canAccessPath(profile.role, pathname)) return redirect("/dashboard");
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|ico)$).*)"],
};
