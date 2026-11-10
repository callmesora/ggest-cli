# Finance domain: receivables, payables, payments, till, overheads, recurring contracts, VAT, obligations

Core views used: `sales_facts`, `sales_docs`, `doc_types`, `customers`; config tables `_bi_expense_rules` /
`_bi_config` (expense categories from `ggest.json`). This domain adds `bi/sql/ext/finance.sql`
(apply: `uv run ggest build-views --file bi/sql/ext/finance.sql`) and the saved queries `bi/queries/finance/finance_*.sql`
(`uv run ggest saved_queries --domain finance`). Skills: `collections`, `month-close`, `payables-and-cash`,
`recurring-contracts`, `tax-calendar` (`.claude/skills/`).

## Views added

| view | raw tables | one row per | notes |
|---|---|---|---|
| `receivable_docs` | `cab_vendas` + `Documentos` | customer document that goes through the current account (`mov_cc` 2/3: FT, FTGOL, NC, VIAT…) | gross (with VAT), `settled`, `open_amount`, `is_open`, `due_date` (= doc date when empty). `SUM(open_amount)` = `Clientes.saldo` total = `totais_clientes` |
| `payable_docs` | `cab_compras` + `Cab_DirCC_Cre` + `Documentos` | supplier document / 'outros credores' document | `party_type` supplier/creditor, net/vat/gross, `open_amount`. **`doc_id` is not unique for creditors** → use `doc_key` (`doc_id@party_code`). Total open = `Fornecedores.saldo` + `Credores.saldo` |
| `expense_docs` | `payable_docs` (creditors) + `_bi_expense_rules` | overhead document (FTOC/FROC/NCOC) | `category` (first matching rule; default category otherwise), `pnl_line` derived from the category name: staff / rent / investment / loans / taxes / opex. Net of VAT |
| `payment_docs` | `cab_recpag` + `Lin_caixa` | receipt (R, RECPT, ACERT; `direction` in) or payment (P supplier, POC creditor; out) | `amount` positive; `method` = main till payment method (receipts only) |
| `payment_allocations` | `lin_recpag` + `cab_recpag` | settlement line: payment × settled document | `settled_doc_id` / `settled_doc_key`, `amount`, `payment_date`. Reconciles exactly with `Total_liquidado`. Use to rebuild balances at a past date |
| `till_movements` | `Lin_caixa` + `cab_caixa` + `formas_pagamento` | till line | `method_group` (cash, card, transfer, mb_reference, mbway, cheque, offset), signed cash-flow `amount`; opening/closing lines and internal consumption excluded |
| `recurring_contracts` | `Avencas_Clientes` + `Avencas` + `customers` | contract (avença) per customer | `period`, `amount_per_billing` (qty × unit net), `annual_value`, `monthly_value`, `is_active`, `next_billing`, `last_billed`, `last_doc_id` |
| `vat_lines` | `cab_vendas`, `cab_compras`, `Cab_DirCC_Cre` (VAT slots 1–7) | document × VAT rate | `side` sales/purchases/overheads, `vat_code` (→ `ivas`), `vat_rate`, `vat_regime`, signed `base` and `vat`, `data_fix` (see traps) |
| `tax_obligations` | `expediente_obrigacoes` | obligation × month it applies | `due_day`, `alert_days`, description/note (free text) |
| `mb_references` | `mov_refMB` | Multibanco reference generated for a sales document | `status` pending/closed, `amount`, `generated_on`, `closed_on` |

Saved queries (main): `finance_collections_list`, `finance_customer_open_items`, `finance_receivables_open/_aging/_trend`,
`finance_slow_payers`, `finance_days_to_pay_by_year`, `finance_payables_open`, `finance_payments_made`,
`finance_cash_flow_by_month`, `finance_till_by_day`, `finance_payment_methods`, `finance_month_close`,
`finance_profit_and_loss_by_year`, `finance_operating_expenses_by_category`, `finance_vat_by_period`, `finance_vat_by_year`,
`finance_vat_quarter_projection`, `finance_tax_calendar` (mode next/all, past-due flag), `finance_recurring_contracts`, `finance_recurring_revenue_summary`,
`finance_customer_supplier_offsets`, `finance_efatura_unmatched`, purchases/freight/stock-value queries.

## Key codes
- **`Documentos.mov_cc`** (how a document moves the current account): `3` debit (invoice: balance grows), `2` credit
  (credit note, receipt, payment), `4` settled on the spot (FR invoice-receipt, NCP refund, FROC), `0` none.
  Use it for signs instead of hard-coding credit-note codes.
- **Current-account documents** (`cab_recpag`/`lin_recpag`): `R` receipt, `RECPT` receipt (sponsorship), `ACERT`
  offset receipt, `P` supplier payment, `POC` creditor payment, `_RCRE`/`_RPAG` withholding on payments.
