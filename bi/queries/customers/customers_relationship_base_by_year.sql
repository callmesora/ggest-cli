-- name: customers_relationship_base_by_year
-- description: Size of the customer relationship per year counting every customer record that bought OR brought equipment for repair (walk-in excluded): buy only, repair only, both, total active, % that used the workshop, plus records opened in gGest that year (record_opened_on) and how many of those bought something in the same year. Repairs go back to 2007 but sales only start in 2017, so earlier years are repair-only by construction. through_mmdd = 12-31 for full years or today_mmdd for year-to-date comparisons.
-- params: start_year=2017, end_year=this_year, through_mmdd=12-31
WITH w AS (SELECT customer_code FROM customer_dim WHERE segment <> 'consumidor_final'),
b AS (SELECT DISTINCT year, customer_code FROM sales_facts WHERE substr(doc_date, 6, 5) <= :through_mmdd
        AND customer_code IN (SELECT customer_code FROM w) AND year BETWEEN :start_year AND :end_year),
r AS (SELECT DISTINCT year, customer_code FROM repairs WHERE substr(opened_on, 6, 5) <= :through_mmdd
        AND customer_code IN (SELECT customer_code FROM w) AND year BETWEEN :start_year AND :end_year),
u AS (SELECT year, customer_code, MAX(src = 'b') AS bought, MAX(src = 'r') AS repaired
      FROM (SELECT year, customer_code, 'b' AS src FROM b UNION ALL SELECT year, customer_code, 'r' FROM r) GROUP BY 1, 2),
cr AS (SELECT CAST(substr(record_opened_on, 1, 4) AS INTEGER) AS year, customer_code FROM customer_dim
       WHERE substr(record_opened_on, 6, 5) <= :through_mmdd AND customer_code IN (SELECT customer_code FROM w))
SELECT u.year, COUNT(*) AS active_customers, SUM(bought AND NOT repaired) AS buy_only, SUM(repaired AND NOT bought) AS repair_only,
       SUM(bought AND repaired) AS buy_and_repair, ROUND(100.0 * SUM(repaired) / COUNT(*), 1) AS used_workshop_pct,
       (SELECT COUNT(*) FROM cr WHERE cr.year = u.year) AS records_created,
       (SELECT COUNT(*) FROM cr JOIN b ON b.customer_code = cr.customer_code AND b.year = cr.year WHERE cr.year = u.year) AS created_and_bought
FROM u GROUP BY u.year ORDER BY u.year
