---
name: winback-campaign
description: Build a reactivation (win-back) list of valuable customers who stopped buying, with what they used to buy, warm leads first and the contact channel available. Use for "clientes perdidos", "clientes que deixaram de comprar", "campanha de reativação", "quem devemos contactar", "win-back", "lapsed / churned customers", "RFM at risk".
---
# Win-back campaign (reativação de clientes)

Run from the project root. Customers are merged by NIF (`entity_key`), walk-in excluded.

1. **Size of the problem (RFM)**: `py -m bi run_saved_query --name customers_rfm_summary`
   Labels 4 "Não pode perder" (bought a lot, ~2 years absent) and 5 "Em risco" are the targets.
2. **Campaign list with what they bought**:
   `py -m bi run_saved_query --name customers_winback_products --params '{"min_net":500,"inactive_days":540,"limit":50}' --json`
   - Narrow: `"segment":"empresa"` (or publico / particular / associativo); shorter absence: `"inactive_days":365`.
3. **RFM detail of label 4**: `py -m bi run_saved_query --name customers_rfm --params '{"label":"4","limit":100}'`
4. **Repair-only customers to convert** (come to the workshop, buy little):
   `py -m bi run_saved_query --name customers_repairs_vs_purchases --params '{"quadrant":"repara_muito_compra_pouco"}'`
5. Public bodies: before declaring one lost, check if it now buys under another NIF/name:
   `py -m bi run_saved_query --name customers_duplicates --params '{"kind":"name"}'` and
   `py -m bi run_saved_query --name customers_briefing --params '{"customer":"<part of name>"}'`.

## Prioritise
1. `still_in_touch = 1` (repaired, asked a quote or had an appointment after the last purchase): warm, easy to call.
2. Highest `lifetime_net` and `lifetime_margin`; empresas return more often than particulares.
3. Offer: start from `suggested_offer` (rule of thumb: PC replacement with the year of the last PC, consumables reminder,
   software update/maintenance, printer replacement, convert repair contact) and refine with `top_groups`/`top_items`;
   public bodies → present to the new department.
4. `same_name_active_code` set → an active record with the same name exists under another NIF (a person now buying via
   their own company, or a public body with a new NIF): not really lost — check it before contacting.
5. `records_same_nif` = records merged into that NIF; one body with two NIFs shows as two rows.
6. Channel: `has_email` / `has_mobile` / `has_phone` say what exists; no channel → call at next visit or fix the record
   (skill customer-data-cleanup). Never paste contact values into the report; the salesperson opens the record in gGest.

## Caveats
- "today" = last document date in the data. Seasonality: public bodies buy at year end/budget time.
- Records without NIF are separate entities even if they are the same person (see duplicates).
- Respect GDPR: only customers with an existing commercial relationship; marketing e-mails need consent.

## Output (Portuguese)
Short intro (how many entities, € at stake), then a table: Cliente | Código | Segmento | Vendas totais | Última compra |
Ainda contacta? | Comprava | Canal (email/tel) | Ação sugerida. Max ~25 rows, warm leads first; offer the full list as CSV
(`--json`) if asked.
