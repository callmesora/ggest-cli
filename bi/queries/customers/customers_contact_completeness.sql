-- name: customers_contact_completeness
-- description: How complete the customer file is (counts only, never contact values): per segment and status (active = bought or repaired in the last active_days days; lapsed = had activity before; never = no sale or repair), records and % with e-mail, mobile, any phone, a contact person, any channel (e-mail or phone), a valid PT NIF (checksum), full postal code NNNN-NNN, a street address, and e-invoicing enabled. Walk-in records excluded. by = segment | status | both
-- params: active_days=1095, by=both
WITH b AS (
  SELECT d.*, CASE WHEN a.last_purchase IS NULL AND a.last_repair IS NULL THEN 'never'
                   WHEN max(COALESCE(a.last_purchase,''), COALESCE(a.last_repair,'')) > date(a.as_of, '-' || :active_days || ' days') THEN 'active'
                   ELSE 'lapsed' END AS status
  FROM customer_dim d JOIN customer_activity a USING (customer_code) WHERE d.segment <> 'consumidor_final')
SELECT CASE WHEN :by IN ('segment','both') THEN segment ELSE 'all' END AS segment,
       CASE WHEN :by IN ('status','both') THEN status ELSE 'all' END AS status,
       COUNT(*) AS records,
       ROUND(100.0 * AVG(has_email), 1) AS email_pct, ROUND(100.0 * AVG(has_mobile), 1) AS mobile_pct,
       ROUND(100.0 * AVG(has_phone), 1) AS phone_pct, ROUND(100.0 * AVG(has_contact_person), 1) AS contact_person_pct,
       ROUND(100.0 * AVG(has_email OR has_phone), 1) AS any_channel_pct,
       ROUND(100.0 * AVG(nif_status = 'valid'), 1) AS valid_nif_pct, ROUND(100.0 * AVG(nif_status = 'missing'), 1) AS missing_nif_pct,
       SUM(nif_status = 'invalid') AS invalid_nifs,
       ROUND(100.0 * AVG(has_full_postal_code), 1) AS full_postal_code_pct, ROUND(100.0 * AVG(has_street_address), 1) AS street_address_pct,
       SUM(sends_e_invoices) AS e_invoicing
FROM b GROUP BY 1, 2 ORDER BY 1, 2
