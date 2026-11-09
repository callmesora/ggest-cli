---
name: data-refresh
description: Refresh the analysis database from the live gGest data folder (new sales, repairs, payments since the last export) and verify it. Use when the user says the data is old, asks to update/refresh/re-export, or the data date in management_kpi_snapshot is behind ("atualizar dados", "refresh", "dados desatualizados").
---
# Refresh the data

1. Current data date: `py -m bi run_saved_query --name management_kpi_snapshot` (the `period` end).
2. Refresh (copies the .fic files first — the live gGest files are only read; runs hidden, ~25 min with WDMap;
   the new database replaces the old one only when complete):
   `py pipeline/refresh.py --source "<gGest data folder>"`
   - another database: add `--out "<its folder>" --skip-dashboard`
   - quick test of the pipeline: `--tables Cab_Vendas,Lin_Vendas --out <scratch folder>`
   Run it in the background and wait for the "done in N min" line; the log lists failed tables.
3. Verify:
   - `py -m bi check-queries` → 0 failed.
   - `py -m bi run_saved_query --name management_kpi_snapshot` → new data date; numbers for earlier periods
     should not change much (small changes = late documents/credit notes).
4. If some tables failed: run the same command again (exported tables are reused only within one run, so it
   redoes all), or report the failed table names from the log.
5. Dashboard (Inforbyte only): `dashboards/export_datasets.py` already ran; ask Claude to upload
   `dashboards/datasets/*.json` to the dashboard artifact.
