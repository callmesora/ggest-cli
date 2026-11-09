-- name: finance_receivables_trend
-- description: Customer receivables balance (gross, with VAT) at the end of each month, rebuilt from documents and their settlements (receivable_docs + payment_allocations: balance at D = documents dated <= D minus settlements dated <= D), with the amount invoiced on credit and collected (settled) in the month, the change vs the previous month and the balance 12 months earlier. The last month runs to the data date and equals finance_receivables_open's total. Use for "are receivables going up?" and month-close.
-- params: start_year=years_ago_3, as_of=today
WITH r AS MATERIALIZED (SELECT doc_id, sign FROM receivable_docs),
a AS MATERIALIZED (SELECT settled_doc_id, amount, payment_date FROM payment_allocations WHERE payment_date <= :as_of),
ev AS (
  SELECT substr(doc_date,1,7) AS month, gross AS invoiced, 0 AS collected FROM receivable_docs WHERE doc_date <= :as_of
  UNION ALL
  SELECT substr(a.payment_date,1,7), 0, r.sign * a.amount
  FROM a JOIN r ON r.doc_id = a.settled_doc_id),
mon AS (SELECT month, SUM(invoiced) AS invoiced, SUM(collected) AS collected FROM ev GROUP BY month),
cum AS (SELECT month, invoiced, collected,
               SUM(invoiced - collected) OVER (ORDER BY month ROWS UNBOUNDED PRECEDING) AS balance FROM mon),
lagged AS (SELECT c.*, LAG(balance) OVER (ORDER BY month) AS prev_balance,
                  (SELECT c2.balance FROM cum c2 WHERE c2.month <= substr(date(c.month || '-01', '-12 months'),1,7)
                   ORDER BY c2.month DESC LIMIT 1) AS balance_year_before
           FROM cum c)
SELECT month, ROUND(balance,2) AS receivables_at_month_end, ROUND(invoiced,2) AS invoiced_on_credit,
       ROUND(collected,2) AS collected, ROUND(balance - prev_balance,2) AS change_vs_prev_month,
       ROUND(balance_year_before,2) AS receivables_year_before
FROM lagged WHERE CAST(substr(month,1,4) AS INTEGER) >= :start_year ORDER BY month
