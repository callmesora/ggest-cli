-- name: repairs_volume
-- description: Repair orders (assistencias, OSA) per year or per month since 2007: orders, distinct customers, distinct devices (serial), orders up to the same day-of-year (ytd_until = MM-DD, for like-for-like comparison with a partial year) and change vs previous period. grain = year | month. Note: data_doc only; 2026 is partial (last order 2026-11-06).
-- params: start=2007-01-01, end=2026-12-31, grain=year, ytd_until=11-06
WITH r AS (
  SELECT CASE WHEN :grain = 'month' THEN month ELSE CAST(year AS TEXT) END AS period,
         customer_code, lower(trim(serial_number)) AS serial, substr(opened_on, 6, 5) <= :ytd_until AS in_ytd
  FROM repairs WHERE opened_on BETWEEN :start AND :end),
p AS (
  SELECT period, COUNT(*) AS repairs, COUNT(DISTINCT customer_code) AS customers,
         COUNT(DISTINCT serial) AS devices_with_serial, SUM(in_ytd) AS repairs_until_ytd_date
  FROM r GROUP BY period)
SELECT period, repairs, customers, devices_with_serial,
       ROUND(1.0 * repairs / customers, 2) AS repairs_per_customer,
       CASE WHEN :grain = 'month' THEN NULL ELSE repairs_until_ytd_date END AS repairs_until_ytd_date,
       ROUND(100.0 * (repairs - LAG(repairs) OVER (ORDER BY period)) / LAG(repairs) OVER (ORDER BY period), 1) AS change_vs_prev_pct,
       CASE WHEN :grain = 'month' THEN NULL ELSE
         ROUND(100.0 * (repairs_until_ytd_date - LAG(repairs_until_ytd_date) OVER (ORDER BY period))
               / LAG(repairs_until_ytd_date) OVER (ORDER BY period), 1) END AS ytd_change_vs_prev_pct
FROM p ORDER BY period
