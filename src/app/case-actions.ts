"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { deviceSchema, componentSchema, followUpSchema, followUpUpdateSchema, attachmentMetaSchema, checkAttachmentFile, ATTACHMENT_MIME } from "@/lib/schemas";

export type UpState = { error?: "invalid" | "forbidden" | "failed" | "file" ; ok?: boolean } | undefined;
function refresh(caseId: string) { revalidatePath(`/technician/cases/${caseId}`); revalidatePath(`/management/cases/${caseId}`); }
const code = (c?: string): UpState => ({ error: c === "42501" ? "forbidden" : c === "23514" ? "invalid" : "failed" });

export async function addDevice(form: FormData): Promise<void> {
  const r = deviceSchema.safeParse(formObject(form, ["case_id", "device_type", "side", "description"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("devices").insert(r.data);
  if (error) console.error("addDevice", error.code);
  refresh(r.data.case_id);
}
export async function addComponent(form: FormData): Promise<void> {
  const r = componentSchema.safeParse(formObject(form, ["device_id", "case_id", "name", "notes"]));
  if (!r.success) return;
  const { case_id, ...row } = r.data;
  const { error } = await (await createClient()).from("device_components").insert(row);
  if (error) console.error("addComponent", error.code);
  refresh(case_id);
}
export async function addFollowUp(form: FormData): Promise<void> {
  const r = followUpSchema.safeParse(formObject(form, ["case_id", "due_date"]));
  if (!r.success) return;
  const { error } = await (await createClient()).from("follow_ups").insert(r.data);
  if (error) console.error("addFollowUp", error.code);
  refresh(r.data.case_id);
}
export async function updateFollowUp(form: FormData): Promise<void> {
  const r = followUpUpdateSchema.safeParse(formObject(form, ["id", "case_id", "status", "technical_feedback", "device_issues"]));
  if (!r.success) return;
  const { case_id, id, ...patch } = r.data;
  const { error } = await (await createClient()).from("follow_ups").update(patch).eq("id", id);
  if (error) console.error("updateFollowUp", error.code);
  refresh(case_id);
}

// D-024 flow: (1) metadata row with a server-generated path, (2) object upload, (3) downloads via /files/<id>.
export async function uploadAttachment(_p: UpState, form: FormData): Promise<UpState> {
  const meta = attachmentMetaSchema.safeParse(formObject(form, ["patient_id", "case_id", "category", "visibility"]));
  const file = form.get("file");
  if (!meta.success || !(file instanceof File)) return { error: "invalid" };
  if (!checkAttachmentFile(file)) return { error: "file" };
  const path = `patients/${meta.data.patient_id}/${crypto.randomUUID()}.${ATTACHMENT_MIME[file.type]}`;
  const supabase = await createClient();
  const { error: e1 } = await supabase.from("attachments").insert({
    ...meta.data, storage_path: path, file_name: file.name, mime_type: file.type, size_bytes: file.size,
  });
  if (e1) return code(e1.code);
  const { error: e2 } = await supabase.storage.from("attachments").upload(path, file, { contentType: file.type, upsert: false });
  if (e2) { console.error("upload", e2.message); return { error: "failed" }; }
  if (meta.data.case_id) refresh(meta.data.case_id);
  return { ok: true };
}
