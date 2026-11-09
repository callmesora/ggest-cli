-- Customers & CRM domain views (depend only on core views and raw gGest tables).
-- Apply with: py -m bi build-views --file bi/sql/ext/customers.sql
-- Documentation: docs/domains/customers.md

-- customer_dim: one row per customer record (Clientes) with the derived segment, legal-entity key, data-quality
-- flags and CRM attributes. Single source of the segment rules used by every bi/queries/customers/* query.
-- No contact values are exposed here, only presence flags.
DROP VIEW IF EXISTS customer_dim;
CREATE VIEW customer_dim AS
WITH c0 AS MATERIALIZED (
  SELECT c.customer_code, c.name, c.nif, c.customer_group, c.is_walk_in, c.is_inactive, c.opened_on, c.postal_code,
         ' ' || lower(replace(replace(replace(c.name,'.',' '),',',' '),'-',' ')) || ' ' AS n,
         upper(replace(replace(replace(COALESCE(c.nif,''),' ',''),'PT',''),'.','')) AS nf
  FROM customers c),
seg AS (
  SELECT c0.*,
   CASE
    WHEN is_walk_in = 1 THEN 'consumidor_final'
    WHEN (nf LIKE '6%' AND length(nf)=9) OR customer_group = '1' THEN 'publico'
    WHEN n LIKE '% lda %' OR n LIKE '% limitada %' OR n LIKE '% unipessoal %' OR n LIKE '% s a %' OR n LIKE '% sgps %'
      THEN 'empresa'
    WHEN n LIKE '% associação %' OR n LIKE '% associacao %' OR n LIKE '% clube %' OR n LIKE '% club %'
      OR n LIKE '% filarmónica %' OR n LIKE '% filarmonica %' OR n LIKE '% misericórdia %' OR n LIKE '% misericordia %'
      OR n LIKE '% paróquia %' OR n LIKE '% paroquia %' OR n LIKE '% fábrica da igreja %' OR n LIKE '% casa do povo %'
      OR n LIKE '% fundação %' OR n LIKE '% fundacao %' OR n LIKE '% bombeiros %' OR n LIKE '% sindicato %'
      OR n LIKE '% irmandade %' OR n LIKE '% centro social %' OR n LIKE '% cooperativa %' OR n LIKE '% escuteiros %'
      OR n LIKE '% agrupamento %' OR n LIKE '% grupo desportivo %' OR n LIKE '% ipss %'
      OR n LIKE '% lar %' OR n LIKE '% casa de infância %' OR n LIKE '% creche %' OR n LIKE '% santa casa %'
      THEN 'associativo'
    WHEN n LIKE '% câmara municipal %' OR n LIKE '% camara municipal %' OR n LIKE '% município %' OR n LIKE '% municipio %'
      OR n LIKE '% junta de freguesia %' OR n LIKE '% freguesia %'
      OR (n LIKE '% escola %' AND n NOT LIKE '% condução %' AND n NOT LIKE '% conducao %' AND n NOT LIKE '% lda %')
      OR n LIKE '% agrupamento de escolas %' OR n LIKE '% secretaria regional %' OR n LIKE '% direção regional %'
      OR n LIKE '% direcção regional %' OR n LIKE '% direccao regional %' OR n LIKE '% direcao regional %'
      OR n LIKE '% governo regional %' OR n LIKE '% assembleia legislativa %' OR n LIKE '% universidade %'
      OR n LIKE '% hospital %' OR n LIKE '% unidade de saúde %' OR n LIKE '% centro de saúde %'
      OR n LIKE '% tribunal %' OR n LIKE '% gnr %' OR n LIKE '% guarda nacional %' OR n LIKE '% psp %'
      OR n LIKE '% capitania %' OR n LIKE '% entidade reguladora %' OR n LIKE '% conservatória %' OR n LIKE '% conservatoria %'
      OR n LIKE '% serviço de desenvolvimento agrário %' OR n LIKE '% inspecção regional %' OR n LIKE '% inspeção regional %'
      OR (n LIKE '% instituto %' AND n NOT LIKE '% s l %' AND n NOT LIKE '% lda %')
      THEN 'publico'
    WHEN customer_group = '2' OR nf GLOB '[589]*' AND nf <> '999999990'
      OR (nf GLOB '7[1-9]*' AND nf NOT GLOB '7[45]*') OR (nf GLOB '[A-Z][A-Z]*' AND nf NOT LIKE 'CONS%')
      OR n LIKE '% lda %' OR n LIKE '% limitada %' OR n LIKE '% unipessoal %' OR n LIKE '% s a %'
      OR n LIKE '% sgps %' OR n LIKE '% crl %' OR n LIKE '% hotel %' OR n LIKE '% restaurante %' OR n LIKE '% sociedade %'
      OR n LIKE '% snack %' OR n LIKE '% & %' OR n LIKE '% s l %'
      THEN 'empresa'
    ELSE 'particular'
   END AS segment,
         CASE WHEN length(nf) = 9 AND nf NOT GLOB '*[^0-9]*' THEN
           (9*substr(nf,1,1) + 8*substr(nf,2,1) + 7*substr(nf,3,1) + 6*substr(nf,4,1) + 5*substr(nf,5,1)
            + 4*substr(nf,6,1) + 3*substr(nf,7,1) + 2*substr(nf,8,1)) % 11 END AS r
  FROM c0),
contracts AS (
  SELECT Cliente AS customer_code, SUM(COALESCE(Inativo,'0') <> '1') AS active_contracts, COUNT(*) AS contracts
  FROM Avencas_Clientes GROUP BY 1),
addr AS (SELECT Cliente AS customer_code, COUNT(*) AS extra_addresses FROM Moradas_Clientes GROUP BY 1)
SELECT s.customer_code, s.name, s.nif,
       NULLIF(s.nf, '') AS nif_clean,
       CASE WHEN s.nf = '' THEN 'missing'
            WHEN s.nf = '999999990' OR s.nf LIKE 'CONS%' THEN 'final_consumer'
            WHEN length(s.nf) = 9 AND s.nf NOT GLOB '*[^0-9]*' THEN
              CASE WHEN s.nf GLOB '[0]*' OR s.nf GLOB '4*' AND s.nf NOT GLOB '45*' THEN 'invalid'
                   WHEN (CASE WHEN s.r < 2 THEN 0 ELSE 11 - s.r END) = CAST(substr(s.nf,9,1) AS INTEGER) THEN 'valid'
                   ELSE 'invalid' END
            WHEN s.nf GLOB '[A-Z][A-Z]*' THEN 'foreign'
            ELSE 'invalid' END AS nif_status,
       CASE WHEN length(s.nf) = 9 AND s.nf NOT GLOB '*[^0-9]*' AND s.nf <> '999999990' THEN 'NIF ' || s.nf
            ELSE 'COD ' || s.customer_code END AS entity_key,
       s.segment, s.customer_group, g.descricao AS group_name, s.is_walk_in, s.is_inactive,
       trim(s.n) AS name_norm,
       NULLIF(trim(r.espaco_fiscal), '') AS fiscal_space,           -- PTA Azores, PTC mainland, PTM Madeira, else foreign/blank
       upper(NULLIF(trim(r.prefixo), '')) AS country_prefix,
       -- contact completeness (flags only; values stay in Clientes)
       (COALESCE(r.mail1,'')||' '||COALESCE(r.mail2,'')||' '||COALESCE(r.mail3,'')||' '||COALESCE(r.mail4,'')) LIKE '%_@_%._%' AS has_email,
       replace(replace(replace(COALESCE(r.telemovel1,'')||' '||COALESCE(r.telemovel2,'')||' '||COALESCE(r.telefone1,'')||' '||
               COALESCE(r.telefone2,'')||' '||COALESCE(r.telemovel3,'')||' '||COALESCE(r.telemovel4,''),' ',''),'.',''),'-','')
         GLOB '*9[1-6][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*' AS has_mobile,
       replace(replace(replace(COALESCE(r.telemovel1,'')||' '||COALESCE(r.telemovel2,'')||' '||COALESCE(r.telefone1,'')||' '||
               COALESCE(r.telefone2,'')||' '||COALESCE(r.telefone3,'')||' '||COALESCE(r.telefone4,'')||' '||COALESCE(r.telemovel3,'')||' '||
               COALESCE(r.telemovel4,''),' ',''),'.',''),'-','')
         GLOB '*[29][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*' AS has_phone,
       (trim(COALESCE(r.contacto1,'')) <> '') AS has_contact_person,
       (replace(trim(COALESCE(s.postal_code,'')),' ','-') GLOB '[1-9][0-9][0-9][0-9]-[0-9][0-9][0-9]*') AS has_full_postal_code,
       (trim(COALESCE(r.morada,'')) <> '' AND lower(trim(r.morada)) NOT IN ('horta','faial','.','-')) AS has_street_address,
       -- commercial / fiscal attributes
       COALESCE(r.administracao_publica,'0') = '1' AS is_public_administration,
       COALESCE(r.enviar_faturacao_eletronica,'0') NOT IN ('0','') AS sends_e_invoices,
       NULLIF(NULLIF(r.iva_isencao,'0'),'') AS vat_exemption_code,
       r.prazo_pagamento AS payment_terms_code,
       CAST(COALESCE(NULLIF(r.saldo,''),'0') AS REAL) AS balance_gross,     -- Clientes.saldo, VAT included (finance owns receivables)
       (COALESCE(r.obs_alerta,'0') = '1' AND trim(COALESCE(r.obs,'')) <> '') AS has_alert_note,  -- note shown as a pop-up when the record is used
       (trim(COALESCE(r.obs,'')) <> '') AS has_notes,
       COALESCE(ct.active_contracts, 0) AS active_contracts, COALESCE(ct.contracts, 0) AS contracts,
       COALESCE(ad.extra_addresses, 0) AS extra_addresses,
       s.opened_on,                                                  -- Clientes.data_abertura: filled until early 2020
       CASE WHEN r.inserido_data > '19000101' THEN date(substr(r.inserido_data,1,4)||'-'||substr(r.inserido_data,5,2)||'-'||substr(r.inserido_data,7,2)) END AS created_on,  -- insert stamp: reliable from 2020-03 (earlier records carry the migration date)
       COALESCE(s.opened_on, CASE WHEN r.inserido_data > '19000101' THEN date(substr(r.inserido_data,1,4)||'-'||substr(r.inserido_data,5,2)||'-'||substr(r.inserido_data,7,2)) END) AS record_opened_on,
       r.inserido_util AS created_by_user,
       CASE WHEN r.alterado_data > '19000101' THEN date(substr(r.alterado_data,1,4)||'-'||substr(r.alterado_data,5,2)||'-'||substr(r.alterado_data,7,2)) END AS modified_on
FROM seg s
JOIN Clientes r ON r.Codigo = s.customer_code
LEFT JOIN Grupos_Entidades g ON g.codigo = s.customer_group
LEFT JOIN contracts ct ON ct.customer_code = s.customer_code
LEFT JOIN addr ad ON ad.customer_code = s.customer_code;

-- customer_activity: one row per customer record with every kind of interaction (purchases, credit notes, quotes,
-- repairs, agenda appointments) and the last contact date. as_of = last document date in the data.
DROP VIEW IF EXISTS customer_activity;
CREATE VIEW customer_activity AS
WITH ra AS MATERIALIZED (   -- raw Cab_Assistec (same rows as the repairs view, much faster to aggregate)
  SELECT entidade_codigo AS customer_code, upper(Estado_Codigo) AS status_code,
         date(substr(data_doc,1,4)||'-'||substr(data_doc,5,2)||'-'||substr(data_doc,7,2)) AS opened_on
  FROM Cab_Assistec WHERE data_doc <> ''),
asof AS MATERIALIZED (SELECT max((SELECT MAX(doc_date) FROM sales_facts), (SELECT MAX(opened_on) FROM ra)) AS d),
s AS (
  SELECT customer_code, MIN(doc_date) AS first_purchase, MAX(doc_date) AS last_purchase,
         COUNT(DISTINCT CASE WHEN doc_class = 'invoice' THEN doc_id END) AS invoices,
         COUNT(DISTINCT CASE WHEN doc_class = 'credit_note' THEN doc_id END) AS credit_notes,
         COUNT(DISTINCT year) AS active_years,
         SUM(net) AS net_lifetime, SUM(margin) AS margin_lifetime,
         SUM(CASE WHEN doc_date > date((SELECT d FROM asof), '-365 days') THEN net ELSE 0 END) AS net_last_365d,
         SUM(CASE WHEN line_kind = 'service' THEN net ELSE 0 END) AS services_net_lifetime
  FROM sales_facts GROUP BY 1),
q AS (
  SELECT entidade_codigo AS customer_code, COUNT(*) AS quotes,
         MAX(date(substr(data_doc,1,4)||'-'||substr(data_doc,5,2)||'-'||substr(data_doc,7,2))) AS last_quote
  FROM cab_outros WHERE Codigo = 'ORC' AND estado_doc <> '1' AND data_doc > '19000101' GROUP BY 1),
r AS (
  SELECT customer_code, COUNT(*) AS repairs, MIN(opened_on) AS first_repair, MAX(opened_on) AS last_repair,
         SUM(status_code <> 'FEC' AND opened_on > date((SELECT d FROM asof), '-365 days')) AS open_repairs
  FROM ra GROUP BY 1),
a AS (
  SELECT entidade_codigo AS customer_code, COUNT(*) AS appointments,
         MAX(date(substr(data_ini,1,4)||'-'||substr(data_ini,5,2)||'-'||substr(data_ini,7,2))) AS last_appointment
  FROM Agenda WHERE lower(entidade_tipo) = 'cliente' AND COALESCE(entidade_codigo,'0') <> '0' GROUP BY 1)
SELECT c.customer_code, c.name,
       s.first_purchase, s.last_purchase, COALESCE(s.invoices,0) AS invoices, COALESCE(s.credit_notes,0) AS credit_notes,
       COALESCE(s.active_years,0) AS active_years,
       ROUND(COALESCE(s.net_lifetime,0),2) AS net_lifetime, ROUND(COALESCE(s.margin_lifetime,0),2) AS margin_lifetime,
       ROUND(COALESCE(s.net_last_365d,0),2) AS net_last_365d, ROUND(COALESCE(s.services_net_lifetime,0),2) AS services_net_lifetime,
       COALESCE(q.quotes,0) AS quotes, q.last_quote,
       COALESCE(r.repairs,0) AS repairs, r.first_repair, r.last_repair, COALESCE(r.open_repairs,0) AS open_repairs,
       COALESCE(a.appointments,0) AS appointments, a.last_appointment,
       NULLIF(max(COALESCE(s.last_purchase,''), COALESCE(q.last_quote,''), COALESCE(r.last_repair,''),
                  COALESCE(CASE WHEN a.last_appointment <= (SELECT d FROM asof) THEN a.last_appointment END,'')), '') AS last_contact,
       CAST(julianday((SELECT d FROM asof)) - julianday(NULLIF(max(COALESCE(s.last_purchase,''), COALESCE(q.last_quote,''),
                  COALESCE(r.last_repair,''), COALESCE(CASE WHEN a.last_appointment <= (SELECT d FROM asof) THEN a.last_appointment END,'')), ''))
            AS INTEGER) AS days_since_contact,
       CASE WHEN s.customer_code IS NOT NULL AND r.customer_code IS NOT NULL THEN 'buys_and_repairs'
            WHEN s.customer_code IS NOT NULL THEN 'buys_only'
            WHEN r.customer_code IS NOT NULL THEN 'repairs_only'
            WHEN q.customer_code IS NOT NULL THEN 'quotes_only'
            ELSE 'no_activity' END AS relationship,
       (SELECT d FROM asof) AS as_of
FROM customers c
LEFT JOIN s ON s.customer_code = c.customer_code
LEFT JOIN q ON q.customer_code = c.customer_code
LEFT JOIN r ON r.customer_code = c.customer_code
LEFT JOIN a ON a.customer_code = c.customer_code;

-- customer_appointments: gGest agenda (Agenda) tasks/appointments, linked to a customer when entidade_tipo = 'cliente'.
-- Contact columns (telemovel, mail) and the free-text details are left out; the title is shown only for entries linked to an entity.
DROP VIEW IF EXISTS customer_appointments;
CREATE VIEW customer_appointments AS
SELECT CAST(a.TarefaID AS INTEGER) AS task_id,
       datetime(substr(a.data_ini,1,4)||'-'||substr(a.data_ini,5,2)||'-'||substr(a.data_ini,7,2)||' '||substr(a.data_ini,9,2)||':'||substr(a.data_ini,11,2)) AS starts_at,
       datetime(substr(a.data_fim,1,4)||'-'||substr(a.data_fim,5,2)||'-'||substr(a.data_fim,7,2)||' '||substr(a.data_fim,9,2)||':'||substr(a.data_fim,11,2)) AS ends_at,
       COALESCE(a.dia_inteiro,'0') = '1' AS all_day,
       CASE WHEN COALESCE(a.entidade_tipo,'') <> '' THEN trim(a.Titulo) END AS title,   -- untyped entries are often private notes: hidden
       a.estado AS status_code, e.descricao AS status,
       NULLIF(a.tipo,'') AS task_type_code, t.descricao AS task_type, a.Recurso AS resource_code,
       NULLIF(lower(a.entidade_tipo),'') AS entity_type,
       CASE WHEN lower(a.entidade_tipo) = 'cliente' AND COALESCE(a.entidade_codigo,'0') <> '0' THEN a.entidade_codigo END AS customer_code,
       NULLIF(trim(a.entidade_nome),'') AS entity_name, NULLIF(trim(a.localizacao),'') AS location,
       NULLIF(a.eventID,'') IS NOT NULL AS synced_to_calendar,
       a.inserido_util AS created_by_user
FROM Agenda a
LEFT JOIN Agenda_Estados e ON e.Codigo = a.estado
LEFT JOIN Agenda_Tipo_Tarefas t ON t.Codigo = a.tipo;
