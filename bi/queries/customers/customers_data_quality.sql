-- name: customers_data_quality
-- description: Customer records to fix in gGest (one row per record and issue; names and codes only, no contact values). Issues: invalid_nif (fails the PT NIF checksum or impossible prefix), missing_nif_buyer (no NIF but net purchases >= min_net: invoices to a person/company without NIF), no_contact_active (active in the last active_days days and no phone nor e-mail), partial_postal_code (active, postal code without the 3-digit suffix, so the locality is unknown), same_nif_same_name (duplicate record: another record with the same NIF and name; merge candidates), inactive_flag_but_buying (marked inactive but bought in the last active_days days). issue = all or one issue name.
-- params: issue=all, min_net=1000, active_days=730, limit=100
WITH b AS MATERIALIZED (
  SELECT d.customer_code, d.name, d.segment, d.nif_status, d.nif_clean, d.has_email, d.has_phone, d.has_full_postal_code,
         d.is_inactive, d.name_norm, a.net_lifetime, a.last_purchase, a.last_contact,
         a.last_contact > date(a.as_of, '-' || :active_days || ' days') AS active,
         a.last_purchase > date(a.as_of, '-' || :active_days || ' days') AS buying
  FROM customer_dim d JOIN customer_activity a USING (customer_code) WHERE d.segment <> 'consumidor_final'),
dup AS (
  SELECT nif_clean, name_norm, COUNT(*) AS n, group_concat(customer_code, ',') AS codes FROM b
  WHERE nif_status = 'valid' GROUP BY 1, 2 HAVING COUNT(*) > 1),
i AS (
  SELECT 'invalid_nif' AS issue, b.*, NULL AS related_codes FROM b WHERE nif_status = 'invalid'
  UNION ALL SELECT 'missing_nif_buyer', b.*, NULL FROM b WHERE nif_status = 'missing' AND net_lifetime >= :min_net
  UNION ALL SELECT 'no_contact_active', b.*, NULL FROM b WHERE active AND NOT has_email AND NOT has_phone
  UNION ALL SELECT 'partial_postal_code', b.*, NULL FROM b WHERE active AND NOT has_full_postal_code
  UNION ALL SELECT 'same_nif_same_name', b.*, dup.codes FROM b JOIN dup USING (nif_clean, name_norm)
  UNION ALL SELECT 'inactive_flag_but_buying', b.*, NULL FROM b WHERE is_inactive = 1 AND buying)
SELECT issue, customer_code, name, segment, nif_status, ROUND(net_lifetime, 2) AS net_lifetime, last_purchase, last_contact,
       related_codes
FROM i WHERE :issue = 'all' OR issue = :issue
ORDER BY issue, net_lifetime DESC LIMIT :limit
