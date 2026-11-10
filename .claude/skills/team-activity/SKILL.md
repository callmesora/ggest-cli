---
name: team-activity
description: How the team's work is distributed in gGest — documents issued per user and module, monthly workload, busiest weekdays/hours, which gGest areas take the most time, and cancellations/deletions (rework). Aggregate only, for planning and process improvement. Use for "quem faz o quê", "carga de trabalho", "horas de maior movimento", "documentos por utilizador", "quantas faturas emitimos por dia", "anulações", "team workload", "busiest hours", "who does what".
---
# Team activity (quem faz o quê no gGest)

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).
Purpose: workload, staffing and process questions. Do not build per-person timelines (exact times of an
individual's actions) or use this to monitor attendance; answer with aggregates (counts per month/area/hour band).

## Steps
1. Division of tasks — documents created per user and module in the period:
   `uv run ggest run_saved_query --name operations_documents_by_user --params '{"start": "year_start", "end": "today"}'`
   (sales value per user: `uv run ggest run_saved_query --name management_sales_by_user`)
2. Monthly workload (documents per module, active users, working days, documents per day):
   `uv run ggest run_saved_query --name operations_workload_by_month --params '{"start": "last_year_start", "end": "today"}'`
3. Busiest weekdays and hours (whole team):
   `uv run ggest run_saved_query --name operations_activity_heatmap --params '{"start": "last_year_start", "end": "today"}'`
4. Where gGest time goes (screens/areas; optional `"user": "3"` for one user's mix):
   `uv run ggest run_saved_query --name operations_activity_by_area --params '{"start": "year_start", "end": "today", "limit": 15}'`
5. Rework: cancellations, deletions, lock overrides per area and year:
   `uv run ggest run_saved_query --name operations_cancellations_by_year --params '{"from_year": "years_ago_3"}'`

## Reading the numbers
- `documents_created` uses the record creation time; documents before 2020-03-24 were imported when gGest was
  installed and are excluded. The activity log also starts 2020-03.
- Users are gGest logins (a login may be shared); user 1 is mostly the administrator/owner account.
- Log areas: "Ordem de Serviço"/"OSA" = repairs, "Vendas"/"VND" = sales documents (VND = printing),
  "Artigos" = catalogue, "Recibos"/"REC" = receipts, "Compras" = purchases. Viewing dominates the log.
- Hours are local shop time as recorded by gGest; documents after 20:00 are usually back-office catch-up.
- Attendance (`Controlo_Assiduidade`) was only used for a few months in 2024: no attendance analysis.

## Output (Portuguese by default)
Brief with: documentos por utilizador/módulo (quota %), tendência mensal (documentos/dia), mapa de horas
(picos e horas calmas, sábado), áreas com mais tempo, anulações/eliminações a vigiar; finish with 2–3
suggestions (redistribute tasks, admin work in quiet hours, training where rework is high).
