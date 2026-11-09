-- name: finance_receivables_open
-- description: Who owes money now: open (unpaid) balance per customer from receivable_docs (current-account sales documents, gross, VAT included: total_documento - Total_liquidado; credit notes negative), with aging by due date (= document date for almost all invoices, payment term 'pronto'). The total reconciles with Clientes.saldo and with the totais_clientes running totals; clientes_saldo is shown per customer as a check.
-- params: as_of=today, min_open=1, limit=50
WITH o AS (
  SELECT customer_code, customer_name AS doc_name, doc_date, due_date, open_amount
  FROM receivable_docs WHERE is_open = 1),
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
