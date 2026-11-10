---
name: customer-segments
description: Who our customers are — segments (público, empresas, particulares, associações), concentration, value bands, new vs returning, retention, geography, and the workshop as a source of buyers. Use for "quem são os nossos clientes", "segmentos", "dependemos de poucos clientes?", "clientes novos", "retenção", "de onde são os clientes", "customer base overview", "customer mix".
---
# Customer segments & base overview

Run from the project root. Money net of VAT; current year is partial → compare year-to-date with `through_mmdd=today_mmdd`.

1. **Segments, whole period**: `uv run ggest run_saved_query --name customers_segment_summary`
   Year-to-date vs last year: `--params '{"start":"last_year_start","through_mmdd":"today_mmdd","by_year":1}'`
2. **Segments per year** (trend): `uv run ggest run_saved_query --name customers_segment_by_year --params '{"start_year":2021}'`
3. **What each segment buys**: `uv run ggest run_saved_query --name customers_segment_product_mix --params '{"segment":"empresa","limit":15}'`
4. **Concentration**: `uv run ggest run_saved_query --name customers_concentration_by_year` and value bands
   `uv run ggest run_saved_query --name customers_value_bands`; top entities:
   `uv run ggest run_saved_query --name customers_top_entities --params '{"limit":15}'` (`"by":"margin"` for profit).
5. **New vs returning** (add `"through_mmdd":"today_mmdd"` for YTD):
   `uv run ggest run_saved_query --name customers_new_vs_returning`;
   retention: `uv run ggest run_saved_query --name customers_cohort_retention --params '{"segment":"particular"}'`
6. **Relationship base incl. workshop**: `uv run ggest run_saved_query --name customers_relationship_base_by_year`
   and repair → purchase conversion: `uv run ggest run_saved_query --name customers_repair_first_conversion`
7. **Geography**: `uv run ggest run_saved_query --name customers_geography --params '{"level":"island"}'` (or `locality`).
8. **RFM picture**: `uv run ggest run_saved_query --name customers_rfm_summary`

## Interpreting
- Segment rules (NIF prefix, gGest group, name words) are in `docs/domains/customers.md`; the gGest group exists
  only since late 2022 so name/NIF rules decide for old records. "Particular" includes the counter (walk-in sales are
  mostly typed with the person's name).
- Concentration and value bands work at entity level (NIF): departments of the same public body count as one.
- 2017 = first year of sales data, so all its buyers look "new"; cohorts are reliable from 2018.
- `repair_only` customers and the repair→purchase conversion measure the workshop as a door to sales.
- Geography comes from postal code / address text; many Faial records have only "9900 Horta" (parish unknown).

## Output (Portuguese)
5–8 bullet conclusions with numbers (share %, margin %, trend vs previous year or same period), then one or two
compact tables (segment table; concentration or new/returning per year). End with 2–3 actions (e.g. focus segment
with highest margin, entry of new customers, retention of empresas).
