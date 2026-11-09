-- name: repairs_warranty_share
-- description: How many repairs are on devices the shop sold, and how many arrive still under warranty - per year (grain=year) or per equipment type (grain=equipment). Device serial on the repair order matched (case-insensitive, >= 6 chars) against serials on sales invoices (lin_mov_series, 2017+; so early years undercount). Columns: repairs, with_serial, sold_here (+ % of repairs with serial), sold_to_same_customer_code (other codes are often duplicate customer records), in_warranty at opening (term from the serial registry, 24 months when missing), in_warranty_order_net (value typed on those orders - should usually be 0 or recovered from the supplier), median device age in days when sold here. Source view repair_warranty.
-- params: start_year=2017, end_year=this_year, grain=year
WITH w AS (
  SELECT CASE WHEN :grain = 'equipment' THEN COALESCE(w.equipment_type, w.equipment_type_code, '?') ELSE CAST(w.year AS TEXT) END AS k,
         w.serial_number, w.sold_here, w.same_customer, w.in_warranty, w.device_age_days, w.quoted_net
  FROM repair_warranty w
  WHERE w.year BETWEEN :start_year AND :end_year)
SELECT k AS period_or_equipment, COUNT(*) AS repairs,
       SUM(length(serial_number) >= 6) AS with_serial,
       SUM(sold_here) AS sold_here,
       ROUND(100.0 * SUM(sold_here) / NULLIF(SUM(length(serial_number) >= 6), 0), 1) AS pct_sold_here_of_with_serial,
       SUM(same_customer) AS sold_to_same_customer_code,
       SUM(in_warranty) AS in_warranty,
       ROUND(100.0 * SUM(in_warranty) / COUNT(*), 1) AS pct_in_warranty_of_repairs,
       ROUND(SUM(CASE WHEN in_warranty = 1 THEN quoted_net END), 2) AS in_warranty_order_net,
       ROUND(AVG(CASE WHEN sold_here = 1 THEN device_age_days END)) AS avg_device_age_days
FROM w GROUP BY k ORDER BY CASE WHEN :grain = 'equipment' THEN -COUNT(*) END, k
