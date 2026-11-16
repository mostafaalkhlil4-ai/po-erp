// FormData -> plain object of strings (missing fields become "").
export function formObject(form: FormData, keys: string[]): Record<string, string> {
  return Object.fromEntries(keys.map((k) => [k, typeof form.get(k) === "string" ? (form.get(k) as string) : ""]));
}
