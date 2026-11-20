"use client";
import { useActionState } from "react";
import { uploadAttachment } from "@/app/case-actions";
type L = Record<string, string>;
export function UploadForm({ patientId, caseId, l }: { patientId: string; caseId: string; l: L }) {
  const [s, a, p] = useActionState(uploadAttachment, undefined);
  return (
    <form action={a} noValidate key={s?.ok ? "ok" : "f"}>
      <input type="hidden" name="patient_id" value={patientId} /><input type="hidden" name="case_id" value={caseId} />
      <label htmlFor="file">{l.file}</label><input id="file" name="file" type="file" required accept="image/jpeg,image/png,image/webp,application/pdf" />
      <label htmlFor="category">{l.category}</label>
      <select id="category" name="category"><option value="photo">{l.photo}</option><option value="document">{l.document}</option><option value="design">{l.design}</option><option value="report">{l.report}</option><option value="other">{l.other}</option></select>
      <label htmlFor="visibility">{l.visibility}</label>
      <select id="visibility" name="visibility"><option value="internal">{l.internal}</option><option value="shared">{l.shared}</option></select>
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      {s?.ok && <p role="status">{l.saved}</p>}
      <p><button type="submit" disabled={p}>{l.upload}</button></p>
    </form>
  );
}
