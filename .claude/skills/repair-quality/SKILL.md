---
name: repair-quality
description: Performance review of the repair workshop — volume trend, equipment and fault mix, what the technicians do, repeat repairs/comebacks, turnaround (where recorded), revenue and unbilled orders, warranty share, conversion to new-equipment sales. Use for "como está a correr a oficina este ano", "relatório das assistências", "reparações repetidas", "avarias mais comuns", "quanto fatura a assistência", "repair quality", "workshop KPIs".
---
# Repair quality & performance review (análise da assistência técnica)

Run from the project root. Use full years for trends; `this_year` is partial (compare with `ytd_until`).

1. **Volume**: `uv run ggest run_saved_query --name repairs_volume --params '{"start":"2017-01-01"}'`
   (`orders_ytd` = same period of each year; seasonality: `repairs_seasonality`, `"by":"weekday"` for weekdays).
2. **Mix**: `uv run ggest run_saved_query --name repairs_equipment_mix --params '{"start":"2021-01-01"}'` (`"dim":"brand"`)
   and faults: `uv run ggest run_saved_query --name repairs_fault_categories --params '{"start":"2021-01-01","grain":"year"}'`.
   Faults of one equipment type (e.g. notebooks this year): add `"equipment_group":"notebook"` (or `desktop`,
   `impressora`, `tablet_telemovel`, `outro`): `uv run ggest run_saved_query --name repairs_fault_categories --params '{"equipment_group":"notebook","start":"year_start"}'`.
3. **Work done**: `uv run ggest run_saved_query --name repairs_work_done --params '{"start":"2015-01-01"}'`;
   parts: `uv run ggest run_saved_query --name repairs_parts_used`.
4. **Quality**: comebacks `uv run ggest run_saved_query --name repairs_repeat_devices --params '{"start":"2017-01-01"}'`
   (`window_days` 30/90); turnaround only 2011-2019: `repairs_turnaround`.
5. **Money**: `uv run ggest run_saved_query --name repairs_revenue_by_year` and unbilled orders
   `uv run ggest run_saved_query --name repairs_unbilled_orders --params '{"start":"2021-01-01"}'`.
6. **Warranty load**: `uv run ggest run_saved_query --name repairs_warranty_share` (`"grain":"equipment"` per type).
7. **Sales from the workshop**: `repairs_replacement_sales` (per year) and `repairs_replacement_leads` (list);
   customers: `repairs_top_customers`, `repairs_customer_frequency`.

## Reading the results
- Comebacks within 30 days ≈ "not fixed the first time" (also planned returns: parts arriving, RMA). >8 % is a warning.
- Categories of faults/work are keyword rules on free text (accents lost) — approximate, trends are reliable.
- Labour (item ASSISTENCIA) has no cost → ~100 % margin; parts ~40 %. Before 2024-03 orders were not converted to
  invoices, so revenue per order is estimated through labour invoices.
- ~half of orders have no value: warranty, quote refused, nothing found — or unbilled work (`no_value_with_work_text`).
- Close date and repairing technician are not recorded since 2020: no turnaround/productivity for recent years —
  recommend recording them.
- `pct_sold_here` (warranty share) is rising: more repairs on equipment the shop sold → the installed base matters.
- Do not quote free texts (passwords/PINs).

## Output (Portuguese by default)
5–8 bullet findings with numbers (volume and YoY, mix shift, top faults, comebacks %, revenue and €/order, % without
value, warranty share, conversion to new equipment), a small table per year, and 3 recommendations.
