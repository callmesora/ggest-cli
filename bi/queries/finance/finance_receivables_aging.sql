-- name: finance_receivables_aging
-- description: Receivables summary by aging bucket (gross, VAT included) at as_of: documents, customers, amount and share; last row TOTAL plus the Clientes.saldo control total. Same rules as finance_receivables_open (receivable_docs).
-- params: as_of=today
WITH o AS (
  SELECT customer_code, due_date, open_amount FROM receivable_docs WHERE is_open = 1),
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
