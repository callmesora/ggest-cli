# Operations: team activity in gGest

Views in `bi/sql/ext/operations.sql` (apply: `py -m bi build-views --file bi/sql/ext/operations.sql`), saved queries
in `bi/queries/operations/`, skill `team-activity`. Purpose: workload, staffing and process questions answered with
aggregates — not individual monitoring (no per-person timelines, no attendance tools).

## Views

| view | grain | source / notes |
|---|---|---|
| `activity_log` | one row per gGest log event | `log_atividades` (from 2020-03-24): event_at/date, year, month, weekday (0=Sun), hour, user_code + user_name (`utilizadores.descricao`), workstation (`posto`), program (GESTAO back-office, POS, POS_T touch POS), operation, `area` = first `[...]` of the description. The free-text description is NOT exposed (it contains customer names/document data) |
| `documents_created` | one row per document | headers of `cab_vendas` (sales), `cab_compras` (purchases), `Cab_Assistec` (repairs), `cab_outros` (quotes ORC / other), `cab_recpag` (receipts & payments), `cab_guias` (delivery notes), `Cab_Stocks` (stock docs, no `_F*`), `cab_producao` (PRCE only), `Cab_DirCC_Cre` (expenses). created_at = `inserido_data`, user = `inserido_util`, `is_cancelled` (`estado_doc = 1`), `is_migrated` |

## Codes
- Operations (`log_atividades.operacao`): VISUALIZOU viewed (~50 %), CRIOU created, ALTEROU changed, IMPRIMIU printed,
  ANULOU cancelled, ELIMINOU deleted, ACEDEU login, IGNOROUBLOQUEIO saved over a record lock, PROCESSOU batch run;
  ALTERAR/NOVO only in 2020.
- Areas (screen names, Portuguese): `Ordem de Serviço` / `OSA` repairs, `Vendas` / `VND` sales documents (VND =
  print of a sales doc), `Artigos` / `Tabela artigos` catalogue, `Clientes`, `Recibos` / `REC`, `Compras`,
  `Pagamentos`, `Movimentos C.C. credores` (expenses), `Produção` (assembly), `Stocks`, `RMA's`, `Agenda`.
- Users: `utilizadores.Codigo` (`Departamento` GER/TEC, `vendedor` flag). Never select `utilizadores.password`.
  The document user fields (`inserido_util`) and `log_atividades.utilizador` use the same codes.

## Traps
- The current gGest installation started **2020-03-24**: all earlier documents (2017 → 2020-03) were imported that
  day by user 1 (`is_migrated = 1`). Exclude them from per-user or per-hour analysis.
- Times are when the record was saved; documents keyed in later (back-office catch-up, evening) are not the hour of
  the sale.
- A login can be shared; user 1 is mainly the administrator/owner account.
- `Controlo_Assiduidade` (attendance clock-in/out) was used only Sept–Dec 2024 (+ a few 2023/2025 rows): not usable
  for trends; deliberately not modelled.
- `Viaturas_Empresa` (company vehicles, 3 rows) and `Expedicoes` (6 shipping methods) are lookups; vehicle costs are
  in the finance expenses (`Cab_DirCC_Cre`).
