-- name: setup_invoice_series
-- description: For configuring a new database (ggest.json): every sales series with document types, documents, first/last date, net sales, margin % and the series group / exclusion the current config gives it. Series with their own pattern (a franchise corner, online shop, vehicle sale, a branch) are candidates for series_groups or excluded_series_prefixes.
-- params: limit=100
WITH d AS (
  SELECT series, GROUP_CONCAT(DISTINCT doc_type) AS doc_types, COUNT(*) AS documents, MIN(doc_date) AS first_date,
         MAX(doc_date) AS last_date, SUM(is_internal) AS internal_docs
  FROM sales_docs GROUP BY series),
f AS (SELECT substr(doc_id, instr(doc_id, ' ') + 1, instr(substr(doc_id, instr(doc_id, ' ') + 1), '/') - 1) AS series,
             SUM(net) AS net, SUM(margin) AS margin FROM sales_facts GROUP BY 1)
SELECT d.series, d.doc_types, d.documents, d.first_date, d.last_date, d.internal_docs,
       ROUND(f.net, 0) AS net, ROUND(100.0 * f.margin / NULLIF(f.net, 0), 1) AS margin_pct,
       COALESCE((SELECT g.series_group FROM _bi_series_groups g WHERE d.series LIKE g.series_prefix || '%' ORDER BY g.priority LIMIT 1),
                (SELECT value FROM _bi_config WHERE key = 'default_series_group')) AS series_group,
       EXISTS (SELECT 1 FROM _bi_config c WHERE c.key = 'excluded_series_prefixes' AND d.series LIKE c.value || '%') AS excluded
FROM d LEFT JOIN f ON f.series = d.series
ORDER BY d.documents DESC LIMIT :limit
