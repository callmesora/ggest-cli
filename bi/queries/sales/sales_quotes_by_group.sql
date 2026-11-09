-- name: sales_quotes_by_group
-- description: What gets quoted and what gets won, per product group (catalogue group; 'ZZ / texto livre' for the generic ZZ item, often most of the quoted value): quote lines, net quoted, net in quotes won (outcome converted_linked or likely_won in quote_outcomes), net in quotes not won, win rate by value, distinct quotes, and indicative margin % of what was quoted (lines with a known cost only: cost = item's current last purchase price, quotes carry no cost). Period on quote date; cancelled and open quotes excluded. doc_type = ORC, FPF, ENC or all.
-- params: start=last_year_start, end=today, doc_type=ORC, limit=100
WITH o AS MATERIALIZED (SELECT doc_id, outcome FROM quote_outcomes
      WHERE doc_date BETWEEN :start AND :end AND outcome <> 'open' AND (doc_type = :doc_type OR :doc_type = 'all'))
SELECT CASE WHEN upper(l.item_code) = 'ZZ' THEN 'ZZ / texto livre' ELSE COALESCE(l.group_name, '(sem grupo)') END AS product_group,
       COUNT(*) AS lines, COUNT(DISTINCT l.doc_id) AS quotes,
       ROUND(SUM(l.net), 0) AS net_quoted,
       ROUND(SUM(CASE WHEN o.outcome IN ('converted_linked','likely_won') THEN l.net ELSE 0 END), 0) AS net_won,
       ROUND(SUM(CASE WHEN o.outcome NOT IN ('converted_linked','likely_won') THEN l.net ELSE 0 END), 0) AS net_not_won,
       ROUND(100.0 * SUM(CASE WHEN o.outcome IN ('converted_linked','likely_won') THEN l.net ELSE 0 END) / NULLIF(SUM(l.net), 0), 1) AS win_rate_value_pct,
       ROUND(100.0 * (SUM(CASE WHEN l.unit_cost > 0 THEN l.net END) - SUM(CASE WHEN l.unit_cost > 0 THEN l.qty * l.unit_cost END))
             / NULLIF(SUM(CASE WHEN l.unit_cost > 0 THEN l.net END), 0), 1) AS quoted_margin_pct
FROM quote_lines l JOIN o ON o.doc_id = l.doc_id
WHERE l.line_kind <> 'text' AND l.net <> 0
GROUP BY 1 ORDER BY net_quoted DESC LIMIT :limit
