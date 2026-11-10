---
name: customer-briefing
description: Everything about one customer before a call, visit or quote — profile, segment, purchases by year, what they buy, devices they own, repairs, open balance, contracts, last contact. Use for "ficha do cliente", "o que sabemos do cliente X", "vou visitar o X", "prepara a reunião com", "customer briefing", "tell me about customer X".
---
# Customer briefing (ficha de cliente antes de contacto/visita)

Run from the project root. `<c>` = customer code (preferred) or NIF; a name fragment works only in step 1.

1. **Find the customer** (code, NIF or part of the name; LIKE is accent-sensitive, so type "munic" not "município"):
   `uv run ggest run_saved_query --name customers_briefing --params '{"customer":"<name or code>"}' --json`
   - Several rows → pick the right one (same `entity_key` = same NIF = same legal entity) or ask the user.
   - `records_same_entity > 1` → other records share the NIF; the next steps merge them by default (`merge_nif=1`).
2. **History by year**: `uv run ggest run_saved_query --name customers_history_by_year --params '{"customer":"<c>"}'`
3. **What they buy**: `uv run ggest run_saved_query --name customers_purchase_mix --params '{"customer":"<c>","limit":10}'`
   (add `"start":"years_ago_3"` for recent habits).
4. **Equipment they own**: `uv run ggest run_saved_query --name customers_devices --params '{"customer":"<c>","limit":20}'`
5. **Latest interactions**: `uv run ggest run_saved_query --name customers_timeline --params '{"customer":"<c>","limit":15}'`
6. **"Biggest customer" questions** (e.g. maior cliente empresa): rank entities first —
   `uv run ggest run_saved_query --name customers_top_entities --params '{"segment":"empresa","limit":10}'` (`"by":"margin"`
   for profit) — then brief the chosen one. Check `largest_invoice_share_pct`: above ~50% means one project made the
   total (one-off, not a regular customer); say so and also name the best *recurring* customer.
7. Optional: debt detail `uv run ggest run_saved_query --name finance_receivables_open --params '{"min_open":0}'` (filter
   the customer); repair desk view `uv run ggest saved_queries --domain repairs`.

## Reading the results
- `segment`: publico / empresa / particular / associativo (rules in `docs/domains/customers.md`).
- Money is **net of VAT** except `open_balance_gross` (VAT included, unpaid documents; `oldest_open_doc` = age).
- `relationship`: buys_and_repairs, buys_only, repairs_only (never bought: first-sale opportunity), quotes_only.
- `open_repairs` > 0: equipment still in the workshop — mention it first.
- `days_since_contact` > 365 with good lifetime value = lapsed (see skill winback-campaign).
- Devices with `years_since_last` ≥ 5 (notebooks/desktops/printers) = replacement opportunity; many repairs on the
  same equipment type = propose maintenance contract (avença) or new equipment.
- `active_contracts`/`contracts_annual_net`/`next_contract_billing` (yyyymmdd): domain/hosting/maintenance avenças.
- `has_alert_note` / `alert_note_chars`: a gGest pop-up note exists. The text is **not** returned by default; only if the
  user asks to see it, rerun with `"show_alert_note":1`, then summarise it and **never quote passwords, serials or
  personal data** (same for repair texts).
- Repair counts: `repairs_all_time_record` (this record, all years) differs from `customers_top_entities.repairs_in_period_entity`
  (all records with the NIF, only the period) and from `top_customers` — say which one you report.
- `largest_invoice_share_pct`: share of lifetime sales from the single largest invoice (high = one-off project).
- Margin is an estimate (services show 100%).

## Output (Portuguese by default)
A one-page brief:
- **Quem é**: nome, código, segmento, NIF válido?, cliente desde, canais disponíveis (só "tem email/telemóvel", sem valores).
- **Números**: vendas totais e últimos 12 meses, margem %, faturas, último ano forte; tabela curta por ano (últimos 5).
- **O que compra / equipamentos**: 3–5 linhas; equipamentos antigos.
- **Assistências**: total, abertas, última.
- **Dinheiro**: saldo em aberto (com IVA) e antiguidade; avenças ativas.
- **Último contacto** e **3 sugestões de conversa** (renovar equipamento, consumíveis habituais, avença, cobrança).
