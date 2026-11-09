-- name: finance_freight_costs_by_year
-- description: Freight ("portes": sea/air freight, forwarders, couriers, port fees) paid on purchases vs freight charged to customers on sales, per year. Purchase freight = purchase lines whose item is in group POR (PORTES) or typed as fee (F); sales freight = sales_facts lines in group PORTES or line_kind fee. recovery_pct = charged / paid.
-- params: start_year=2017, end_year=this_year
WITH pl AS (
  SELECT CAST(substr(c.data_doc,1,4) AS INTEGER) AS year,
         CASE WHEN c.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(l.Total AS REAL) AS net,
         CASE WHEN a.grupo = 'POR' OR l.tipo_artigo = 'F' THEN 1 ELSE 0 END AS is_freight,
         c.entidade_codigo AS supplier_code
  FROM lin_compras l
  JOIN cab_compras c ON c.Codigo = l.Codigo AND c.serie = l.serie AND c.numero = l.numero
  LEFT JOIN Artigos a ON a.Codigo = l.Artigo
  WHERE c.estado_doc <> '1' AND c.data_doc <> ''),
p AS (SELECT year, SUM(net) AS purchase_lines_net, SUM(CASE WHEN is_freight = 1 THEN net END) AS freight_paid,
             SUM(CASE WHEN is_freight = 1 AND supplier_code = '78' THEN net END) AS freight_main_forwarder
      FROM pl GROUP BY year),
s AS (SELECT year, SUM(CASE WHEN group_name = 'PORTES' OR line_kind = 'fee' THEN net END) AS freight_charged,
             COUNT(DISTINCT CASE WHEN group_name = 'PORTES' OR line_kind = 'fee' THEN doc_id END) AS sales_docs_with_freight
      FROM sales_facts GROUP BY year)
SELECT p.year, ROUND(p.freight_paid,0) AS freight_paid_on_purchases,
       ROUND(100.0 * p.freight_paid / (p.purchase_lines_net - p.freight_paid),1) AS freight_pct_of_goods_bought,
       ROUND(p.freight_main_forwarder,0) AS of_which_ismael_pimenta,
       ROUND(s.freight_charged,0) AS freight_charged_on_sales, s.sales_docs_with_freight,
       ROUND(100.0 * s.freight_charged / p.freight_paid,1) AS recovery_pct,
       ROUND(p.freight_paid - COALESCE(s.freight_charged,0),0) AS freight_absorbed
FROM p LEFT JOIN s ON s.year = p.year
WHERE p.year BETWEEN :start_year AND :end_year ORDER BY p.year
