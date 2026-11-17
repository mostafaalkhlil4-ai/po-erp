"use client";
import { useActionState, useState } from "react";
import { addItem } from "./actions";
type L = Record<string, string>;
export function ItemForm({ quotationId, products, l }: { quotationId: string; products: { id: string; label: string }[]; l: L }) {
  const [s, a, p] = useActionState(addItem, undefined);
  const [type, setType] = useState("product");
  return (
    <form action={a} noValidate>
      <input type="hidden" name="quotation_id" value={quotationId} />
      <label htmlFor="item_type">{l.itemType}</label>
      <select id="item_type" name="item_type" value={type} onChange={(e) => setType(e.target.value)}>
        <option value="product">{l.product}</option><option value="material">{l.material}</option><option value="service">{l.service}</option>
      </select>
      {type === "product" ? (<>
        <label htmlFor="product_id">{l.product}</label>
        <select id="product_id" name="product_id" required>{products.map((x) => <option key={x.id} value={x.id}>{x.label}</option>)}</select>
        <p><small>{l.autoPrice}</small></p>
      </>) : (<>
        <label htmlFor="description">{l.details}</label><input id="description" name="description" required maxLength={500} />
        <label htmlFor="unit_price">{l.price}</label><input id="unit_price" name="unit_price" type="number" step="0.01" min="0" required dir="ltr" />
      </>)}
      <label htmlFor="quantity">{l.quantity}</label><input id="quantity" name="quantity" type="number" step="0.01" min="0.01" defaultValue="1" required dir="ltr" />
      {s?.error && <p role="alert" className="error">{l[`err_${s.error}`]}</p>}
      <p><button type="submit" disabled={p}>{l.add}</button></p>
    </form>
  );
}
