---
name: tax-calendar
description: Tax and accounting calendar from gGest — upcoming obligations (SAF-T, VAT return, social security, payroll, withholding tax, monthly maps for the accountant) with due dates, plus the VAT position per period by rate. Use for "obrigações fiscais", "o que temos de entregar", "prazos", "IVA a pagar", "declaração de IVA", "calendário fiscal", "SAF-T", "tax calendar", "VAT return", "what is due this month".
---
# Tax calendar and VAT

Run from the project root.

## Steps
1. Upcoming obligations: `py -m bi run_saved_query --name finance_tax_calendar` — the next due date of each
   obligation (status upcoming / due_today) plus the ones passed in the last 15 days and not marked done
   (status past_due_not_marked_done, listed first). Every occurrence in a window:
   `--params '{"mode":"all","days_ahead":60,"days_back":15}'`. The list is gGest's obligations calendar
   (Expediente > Obrigações).
2. VAT for the period to declare (quarterly by default; `"granularity":"month"` for monthly filers):
   `py -m bi run_saved_query --name finance_vat_by_period --params '{"start":"2026-07-01","end":"2026-09-30"}'`
   → base and VAT per rate for sales (output) and purchases/overheads (input), and a NET row (positive = to pay).
3. Current quarter estimate: `py -m bi run_saved_query --name finance_vat_quarter_projection`
   (quarter-to-date, linear projection by days, seasonal projection from last year's same quarter, last year's actual).
   Year view: `py -m bi run_saved_query --name finance_vat_by_year`.
4. Invoices the tax authority has but gGest does not (missing input VAT):
   `py -m bi run_saved_query --name finance_efatura_unmatched` (only the periods imported from e-fatura).
5. Payroll, social security and taxes actually paid:
   `py -m bi run_saved_query --name finance_payments_made --params '{"party_type":"creditor"}'`.

## Rules and traps
- VAT figures are **indicative** (built from gGest documents): reverse charge on intra-EU purchases (regime
  `int`/`aut`) is not self-assessed and costs not registered in gGest are missing. The accountant files the return.
- Azores rates are lower than the mainland (e.g. 16 % vs 23 % on mainland supplier invoices): a small or
  negative NET is common and means VAT to recover.
- "Done" comes from gGest's generated-obligations table, which is often not maintained: present
  past_due_not_marked_done as "confirmar se foi feito", not as a missed deadline.
- VAT typed by mistake on a 0 % line is corrected in the data (`vat_lines.data_fix`): 0 % rows carry no VAT.
- Some obligation descriptions name people (owner, staff): don't repeat names outside the company.

## Output (Portuguese by default)
- **Próximos prazos**: table Data | Faltam (dias) | Obrigação | Nota — passed/at-risk first.
- **IVA do período**: liquidado, dedutível, saldo (a pagar / a recuperar), with the main rates.
- One line of advice when something is due within 5 days.
