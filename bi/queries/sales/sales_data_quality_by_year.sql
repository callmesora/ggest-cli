-- name: sales_data_quality_by_year
-- description: Margin data-quality check per year: reported margin vs margin corrected for double-counted cost of assembled PCs/bundles (priced header with guessed cost + zero-price component lines with real cost), sales with estimated cost, generic ZZ item sales, hardware margin coming from lines above 60% margin (suspect low average cost) and vehicle sales counted as revenue.
-- params: start_year=2017, end_year=2026
WITH comp AS (
  SELECT doc_id, SUM(cost) AS comp_cost FROM sales_facts
  WHERE line_kind = 'product' AND net = 0 AND cost > 0 GROUP BY doc_id),
hdr AS (
  SELECT f.doc_id,
         SUM(CASE WHEN f.cost_source IN ('estimated','last_purchase') THEN f.cost ELSE 0 END) AS hdr_guess_cost,
         SUM(CASE WHEN f.cost_source = 'pmc' THEN f.cost ELSE 0 END) AS hdr_pmc_cost
  FROM sales_facts f JOIN comp c ON c.doc_id = f.doc_id
  WHERE f.line_kind = 'product' AND f.net > 0
    AND (f.line_role = 'bundle' OR lower(f.item_description) LIKE '%compost%' OR upper(f.item_code) LIKE 'COMPIN%')
  GROUP BY f.doc_id),
dbl AS (
  SELECT c.doc_id, CASE WHEN h.hdr_guess_cost > 0 THEN h.hdr_guess_cost WHEN h.hdr_pmc_cost > 0 THEN c.comp_cost ELSE 0 END AS double_cost
  FROM comp c LEFT JOIN hdr h ON h.doc_id = c.doc_id),
dy AS (
  SELECT s.year, SUM(dbl.double_cost) AS double_cost
  FROM dbl JOIN (SELECT DISTINCT doc_id, year FROM sales_facts) s ON s.doc_id = dbl.doc_id GROUP BY s.year)
SELECT f.year,
       ROUND(SUM(f.net), 2) AS net_sales,
       ROUND(100.0 * SUM(f.margin) / SUM(f.net), 1) AS margin_pct_reported,
       ROUND(COALESCE(MAX(dy.double_cost), 0), 2) AS double_counted_cost,
       ROUND(100.0 * (SUM(f.margin) + COALESCE(MAX(dy.double_cost), 0)) / SUM(f.net), 1) AS margin_pct_corrected,
       ROUND(SUM(CASE WHEN f.cost_source = 'estimated' THEN f.net ELSE 0 END), 2) AS net_with_estimated_cost,
       ROUND(SUM(CASE WHEN upper(f.item_code) = 'ZZ' THEN f.net ELSE 0 END), 2) AS zz_generic_net,
       ROUND(100.0 * SUM(CASE WHEN upper(f.item_code) = 'ZZ' THEN f.net ELSE 0 END) / SUM(f.net), 2) AS zz_share_pct,
       SUM(CASE WHEN upper(f.item_code) = 'ZZ' AND f.net <> 0 THEN 1 ELSE 0 END) AS zz_lines,
       ROUND(SUM(CASE WHEN f.line_kind = 'product' AND f.net > 50 AND f.margin > 0.6 * f.net AND f.group_name IN ('COMPUTADORES','TABLET','CONSUMÍVEIS','COMPONENTES','SPARES','ARMAZENAMENTO DE DADOS','MONITORES','PERIFERICOS','IMPRESSORAS  SCANNERS','ACESSÓRIOS','CABOS','ADAPTADORES','ALIMENTAÇÃO / ENERGIA','VIDEOPROJETORES','TV','REDES','VIDEOVIGILÂNCIA','POS','TELEMOVEIS E SMARTWATCH')
                      THEN f.margin ELSE 0 END), 2) AS hw_margin_on_lines_over_60pct,
       ROUND(SUM(CASE WHEN f.group_name = 'Viatura' THEN f.net ELSE 0 END), 2) AS vehicle_sales_net
FROM sales_facts f LEFT JOIN dy ON dy.year = f.year
WHERE f.year BETWEEN :start_year AND :end_year
GROUP BY f.year ORDER BY f.year
