-- name: finance_receivables_aging
-- description: Receivables summary by aging bucket (gross, VAT included) at as_of: documents, customers, amount and share; last row TOTAL plus the Clientes.saldo control total. Same rules as finance_receivables_open.
-- params: as_of=2026-11-08
WITH o AS (
  SELECT v.entidade_codigo AS customer_code,
         CASE WHEN v.data_venc > '19000101' THEN date(substr(v.data_venc,1,4)||'-'||substr(v.data_venc,5,2)||'-'||substr(v.data_venc,7,2))
              ELSE date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) END AS due_date,
         CASE WHEN v.Codigo IN ('NC','NCP','NCCIR') THEN -1 ELSE 1 END
           * (CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) AS open_amount
  FROM cab_vendas v
  WHERE v.estado_doc <> '1' AND v.data_doc <> ''
    AND abs(CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) > 0.005),
b AS (
  SELECT CASE WHEN due_date >= :as_of THEN '0 por vencer'
              WHEN due_date >= date(:as_of,'-30 days') THEN '1 vencido 1-30 dias'
              WHEN due_date >= date(:as_of,'-90 days') THEN '2 vencido 31-90 dias'
              WHEN due_date >= date(:as_of,'-365 days') THEN '3 vencido 91-365 dias'
              ELSE '4 vencido ha mais de 1 ano' END AS bucket, customer_code, open_amount
  FROM o)
SELECT bucket, COUNT(*) AS docs, COUNT(DISTINCT customer_code) AS customers, ROUND(SUM(open_amount),2) AS open_amount,
       ROUND(100.0 * SUM(open_amount) / (SELECT SUM(open_amount) FROM b),1) AS share_pct
FROM b GROUP BY bucket
UNION ALL
SELECT 'TOTAL', COUNT(*), COUNT(DISTINCT customer_code), ROUND(SUM(open_amount),2), 100.0 FROM b
UNION ALL
SELECT 'controlo: soma Clientes.saldo', NULL, SUM(CAST(saldo AS REAL) <> 0), ROUND(SUM(CAST(saldo AS REAL)),2), NULL FROM Clientes
