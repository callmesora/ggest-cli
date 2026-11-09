-- name: finance_receivables_open
-- description: Who owes money now: open (unpaid) balance per customer from sales documents (gross, VAT included: total_documento - Total_liquidado; credit notes negative), with aging by due date (= document date for almost all invoices, payment term 'pronto'). The total reconciles with Clientes.saldo and with the totais_clientes running totals (17,286 EUR at 2026-11-08); clientes_saldo is shown per customer as a check.
-- params: as_of=2026-11-08, min_open=1, limit=50
WITH o AS (
  SELECT v.entidade_codigo AS customer_code, trim(v.entidade_descricao) AS doc_name,
         date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) AS doc_date,
         CASE WHEN v.data_venc > '19000101' THEN date(substr(v.data_venc,1,4)||'-'||substr(v.data_venc,5,2)||'-'||substr(v.data_venc,7,2))
              ELSE date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) END AS due_date,
         CASE WHEN v.Codigo IN ('NC','NCP','NCCIR') THEN -1 ELSE 1 END
           * (CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) AS open_amount
  FROM cab_vendas v
  WHERE v.estado_doc <> '1' AND v.data_doc <> ''
    AND abs(CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) > 0.005),
c AS (
  SELECT customer_code, MAX(doc_name) AS customer_name, COUNT(*) AS open_docs, SUM(open_amount) AS open_total,
         SUM(CASE WHEN due_date >= :as_of THEN open_amount ELSE 0 END) AS not_due,
         SUM(CASE WHEN due_date < :as_of AND due_date >= date(:as_of,'-30 days') THEN open_amount ELSE 0 END) AS d1_30,
         SUM(CASE WHEN due_date < date(:as_of,'-30 days') AND due_date >= date(:as_of,'-90 days') THEN open_amount ELSE 0 END) AS d31_90,
         SUM(CASE WHEN due_date < date(:as_of,'-90 days') AND due_date >= date(:as_of,'-365 days') THEN open_amount ELSE 0 END) AS d91_365,
         SUM(CASE WHEN due_date < date(:as_of,'-365 days') THEN open_amount ELSE 0 END) AS over_1y,
         MIN(doc_date) AS oldest_open_doc
  FROM o GROUP BY customer_code)
SELECT c.customer_code, c.customer_name, c.open_docs, ROUND(c.open_total,2) AS open_total,
       ROUND(c.not_due,2) AS not_due, ROUND(c.d1_30,2) AS overdue_1_30d, ROUND(c.d31_90,2) AS overdue_31_90d,
       ROUND(c.d91_365,2) AS overdue_91_365d, ROUND(c.over_1y,2) AS overdue_over_1y, c.oldest_open_doc,
       CAST(julianday(:as_of) - julianday(c.oldest_open_doc) AS INTEGER) AS oldest_days,
       ROUND(CAST(k.saldo AS REAL),2) AS clientes_saldo,
       ROUND(100.0 * c.open_total / SUM(c.open_total) OVER (),1) AS share_pct
FROM c LEFT JOIN Clientes k ON k.Codigo = c.customer_code
WHERE c.open_total >= :min_open
ORDER BY c.open_total DESC LIMIT :limit
