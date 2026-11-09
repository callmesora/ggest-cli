-- name: customers_data_quality_summary
-- description: Counts of customer-file problems (see customers_data_quality for the list of records): records, active records (any contact in the last active_days days), invalid NIF, missing NIF (all / buyers with net >= min_net), active without any phone or e-mail, active without full postal code, duplicate records with same NIF and same name (groups and records), NIFs shared by several records (often departments of a public body), inactive-flagged records still buying, records with alert notes, records opened this year and last year.
-- params: min_net=1000, active_days=730
WITH b AS MATERIALIZED (
  SELECT d.*, a.net_lifetime, a.last_contact > date(a.as_of, '-' || :active_days || ' days') AS active,
         a.last_purchase > date(a.as_of, '-' || :active_days || ' days') AS buying, a.as_of
  FROM customer_dim d JOIN customer_activity a USING (customer_code) WHERE d.segment <> 'consumidor_final'),
dup AS (SELECT nif_clean, name_norm, COUNT(*) AS n FROM b WHERE nif_status = 'valid' GROUP BY 1, 2 HAVING COUNT(*) > 1),
sh AS (SELECT nif_clean, COUNT(*) AS n FROM b WHERE nif_status = 'valid' GROUP BY 1 HAVING COUNT(*) > 1)
SELECT COUNT(*) AS records, SUM(active) AS active_records,
       SUM(nif_status = 'invalid') AS invalid_nif, SUM(nif_status = 'missing') AS missing_nif,
       SUM(nif_status = 'missing' AND net_lifetime >= :min_net) AS missing_nif_buyers,
       SUM(active AND NOT has_email AND NOT has_phone) AS active_without_contact,
       SUM(active AND NOT has_full_postal_code) AS active_without_full_postal_code,
       (SELECT COUNT(*) FROM dup) AS duplicate_groups, (SELECT SUM(n) FROM dup) AS duplicate_records,
       (SELECT COUNT(*) FROM sh) AS shared_nifs, (SELECT SUM(n) FROM sh) AS records_with_shared_nif,
       SUM(is_inactive = 1 AND buying) AS inactive_flag_but_buying, SUM(has_alert_note) AS alert_notes,
       SUM(substr(record_opened_on,1,4) = (SELECT substr(MAX(as_of),1,4) FROM b)) AS created_this_year,
       SUM(CAST(substr(record_opened_on,1,4) AS INTEGER) = CAST((SELECT substr(MAX(as_of),1,4) FROM b) AS INTEGER) - 1) AS created_last_year
FROM b
