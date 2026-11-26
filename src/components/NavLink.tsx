"use client";
import { usePathname } from "next/navigation";
import type { ReactNode } from "react";

// Marks the current section for the sidebar (visual + aria-current). Authorization is NOT decided here.
export function NavLink({ href, children }: { href: string; children: ReactNode }) {
  const path = usePathname() ?? "";
  const active = path === href || path.startsWith(href + "/");
  return <a href={href} aria-current={active ? "page" : undefined}>{children}</a>;
}
