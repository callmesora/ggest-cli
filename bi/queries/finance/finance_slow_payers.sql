-- name: finance_slow_payers
-- description: Customers ranked by value-weighted days to pay their credit invoices (FT/FTGOL settled by receipt) since `start`, for customers invoiced at least min_invoiced (gross). Also current open balance. Use to decide who should pay upfront / get reminders.
-- params: start=2024-01-01, min_invoiced=2000, limit=25
WITH r AS (
  SELECT l.liquida_codigo AS t, l.liquida_serie AS s, l.liquida_numero AS n, MAX(l.data_doc) AS paid_on
  FROM lin_recpag l
  JOIN cab_recpag c ON c.Codigo = l.Codigo AND c.serie = l.serie AND c.numero = l.numero
  WHERE l.Codigo = 'R' AND c.estado_doc <> '1' AND l.liquida_codigo IN ('FT','FTGOL')
  GROUP BY 1,2,3),
i AS (
  SELECT v.entidade_codigo AS customer_code, trim(v.entidade_descricao) AS customer_name, CAST(v.total_documento AS REAL) AS gross,
         CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL) AS open_amount,
         julianday(date(substr(r.paid_on,1,4)||'-'||substr(r.paid_on,5,2)||'-'||substr(r.paid_on,7,2)))
           - julianday(date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2))) AS days
  FROM cab_vendas v
  LEFT JOIN r ON r.t = v.Codigo AND r.s = v.serie AND r.n = v.numero
  WHERE v.Codigo IN ('FT','FTGOL') AND v.estado_doc <> '1'
    AND date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) >= :start)
SELECT customer_code, MAX(customer_name) AS customer_name, COUNT(*) AS invoices, ROUND(SUM(gross),0) AS invoiced_gross,
       ROUND(SUM(days*gross) / SUM(CASE WHEN days IS NOT NULL THEN gross END),0) AS weighted_days_to_pay,
       CAST(MAX(days) AS INTEGER) AS max_days, ROUND(SUM(CASE WHEN open_amount > 0.005 THEN open_amount ELSE 0 END),2) AS open_now
FROM i GROUP BY customer_code
HAVING SUM(gross) >= :min_invoiced AND SUM(days IS NOT NULL) > 0
ORDER BY weighted_days_to_pay DESC LIMIT :limit
