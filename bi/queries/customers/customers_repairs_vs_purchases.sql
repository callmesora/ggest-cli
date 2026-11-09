-- name: customers_repairs_vs_purchases
-- description: Cross-sell: per customer, repair orders (assistencias) vs purchases. Quadrants: repara_muito_compra_pouco (>= min_repairs repairs and product net < low_net: offer new equipment / maintenance contract); compra_muito_sem_assistencia (product net >= high_net and 0 repairs: offer support/maintenance); equilibrado. quadrant = all | repara_muito_compra_pouco | compra_muito_sem_assistencia | equilibrado
-- params: start=2017-01-01, end=today, min_repairs=5, low_net=300, high_net=3000, quadrant=repara_muito_compra_pouco, limit=50
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim),
rp AS (
  SELECT customer_code, COUNT(*) AS repairs, MAX(opened_on) AS last_repair,
         group_concat(DISTINCT equipment_type) AS equipment_types
  FROM repairs WHERE opened_on BETWEEN :start AND :end GROUP BY 1),
sl AS (
  SELECT customer_code,
         SUM(CASE WHEN line_kind = 'product' THEN net ELSE 0 END) AS product_net,
         SUM(CASE WHEN line_kind = 'service' THEN net ELSE 0 END) AS service_net,
         SUM(CASE WHEN origin_doc_type = 'OSA' THEN net ELSE 0 END) AS billed_from_repairs_net,
         SUM(net) AS net_sales, SUM(margin) AS gross_margin, MAX(doc_date) AS last_purchase
  FROM sales_facts WHERE doc_date BETWEEN :start AND :end GROUP BY 1),
x AS (
  SELECT seg.customer_code, seg.name AS customer, seg.segment, COALESCE(rp.repairs, 0) AS repairs, rp.equipment_types, rp.last_repair,
         COALESCE(sl.product_net, 0) AS product_net, COALESCE(sl.service_net, 0) AS service_net,
         COALESCE(sl.billed_from_repairs_net, 0) AS billed_from_repairs_net, COALESCE(sl.net_sales, 0) AS net_sales,
         COALESCE(sl.gross_margin, 0) AS gross_margin, sl.last_purchase,
         CASE WHEN COALESCE(rp.repairs, 0) >= :min_repairs AND COALESCE(sl.product_net, 0) < :low_net THEN 'repara_muito_compra_pouco'
              WHEN COALESCE(rp.repairs, 0) = 0 AND COALESCE(sl.product_net, 0) >= :high_net THEN 'compra_muito_sem_assistencia'
              ELSE 'equilibrado' END AS quadrant
  FROM seg LEFT JOIN rp USING (customer_code) LEFT JOIN sl USING (customer_code)
  WHERE seg.segment <> 'consumidor_final' AND (rp.customer_code IS NOT NULL OR sl.customer_code IS NOT NULL))
SELECT customer_code, customer, segment, quadrant, repairs, equipment_types, last_repair,
       ROUND(product_net, 2) AS product_net, ROUND(service_net, 2) AS service_net,
       ROUND(billed_from_repairs_net, 2) AS billed_from_repairs_net, ROUND(net_sales, 2) AS net_sales,
       ROUND(gross_margin, 2) AS gross_margin, last_purchase
FROM x WHERE :quadrant = 'all' OR quadrant = :quadrant
ORDER BY CASE WHEN quadrant = 'compra_muito_sem_assistencia' THEN product_net ELSE repairs END DESC, net_sales DESC
LIMIT :limit
