import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Short-lived signed URL. Access is decided by RLS on the attachment row (and again by storage policies).
export async function GET(request: NextRequest, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f-]{36}$/i.test(id)) return new NextResponse("Not found", { status: 404 });
  const supabase = await createClient();
  const { data: row } = await supabase.from("attachments").select("storage_path").eq("id", id).maybeSingle();
  if (!row) return new NextResponse("Not found", { status: 404 });
  const { data, error } = await supabase.storage.from("attachments").createSignedUrl(row.storage_path, 60);
  if (error || !data) return new NextResponse("Not found", { status: 404 });
  return NextResponse.redirect(data.signedUrl, { headers: { "Cache-Control": "no-store" } });
}
