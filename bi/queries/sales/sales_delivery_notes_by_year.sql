-- name: sales_delivery_notes_by_year
-- description: Delivery/transport notes to customers (guias, view delivery_notes) per year and doc type: notes, net value, customers, how many are invoiced (linked to an invoice or converted), after_invoice (accompany goods already invoiced) and not_linked, with net of the not-linked ones. Cancelled notes excluded. Links exist only from late 2021.
-- params: start_year=2017, end_year=this_year
SELECT year, doc_type, COUNT(*) AS notes, ROUND(SUM(net), 0) AS net, COUNT(DISTINCT customer_code) AS customers,
       SUM(billing_status = 'invoiced') AS invoiced, SUM(billing_status = 'after_invoice') AS after_invoice,
       SUM(billing_status = 'not_linked') AS not_linked,
       ROUND(SUM(CASE WHEN billing_status = 'not_linked' THEN net ELSE 0 END), 0) AS net_not_linked
FROM delivery_notes
WHERE is_cancelled = 0 AND year BETWEEN :start_year AND :end_year
GROUP BY year, doc_type ORDER BY year, doc_type
LIMIT 200
