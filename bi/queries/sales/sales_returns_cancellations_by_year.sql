-- name: sales_returns_cancellations_by_year
-- description: Per year: invoices issued, credit notes (count, value, % of invoiced value), cancelled documents (count, value, % of documents) and internal-consumption/sponsorship documents left out of sales.
-- params: start_year=2017, end_year=2026
SELECT year,
       SUM(CASE WHEN doc_class = 'invoice' AND is_cancelled = 0 AND is_internal = 0 THEN 1 ELSE 0 END) AS invoices,
       ROUND(SUM(CASE WHEN doc_class = 'invoice' AND is_cancelled = 0 AND is_internal = 0 THEN net ELSE 0 END), 2) AS invoiced_net,
       SUM(CASE WHEN doc_class = 'credit_note' AND is_cancelled = 0 AND is_internal = 0 THEN 1 ELSE 0 END) AS credit_notes,
       ROUND(-SUM(CASE WHEN doc_class = 'credit_note' AND is_cancelled = 0 AND is_internal = 0 THEN net ELSE 0 END), 2) AS credited_net,
       ROUND(-100.0 * SUM(CASE WHEN doc_class = 'credit_note' AND is_cancelled = 0 AND is_internal = 0 THEN net ELSE 0 END)
             / NULLIF(SUM(CASE WHEN doc_class = 'invoice' AND is_cancelled = 0 AND is_internal = 0 THEN net ELSE 0 END), 0), 2) AS credited_pct_of_invoiced,
       SUM(is_cancelled) AS cancelled_docs,
       ROUND(SUM(CASE WHEN is_cancelled = 1 THEN abs(net) ELSE 0 END), 2) AS cancelled_net,
       ROUND(100.0 * SUM(is_cancelled) / COUNT(*), 2) AS cancelled_pct_of_docs,
       SUM(CASE WHEN is_internal = 1 AND is_cancelled = 0 THEN 1 ELSE 0 END) AS internal_docs,
       ROUND(SUM(CASE WHEN is_internal = 1 AND is_cancelled = 0 THEN net ELSE 0 END), 2) AS internal_net
FROM sales_docs
WHERE doc_class IN ('invoice', 'credit_note') AND year BETWEEN :start_year AND :end_year
GROUP BY year ORDER BY year
