-- name: management_change_drivers
-- description: What drove the change in sales and margin between two periods (default: this year to the data date vs the same days last year), broken down by one dimension at a time: dim = series_group (business units on their own invoice series) | group (product group) | family | brand | segment (customer segment from customer_dim) | customer | line_kind (product/service/fee) | ticket (document size band). One row per value with net and margin in both periods, the change, and its share of the total change; sorted by the size of the change. Run it for series_group, segment and group first: the biggest |net_change| explains the drop or growth.
-- params: dim=series_group, a_start=last_year_start, a_end=today_last_year, b_start=year_start, b_end=today, limit=15
WITH f AS (
  SELECT f.doc_date, f.net, f.margin,
         CASE :dim WHEN 'series_group' THEN f.series_group WHEN 'group' THEN COALESCE(f.group_name, '(none)')
                   WHEN 'family' THEN COALESCE(f.family_name, '(none)') WHEN 'brand' THEN COALESCE(NULLIF(f.brand_name, ''), '(none)')
                   WHEN 'segment' THEN COALESCE(cd.segment, '(unknown)') WHEN 'customer' THEN f.customer_name
                   WHEN 'line_kind' THEN f.line_kind
                   WHEN 'ticket' THEN CASE WHEN d.net < 100 THEN 'a <100' WHEN d.net < 500 THEN 'b 100-500'
                                           WHEN d.net < 2000 THEN 'c 500-2k' WHEN d.net < 5000 THEN 'd 2k-5k' ELSE 'e >=5k' END
         END AS value
  FROM sales_facts f
  LEFT JOIN customer_dim cd ON :dim = 'segment' AND cd.customer_code = f.customer_code
  LEFT JOIN sales_docs d ON :dim = 'ticket' AND d.doc_id = f.doc_id
  WHERE f.doc_date BETWEEN :a_start AND :a_end OR f.doc_date BETWEEN :b_start AND :b_end),
g AS (
  SELECT value,
         SUM(CASE WHEN doc_date BETWEEN :a_start AND :a_end THEN net ELSE 0 END) AS net_a,
         SUM(CASE WHEN doc_date BETWEEN :b_start AND :b_end THEN net ELSE 0 END) AS net_b,
         SUM(CASE WHEN doc_date BETWEEN :a_start AND :a_end THEN margin ELSE 0 END) AS margin_a,
         SUM(CASE WHEN doc_date BETWEEN :b_start AND :b_end THEN margin ELSE 0 END) AS margin_b
  FROM f GROUP BY value)
SELECT :dim AS dimension, value, ROUND(net_a, 0) AS net_period_a, ROUND(net_b, 0) AS net_period_b,
       ROUND(net_b - net_a, 0) AS net_change, ROUND(100.0 * (net_b - net_a) / NULLIF(net_a, 0), 1) AS net_change_pct,
       ROUND(100.0 * (net_b - net_a) / NULLIF((SELECT SUM(net_b) - SUM(net_a) FROM g), 0), 1) AS share_of_total_change_pct,
       ROUND(margin_b - margin_a, 0) AS margin_change,
       ROUND(100.0 * margin_b / NULLIF(net_b, 0), 1) AS margin_pct_b,
       ROUND(100.0 * margin_b / NULLIF(net_b, 0) - 100.0 * margin_a / NULLIF(net_a, 0), 1) AS margin_pct_change_points
FROM g ORDER BY ABS(net_b - net_a) DESC LIMIT :limit
