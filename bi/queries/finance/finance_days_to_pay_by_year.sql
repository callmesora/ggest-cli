-- name: finance_days_to_pay_by_year
-- description: Collection speed of credit invoices (FT and FTGOL, i.e. not paid at the counter) per invoice year: days from invoice date to the date of the (last) receipt R that settled it (lin_recpag.liquida_*; cancelled receipts excluded). avg_days, value-weighted days, median-ish share paid same day / within 30 / over 60 days. Invoices still open are excluded from the averages and counted in still_open (recent years are therefore biased low).
-- params: start_year=2017, end_year=2026
WITH r AS (
  SELECT l.liquida_codigo AS t, l.liquida_serie AS s, l.liquida_numero AS n, MAX(l.data_doc) AS paid_on
  FROM lin_recpag l
  JOIN cab_recpag c ON c.Codigo = l.Codigo AND c.serie = l.serie AND c.numero = l.numero
  WHERE l.Codigo = 'R' AND c.estado_doc <> '1' AND l.liquida_codigo IN ('FT','FTGOL')
  GROUP BY 1,2,3),
i AS (
  SELECT CAST(substr(v.data_doc,1,4) AS INTEGER) AS year, CAST(v.total_documento AS REAL) AS gross,
         CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL) AS open_amount,
         julianday(date(substr(r.paid_on,1,4)||'-'||substr(r.paid_on,5,2)||'-'||substr(r.paid_on,7,2)))
           - julianday(date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2))) AS days
  FROM cab_vendas v
  LEFT JOIN r ON r.t = v.Codigo AND r.s = v.serie AND r.n = v.numero
  WHERE v.Codigo IN ('FT','FTGOL') AND v.estado_doc <> '1' AND v.data_doc <> '')
SELECT year, COUNT(*) AS invoices, ROUND(SUM(gross),0) AS invoiced_gross,
       SUM(days IS NOT NULL) AS paid_by_receipt,
       SUM(open_amount > 0.005) AS still_open, ROUND(SUM(CASE WHEN open_amount > 0.005 THEN open_amount END),0) AS still_open_amount,
       ROUND(AVG(days),1) AS avg_days, ROUND(SUM(days*gross) / SUM(CASE WHEN days IS NOT NULL THEN gross END),1) AS weighted_avg_days,
       ROUND(100.0 * SUM(days = 0) / SUM(days IS NOT NULL),1) AS pct_same_day,
       ROUND(100.0 * SUM(days <= 30) / SUM(days IS NOT NULL),1) AS pct_within_30d,
       ROUND(100.0 * SUM(days > 60) / SUM(days IS NOT NULL),1) AS pct_over_60d,
       ROUND(100.0 * SUM(CASE WHEN days > 60 THEN gross END) / SUM(CASE WHEN days IS NOT NULL THEN gross END),1) AS pct_value_over_60d
FROM i WHERE year BETWEEN :start_year AND :end_year
GROUP BY year ORDER BY year