- **Creditors** (`Cab_DirCC_Cre`, 'outros credores'): `FTOC` invoice, `FROC` invoice-receipt, `NCOC` credit note;
  `_CCRE` credit on account. Suppliers' extra docs: `Cab_DirCC_For` (`VPC` payment on account, `_CPAG` credit on
  account); customers: `Cab_DirCC` (`_CREC` credit on account).
- **Year-end carry-forward records** `_FCLC/_FCLD` (customers), `_FFOC/_FFOD` (suppliers), `_FCRC/_FCRD`
  (creditors), text "TRANSPORTE DO ANO": opening balances, no date — never count them as movements.
- **Till** (`cab_caixa`/`Lin_caixa`): `_CX01` opening, `_CX02` cash in, `_CX03` cash out, `_CX99` closing (repeats
  the totals by method — never add). Payment methods `formas_pagamento` (NUM cash, MB card, TRB transfer, `if`/`eas`
  Multibanco-reference providers, mbway, CHQB cheque, `ace` offset); `tipos_pagamento` = method families.
- **VAT**: `ivas` (code → rate, regime, exemption M-code, fiscal space PTA Azores / PTC mainland), `regime_iva`
  (`int` intra-EU, `aut` reverse charge, `ext`/`ter` exports, `aço`/`açp` Azores 0 %…), `isencoes_iva` (M01–M99 legal basis).
- **Avenças periods**: MENSAL, TRIMESTRAL, SEMESTRAL, ANUAL; `Fim` 2199-12-31 = no end; `Inativo` 1 = stopped.
- `mov_refMB.estado`: 1 pending, 2 closed (document settled by any means).

## Joins
- Sales/receivable docs: `Codigo || ' ' || serie || '/' || numero` = `doc_id` everywhere (`sales_docs`, `mb_references`,
  `registo_fact_eletronica` codigo/serie/numero, `recurring_contracts.last_doc_id`, `payment_allocations.settled_doc_id`).
- `lin_recpag` → `cab_recpag` on (Codigo, serie, numero, **entidade_codigo**) (payment numbers can repeat);
  `lin_recpag.liquida_codigo/serie/numero` (+ `entidade_codigo` for suppliers/creditors) → the settled document.
- `Lin_caixa` → `cab_caixa` on (Codigo, numero, serie, ano); `Lin_caixa` (Codigo, serie, numero) → the R/FR document.
- Customer ↔ supplier/creditor: same NIF (`Clientes.contribuinte` = `Fornecedores`/`Credores.contribuinte`).
- `cab_efatura`/`lin_efatura` (documents imported from the tax authority's e-fatura portal, supplier side):
  match to `cab_compras`/`Cab_DirCC_Cre` by issuer NIF + total + date (only a handful carry `doc_codigo`).

## Traps
- Receivables and payables are **gross (with VAT)**; P&L/overheads/purchases are **net**.
- Balance at a past date = documents dated ≤ D − allocations dated ≤ D (`finance_receivables_trend`,
  `finance_month_close`); with the entity in the join this matches today's open balance exactly.
- Joining views on computed `doc_id` strings is slow: materialize first (`WITH x AS MATERIALIZED (...)`).
- `expense_docs.category` is a correlated rule lookup: query the view once per answer.
- Overheads exist only from the year the company started registering them as 'outros credores'.
- Supplier/creditor payments do not pass through the till, and the bank modules (`Movimentos_Bancarios`,
  `cab_extratos_bancos`, `contas_bancarias_entidades`) are empty: there is no bank balance in gGest.
- `vat_lines` is indicative: no self-assessment of reverse-charge VAT.
- **VAT typed on a 0 % slot** (creditor documents): with no base it is the whole amount typed in the VAT box (e.g. a
  salary or postage fee) → moved to base, VAT 0 (`data_fix = amount_in_vat_box_moved_to_base`; `payable_docs` /
  `expense_docs` apply the same rule, so those amounts count as costs, not deductible VAT); with a base it is a wrong
  VAT code → rate derived from vat/base (`rate_derived_from_amounts`).
- Balances in `finance_month_close` are at each period end; `finance_receivables_aging/_open` are at the data date.
- `mov_refMB` "closed" ≠ paid by reference: the reference closes when the receipt is issued. Paid-by-reference = till
  method `if`/`eas`.
- `expediente_obrigacoes_geradas` (done/not done per month) is rarely maintained: treat the calendar as a plan only.
  Obligation texts and `Avencas` descriptions can contain personal names and customer domains.
- `registo_fact_eletronica` = invoices sent as electronic invoices (public-sector customers); `data_hora_envio`
  empty/zero = not sent.
- `cab_efatura` is imported occasionally (a few months only): "unmatched" is meaningful only for imported periods.
- Small tables `Dinheiro` (coin/note denominations), `prazos_pagamento` (payment terms: pronto, 30 days…),
  `tipos_mov_bancarios`, `despesas`/`lin_despesas` (freight/customs extra costs on a few purchase invoices) are
  configuration or near-empty; `conf_refMB`/`contas_bancarias` hold payment-provider/bank settings — never expose
  account numbers.
