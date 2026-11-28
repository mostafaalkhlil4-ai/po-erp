"use server";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

// Revokes every refresh token of this user (all devices) and ends the current session.
export async function signOutEverywhere() {
  const supabase = await createClient();
  await supabase.auth.signOut({ scope: "global" });
  redirect("/login");
}
