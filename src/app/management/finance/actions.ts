"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { paymentSchema, expenseSchema, voidInvoiceSchema, quotationIdSchema } from "@/lib/schemas";

export type FinState = { error?: "invalid" | "forbidden" | "exceeds" | "failed"; ok?: boolean } | undefined;
const map = (c?: string): FinState => ({ error: c === "42501" ? "forbidden" : c === "23514" ? "exceeds" : "failed" });

export async function recordPayment(_p: FinState, form: FormData): Promise<FinState> {
  const r = paymentSchema.safeParse(formObject(form, ["invoice_id", "amount", "method", "reference"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("payments").insert(r.data);
  if (error) return map(error.code);
  revalidatePath("/management/finance"); return { ok: true };
}
export async function addExpense(_p: FinState, form: FormData): Promise<FinState> {
  const r = expenseSchema.safeParse(formObject(form, ["category", "description", "amount", "currency", "incurred_on"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("expenses").insert(r.data);
  if (error) return map(error.code);
  revalidatePath("/management/finance"); return { ok: true };
}
export async function issueInvoice(form: FormData): Promise<void> {
  const r = quotationIdSchema.safeParse(formObject(form, ["id"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc("issue_invoice", { p_quotation: r.data.id });
  if (error) { console.error("issueInvoice", error.code); return; }
  redirect("/management/finance");
}
export async function voidInvoice(form: FormData): Promise<void> {
  const r = voidInvoiceSchema.safeParse(formObject(form, ["id", "reason"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc("void_invoice", { p_invoice: r.data.id, p_reason: r.data.reason });
  if (error) console.error("voidInvoice", error.code);
  revalidatePath("/management/finance");
}

import { visibilitySchema } from "@/lib/schemas";
// Staff decide manually what the patient sees (D-029 amended, migration 0013).
export async function setVisibility(form: FormData): Promise<void> {
  const r = visibilitySchema.safeParse(formObject(form, ["kind", "id", "visible"]));
  if (!r.success) return;
  const { error } = await (await createClient()).rpc("set_patient_visibility", { p_kind: r.data.kind, p_ref: r.data.id, p_visible: r.data.visible });
  if (error) console.error("setVisibility", error.code);
  revalidatePath("/management/finance"); revalidatePath(`/management/quotations/${r.data.id}`);
}
