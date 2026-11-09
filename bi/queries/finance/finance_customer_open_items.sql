-- name: finance_customer_open_items
-- description: Statement of open items (extrato de pendentes) for ONE customer, to send or read to the customer: every unpaid or partly paid document (receivable_docs) with document date, due date, days overdue, original amount, already paid, still open (gross, with VAT), the Multibanco entity/reference still pending for it, and when it was sent as e-invoice. customer = customer code, NIF or part of the name (case-insensitive). Last line = TOTAL.
-- params: customer=, as_of=today
WITH k AS (
  SELECT customer_code FROM customers
  WHERE customer_code = :customer OR replace(COALESCE(nif,''),' ','') = :customer
     OR (length(:customer) >= 3 AND lower(name) LIKE '%' || lower(:customer) || '%')),
o AS (
  SELECT r.customer_code, r.customer_name, r.doc_id, r.doc_date, r.due_date,
         CAST(julianday(:as_of) - julianday(r.due_date) AS INTEGER) AS days_overdue,
         r.gross, r.settled, r.open_amount,
         (SELECT m.mb_entity || ' / ' || m.mb_reference FROM mb_references m WHERE m.doc_id = r.doc_id AND m.status = 'pending' LIMIT 1) AS mb_entity_reference,
         (SELECT MAX(substr(e.data_hora_envio,1,8)) FROM registo_fact_eletronica e
           WHERE e.codigo || ' ' || e.serie || '/' || e.numero = r.doc_id AND e.data_hora_envio > '19000101') AS einvoice_sent
  FROM receivable_docs r WHERE r.is_open = 1 AND r.customer_code IN (SELECT customer_code FROM k))
SELECT * FROM (
SELECT 0 AS is_total, customer_code, customer_name, doc_id, doc_date, due_date, days_overdue, ROUND(gross,2) AS gross,
       ROUND(settled,2) AS paid, ROUND(open_amount,2) AS open_amount, mb_entity_reference, einvoice_sent
FROM o
UNION ALL
SELECT 1, NULL, 'TOTAL', COUNT(*) || ' docs', MIN(doc_date), NULL, MAX(days_overdue), ROUND(SUM(gross),2), ROUND(SUM(settled),2),
       ROUND(SUM(open_amount),2), NULL, NULL FROM o
) ORDER BY is_total, customer_code, due_date
