"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { formObject } from "@/lib/form";
import { productSchema, categorySchema, priceSchema } from "@/lib/schemas";

export type CatState = { error?: "invalid" | "forbidden" | "duplicate" | "failed"; ok?: boolean } | undefined;
const code = (c?: string): CatState => ({ error: c === "42501" ? "forbidden" : c === "23505" ? "duplicate" : c === "23514" ? "invalid" : "failed" });

export async function createCategory(_p: CatState, form: FormData): Promise<CatState> {
  const r = categorySchema.safeParse(formObject(form, ["name"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("product_categories").insert(r.data);
  if (error) return code(error.code);
  revalidatePath("/management/catalog"); return { ok: true };
}
export async function createProduct(_p: CatState, form: FormData): Promise<CatState> {
  const r = productSchema.safeParse(formObject(form, ["manufacturer_id", "category_id", "name", "sku", "description"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("products").insert(r.data);
  if (error) return code(error.code);
  revalidatePath("/management/catalog"); return { ok: true };
}
export async function addPrice(_p: CatState, form: FormData): Promise<CatState> {
  const r = priceSchema.safeParse(formObject(form, ["product_id", "price", "currency"]));
  if (!r.success) return { error: "invalid" };
  const { error } = await (await createClient()).from("product_price_history").insert(r.data);
  if (error) return code(error.code);
  revalidatePath("/management/catalog"); return { ok: true };
}
