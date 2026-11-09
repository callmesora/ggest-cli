-- name: finance_collections_list
-- description: Collections worklist (cobranças), who owes what, oldest first: one row per customer with an open balance at the data date (receivable_docs, gross with VAT, credit notes netted), overdue amount and amount overdue > 90 days, oldest due date and days overdue, the open documents ('FT 2025/123 2025-03-01 150.00' oldest first), pending Multibanco references, documents already sent as e-invoice, last payment received, contact (phone, email: only with include_contacts=1, use it for a short list) and what WE owe the same entity as supplier/creditor (same NIF; candidate for an offset). Ordered by oldest due date unless order=amount. First row = TOTAL over ALL customers with an open balance >= min_open (with how many are listed), so the total is right even when limit cuts the list. Balances are as of now: as_of only moves the overdue cut-off.
-- params: as_of=today, min_open=1, order=oldest, include_contacts=0, limit=500
WITH o AS (
  SELECT r.*, CAST(julianday(:as_of) - julianday(r.due_date) AS INTEGER) AS days_overdue
  FROM receivable_docs r WHERE r.is_open = 1),
lp AS (SELECT party_code, MAX(doc_date) AS last_payment FROM payment_docs WHERE party_type = 'customer' GROUP BY party_code),
mb AS (SELECT m.customer_code, COUNT(*) AS n FROM mb_references m JOIN o ON o.doc_id = m.doc_id WHERE m.status = 'pending' GROUP BY 1),
ei AS (SELECT o.customer_code, COUNT(*) AS n FROM registo_fact_eletronica e
       JOIN o ON o.doc_id = e.codigo || ' ' || e.serie || '/' || e.numero WHERE e.data_hora_envio > '19000101' GROUP BY 1),
c AS (
  SELECT customer_code, MAX(customer_name) AS customer_name, COUNT(*) AS open_docs, SUM(open_amount) AS open_total,
         SUM(CASE WHEN days_overdue > 0 THEN open_amount ELSE 0 END) AS overdue,
         SUM(CASE WHEN days_overdue > 90 THEN open_amount ELSE 0 END) AS overdue_90d,
         MIN(due_date) AS oldest_due, MAX(days_overdue) AS max_days_overdue,
         GROUP_CONCAT(doc_id || ' ' || doc_date || ' ' || printf('%.2f', open_amount), ' | ') AS docs
  FROM (SELECT * FROM o ORDER BY due_date) GROUP BY customer_code),
nif AS (SELECT customer_code, upper(replace(replace(COALESCE(nif,''),' ',''),'PT','')) AS nf FROM customers),
owe AS (
  SELECT upper(replace(replace(COALESCE(k.contribuinte,''),' ',''),'PT','')) AS nf, SUM(p.open_amount) AS we_owe
  FROM payable_docs p
  JOIN (SELECT 'supplier' AS t, Codigo, contribuinte FROM Fornecedores UNION ALL SELECT 'creditor', Codigo, contribuinte FROM Credores) k
    ON k.t = p.party_type AND k.Codigo = p.party_code
  WHERE p.is_open = 1 GROUP BY 1),
cl AS (
  SELECT c.customer_code, c.customer_name, c.open_docs, ROUND(c.open_total,2) AS open_total, ROUND(c.overdue,2) AS overdue,
         ROUND(c.overdue_90d,2) AS overdue_90d, c.oldest_due, c.max_days_overdue, lp.last_payment,
         COALESCE(mb.n,0) AS pending_mb_refs, COALESCE(ei.n,0) AS einvoices_sent, ROUND(w.we_owe,2) AS we_owe_them,
         CASE WHEN :include_contacts = 1 THEN k.phone END AS phone, CASE WHEN :include_contacts = 1 THEN k.email END AS email, c.docs
  FROM c
  LEFT JOIN lp ON lp.party_code = c.customer_code
  LEFT JOIN mb ON mb.customer_code = c.customer_code
  LEFT JOIN ei ON ei.customer_code = c.customer_code
  LEFT JOIN customers k ON k.customer_code = c.customer_code
  LEFT JOIN nif ON nif.customer_code = c.customer_code
  LEFT JOIN owe w ON w.nf = nif.nf AND length(nif.nf) = 9
  WHERE c.open_total >= :min_open)
SELECT * FROM (
  SELECT 'TOTAL (' || COUNT(*) || ' customers, ' || MIN(COUNT(*), :limit) || ' listed)' AS customer_code, NULL AS customer_name,
         SUM(open_docs) AS open_docs, ROUND(SUM(open_total),2) AS open_total, ROUND(SUM(overdue),2) AS overdue,
         ROUND(SUM(overdue_90d),2) AS overdue_90d, MIN(oldest_due) AS oldest_due, MAX(max_days_overdue) AS max_days_overdue,
         NULL AS last_payment, SUM(pending_mb_refs) AS pending_mb_refs, SUM(einvoices_sent) AS einvoices_sent,
         ROUND(SUM(we_owe_them),2) AS we_owe_them, NULL AS phone, NULL AS email, NULL AS docs
  FROM cl)
UNION ALL
SELECT * FROM (
  SELECT * FROM cl
  ORDER BY CASE WHEN :order = 'amount' THEN -open_total END, oldest_due, open_total DESC
  LIMIT :limit)
