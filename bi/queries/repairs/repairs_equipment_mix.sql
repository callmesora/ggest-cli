-- name: repairs_equipment_mix
-- description: Repairs by equipment group (dim=type: notebook, desktop (incl. all-in-one/mini PC), impressora, tablet_telemovel, monitor_projetor, armazenamento, ups_energia, rede, outro) or by brand (dim=brand; 'Outra/sem marca' = brand code 'out' or empty, mostly white-box desktops) per period. grain = year | total. Long format: period, key, repairs, pct_of_period. min_repairs hides tiny rows.
-- params: start=2007-01-01, end=2026-12-31, dim=type, grain=year, equipment_group=all, min_repairs=1
WITH r AS (
  SELECT CASE WHEN :grain = 'total' THEN 'total' ELSE CAST(year AS TEXT) END AS period,
         CASE WHEN equipment_type_code = 'not' THEN 'notebook'
              WHEN equipment_type_code IN ('des','all','min') THEN 'desktop'
              WHEN equipment_type_code IN ('imp','sca') THEN 'impressora'
              WHEN equipment_type_code IN ('tab','ipa','pda','tel') THEN 'tablet_telemovel'
              WHEN equipment_type_code IN ('mon','vid') THEN 'monitor_projetor'
              WHEN equipment_type_code IN ('hde','hdd','pen') THEN 'armazenamento'
              WHEN equipment_type_code IN ('ups','tra','fao','pow') THEN 'ups_energia'
              WHEN equipment_type_code IN ('rou') THEN 'rede'
              ELSE 'outro' END AS equipment_group,
         CASE WHEN COALESCE(brand_name, '') = '' THEN 'Outra/sem marca' ELSE brand_name END AS brand
  FROM repairs WHERE opened_on BETWEEN :start AND :end),
f AS (SELECT period, CASE WHEN :dim = 'brand' THEN brand ELSE equipment_group END AS key
      FROM r WHERE :equipment_group = 'all' OR equipment_group = :equipment_group),
g AS (SELECT period, key, COUNT(*) AS repairs FROM f GROUP BY period, key),
s AS (SELECT period, key, repairs, ROUND(100.0 * repairs / SUM(repairs) OVER (PARTITION BY period), 1) AS pct_of_period FROM g)
SELECT period, key, repairs, pct_of_period
FROM s WHERE repairs >= :min_repairs
ORDER BY period, repairs DESC
