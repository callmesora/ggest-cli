-- name: stock_supplier_scorecard
-- description: Supplier review for a period: one row per supplier with invoices, net purchases (net of credit notes, VAT excluded), share of total purchases, distinct items bought, goods returned/credited (DEVNC/VNC/VNCP/NCADI) value and % of gross purchases, average days between invoices (order frequency), first and last invoice date, and supplier RMAs opened in the period (assTec_RMA, recorded only 2020-2024). Ranked by net purchases. Freight is in finance_freight_costs_by_year; concentration over years in finance_top_suppliers.
-- params: start=last_year_start, end=today, limit=30
WITH p AS (
  SELECT supplier_code, MAX(supplier_name) AS supplier_name,
         SUM(CASE WHEN net > 0 THEN 1 ELSE 0 END) AS invoices,
         SUM(net) AS net_purchases,
         SUM(CASE WHEN net > 0 THEN net ELSE 0 END) AS gross_purchases,
         -SUM(CASE WHEN net < 0 THEN net ELSE 0 END) AS credited,
         MIN(doc_date) AS first_invoice, MAX(doc_date) AS last_invoice
  FROM purchase_docs WHERE is_cancelled = 0 AND doc_date BETWEEN :start AND :end GROUP BY supplier_code),
it AS (SELECT supplier_code, COUNT(DISTINCT item_code) AS items FROM stock_purchase_lines
       WHERE is_cancelled = 0 AND doc_date BETWEEN :start AND :end AND line_kind = 'product' GROUP BY supplier_code),
r AS (SELECT supplier_code, COUNT(*) AS rmas FROM supplier_rmas WHERE opened_on BETWEEN :start AND :end GROUP BY supplier_code),
tot AS (SELECT SUM(net_purchases) AS t FROM p)
SELECT p.supplier_code, p.supplier_name, p.invoices, ROUND(p.net_purchases,0) AS net_purchases,
       ROUND(100.0 * p.net_purchases / tot.t, 1) AS share_pct, it.items,
       ROUND(p.credited,0) AS credited, ROUND(100.0 * p.credited / NULLIF(p.gross_purchases,0), 1) AS credited_pct,
       CASE WHEN p.invoices > 1 THEN ROUND((julianday(p.last_invoice) - julianday(p.first_invoice)) / (p.invoices - 1), 0) END AS avg_days_between_invoices,
       p.first_invoice, p.last_invoice, COALESCE(r.rmas,0) AS rmas
FROM p CROSS JOIN tot
LEFT JOIN it ON it.supplier_code = p.supplier_code
LEFT JOIN r ON r.supplier_code = p.supplier_code
ORDER BY p.net_purchases DESC
LIMIT :limit
