-- name: repairs_repeat_devices
-- description: Repeat repairs on the same device (serial number; serials shorter than 6 chars or with odd characters such as 's/n' ignored). Per year: repairs with a usable serial, how many devices had been repaired before (installed-base loyalty) and comebacks = same serial re-opened within window_days of the previous order (quality / 'did not get fixed' signal; also includes planned returns such as RMA or parts arriving). by = year | equipment.
-- params: start=2008-01-01, end=2026-12-31, window_days=30, by=year
WITH s AS (
  SELECT lower(replace(trim(serial_number), ' ', '')) AS s, opened_on, year,
         CASE WHEN equipment_type_code = 'not' THEN 'notebook' WHEN equipment_type_code IN ('des','all','min') THEN 'desktop'
              WHEN equipment_type_code IN ('imp','sca') THEN 'impressora' WHEN equipment_type_code IN ('tab','ipa','pda','tel') THEN 'tablet_telemovel'
              ELSE 'outro' END AS equipment_group
  FROM repairs
  WHERE length(trim(serial_number)) >= 6 AND lower(serial_number) NOT LIKE '%n/a%' AND lower(serial_number) NOT LIKE 's/n%'
    AND lower(replace(trim(serial_number), ' ', '')) NOT GLOB '*[^a-z0-9./_-]*'),
k AS (SELECT s.*, LAG(opened_on) OVER (PARTITION BY s ORDER BY opened_on) AS prev_opened FROM s)
SELECT CASE WHEN :by = 'equipment' THEN equipment_group ELSE CAST(year AS TEXT) END AS grp,
       COUNT(*) AS repairs_with_serial,
       SUM(prev_opened IS NOT NULL) AS device_seen_before,
       ROUND(100.0 * SUM(prev_opened IS NOT NULL) / COUNT(*), 1) AS seen_before_pct,
       SUM(julianday(opened_on) - julianday(prev_opened) <= :window_days) AS comebacks,
       ROUND(100.0 * SUM(julianday(opened_on) - julianday(prev_opened) <= :window_days) / COUNT(*), 1) AS comeback_pct,
       COUNT(DISTINCT s) AS distinct_devices
FROM k WHERE opened_on BETWEEN :start AND :end
GROUP BY 1 ORDER BY 1
