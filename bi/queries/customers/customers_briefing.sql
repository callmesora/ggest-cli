-- name: customers_briefing
-- description: Briefing card for one customer before a call/visit. customer = customer code, NIF or part of the name (up to `limit` matching records). One row per record: segment, gGest group, NIF status, entity_key and how many records share the NIF, contact-channel flags (has_email/has_mobile/has_phone, never the values), lifetime and last-365-days net sales and margin, first/last purchase, invoices, quotes and last quote, repairs, open repairs (not closed, opened in the last year), last repair, last contact and days since, relationship type, open balance (VAT incl., unpaid sales documents, same rule as finance_receivables_open) and oldest open document, active avenca contracts (annual net value = quantity x value x billings per year, items, next billing yyyymmdd), has_alert_note + alert_note_chars (Clientes.obs shown as a pop-up when obs_alerta = 1); the note text itself (alert_note) is returned only with show_alert_note = 1, because it is free text that can hold serials, personal data or passwords: open it only when the user asks. Repair counts here are per customer record, all time. largest_invoice_net / largest_invoice_share_pct show whether one project dominates the lifetime total. Next steps: customers_history_by_year, customers_timeline, customers_devices, customers_purchase_mix.
-- params: customer=, show_alert_note=0, limit=5
WITH m AS (
  SELECT d.* FROM customer_dim d
  WHERE :customer <> '' AND (d.customer_code = :customer OR d.nif_clean = upper(replace(:customer, ' ', ''))
         OR lower(d.name) LIKE '%' || lower(trim(:customer)) || '%')
  ORDER BY (d.customer_code = :customer) DESC, d.is_inactive, d.name LIMIT :limit),
ob AS (
  SELECT v.entidade_codigo AS customer_code, COUNT(*) AS open_docs,
         SUM(CASE WHEN v.Codigo IN ('NC','NCP','NCCIR') THEN -1 ELSE 1 END
             * (CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL))) AS open_balance,
         MIN(date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2))) AS oldest_open_doc
  FROM cab_vendas v
  WHERE v.entidade_codigo IN (SELECT customer_code FROM m) AND v.estado_doc <> '1' AND v.data_doc <> ''
    AND abs(CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) > 0.005
  GROUP BY 1),
av AS (
  SELECT ac.Cliente AS customer_code,
         ROUND(SUM(CAST(ac.Quantidade AS REAL) * CAST(ac.Valor AS REAL)
                   * CASE upper(a.Periodo) WHEN 'MENSAL' THEN 12 WHEN 'TRIMESTRAL' THEN 4 WHEN 'SEMESTRAL' THEN 2 ELSE 1 END), 2) AS contracts_annual_net,
         group_concat(DISTINCT lower(a.Artigo)) AS contract_items, MIN(ac.Seguinte) AS next_contract_billing
  FROM Avencas_Clientes ac LEFT JOIN Avencas a ON a.Codigo = ac.Avenca
  WHERE COALESCE(ac.Inativo,'0') <> '1' AND ac.Cliente IN (SELECT customer_code FROM m) GROUP BY 1),
li AS (SELECT customer_code, ROUND(MAX(net), 2) AS largest_invoice_net FROM sales_docs
       WHERE customer_code IN (SELECT customer_code FROM m) AND is_cancelled = 0 AND is_internal = 0 GROUP BY 1),
ek AS (SELECT entity_key, COUNT(*) AS records_same_entity FROM customer_dim
       WHERE entity_key IN (SELECT entity_key FROM m) GROUP BY 1)
SELECT m.customer_code, m.name, m.segment, m.group_name, m.nif_status, m.entity_key, ek.records_same_entity,
       m.is_inactive, m.has_email, m.has_mobile, m.has_phone, m.has_contact_person, m.sends_e_invoices,
       a.relationship, a.net_lifetime, a.margin_lifetime,
       ROUND(100.0 * a.margin_lifetime / NULLIF(a.net_lifetime, 0), 1) AS margin_pct,
       a.net_last_365d, a.first_purchase, a.last_purchase, a.invoices, a.credit_notes, a.active_years,
       a.services_net_lifetime, a.quotes, a.last_quote, a.repairs AS repairs_all_time_record, a.open_repairs, a.last_repair,
       a.appointments, a.last_appointment, a.last_contact, a.days_since_contact,
       ROUND(COALESCE(ob.open_balance, 0), 2) AS open_balance_gross, COALESCE(ob.open_docs, 0) AS open_docs, ob.oldest_open_doc,
       m.active_contracts, av.contracts_annual_net, av.contract_items, av.next_contract_billing, m.created_on, m.payment_terms_code, m.vat_exemption_code,
       li.largest_invoice_net, ROUND(100.0 * li.largest_invoice_net / NULLIF(a.net_lifetime, 0), 1) AS largest_invoice_share_pct,
       m.has_alert_note, CASE WHEN m.has_alert_note THEN length(trim(c.obs)) END AS alert_note_chars,
       CASE WHEN m.has_alert_note AND :show_alert_note = 1 THEN substr(trim(c.obs), 1, 300) END AS alert_note
FROM m JOIN customer_activity a USING (customer_code)
LEFT JOIN ob USING (customer_code) LEFT JOIN av USING (customer_code) LEFT JOIN ek USING (entity_key) LEFT JOIN li USING (customer_code)
LEFT JOIN Clientes c ON c.Codigo = m.customer_code
ORDER BY (m.customer_code = :customer) DESC, a.net_lifetime DESC
