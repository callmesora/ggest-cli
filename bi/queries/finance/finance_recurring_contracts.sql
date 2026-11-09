-- name: finance_recurring_contracts
-- description: Recurring contracts (avenças: hosting, domains, DNS management, licences) per customer from recurring_contracts, with period, amount per billing and annual value (net of VAT), next billing date, last billing and last invoice, and whether that last invoice is still unpaid. billing_status: overdue (active, next billing date already passed: invoice not issued), due_soon (within days_ahead), never_billed (active, no invoice yet), ok, inactive. status filter = all | active | to_bill (overdue + due_soon + never_billed) | inactive.
-- params: as_of=today, days_ahead=30, status=active, limit=200
WITH r AS MATERIALIZED (SELECT doc_id, open_amount, is_open FROM receivable_docs WHERE is_open = 1),
c AS (
  SELECT k.*,
         CASE WHEN k.is_active = 0 THEN 'inactive'
              WHEN k.last_billed IS NULL THEN 'never_billed'
              WHEN k.next_billing <= :as_of THEN 'overdue'
              WHEN k.next_billing <= date(:as_of, '+' || :days_ahead || ' days') THEN 'due_soon'
              ELSE 'ok' END AS billing_status
  FROM recurring_contracts k)
SELECT c.billing_status, c.customer_code, c.customer_name, c.contract_code, c.description, c.period, c.item_code,
       ROUND(c.amount_per_billing,2) AS amount_per_billing, ROUND(c.annual_value,2) AS annual_value,
       c.start_date, c.last_billed, c.next_billing, c.last_doc_id, ROUND(r.open_amount,2) AS last_doc_unpaid
FROM c LEFT JOIN r ON r.doc_id = c.last_doc_id
WHERE :status = 'all' OR (:status = 'active' AND c.is_active = 1) OR (:status = 'inactive' AND c.is_active = 0)
   OR (:status = 'to_bill' AND c.billing_status IN ('overdue','due_soon','never_billed'))
ORDER BY CASE c.billing_status WHEN 'overdue' THEN 0 WHEN 'never_billed' THEN 1 WHEN 'due_soon' THEN 2 WHEN 'ok' THEN 3 ELSE 4 END,
         c.next_billing, c.customer_name
LIMIT :limit
