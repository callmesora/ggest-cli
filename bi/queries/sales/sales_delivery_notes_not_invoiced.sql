-- name: sales_delivery_notes_not_invoiced
-- description: Delivery/transport notes (guias GTC etc., view delivery_notes) with no invoice linked, in a period, net >= min_net: goods that left the shop and may still need invoicing. Columns: doc_id, doc_date, customer, net, origin document (quote/order/pro-forma it came from), refers_to_invoice (text line quotes an invoice: transport of goods already invoiced), nearest same-customer invoice within 30 days (first one after the note, else last one before; sales_facts), the customer's net sales within +-30 days — if one exists the note was probably invoiced without a link. Many notes carry customer equipment sent for repair or Chip7 orders: review, don't assume lost money. Cancelled notes excluded. total_notes / total_net cover ALL matching notes, not only the rows shown.
-- params: start=last_year_start, end=today, min_net=0, limit=100
WITH d AS MATERIALIZED (SELECT *, COUNT(*) OVER () AS total_notes, ROUND(SUM(net) OVER (), 2) AS total_net FROM delivery_notes
  WHERE is_cancelled = 0 AND billing_status = 'not_linked' AND doc_date BETWEEN :start AND :end AND net >= :min_net
  ORDER BY net DESC LIMIT :limit)
SELECT d.doc_id, d.doc_date, d.customer_code, d.customer_name, ROUND(d.net, 2) AS net, d.line_count, d.origin_doc_id,
       d.refers_to_invoice,
       COALESCE((SELECT f.doc_id FROM sales_facts f WHERE f.customer_code = d.customer_code AND f.net > 0
                   AND f.doc_date BETWEEN d.doc_date AND date(d.doc_date, '+30 days') ORDER BY f.doc_date LIMIT 1),
                (SELECT f.doc_id FROM sales_facts f WHERE f.customer_code = d.customer_code AND f.net > 0
                   AND f.doc_date BETWEEN date(d.doc_date, '-30 days') AND d.doc_date ORDER BY f.doc_date DESC LIMIT 1)) AS nearby_invoice,
       (SELECT ROUND(SUM(f.net), 2) FROM sales_facts f WHERE f.customer_code = d.customer_code
          AND f.doc_date BETWEEN date(d.doc_date, '-30 days') AND date(d.doc_date, '+30 days')) AS customer_net_pm30d, d.total_notes, d.total_net,
       (SELECT group_concat(substr(trim(g.descricao), 1, 35), ' | ') FROM lin_guias g
         WHERE g.Codigo || ' ' || g.serie || '/' || g.numero = d.doc_id AND CAST(g.quantidade AS REAL) <> 0) AS items
FROM d
ORDER BY d.net DESC
LIMIT 500
