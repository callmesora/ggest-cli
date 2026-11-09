-- name: finance_cash_flow_by_month
-- description: Money in vs money out per month (indicative cash flow, gross with VAT): in = receipts from customers for credit invoices (R/RECPT/ACERT, payment_docs) + documents settled on the spot (FR/FS invoice-receipts minus NCP refunds, internal consumption excluded); out = payments to suppliers (P) and to other creditors (POC: salaries, rents, taxes, overheads). net_flow and the running total over the period. Purchases paid at the till and bank fees/interest not recorded in gGest are not included.
-- params: start=last_year_start, end=today
WITH s AS (
  SELECT substr(d.doc_date,1,7) AS month, SUM(d.gross) AS amt
  FROM sales_docs d JOIN Documentos t ON t.codigo = d.doc_type
  WHERE t.mov_cc = '4' AND d.is_cancelled = 0 AND d.is_internal = 0 AND d.doc_date BETWEEN :start AND :end GROUP BY 1),
p AS (
  SELECT month, SUM(CASE WHEN direction = 'in' THEN amount ELSE 0 END) AS receipts,
         SUM(CASE WHEN party_type = 'supplier' THEN amount ELSE 0 END) AS paid_suppliers,
         SUM(CASE WHEN party_type = 'creditor' THEN amount ELSE 0 END) AS paid_creditors
  FROM payment_docs WHERE doc_date BETWEEN :start AND :end GROUP BY month),
m AS (SELECT month FROM s UNION SELECT month FROM p)
SELECT m.month, ROUND(COALESCE(p.receipts,0),0) AS receipts_credit_invoices, ROUND(COALESCE(s.amt,0),0) AS counter_sales_paid,
       ROUND(COALESCE(p.receipts,0) + COALESCE(s.amt,0),0) AS money_in,
       ROUND(COALESCE(p.paid_suppliers,0),0) AS paid_suppliers, ROUND(COALESCE(p.paid_creditors,0),0) AS paid_overheads,
       ROUND(COALESCE(p.paid_suppliers,0) + COALESCE(p.paid_creditors,0),0) AS money_out,
       ROUND(COALESCE(p.receipts,0) + COALESCE(s.amt,0) - COALESCE(p.paid_suppliers,0) - COALESCE(p.paid_creditors,0),0) AS net_flow,
       ROUND(SUM(COALESCE(p.receipts,0) + COALESCE(s.amt,0) - COALESCE(p.paid_suppliers,0) - COALESCE(p.paid_creditors,0))
             OVER (ORDER BY m.month ROWS UNBOUNDED PRECEDING),0) AS cumulative_net_flow
FROM m LEFT JOIN s ON s.month = m.month LEFT JOIN p ON p.month = m.month
ORDER BY m.month
