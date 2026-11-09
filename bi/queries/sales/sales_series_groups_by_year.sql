-- name: sales_series_groups_by_year
-- description: Sales per invoice-series group per year (sales_facts.series_group: groups from series_groups in the database's ggest.json, e.g. a franchise corner or online shop invoiced on its own series; all other series = default_series_group): net sales, gross margin, margin %, documents and share of the year's sales. cutoff_mmdd limits every year to 1 Jan..MM-DD for like-for-like year-to-date comparisons (use today_mmdd; 12-31 = full years).
-- params: start_year=2017, end_year=this_year, cutoff_mmdd=12-31
SELECT year, series_group, ROUND(SUM(net), 2) AS net, ROUND(SUM(margin), 2) AS margin,
       ROUND(100.0 * SUM(margin) / NULLIF(SUM(net), 0), 1) AS margin_pct, COUNT(DISTINCT doc_id) AS documents,
       ROUND(100.0 * SUM(net) / SUM(SUM(net)) OVER (PARTITION BY year), 1) AS share_pct,
       CASE WHEN :cutoff_mmdd = '12-31' THEN 'full year' ELSE '01-01..' || :cutoff_mmdd END AS period
FROM sales_facts
WHERE year BETWEEN :start_year AND :end_year AND substr(doc_date, 6, 5) <= :cutoff_mmdd
GROUP BY year, series_group ORDER BY year, net DESC
