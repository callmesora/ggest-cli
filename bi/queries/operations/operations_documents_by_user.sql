-- name: operations_documents_by_user
-- description: Who issues what in gGest: documents created per gGest user in a period, by module (sales invoices/credit notes, repair orders, quotes, purchases, receipts/payments, delivery notes, expenses, stock and assembly documents), with total and share of all documents, plus cancelled documents. Aggregate workload view (division of tasks), not individual monitoring. Documents imported at the 2020-03 gGest installation are excluded. For sales value per user see management_sales_by_user.
-- params: start=year_start, end=today
SELECT user_code, COALESCE(user_name, '(user ' || user_code || ')') AS user_name,
       SUM(module = 'sales') AS sales, SUM(module = 'repairs') AS repairs, SUM(module = 'quotes') AS quotes,
       SUM(module = 'purchases') AS purchases, SUM(module = 'receipts_payments') AS receipts_payments,
       SUM(module = 'delivery_notes') AS delivery_notes, SUM(module = 'expenses') AS expenses,
       SUM(module IN ('stock','assembly','other_sales_docs')) AS stock_assembly_other,
       COUNT(*) AS total, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct,
       SUM(is_cancelled) AS cancelled
FROM documents_created
WHERE is_migrated = 0 AND date(created_at) BETWEEN :start AND :end
GROUP BY user_code
ORDER BY total DESC
