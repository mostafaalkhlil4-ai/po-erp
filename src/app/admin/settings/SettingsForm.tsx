"use client";
import { useActionState } from "react";
import { saveSettings, type SettingsState } from "./actions";

type L = Record<string, string>;
export function SettingsForm({ l, init }: { l: L; init: { center_name: string; phone: string; email: string; address: string } }) {
  const [s, action, pending] = useActionState<SettingsState, FormData>(saveSettings, undefined);
  return (
    <form action={action}>
      <label htmlFor="center_name">{l.center_name}</label>
      <input id="center_name" name="center_name" defaultValue={init.center_name} maxLength={200} />
      <label htmlFor="phone">{l.phone}</label>
      <input id="phone" name="phone" dir="ltr" defaultValue={init.phone} maxLength={50} />
      <label htmlFor="email">{l.email}</label>
      <input id="email" name="email" type="email" dir="ltr" defaultValue={init.email} maxLength={200} />
      <label htmlFor="address">{l.address}</label>
      <input id="address" name="address" defaultValue={init.address} maxLength={500} />
      <p><button type="submit" disabled={pending}>{l.save}</button></p>
      <div role="status">
        {s?.ok && <span className="ok">{l.saved}</span>}
        {s?.error && <span className="error">{s.error === "forbidden" ? l.err_forbidden : s.error === "invalid" ? l.err_invalid : l.err_failed}</span>}
      </div>
    </form>
  );
}
