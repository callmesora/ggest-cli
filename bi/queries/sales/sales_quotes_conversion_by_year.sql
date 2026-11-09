-- name: sales_quotes_conversion_by_year
-- description: Quote (ORC), pro-forma (FPF) and customer order (ENC) win rate per year and doc type, from view quote_outcomes (cancelled excluded). Columns: documents, net value quoted, converted_linked (explicit link to an invoice/delivery note — a small minority, the shop usually retypes the invoice), likely_won (same customer invoiced >= 50% of the quote within 60 days), partial, open (< 60 days old), not_won, win_rate_pct by count and by value ((linked+likely_won)/decided docs), net won/open, median days to first invoice. Heuristic: a won quote can be undercounted (invoice to another customer code) or overcounted (customer bought something else). Big tender quotes to public bodies inflate the value quoted. doc_type = ORC, FPF, ENC or all.
-- params: start_year=years_ago_3, end_year=this_year, doc_type=ORC
WITH q AS MATERIALIZED (
  SELECT year, doc_type, net, outcome, days_to_invoice FROM quote_outcomes
  WHERE year BETWEEN :start_year AND :end_year AND (doc_type = :doc_type OR :doc_type = 'all')),
d AS (SELECT year, doc_type, days_to_invoice,
             ROW_NUMBER() OVER (PARTITION BY year, doc_type ORDER BY days_to_invoice) AS rn,
             COUNT(*) OVER (PARTITION BY year, doc_type) AS cnt
      FROM q WHERE outcome IN ('converted_linked','likely_won') AND days_to_invoice IS NOT NULL),
med AS (SELECT year, doc_type, MIN(days_to_invoice) AS median_days_to_invoice FROM d WHERE rn = (cnt + 1) / 2 GROUP BY 1, 2)
SELECT q.year, q.doc_type, COUNT(*) AS documents, ROUND(SUM(net), 0) AS net_quoted,
       SUM(outcome = 'converted_linked') AS converted_linked, SUM(outcome = 'likely_won') AS likely_won,
       SUM(outcome = 'partial') AS partial, SUM(outcome = 'open') AS open, SUM(outcome = 'not_won') AS not_won,
       ROUND(100.0 * SUM(outcome IN ('converted_linked','likely_won')) / NULLIF(SUM(outcome <> 'open'), 0), 1) AS win_rate_pct,
       ROUND(100.0 * SUM(CASE WHEN outcome IN ('converted_linked','likely_won') THEN net ELSE 0 END)
             / NULLIF(SUM(CASE WHEN outcome <> 'open' THEN net ELSE 0 END), 0), 1) AS win_rate_value_pct,
       ROUND(SUM(CASE WHEN outcome IN ('converted_linked','likely_won') THEN net ELSE 0 END), 0) AS net_won,
       ROUND(SUM(CASE WHEN outcome = 'open' THEN net ELSE 0 END), 0) AS net_open,
       ROUND(AVG(net), 0) AS avg_quote_net, MAX(m.median_days_to_invoice) AS median_days_to_invoice
FROM q LEFT JOIN med m ON m.year = q.year AND m.doc_type = q.doc_type
GROUP BY q.year, q.doc_type ORDER BY q.doc_type, q.year
LIMIT 200
