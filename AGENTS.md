# Agent guide: gGest business data

Read-only toolkit over a gGest (Golfinho Software) ERP database exported to SQLite. Use it to answer any business
question: sales, margin, customers, quotes, repairs, warranty, stock, purchasing, receivables, payables, VAT, team.

## Golden rules
1. **Read-only.** Never write to gGest files or `data/`. The only writes are `build-views` / `refresh` when the
   user asks for a refresh or setup.
2. Start with the skill `.claude/skills/ggest-analyst/SKILL.md`, then the task skill that matches (table below).
3. Tool order: named tool (`py -m bi list`) → saved query (`py -m bi saved_queries --search "<words>"`) →
   read-only SQL on the business views (`py -m bi query --sql ...`). Read `py -m bi data_dictionary` (and
   `--topic <domain>`) before writing SQL.
4. "Today" = the data date (last document in the snapshot), shown by `management_kpi_snapshot`.
5. Money is EUR net of VAT; credit notes negative; cancelled/internal documents excluded. Margin is an estimate.
6. Never output credentials, raw repair-fault text in bulk, or customer contact lists unless asked for one customer.

## Interfaces
- CLI: `py -m bi [--db <path>] <tool> [--param v] [--json]`. `--params` accepts JSON or `key=value,key=value`.
- MCP: `py -m bi.mcp_server [--db <path>]` (stdio, no dependencies) exposes the same tools.
- Date words in any date/year parameter: `today`, `year_start`, `this_year`, `last_year`, `last_year_start`,
  `last_year_end`, `today_last_year`, `today_mmdd`, `years_ago_3`.

## Skills (`.claude/skills/<name>/SKILL.md`)
| Area | Skills |
|---|---|
| Any question | `ggest-analyst` |
| Management | `business-review`, `sales-report`, `month-close` |
| Sales & products | `quote-followup`, `product-lookup`, `pricing-review` |
| Customers | `customer-briefing`, `winback-campaign`, `customer-segments`, `customer-data-cleanup` |
| Repairs | `repair-desk`, `device-history`, `warranty-check`, `repair-quality` |
| Finance | `collections`, `payables-and-cash`, `recurring-contracts`, `tax-calendar` |
| Stock & purchasing | `reorder-suggestions`, `stock-cleanup`, `stock-check`, `supplier-review` |
| Operations | `team-activity` |
| Data | `data-refresh`, `new-database-setup` |

## Library
23 named tools and 139 saved queries (`bi/queries/<domain>/`: sales 26, customers 27, repairs 23, finance 29,
stock 21, operations 5, management 5, setup 3). `py -m bi check-queries` runs them all.
Start "why did sales change" questions with `management_change_drivers` (by series group, segment, product group,
ticket size, customer).

## Extending (developers and agents)
- New question → a `.sql` file in `bi/queries/<domain>/` with `-- name:`, `-- description:` (what it answers,
  columns, caveats; agents pick queries from this text), `-- params:` using date words. It becomes a tool.
- New view → `bi/sql/ext/<domain>.sql` (`DROP VIEW IF EXISTS x; CREATE VIEW x AS ...`), apply with
  `py -m bi build-views --file bi/sql/ext/<domain>.sql`; document it in `docs/domains/<domain>.md`.
- New skill → `.claude/skills/<name>/SKILL.md` (frontmatter `name`, `description` with when-to-use phrases; steps
  with exact commands; output format). Test every command.
- Company-specific rules go in `ggest.json` (see `bi/config.example.json`), never hard-coded.
- Public repo: no customer/staff names, NIFs, contacts or business figures in code, queries, skills or docs.
