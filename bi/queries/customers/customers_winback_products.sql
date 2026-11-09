-- name: customers_winback_products
-- description: Win-back campaign list with what each lapsed customer used to buy. Legal entities (records sharing a NIF merged; walk-in excluded) with lifetime net >= min_net and no purchase for inactive_days days: segment, lifetime net and margin, last purchase, last other contact (repair, quote, appointment), their top 3 product groups and top 3 items (by net), and which channels exist on file (has_email / has_mobile / has_phone flags, never the values). still_in_touch = 1 when they repaired, asked a quote or had an appointment after their last purchase (warm lead). records_same_nif = customer records merged into the entity (same NIF; each NIF is its own row). same_name_active_code = code of an ACTIVE record of another entity with the same normalised name once company words (lda, unipessoal, limitada, sociedade) are removed, e.g. a person now buying through their own company: check before contacting. suggested_offer is a rule of thumb from what they bought and when (product groups matched by name: comput*/notebook/desktop, consum*, software, impress*; ages vs the data date): PC replacement (last PC bought YYYY, >= 3 years), consumables reminder (consumables >= 25% of spend), software update/maintenance, printer replacement, convert repair contact, else general reactivation. segment = all | publico | empresa | particular | associativo
-- params: min_net=500, inactive_days=540, segment=all, limit=50
WITH e AS MATERIALIZED (
  SELECT d.entity_key, d.customer_code, d.segment, d.name, d.has_email, d.has_mobile, d.has_phone
  FROM customer_dim d WHERE d.segment <> 'consumidor_final'),
asof AS (SELECT MAX(doc_date) AS d FROM sales_docs),
cs AS MATERIALIZED (
  SELECT customer_code, SUM(net) AS net, SUM(margin) AS margin, MAX(doc_date) AS last_purchase,
         COUNT(DISTINCT doc_id) AS invoices
  FROM sales_facts GROUP BY 1),
s AS MATERIALIZED (
  SELECT e.entity_key, SUM(cs.net) AS net, SUM(cs.margin) AS margin, MAX(cs.last_purchase) AS last_purchase,
         SUM(cs.invoices) AS invoices, COUNT(*) AS records_with_sales, MAX(e.segment) AS segment,
         MAX(e.has_email) AS has_email, MAX(e.has_mobile) AS has_mobile, MAX(e.has_phone) AS has_phone
  FROM cs JOIN e USING (customer_code) GROUP BY 1
  HAVING SUM(cs.net) >= :min_net AND MAX(cs.last_purchase) <= date((SELECT d FROM asof), '-' || :inactive_days || ' days')),
ec AS MATERIALIZED (
  SELECT e.entity_key, e.customer_code, e.name, COALESCE(cs.net, 0) AS net,
         ROW_NUMBER() OVER (PARTITION BY e.entity_key ORDER BY COALESCE(cs.net, 0) DESC) AS rn
  FROM e LEFT JOIN cs USING (customer_code) WHERE e.entity_key IN (SELECT entity_key FROM s)),
lc AS (
  SELECT ec.entity_key, NULLIF(MAX(max(COALESCE(a.last_repair, ''), COALESCE(a.last_quote, ''),
         COALESCE(CASE WHEN a.last_appointment <= (SELECT d FROM asof) THEN a.last_appointment END, ''))), '') AS last_other_contact
  FROM ec JOIN customer_activity a ON a.customer_code = ec.customer_code GROUP BY 1),
g AS (
  SELECT ec.entity_key, f.group_name, SUM(f.net) AS net,
         ROW_NUMBER() OVER (PARTITION BY ec.entity_key ORDER BY SUM(f.net) DESC) AS rn
  FROM sales_facts f JOIN ec ON ec.customer_code = f.customer_code GROUP BY 1, 2),
