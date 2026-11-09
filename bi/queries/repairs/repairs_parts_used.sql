-- name: repairs_parts_used
-- description: Parts/products charged on repair orders (Lin_Assistec product lines; labour item ASSISTENCIA and technician travel (DESLOCACAO) excluded; generic ZZ text-items and PORTES shipping excluded unless include_generic=1) grouped by catalogue family (level=family) or item (level=item): lines, repair orders, qty, net, average unit net, years seen. Shows what breaks and what the workshop sells as spare parts (disks/SSD, PSUs, memory, notebook screens/keyboards, chargers...).
-- params: start_year=2021, end_year=this_year, level=family, include_generic=0, limit=40
WITH l AS (
  SELECT rl.repair_id, rl.year, rl.item_code, rl.description, rl.qty, rl.net,
         COALESCE(NULLIF(i.family_name, ''), NULLIF(i.group_name, ''), '(sem familia)') AS family
  FROM repair_lines rl LEFT JOIN items i ON i.item_code = rl.item_code
  WHERE rl.year BETWEEN :start_year AND :end_year AND rl.line_kind = 'product' AND rl.net > 0
    AND COALESCE(rl.item_code, '') <> 'ASSISTENCIA' AND COALESCE(i.family_name, '') NOT LIKE 'DESLOCA%'
    AND (:include_generic = 1 OR (COALESCE(rl.item_code, '') NOT IN ('ZZ', 'PORTES', '') AND family NOT LIKE 'PORTES%'))),
g AS (
  SELECT CASE WHEN :level = 'item' THEN item_code ELSE family END AS key,
         CASE WHEN :level = 'item' THEN MAX(description) ELSE NULL END AS item_description,
         CASE WHEN :level = 'item' THEN MAX(family) ELSE NULL END AS family,
         COUNT(*) AS lines, COUNT(DISTINCT repair_id || '#' || year) AS repair_orders, SUM(qty) AS qty, SUM(net) AS net,
         MIN(year) AS first_year, MAX(year) AS last_year
  FROM l GROUP BY 1)
SELECT key, item_description, family, lines, repair_orders, ROUND(qty, 0) AS qty, ROUND(net, 2) AS net,
       ROUND(net / NULLIF(qty, 0), 2) AS avg_unit_net,
       ROUND(100.0 * net / SUM(net) OVER (), 1) AS pct_of_parts_net, first_year, last_year
FROM g ORDER BY net DESC LIMIT :limit
