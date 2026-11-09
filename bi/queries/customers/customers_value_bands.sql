-- name: customers_value_bands
-- description: Customer value distribution at legal-entity level (records sharing a NIF merged; walk-in excluded): entities, net sales, share of sales, margin % and average per entity by spend band (< 100, 100-500, 500-2000, 2000-10000, >= 10000 EUR net in the period), with cumulative entities and share from the top band down. Answers "how many customers make most of the revenue".
-- params: start=2017-01-01, end=today
WITH e AS (
  SELECT d.entity_key, SUM(f.net) AS net, SUM(f.margin) AS margin
  FROM sales_facts f JOIN customer_dim d ON d.customer_code = f.customer_code
  WHERE f.doc_date BETWEEN :start AND :end AND d.segment <> 'consumidor_final' GROUP BY 1 HAVING SUM(f.net) > 0),
b AS (
  SELECT CASE WHEN net < 100 THEN 1 WHEN net < 500 THEN 2 WHEN net < 2000 THEN 3 WHEN net < 10000 THEN 4 ELSE 5 END AS k,
         net, margin FROM e)
SELECT CASE k WHEN 1 THEN '< 100' WHEN 2 THEN '100-500' WHEN 3 THEN '500-2000' WHEN 4 THEN '2000-10000' ELSE '>= 10000' END AS band,
       COUNT(*) AS entities, ROUND(SUM(net), 2) AS net_sales, ROUND(100.0 * SUM(net) / (SELECT SUM(net) FROM b), 1) AS share_pct,
       SUM(COUNT(*)) OVER (ORDER BY k DESC) AS cumulative_entities_from_top,
       ROUND(SUM(SUM(net)) OVER (ORDER BY k DESC) * 100.0 / (SELECT SUM(net) FROM b), 1) AS cumulative_share_from_top_pct,
       ROUND(100.0 * SUM(margin) / SUM(net), 1) AS margin_pct, ROUND(AVG(net), 2) AS avg_net
FROM b GROUP BY k ORDER BY k DESC
