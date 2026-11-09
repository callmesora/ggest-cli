---
name: quote-followup
description: List open / not converted quotes (orçamentos ORC), pro-formas (FPF) and customer orders (ENC) to follow up, plus win rate and what is quoted vs won. Use for "orçamentos pendentes", "orçamentos por converter", "que orçamentos devo seguir", "taxa de conversão de orçamentos", "encomendas por faturar", "guias por faturar", "quote follow-up", "open quotes", "quote conversion rate".
---
# Quote follow-up and conversion

Run from the project root (bash quoting; in PowerShell 5.1 escape inner quotes as `\"`).

## How quotes are tracked in gGest
Quotes, pro-formas and orders live in `cab_outros`/`lin_outros` (views `quote_docs`, `quote_lines`,
`quote_outcomes`). The shop usually **retypes** the invoice, so an explicit link exists for only a small minority of
quotes. `quote_outcomes.outcome` adds a heuristic: `converted_linked` (link) · `likely_won` (same customer
invoiced ≥ 50 % of the value within 60 days) · `partial` · `open` (< 60 days, nothing yet) · `not_won`.
It is an estimate: say "provavelmente" for likely_won / not_won.

## Steps
1. Follow-up list (recent quotes not converted, biggest first):
   `py -m bi run_saved_query --name sales_quotes_followup --params '{"start": "2026-08-01", "min_net": 200}'`
   (default: since last_year_start; `doc_type` ORC / FPF / ENC / all; `outcome` open / partial / not_won / all).
   `open` = still valid (`valid_until` not passed; else ≤ 60 days old). Rows with `variant_of` are revisions of
   another quote: report the pipeline as `open_net_dedup` (totals cover all matches, not just the rows shown).
   Old `not_won` to public bodies are usually lost tenders, not forgotten sales.
2. Detail of one quote (lines, current price/stock, cost) before calling the customer:
   `py -m bi run_saved_query --name sales_quote_detail --params '{"doc_id": "ORC 2026/427"}'`
   or all quotes of a customer: `--params '{"customer_code": "<customer_code>"}'`.
   Contact data only for that customer: `py -m bi customer_profile --query <customer_code>`.
3. Win rate per year: `py -m bi run_saved_query --name sales_quotes_conversion_by_year --params '{"doc_type": "all"}'`
   (value win rate is usually far below the count win rate: big tender quotes are rarely won).
4. What we lose by product group: `py -m bi run_saved_query --name sales_quotes_by_group --params '{"start": "last_year_start"}'`.
5. Goods shipped but not invoiced (delivery notes without an invoice link):
   `py -m bi run_saved_query --name sales_delivery_notes_not_invoiced --params '{"start": "year_start"}'`
   — if `nearby_invoice` is filled the note was probably invoiced without a link; `refers_to_invoice = 1` means
   it only accompanied invoiced goods. Review the rest.

## Output (Portuguese by default)
**Orçamentos a seguir** (dados até <today>): a table `Doc | Data | Dias | Cliente | Valor | Principais artigos | Estado`
(top 10–15), then one line each: total value open, win rate this year vs last year, and delivery notes to check.
Suggested action per row in 3–6 words ("ligar — validade termina 09/11", "confirmar se foi faturado na CHIP").
Do not list phone numbers/emails in bulk.
