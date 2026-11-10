---
name: collections
description: Collections worklist from gGest — who owes money, oldest debts first, with a contact-ready summary per customer (open invoices, Multibanco references, e-invoice status, phone/email, offsets with suppliers). Use for "quem nos deve", "dívidas de clientes", "cobranças", "lista de cobranças", "extrato do cliente", "pendentes", "who owes us", "collections list", "overdue invoices", "customer statement".
---
# Collections (cobranças)

All amounts are **gross, with VAT** (what the customer pays). Run from the project root.

## Steps
1. Overview and control total: `uv run ggest run_saved_query --name finance_receivables_aging`
   (buckets by days past due; TOTAL must match the `Clientes.saldo` control row within a few euros).
2. Worklist, oldest first (no contacts): `uv run ggest run_saved_query --name finance_collections_list --json`
   (`--params '{"order":"amount"}'` for biggest first; `min_open` to skip cents). The first row is the TOTAL over
   all debtors ("TOTAL (N customers, M listed)"): quote totals from it, never from summing a cut list.
   Columns: open_total, overdue, overdue_90d, oldest_due, max_days_overdue, last_payment, pending_mb_refs,
   einvoices_sent, we_owe_them (open supplier/creditor balance with the same NIF), docs.
   Contacts only for the shortlist you print (e.g. top 10 by amount):
   `uv run ggest run_saved_query --name finance_collections_list --params '{"order":"amount","limit":10,"include_contacts":1}'`.
3. For each customer to contact, the statement to send:
   `uv run ggest run_saved_query --name finance_customer_open_items --params '{"customer":"<code, NIF or name>"}'`
   (each open document with due date, days overdue, paid so far, Multibanco entity/reference, e-invoice sent date).
4. Who pays late as a habit (to require upfront payment): `uv run ggest run_saved_query --name finance_slow_payers`.
5. Is the total going up? `uv run ggest run_saved_query --name finance_receivables_trend` (month-end balances).

## Rules and traps
- Open amount = document total − amount settled (`receivable_docs`); credit notes are negative and already netted.
- Due date = document date for most invoices ("pronto pagamento"): "overdue 1–30 days" is normal for credit customers.
- Public entities (NIF starting with 6: hospitals, municipalities, parishes) usually only pay invoices received as
  **e-invoice**: if `einvoice_sent` is empty on an old document, resend it electronically before chasing.
- `we_owe_them` > 0 → propose an offset (encontro de contas) instead of a payment.
- Very old small amounts (> 1 year, a few euros) are usually rounding or forgotten credit notes: list them apart
  as "a regularizar" rather than chasing.
- Phones and emails are personal data: use them to contact, don't paste lists of them into shared documents.

## Output (Portuguese by default)
- **Resumo**: total em dívida, vencido > 90 dias (valor e %), n.º de clientes, variação face ao mês anterior.
- Table, oldest first: Cliente | Em dívida | Vencido > 90 d | Desde | Último pagamento | Contacto | Ação sugerida
  (telefonar / enviar extrato / reenviar e-fatura / encontro de contas / regularizar).
- For each of the top 5: a 2-line message ready to send (documents, total, MB reference), in a polite tone.
