---
name: recurring-contracts
description: Recurring contracts (avenças: hosting, domains, DNS, licences, subscriptions) in gGest — active contracts, monthly recurring revenue, contracts due or overdue for billing, never billed, unpaid renewals and cancellations. Use for "avenças", "contratos recorrentes", "o que falta faturar", "faturar avenças do mês", "receita recorrente", "MRR", "renovações de domínios", "recurring revenue", "subscriptions to invoice".
---
# Recurring contracts (avenças)

Values **net of VAT**. Run from the project root.

## Steps
1. Portfolio: `uv run ggest run_saved_query --name finance_recurring_revenue_summary`
   (per item: active contracts, customers, annual value, MRR, to_bill_now, inactive, billed_last_12m as a check).
2. What to invoice now or soon:
   `uv run ggest run_saved_query --name finance_recurring_contracts --params '{"status":"to_bill","days_ahead":30}'`
   billing_status: overdue (next billing date passed, no invoice yet), never_billed, due_soon.
3. Full list or cancelled ones: `--params '{"status":"all"}'` / `'{"status":"inactive"}'`.
   `last_doc_unpaid` > 0 = the last renewal invoice is still open: chase it (collections skill) before renewing.
4. All recurring revenue streams, including software update contracts not managed as avenças:
   `uv run ggest run_saved_query --name sales_recurring_revenue_by_year`.

## Rules and traps
- amount_per_billing = quantity × unit price; annual_value = amount × billings per year
  (MENSAL 12, TRIMESTRAL 4, SEMESTRAL 2, ANUAL 1); MRR = annual / 12.
- next_billing is the date gGest will propose the next invoice (Avenças > processar). `never_billed` may simply
  be a new contract: check start_date.
- The same service can appear twice when the customer record changed (old code kept active): check duplicates
  by description before invoicing.
- Inactive = the contract was stopped in gGest; the customer may still have other contracts.

## Output (Portuguese by default)
- **Resumo**: contratos ativos, clientes, valor anual e MRR; quantos estão por faturar.
- Table "A faturar": Cliente | Serviço | Valor | Próxima faturação | Estado (atrasado / nunca faturado / em breve).
- Table "Renovações por pagar" (last_doc_unpaid > 0) and a note on cancellations.
