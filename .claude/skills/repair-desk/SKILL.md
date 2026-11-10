---
name: repair-desk
description: Morning check of the repair workshop (assistência técnica) — open orders by status and age, equipment ready but not collected, stuck orders, intake vs last year, who is opening orders, warranty jobs and unbilled orders. Use for "como está a oficina", "ponto de situação das assistências", "ordens em aberto", "o que está pronto para levantar", "assistências paradas", "repair desk", "open repair orders", "workshop status".
---
# Repair desk morning check (ponto de situação da oficina)

Run from the project root. All dates default to `today` (= last document date in the data).

Scope: repair orders (OSA) only. Customer orders/encomendas (`ENC`) and quotes are in the skill quote-followup.

1. **Summary board** (one row per open status + intake counts; `probably_closed` = PRO never closed in gGest):
   `uv run ggest run_saved_query --name repairs_desk_summary`
2. **Live open orders** (default `view=active` hides the probably-closed PRO; ready-for-pickup PRO first, newest
   first, then the oldest ABR/INT): `uv run ggest run_saved_query --name repairs_open_backlog --params '{"limit":40}'`
   - **Call list (ready, recent)**: `--params '{"status":"PRO"}'` — only PRO changed in the last 60 days
     (`stale_days`) and not yet invoiced. Phone numbers: `customer_profile` for each customer, one at a time.
   - **Stuck repair orders**: `--params '{"status":"ABR","min_age_days":15}'` (also `"status":"INT"`).
   - **gGest cleanup** (PRO delivered/finished but never closed): `--params '{"view":"stale"}'`.
3. **Who is opening orders** (this year vs last): 
   `uv run ggest run_saved_query --name repairs_workload_by_user --params '{"start":"year_start"}'`
4. **Warranty jobs this year** (devices sold by the shop, still under warranty — must not be charged; claim from supplier):
   `uv run ggest run_saved_query --name repairs_warranty_orders --params '{"start":"year_start","limit":20}'`
5. Optional, weekly: orders with no value and no invoice (possible unbilled work):
   `uv run ggest run_saved_query --name repairs_unbilled_orders --params '{"grain":"list","start":"year_start","limit":30}'`
   and replacement leads: `uv run ggest run_saved_query --name repairs_replacement_leads --params '{"limit":20}'`.

## Reading the results
- Status codes: `ABR` aberta (received, not started) · `INT` em intervenção · `PRO` pronta em testes (repaired,
  waiting for pickup or simply never closed) · `FEC` fechada. Only 2021+ status is meaningful.
- Age = days since the order was opened; gGest stores no promised date and, since 2020, no close date or technician,
  so turnaround and per-technician productivity cannot be measured for recent orders.
- `probably_closed = 1`: PRO with no change for > `stale_days` (60) or already invoiced — almost always delivered and
  never closed. Do not put them in the call list; list them once as cleanup ("fechar no gGest"). Recent PRO
  (`probably_closed = 0`) are the real "ready to collect". `ABR`/`INT` older than 15 days: waiting for parts/RMA or
  forgotten — check. `last_activity` = last change of the order in gGest.
- `invoiced_from_order = 1`: an invoice was converted from the order (practice since 2024-03); before, labour was
  billed on separate invoices, so 0 does not prove the job was not charged.
- `order_net` is the value typed on the order (estimate), not the invoice.
- `created_by_user` is the person at the counter who typed the order, not the technician.
- `same_customer = 0` in warranty jobs: the device was sold under another customer code (often a duplicate record).
- Never quote the customer's fault text (`reported_fault`): it often contains passwords/PINs.

## Output (Portuguese by default)
- **Hoje**: ordens em aberto (ABR/INT/PRO), entradas últimos 7/30 dias vs ano passado.
- **Para levantar** (PRO recentes, `probably_closed = 0`): lista para telefonar (ordem, cliente, equipamento, dias, valor).
- **Paradas**: ordens de reparação ABR/INT com > 15 dias (lista curta).
- **Higiene gGest**: nº de PRO provavelmente fechadas (só o número + ação "fechar no gGest").
- **Garantias** em curso e **sem cobrança** (só números + 3 exemplos).
- 2–3 ações concretas (ligar a X clientes, fechar PRO antigas, reclamar RMA ao fornecedor).
