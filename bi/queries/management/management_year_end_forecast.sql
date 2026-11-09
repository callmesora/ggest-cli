-- name: management_year_end_forecast
-- description: Full-year sales/margin projection from year-to-date, using the share of sales that came after the cut-off day in reference years (min / average / max scenarios)
-- params: cutoff=11-07, year=2026, ref_from=2022, ref_to=2024
WITH ref AS (
  SELECT year,
         SUM(CASE WHEN substr(doc_date, 6, 5) > :cutoff THEN net END) / SUM(net) AS share_after,
         SUM(CASE WHEN substr(doc_date, 6, 5) > :cutoff THEN margin END) / SUM(margin) AS mshare_after
  FROM sales_facts WHERE year BETWEEN :ref_from AND :ref_to GROUP BY year),
ytd AS (
  SELECT SUM(net) AS net, SUM(margin) AS margin FROM sales_facts
  WHERE year = :year AND substr(doc_date, 6, 5) <= :cutoff)
SELECT s.scenario, ROUND(ytd.net, 0) AS ytd_net, ROUND(s.share * 100, 1) AS share_after_cutoff_pct,
       ROUND(ytd.net / (1 - s.share), 0) AS projected_net,
       ROUND(ytd.margin / (1 - s.mshare), 0) AS projected_margin
FROM ytd, (SELECT 'low' AS scenario, MIN(share_after) AS share, MIN(mshare_after) AS mshare FROM ref
           UNION ALL SELECT 'base', AVG(share_after), AVG(mshare_after) FROM ref
           UNION ALL SELECT 'high', MAX(share_after), MAX(mshare_after) FROM ref) s
ORDER BY projected_net
