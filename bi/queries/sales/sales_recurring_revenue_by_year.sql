-- name: sales_recurring_revenue_by_year
-- description: Recurring revenue estimate per year by stream: gGest annual update contracts (ACTPER*), gGest annual/cloud subscriptions, year-end close service (F/A), hosting and domains, other renewals/subscriptions; with paying customers. One-off gGest perpetual ('vitalicio') licences shown for comparison (not recurring).
-- params: start_year=2017, end_year=this_year
WITH r AS (
  SELECT year, customer_code, net,
         CASE WHEN family_name = 'GOLFINHO SOFTWARE' AND item_code LIKE 'ACTPER%' THEN 'gGest contrato anual actualizacao'
              WHEN family_name = 'GOLFINHO SOFTWARE' AND (lower(item_description) LIKE '%anual%' OR lower(item_description) LIKE '%cloud%'
                   OR lower(item_description) LIKE '%mensal%') THEN 'gGest subscricao anual/cloud'
              WHEN family_name = 'GOLFINHO SOFTWARE' AND lower(item_description) LIKE '%vitalic%' THEN 'gGest licenca vitalicia (NAO recorrente)'
              WHEN item_code = 'F/A' THEN 'Servico fecho/abertura de ano'
              WHEN group_name = 'INTERNET E CLOUD' THEN 'Alojamento e dominios'
              WHEN lower(item_description) LIKE '%renewal%' OR lower(item_description) LIKE '%renova%' OR lower(item_description) LIKE '%subscri%'
                   OR lower(item_description) LIKE '%avença%' OR lower(item_description) LIKE '%avenca%' THEN 'Outras renovacoes/subscricoes'
         END AS stream
  FROM sales_facts WHERE year BETWEEN :start_year AND :end_year)
SELECT year, stream, ROUND(SUM(net), 2) AS net_sales, COUNT(DISTINCT customer_code) AS customers,
       ROUND(SUM(net) / NULLIF(COUNT(DISTINCT customer_code), 0), 2) AS net_per_customer
FROM r WHERE stream IS NOT NULL GROUP BY year, stream ORDER BY year, net_sales DESC