pf AS (
  SELECT ec.entity_key,
         MAX(CASE WHEN upper(f.group_name) LIKE 'COMPUT%' OR upper(f.family_name) IN ('NOTEBOOKS','DESKTOPS','MINI PC','ALL-IN-ONE')
                  THEN f.year END) AS last_pc_year,
         SUM(CASE WHEN upper(f.group_name) LIKE 'CONSUM%' THEN f.net ELSE 0 END) / NULLIF(SUM(f.net), 0) AS consumables_share,
         SUM(CASE WHEN upper(f.group_name) LIKE 'SOFTWARE%' THEN f.net ELSE 0 END) / NULLIF(SUM(f.net), 0) AS software_share,
         MAX(CASE WHEN upper(f.group_name) LIKE 'IMPRESS%' AND f.line_kind = 'product' THEN f.year END) AS last_printer_year
  FROM sales_facts f JOIN ec ON ec.customer_code = f.customer_code GROUP BY 1),
core AS (
  SELECT d.customer_code, d.entity_key,
         trim(replace(replace(replace(replace(replace(' ' || d.name_norm || ' ', ' unipessoal ', ' '), ' lda ', ' '),
              ' limitada ', ' '), ' sociedade ', ' '), '  ', ' ')) AS k
  FROM customer_dim d WHERE d.segment <> 'consumidor_final'),
act AS MATERIALIZED (
  SELECT core.k, core.entity_key, MIN(core.customer_code) AS code FROM core JOIN cs USING (customer_code)
  WHERE cs.last_purchase > date((SELECT d FROM asof), '-' || :inactive_days || ' days') AND length(core.k) >= 8 GROUP BY 1, 2),
nl AS (
  SELECT ec.entity_key, MIN(act.code) AS same_name_active_code
  FROM ec JOIN core ON core.customer_code = ec.customer_code JOIN act ON act.k = core.k AND act.entity_key <> ec.entity_key
  GROUP BY 1),
i AS (
  SELECT ec.entity_key, f.item_description, SUM(f.net) AS net,
         ROW_NUMBER() OVER (PARTITION BY ec.entity_key ORDER BY SUM(f.net) DESC) AS rn
  FROM sales_facts f JOIN ec ON ec.customer_code = f.customer_code WHERE f.item_code <> 'ZZ' GROUP BY 1, 2)
SELECT ec.name AS customer, ec.customer_code AS main_code, s.entity_key,
       (SELECT COUNT(*) FROM ec e2 WHERE e2.entity_key = s.entity_key) AS records_same_nif, s.segment,
       ROUND(s.net, 2) AS lifetime_net, ROUND(s.margin, 2) AS lifetime_margin, s.invoices, s.last_purchase,
       CAST(julianday((SELECT d FROM asof)) - julianday(s.last_purchase) AS INTEGER) AS days_since_purchase,
       lc.last_other_contact, COALESCE(lc.last_other_contact > s.last_purchase, 0) AS still_in_touch,
       (SELECT group_concat(group_name || ' ' || CAST(ROUND(net) AS INTEGER), '; ' ORDER BY rn) FROM g WHERE g.entity_key = s.entity_key AND g.rn <= 3) AS top_groups,
       (SELECT group_concat(substr(item_description, 1, 40), '; ' ORDER BY rn) FROM i WHERE i.entity_key = s.entity_key AND i.rn <= 3) AS top_items,
       CASE WHEN pf.last_pc_year <= CAST(substr((SELECT d FROM asof), 1, 4) AS INTEGER) - 3 THEN 'PC replacement (last PC bought ' || pf.last_pc_year || ')'
            WHEN pf.consumables_share >= 0.25 THEN 'consumables reminder (toner/ink)'
            WHEN pf.software_share >= 0.25 THEN 'software update / maintenance contract'
            WHEN pf.last_printer_year <= CAST(substr((SELECT d FROM asof), 1, 4) AS INTEGER) - 4 THEN 'printer replacement (bought ' || pf.last_printer_year || ')'
            WHEN COALESCE(lc.last_other_contact > s.last_purchase, 0) THEN 'convert repair/quote contact into a purchase'
            ELSE 'general reactivation offer' END AS suggested_offer,
       nl.same_name_active_code,
       s.has_email, s.has_mobile, s.has_phone
FROM s JOIN ec ON ec.entity_key = s.entity_key AND ec.rn = 1 LEFT JOIN lc ON lc.entity_key = s.entity_key
LEFT JOIN pf ON pf.entity_key = s.entity_key LEFT JOIN nl ON nl.entity_key = s.entity_key
WHERE :segment = 'all' OR s.segment = :segment
ORDER BY s.net DESC LIMIT :limit
