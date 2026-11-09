-- name: sales_ticket_bands_by_year
-- description: Invoices per year by ticket size (net per invoice: <50, 50-250, 250-1000, 1000-5000, >=5000 EUR): count, revenue, average ticket and share of the year. Separates everyday retail from big deals.
-- params: start_year=2017, end_year=this_year
WITH d AS (SELECT doc_id, year, SUM(net) AS net FROM sales_facts
           WHERE doc_class = 'invoice' AND year BETWEEN :start_year AND :end_year GROUP BY doc_id, year),
b AS (SELECT year, net,
             CASE WHEN net < 50 THEN '1: <50' WHEN net < 250 THEN '2: 50-250' WHEN net < 1000 THEN '3: 250-1000'
                  WHEN net < 5000 THEN '4: 1000-5000' ELSE '5: >=5000' END AS ticket_band FROM d)
SELECT year, ticket_band, COUNT(*) AS invoices, ROUND(SUM(net), 2) AS net_sales,
       ROUND(AVG(net), 2) AS avg_ticket,
       ROUND(100.0 * SUM(net) / (SELECT SUM(net) FROM b b2 WHERE b2.year = b.year), 1) AS share_of_year_pct
FROM b GROUP BY year, ticket_band ORDER BY year, ticket_band
