-- name: customers_geography
-- description: Where customers are: region and area (view customer_regions: postcode and address rules from the database's ggest.json, with the locality of gGest's postcode table codpostal) with customers on file, buying customers, net sales, margin, share of sales, net per buyer and repair orders in the period. level = region (one row per region) | area (one row per region and area). Regions and areas are configurable per company (ggest.json `regions` / `areas`); the defaults split Portugal into Continente / Madeira / Açores by postcode.
-- params: start=2017-01-01, end=today, level=area
WITH f AS (SELECT customer_code, SUM(net) AS net, SUM(margin) AS margin FROM sales_facts
           WHERE doc_date BETWEEN :start AND :end GROUP BY 1),
r AS (SELECT customer_code, COUNT(*) AS repairs FROM repairs WHERE opened_on BETWEEN :start AND :end GROUP BY 1)
SELECT g.region, CASE WHEN :level IN ('region', 'island') THEN NULL ELSE COALESCE(g.area, '(n/d)') END AS area,
       COUNT(*) AS customers_on_file, COUNT(f.customer_code) AS buying_customers,
       ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.net) / (SELECT SUM(net) FROM sales_facts WHERE doc_date BETWEEN :start AND :end), 1) AS share_pct,
       ROUND(SUM(f.net) / NULLIF(COUNT(f.customer_code), 0), 2) AS net_per_buyer,
       COALESCE(SUM(r.repairs), 0) AS repairs
FROM customer_regions g LEFT JOIN f USING (customer_code) LEFT JOIN r USING (customer_code)
GROUP BY 1, 2 ORDER BY net_sales DESC
