-- name: repairs_customer_frequency
-- description: How often customers use the workshop in a period: distinct customers (walk-in/generic customer records excluded unless include_walk_in=1) bucketed by number of repair orders (1, 2, 3-4, 5-9, 10+), with orders and % of customers and of orders per bucket, plus orders per customer per year. Shows the loyal core (customers with 5+ orders) vs one-off visitors.
-- params: start=years_ago_3, end=today, include_walk_in=0
WITH c AS (
  SELECT r.customer_code, COUNT(*) AS n
  FROM repairs r LEFT JOIN customers cu ON cu.customer_code = r.customer_code
  WHERE r.opened_on BETWEEN (CASE WHEN length(:start) = 4 THEN :start || '-01-01' ELSE :start END) AND :end
    AND (:include_walk_in = 1 OR COALESCE(cu.is_walk_in, 0) = 0)
  GROUP BY r.customer_code),
b AS (SELECT CASE WHEN n = 1 THEN '1' WHEN n = 2 THEN '2' WHEN n <= 4 THEN '3-4' WHEN n <= 9 THEN '5-9' ELSE '10+' END AS bucket,
             MIN(n) AS o, COUNT(*) AS customers, SUM(n) AS orders FROM c GROUP BY 1)
SELECT bucket AS repairs_per_customer, customers, orders,
       ROUND(100.0 * customers / SUM(customers) OVER (), 1) AS pct_customers,
       ROUND(100.0 * orders / SUM(orders) OVER (), 1) AS pct_orders,
       SUM(customers) OVER () AS total_customers, SUM(orders) OVER () AS total_orders
FROM b ORDER BY o
