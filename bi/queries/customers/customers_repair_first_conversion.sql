-- name: customers_repair_first_conversion
-- description: Does the workshop bring buyers? Customers whose first known interaction was a repair order (first repair on or before their first purchase, or no purchase at all), grouped by year of first repair: how many, % that ever bought (any invoice), % that bought on/after the first repair, average net bought after it (buyers only) and average days from first repair to first purchase. Meaningful from 2018 (sales history starts 2017). Walk-in excluded.
-- params: start_year=2018, end_year=this_year
WITH w AS (SELECT customer_code FROM customer_dim WHERE segment <> 'consumidor_final'),
fr AS (SELECT customer_code, MIN(opened_on) AS first_repair FROM repairs WHERE customer_code IN (SELECT customer_code FROM w) GROUP BY 1),
fs AS (SELECT customer_code, MIN(doc_date) AS first_purchase FROM sales_facts GROUP BY 1),
c AS (
  SELECT fr.customer_code, CAST(substr(fr.first_repair, 1, 4) AS INTEGER) AS year, fr.first_repair, fs.first_purchase
  FROM fr LEFT JOIN fs USING (customer_code)
  WHERE fs.first_purchase IS NULL OR fr.first_repair <= fs.first_purchase),
aft AS (
  SELECT c.customer_code, SUM(f.net) AS net_after FROM c JOIN sales_facts f ON f.customer_code = c.customer_code
  WHERE f.doc_date >= c.first_repair GROUP BY 1)
SELECT c.year AS first_repair_year, COUNT(*) AS repair_first_customers,
       ROUND(100.0 * AVG(c.first_purchase IS NOT NULL), 1) AS ever_bought_pct,
       ROUND(100.0 * AVG(COALESCE(a.net_after, 0) > 0), 1) AS bought_after_repair_pct,
       ROUND(AVG(a.net_after), 2) AS avg_net_after_for_buyers,
       ROUND(AVG(julianday(c.first_purchase) - julianday(c.first_repair)), 0) AS avg_days_to_first_purchase
FROM c LEFT JOIN aft a USING (customer_code)
WHERE c.year BETWEEN :start_year AND :end_year
GROUP BY 1 ORDER BY 1
