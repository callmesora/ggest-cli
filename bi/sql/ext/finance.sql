-- Finance domain views: receivables, payables, payments, till, overheads, recurring contracts, VAT, obligations.
-- Depend only on core views (doc_types, customers) and raw gGest tables (+ the _bi_* config tables).
-- Apply with: uv run ggest build-views --file bi/sql/ext/finance.sql
-- Documentation: docs/domains/finance.md
--
-- gGest current-account rule used throughout: Documentos.mov_cc says how a document moves the entity's
-- current account: '3' = debit (invoice: the balance grows), '2' = credit (credit note, receipt, payment),
-- '4' = settled on the spot (FR invoice-receipt, FROC). Open amount = total_documento - Total_liquidado.
-- Year-end carry-forward records (_FCLC/_FCLD, _FFOC/_FFOD, _FCRC/_FCRD "TRANSPORTE DO ANO") are NOT movements.

-- receivable_docs: customer documents that go through the current account (FT, FTGOL, NC, VIAT...: mov_cc 2/3),
-- not cancelled. Amounts gross (VAT included, what the customer pays), signed (credit notes negative).
-- SUM(open_amount) = Clientes.saldo total = totais_clientes running balance.
DROP VIEW IF EXISTS receivable_docs;
CREATE VIEW receivable_docs AS
SELECT v.Codigo || ' ' || v.serie || '/' || v.numero AS doc_id, v.Codigo AS doc_type, v.serie AS series,
       CAST(v.numero AS INTEGER) AS number,
       date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) AS doc_date,
       CAST(substr(v.data_doc,1,4) AS INTEGER) AS year, substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2) AS month,
       CASE WHEN v.data_venc > '19000101' THEN date(substr(v.data_venc,1,4)||'-'||substr(v.data_venc,5,2)||'-'||substr(v.data_venc,7,2))
            ELSE date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) END AS due_date,
       v.entidade_codigo AS customer_code, trim(v.entidade_descricao) AS customer_name,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END AS sign,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * CAST(v.total_documento AS REAL) AS gross,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * CAST(v.Total_liquidado AS REAL) AS settled,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * (CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) AS open_amount,
       CASE WHEN abs(CAST(v.total_documento AS REAL) - CAST(v.Total_liquidado AS REAL)) > 0.005 THEN 1 ELSE 0 END AS is_open
FROM cab_vendas v JOIN Documentos d ON d.codigo = v.Codigo
WHERE v.estado_doc <> '1' AND v.data_doc <> '' AND d.mov_cc IN ('2','3');

-- payable_docs: what the company is invoiced: supplier documents (cab_compras: VFT, FTINC, FTEXC, DEVNC, VNC...)
-- and 'outros credores' documents (Cab_DirCC_Cre: FTOC, FROC, NCOC: overheads, salaries, rents, taxes).
-- Gross (VAT included), signed by mov_cc (credit notes negative), not cancelled.
-- Data-entry fix: an amount typed in the VAT box of a 0%-rate slot with no taxable base (e.g. a salary or a postage
-- fee recorded entirely as "VAT") is NOT VAT: it is excluded from vat and therefore counted in net (same rule as vat_lines).
-- doc_id is NOT unique for creditor documents (FTOC numbers repeat across creditors): join on doc_key
-- (doc_id@party_code), e.g. with payment_allocations.settled_doc_key.
DROP VIEW IF EXISTS payable_docs;
CREATE VIEW payable_docs AS
WITH x AS (
  SELECT 'supplier' AS party_type, c.Codigo, c.serie, c.numero, c.numero2, c.data_doc, c.data_venc, c.entidade_codigo,
         c.entidade_descricao, c.total_documento, CAST(c.Total_iva AS REAL) - (CASE WHEN CAST(c.taxa_iva1 AS REAL) = 0 AND CAST(c.incide_iva1 AS REAL) = 0 THEN CAST(c.Valor_iva1 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva2 AS REAL) = 0 AND CAST(c.incide_iva2 AS REAL) = 0 THEN CAST(c.Valor_iva2 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva3 AS REAL) = 0 AND CAST(c.incide_iva3 AS REAL) = 0 THEN CAST(c.Valor_iva3 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva4 AS REAL) = 0 AND CAST(c.incide_iva4 AS REAL) = 0 THEN CAST(c.Valor_iva4 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva5 AS REAL) = 0 AND CAST(c.incide_iva5 AS REAL) = 0 THEN CAST(c.Valor_iva5 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva6 AS REAL) = 0 AND CAST(c.incide_iva6 AS REAL) = 0 THEN CAST(c.Valor_iva6 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva7 AS REAL) = 0 AND CAST(c.incide_iva7 AS REAL) = 0 THEN CAST(c.Valor_iva7 AS REAL) ELSE 0 END) AS Total_iva,
         c.Total_liquidado, NULL AS descritivo
  FROM cab_compras c WHERE c.estado_doc <> '1' AND c.data_doc <> ''
  UNION ALL
  SELECT 'creditor', c.Codigo, c.serie, c.numero, c.numero2, c.data_doc, c.data_venc, c.entidade_codigo,
         c.entidade_descricao, c.total_documento, CAST(c.Total_iva AS REAL) - (CASE WHEN CAST(c.taxa_iva1 AS REAL) = 0 AND CAST(c.incide_iva1 AS REAL) = 0 THEN CAST(c.Valor_iva1 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva2 AS REAL) = 0 AND CAST(c.incide_iva2 AS REAL) = 0 THEN CAST(c.Valor_iva2 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva3 AS REAL) = 0 AND CAST(c.incide_iva3 AS REAL) = 0 THEN CAST(c.Valor_iva3 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva4 AS REAL) = 0 AND CAST(c.incide_iva4 AS REAL) = 0 THEN CAST(c.Valor_iva4 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva5 AS REAL) = 0 AND CAST(c.incide_iva5 AS REAL) = 0 THEN CAST(c.Valor_iva5 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva6 AS REAL) = 0 AND CAST(c.incide_iva6 AS REAL) = 0 THEN CAST(c.Valor_iva6 AS REAL) ELSE 0 END + CASE WHEN CAST(c.taxa_iva7 AS REAL) = 0 AND CAST(c.incide_iva7 AS REAL) = 0 THEN CAST(c.Valor_iva7 AS REAL) ELSE 0 END) AS Total_iva,
         c.Total_liquidado, c.descritivo
  FROM Cab_DirCC_Cre c WHERE c.estado_doc <> '1' AND c.data_doc <> '' AND c.Codigo NOT LIKE '\_%' ESCAPE '\')
SELECT x.party_type, x.Codigo || ' ' || x.serie || '/' || x.numero AS doc_id,
       x.Codigo || ' ' || x.serie || '/' || x.numero || '@' || x.entidade_codigo AS doc_key, x.Codigo AS doc_type,
       NULLIF(trim(x.numero2),'') AS external_number,
       date(substr(x.data_doc,1,4)||'-'||substr(x.data_doc,5,2)||'-'||substr(x.data_doc,7,2)) AS doc_date,
       CAST(substr(x.data_doc,1,4) AS INTEGER) AS year, substr(x.data_doc,1,4)||'-'||substr(x.data_doc,5,2) AS month,
       CASE WHEN x.data_venc > '19000101' THEN date(substr(x.data_venc,1,4)||'-'||substr(x.data_venc,5,2)||'-'||substr(x.data_venc,7,2))
            ELSE date(substr(x.data_doc,1,4)||'-'||substr(x.data_doc,5,2)||'-'||substr(x.data_doc,7,2)) END AS due_date,
       x.entidade_codigo AS party_code, trim(x.entidade_descricao) AS party_name, NULLIF(trim(x.descritivo),'') AS description,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END AS sign,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * (CAST(x.total_documento AS REAL) - CAST(x.Total_iva AS REAL)) AS net,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * CAST(x.Total_iva AS REAL) AS vat,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * CAST(x.total_documento AS REAL) AS gross,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * CAST(x.Total_liquidado AS REAL) AS settled,
       CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END * (CAST(x.total_documento AS REAL) - CAST(x.Total_liquidado AS REAL)) AS open_amount,
       CASE WHEN d.mov_cc IN ('2','3') AND abs(CAST(x.total_documento AS REAL) - CAST(x.Total_liquidado AS REAL)) > 0.005 THEN 1 ELSE 0 END AS is_open
FROM x JOIN Documentos d ON d.codigo = x.Codigo;

-- expense_docs: overhead documents ('outros credores', FTOC/FROC/NCOC; recorded from the year the company started
-- using them) with the category from the expense rules (ggest.json -> _bi_expense_rules, first match wins) and a
-- P&L line derived from the category name: staff / rent / investment / loans / taxes (shown below the result,
-- not deducted) / opex. Net of VAT (the VAT is deductible), signed.
DROP VIEW IF EXISTS expense_docs;
CREATE VIEW expense_docs AS
WITH e AS (
  SELECT p.*, lower(COALESCE(p.party_name,'')) AS lname, lower(COALESCE(p.description,'')) AS ltxt
  FROM payable_docs p WHERE p.party_type = 'creditor'),
c AS MATERIALIZED (
  SELECT e.*, COALESCE((SELECT r.category FROM _bi_expense_rules r
                        WHERE (r.code IS NULL OR r.code = e.party_code)
                          AND (r.name_like IS NULL OR e.lname LIKE r.name_like)
                          AND (r.text_like IS NULL OR e.ltxt LIKE r.text_like)
                        ORDER BY r.priority LIMIT 1),
                       (SELECT value FROM _bi_config WHERE key = 'default_expense_category'), 'Other') AS category
  FROM e)
SELECT doc_id, doc_type, external_number, doc_date, year, month, due_date, party_code AS creditor_code,
       party_name AS creditor_name, description, category,
       CASE WHEN lower(category) LIKE '%invest%' THEN 'investment'
            WHEN lower(category) LIKE '%emprest%' OR lower(category) LIKE '%empr_stimo%' OR lower(category) LIKE '%loan%' THEN 'loans'
            WHEN lower(category) LIKE '%impost%' OR lower(category) LIKE '%tax%' THEN 'taxes'
            WHEN lower(category) LIKE '%pessoal%' OR lower(category) LIKE '%staff%' OR lower(category) LIKE '%salar%' THEN 'staff'
            WHEN lower(category) LIKE '%renda%' OR lower(category) LIKE '%rent%' THEN 'rent'
            ELSE 'opex' END AS pnl_line,
       net, vat, gross, settled, open_amount, is_open
FROM c;

-- payment_docs: money documents of the current accounts (cab_recpag): receipts from customers (R, RECPT, ACERT)
-- and payments to suppliers (P) and to other creditors (POC). Cancelled receipts excluded. amount is positive;
-- direction says 'in' or 'out'. method = main payment method recorded in the till (Lin_caixa; receipts only,
-- from the year the till module was used; supplier/creditor payments are not in the till: method NULL).
DROP VIEW IF EXISTS payment_docs;
CREATE VIEW payment_docs AS
WITH m AS (
  SELECT Codigo, serie, numero, forma_pagamento AS method,
         ROW_NUMBER() OVER (PARTITION BY Codigo, serie, numero ORDER BY CAST(valor AS REAL) DESC) AS rn
  FROM Lin_caixa WHERE Codigo IN ('R','RECPT','ACERT'))
SELECT c.Codigo || ' ' || c.serie || '/' || c.numero AS doc_id, c.Codigo AS doc_type,
       CASE c.Codigo WHEN 'P' THEN 'supplier' WHEN 'POC' THEN 'creditor' ELSE 'customer' END AS party_type,
       CASE WHEN c.Codigo IN ('P','POC') THEN 'out' ELSE 'in' END AS direction,
       date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS doc_date,
       CAST(substr(c.data_doc,1,4) AS INTEGER) AS year, substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2) AS month,
       c.entidade_codigo AS party_code, trim(c.entidade_descricao) AS party_name,
       CAST(c.total_documento AS REAL) AS amount, CAST(c.Total_iva AS REAL) AS vat_settled,
       m.method, c.cx_sessao AS cash_session
FROM cab_recpag c
LEFT JOIN m ON m.Codigo = c.Codigo AND m.serie = c.serie AND m.numero = c.numero AND m.rn = 1
WHERE c.Codigo IN ('R','RECPT','ACERT','P','POC') AND c.estado_doc <> '1' AND c.data_doc <> '';

-- payment_allocations: which receipt/payment settled which document (lin_recpag), for days-to-pay and for
-- balances at a past date (open at D = gross - allocations dated <= D). Reconciles with Total_liquidado.
-- settled_doc_id uses the same 'TYPE SERIES/NUMBER' format as sales_docs / receivable_docs / payable_docs; for
-- supplier/creditor documents join on settled_doc_key = payable_docs.doc_key (numbers repeat across creditors).
-- Payment numbers can also repeat (rare), hence the join on the entity as well.
DROP VIEW IF EXISTS payment_allocations;
CREATE VIEW payment_allocations AS
SELECT l.Codigo || ' ' || l.serie || '/' || l.numero AS payment_doc_id, l.Codigo AS payment_type,
       date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS payment_date,
       l.entidade_codigo AS party_code,
       l.liquida_codigo AS settled_doc_type,
       l.liquida_codigo || ' ' || l.liquida_serie || '/' || l.liquida_numero AS settled_doc_id,
       l.liquida_codigo || ' ' || l.liquida_serie || '/' || l.liquida_numero || '@' || l.entidade_codigo AS settled_doc_key,
       CASE WHEN l.liquida_data > '19000101' THEN date(substr(l.liquida_data,1,4)||'-'||substr(l.liquida_data,5,2)||'-'||substr(l.liquida_data,7,2)) END AS settled_doc_date,
       CASE WHEN l.liquida_data_venc > '19000101' THEN date(substr(l.liquida_data_venc,1,4)||'-'||substr(l.liquida_data_venc,5,2)||'-'||substr(l.liquida_data_venc,7,2)) END AS settled_due_date,
       CAST(l.valor_liquidado AS REAL) AS amount
FROM lin_recpag l
JOIN cab_recpag c ON c.Codigo = l.Codigo AND c.serie = l.serie AND c.numero = l.numero AND c.entidade_codigo = l.entidade_codigo
WHERE c.estado_doc <> '1' AND l.liquida_codigo <> '' AND c.data_doc <> '';

-- till_movements: every till line (Lin_caixa + cab_caixa; the till module exists only from the year it was
-- adopted) with the payment method and a cash-flow sign: money in (FR/FS counter sales, R receipts, cash entries
-- _CX02, supplier refunds DEVNC) positive, money out (refunds NC/NCP, supplier invoices paid at the till, cash
-- withdrawals _CX03) negative. Opening (_CX01) and closing (_CX99, repeats the totals) are excluded, and so are
-- internal-consumption documents (FRCIN/NCCIR).
DROP VIEW IF EXISTS till_movements;
CREATE VIEW till_movements AS
SELECT date(substr(c.data,1,4)||'-'||substr(c.data,5,2)||'-'||substr(c.data,7,2)) AS move_date,
       substr(c.data,1,4)||'-'||substr(c.data,5,2) AS month, c.cx_sessao AS cash_session, c.posto AS terminal,
       l.Codigo AS doc_type, l.Codigo || ' ' || l.serie || '/' || l.numero AS doc_id, l.entidade AS party_code,
       l.forma_pagamento AS method_code, trim(f.descricao) AS method_name,
       CASE WHEN l.forma_pagamento = 'NUM' THEN 'cash' WHEN l.forma_pagamento IN ('MB','mypos') OR f.tipo_pagamento IN ('MB','CC','CD') THEN 'card'
            WHEN l.forma_pagamento = 'TRB' THEN 'transfer' WHEN l.forma_pagamento IN ('if','eas') THEN 'mb_reference'
            WHEN l.forma_pagamento = 'mbway' THEN 'mbway' WHEN f.tipo_pagamento = 'CHB' THEN 'cheque'
            WHEN l.forma_pagamento = 'ace' THEN 'offset' ELSE 'other' END AS method_group,
       CASE WHEN l.Codigo IN ('NC','NCP','FTEXC','FTINC','VFT','_CX03') THEN -1 ELSE 1 END * CAST(l.valor AS REAL) AS amount
FROM Lin_caixa l
JOIN cab_caixa c ON c.codigo = l.Codigo AND c.numero = l.numero AND c.serie = l.serie AND c.ano = l.ano
LEFT JOIN formas_pagamento f ON f.codigo = l.forma_pagamento
WHERE l.Codigo NOT IN ('_CX01','_CX99','FRCIN','NCCIR');

-- recurring_contracts: subscriptions/retainers ("avenças": hosting, domains, DNS, licences...) per customer
-- (Avencas_Clientes + the Avencas template). amount_per_billing = qty x unit price (net of VAT), billed every
-- period (MENSAL 12x/year, BIMESTRAL 6x, TRIMESTRAL 4x, SEMESTRAL 2x, ANUAL 1x). next_billing = date gGest will
-- propose the next invoice; last_doc_id = last invoice generated ('TYPE SERIES/NUMBER'); end_date 2199 = no end.
DROP VIEW IF EXISTS recurring_contracts;
CREATE VIEW recurring_contracts AS
WITH x AS (
  SELECT ac.*, a.Descricao AS t_desc, a.Periodo AS period, a.Artigo AS t_item,
         CASE upper(trim(a.Periodo)) WHEN 'MENSAL' THEN 12 WHEN 'BIMESTRAL' THEN 6 WHEN 'TRIMESTRAL' THEN 4
              WHEN 'QUADRIMESTRAL' THEN 3 WHEN 'SEMESTRAL' THEN 2 WHEN 'ANUAL' THEN 1 ELSE 1 END AS per_year
  FROM Avencas_Clientes ac LEFT JOIN Avencas a ON a.Codigo = ac.Avenca)
SELECT x.Cliente AS customer_code, k.name AS customer_name, x.Avenca AS contract_code,
       trim(COALESCE(NULLIF(trim(x.descricao_extensa),''), x.t_desc)) AS description,
       upper(trim(x.period)) AS period, x.per_year AS billings_per_year, upper(trim(x.t_item)) AS item_code,
       CAST(x.Quantidade AS REAL) AS qty, CAST(x.Valor AS REAL) AS unit_net,
       CAST(x.Quantidade AS REAL) * CAST(x.Valor AS REAL) AS amount_per_billing,
       CAST(x.Quantidade AS REAL) * CAST(x.Valor AS REAL) * x.per_year AS annual_value,
       CAST(x.Quantidade AS REAL) * CAST(x.Valor AS REAL) * x.per_year / 12.0 AS monthly_value,
       CASE WHEN x.Inativo = '1' THEN 0 ELSE 1 END AS is_active,
       CASE WHEN x.Inicio > '19000101' THEN date(substr(x.Inicio,1,4)||'-'||substr(x.Inicio,5,2)||'-'||substr(x.Inicio,7,2)) END AS start_date,
       CASE WHEN x.Seguinte > '19000101' THEN date(substr(x.Seguinte,1,4)||'-'||substr(x.Seguinte,5,2)||'-'||substr(x.Seguinte,7,2)) END AS next_billing,
       CASE WHEN x.Fim > '19000101' THEN date(substr(x.Fim,1,4)||'-'||substr(x.Fim,5,2)||'-'||substr(x.Fim,7,2)) END AS end_date,
       CASE WHEN x.Ultima > '19000101' THEN date(substr(x.Ultima,1,4)||'-'||substr(x.Ultima,5,2)||'-'||substr(x.Ultima,7,2)) END AS last_billed,
       CASE WHEN x.documento_ultimo GLOB '[A-Z]* [0-9A-Z]*/[0-9]*' THEN trim(x.documento_ultimo) END AS last_doc_id,
       NULLIF(trim(x.Documento),'') AS doc_type_to_issue
FROM x LEFT JOIN customers k ON k.customer_code = x.Cliente;

-- vat_lines: VAT base and VAT per document and rate (the 10 VAT slots of each header), for sales (cab_vendas,
-- fiscal documents, incl. internal ones), supplier purchases (cab_compras) and overheads (Cab_DirCC_Cre).
-- Cancelled excluded; credit notes negative. vat_code joins ivas (rate table: rate, regime, exemption M-code).
-- Data-entry fixes (data_fix): VAT typed on a 0%-rate slot with no base = the whole amount typed in the VAT box
-- (moved to base, VAT 0); VAT on a 0%-rate slot WITH a base = wrong VAT code (rate derived from vat/base).
DROP VIEW IF EXISTS vat_lines;
CREATE VIEW vat_lines AS
WITH RECURSIVE slot(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM slot WHERE n < 7),
a AS (
  SELECT 'sales' AS side, CAST(t.sign AS INTEGER) AS sign, x.Codigo, x.serie, x.numero, x.data_doc, x.entidade_codigo,
         CASE n WHEN 1 THEN cod_iva1 WHEN 2 THEN cod_iva2 WHEN 3 THEN cod_iva3 WHEN 4 THEN cod_iva4 WHEN 5 THEN cod_iva5 WHEN 6 THEN cod_iva6 WHEN 7 THEN cod_iva7 END AS code,
         CASE n WHEN 1 THEN taxa_iva1 WHEN 2 THEN taxa_iva2 WHEN 3 THEN taxa_iva3 WHEN 4 THEN taxa_iva4 WHEN 5 THEN taxa_iva5 WHEN 6 THEN taxa_iva6 WHEN 7 THEN taxa_iva7 END AS rate,
         CASE n WHEN 1 THEN reg_iva1 WHEN 2 THEN reg_iva2 WHEN 3 THEN reg_iva3 WHEN 4 THEN reg_iva4 WHEN 5 THEN reg_iva5 WHEN 6 THEN reg_iva6 WHEN 7 THEN reg_iva7 END AS reg,
         CASE n WHEN 1 THEN incide_iva1 WHEN 2 THEN incide_iva2 WHEN 3 THEN incide_iva3 WHEN 4 THEN incide_iva4 WHEN 5 THEN incide_iva5 WHEN 6 THEN incide_iva6 WHEN 7 THEN incide_iva7 END AS base,
         CASE n WHEN 1 THEN Valor_iva1 WHEN 2 THEN Valor_iva2 WHEN 3 THEN Valor_iva3 WHEN 4 THEN Valor_iva4 WHEN 5 THEN Valor_iva5 WHEN 6 THEN Valor_iva6 WHEN 7 THEN Valor_iva7 END AS vat
  FROM cab_vendas x JOIN doc_types t ON t.doc_type = x.Codigo CROSS JOIN slot
  WHERE x.estado_doc <> '1' AND x.data_doc <> '' AND t.module = 'VND'
  UNION ALL
  SELECT 'purchases' AS side, CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END AS sign, x.Codigo, x.serie, x.numero, x.data_doc, x.entidade_codigo,
         CASE n WHEN 1 THEN cod_iva1 WHEN 2 THEN cod_iva2 WHEN 3 THEN cod_iva3 WHEN 4 THEN cod_iva4 WHEN 5 THEN cod_iva5 WHEN 6 THEN cod_iva6 WHEN 7 THEN cod_iva7 END AS code,
         CASE n WHEN 1 THEN taxa_iva1 WHEN 2 THEN taxa_iva2 WHEN 3 THEN taxa_iva3 WHEN 4 THEN taxa_iva4 WHEN 5 THEN taxa_iva5 WHEN 6 THEN taxa_iva6 WHEN 7 THEN taxa_iva7 END AS rate,
         CASE n WHEN 1 THEN reg_iva1 WHEN 2 THEN reg_iva2 WHEN 3 THEN reg_iva3 WHEN 4 THEN reg_iva4 WHEN 5 THEN reg_iva5 WHEN 6 THEN reg_iva6 WHEN 7 THEN reg_iva7 END AS reg,
         CASE n WHEN 1 THEN incide_iva1 WHEN 2 THEN incide_iva2 WHEN 3 THEN incide_iva3 WHEN 4 THEN incide_iva4 WHEN 5 THEN incide_iva5 WHEN 6 THEN incide_iva6 WHEN 7 THEN incide_iva7 END AS base,
         CASE n WHEN 1 THEN Valor_iva1 WHEN 2 THEN Valor_iva2 WHEN 3 THEN Valor_iva3 WHEN 4 THEN Valor_iva4 WHEN 5 THEN Valor_iva5 WHEN 6 THEN Valor_iva6 WHEN 7 THEN Valor_iva7 END AS vat
  FROM cab_compras x JOIN Documentos d ON d.codigo = x.Codigo CROSS JOIN slot
  WHERE x.estado_doc <> '1' AND x.data_doc <> ''
  UNION ALL
  SELECT 'overheads' AS side, CASE WHEN d.mov_cc = '2' THEN -1 ELSE 1 END AS sign, x.Codigo, x.serie, x.numero, x.data_doc, x.entidade_codigo,
         CASE n WHEN 1 THEN cod_iva1 WHEN 2 THEN cod_iva2 WHEN 3 THEN cod_iva3 WHEN 4 THEN cod_iva4 WHEN 5 THEN cod_iva5 WHEN 6 THEN cod_iva6 WHEN 7 THEN cod_iva7 END AS code,
         CASE n WHEN 1 THEN taxa_iva1 WHEN 2 THEN taxa_iva2 WHEN 3 THEN taxa_iva3 WHEN 4 THEN taxa_iva4 WHEN 5 THEN taxa_iva5 WHEN 6 THEN taxa_iva6 WHEN 7 THEN taxa_iva7 END AS rate,
         CASE n WHEN 1 THEN reg_iva1 WHEN 2 THEN reg_iva2 WHEN 3 THEN reg_iva3 WHEN 4 THEN reg_iva4 WHEN 5 THEN reg_iva5 WHEN 6 THEN reg_iva6 WHEN 7 THEN reg_iva7 END AS reg,
         CASE n WHEN 1 THEN incide_iva1 WHEN 2 THEN incide_iva2 WHEN 3 THEN incide_iva3 WHEN 4 THEN incide_iva4 WHEN 5 THEN incide_iva5 WHEN 6 THEN incide_iva6 WHEN 7 THEN incide_iva7 END AS base,
         CASE n WHEN 1 THEN Valor_iva1 WHEN 2 THEN Valor_iva2 WHEN 3 THEN Valor_iva3 WHEN 4 THEN Valor_iva4 WHEN 5 THEN Valor_iva5 WHEN 6 THEN Valor_iva6 WHEN 7 THEN Valor_iva7 END AS vat
  FROM Cab_DirCC_Cre x JOIN Documentos d ON d.codigo = x.Codigo CROSS JOIN slot
  WHERE x.estado_doc <> '1' AND x.data_doc <> '' AND x.Codigo IN ('FTOC','FROC','NCOC'))
SELECT side, Codigo || ' ' || serie || '/' || numero AS doc_id, Codigo AS doc_type,
       date(substr(data_doc,1,4)||'-'||substr(data_doc,5,2)||'-'||substr(data_doc,7,2)) AS doc_date,
       CAST(substr(data_doc,1,4) AS INTEGER) AS year, substr(data_doc,1,4)||'-'||substr(data_doc,5,2) AS month,
       substr(data_doc,1,4)||'-Q'||((CAST(substr(data_doc,5,2) AS INTEGER)+2)/3) AS quarter,
       entidade_codigo AS party_code, NULLIF(trim(code),'') AS vat_code,
       CASE WHEN CAST(rate AS REAL) = 0 AND CAST(vat AS REAL) <> 0 AND CAST(base AS REAL) <> 0
            THEN ROUND(100.0 * CAST(vat AS REAL) / CAST(base AS REAL), 0) ELSE CAST(rate AS REAL) END AS vat_rate,
       NULLIF(trim(reg),'') AS vat_regime,
       sign * CASE WHEN CAST(rate AS REAL) = 0 AND CAST(base AS REAL) = 0 THEN CAST(vat AS REAL) ELSE CAST(base AS REAL) END AS base,
       sign * CASE WHEN CAST(rate AS REAL) = 0 AND CAST(base AS REAL) = 0 THEN 0 ELSE CAST(vat AS REAL) END AS vat,
       CASE WHEN CAST(rate AS REAL) = 0 AND CAST(vat AS REAL) <> 0 THEN
            CASE WHEN CAST(base AS REAL) = 0 THEN 'amount_in_vat_box_moved_to_base' ELSE 'rate_derived_from_amounts' END END AS data_fix
FROM a
WHERE CAST(base AS REAL) <> 0 OR CAST(vat AS REAL) <> 0;

-- tax_obligations: the company's recurring obligations calendar (gGest "Expediente > Obrigações":
-- expediente_obrigacoes), one row per obligation and month in which it applies, with the due day and the
-- number of alert days. Free text: what to send/pay (SAF-T, VAT, social security, payroll, maps for the accountant).
DROP VIEW IF EXISTS tax_obligations;
CREATE VIEW tax_obligations AS
WITH RECURSIVE m(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM m WHERE n < 12),
x AS (
  SELECT o.Codigo AS obligation_code, trim(o.Descricao) AS description, NULLIF(trim(o.Observacao),'') AS note, m.n AS month,
         CASE m.n WHEN 1 THEN o.Mes1 WHEN 2 THEN o.Mes2 WHEN 3 THEN o.Mes3 WHEN 4 THEN o.Mes4 WHEN 5 THEN o.Mes5
              WHEN 6 THEN o.Mes6 WHEN 7 THEN o.Mes7 WHEN 8 THEN o.Mes8 WHEN 9 THEN o.Mes9 WHEN 10 THEN o.Mes10
              WHEN 11 THEN o.Mes11 ELSE o.Mes12 END AS active,
         CASE m.n WHEN 1 THEN o.Mes1_DiaFim WHEN 2 THEN o.Mes2_DiaFim WHEN 3 THEN o.Mes3_DiaFim WHEN 4 THEN o.Mes4_DiaFim
              WHEN 5 THEN o.Mes5_DiaFim WHEN 6 THEN o.Mes6_DiaFim WHEN 7 THEN o.Mes7_DiaFim WHEN 8 THEN o.Mes8_DiaFim
              WHEN 9 THEN o.Mes9_DiaFim WHEN 10 THEN o.Mes10_DiaFim WHEN 11 THEN o.Mes11_DiaFim ELSE o.Mes12_DiaFim END AS due_day,
         CASE m.n WHEN 1 THEN o.Mes1_DiasAlerta WHEN 2 THEN o.Mes2_DiasAlerta WHEN 3 THEN o.Mes3_DiasAlerta WHEN 4 THEN o.Mes4_DiasAlerta
              WHEN 5 THEN o.Mes5_DiasAlerta WHEN 6 THEN o.Mes6_DiasAlerta WHEN 7 THEN o.Mes7_DiasAlerta WHEN 8 THEN o.Mes8_DiasAlerta
              WHEN 9 THEN o.Mes9_DiasAlerta WHEN 10 THEN o.Mes10_DiasAlerta WHEN 11 THEN o.Mes11_DiasAlerta ELSE o.Mes12_DiasAlerta END AS alert_days
  FROM expediente_obrigacoes o CROSS JOIN m)
SELECT obligation_code, description, note, month, CAST(due_day AS INTEGER) AS due_day, CAST(alert_days AS INTEGER) AS alert_days
FROM x WHERE active = '1' AND CAST(due_day AS INTEGER) > 0;

-- mb_references: Multibanco payment references generated for sales documents (mov_refMB, Ifthenpay/EasyPay style
-- entity + reference + amount, printed on the invoice). status 'pending' = still open, 'closed' = the document was
-- settled (by ANY means: the reference is closed when the receipt is issued, so closed does not mean paid by
-- reference; use the till method 'if'/'eas' for that).
DROP VIEW IF EXISTS mb_references;
CREATE VIEW mb_references AS
SELECT r.doc_codigo || ' ' || r.doc_serie || '/' || r.doc_numero AS doc_id, r.doc_codigo AS doc_type,
       r.doc_entidade AS customer_code, trim(r.entidade_mb) AS mb_entity, trim(r.referencia) AS mb_reference,
       CAST(r.valor_pagar AS REAL) AS amount, CAST(r.valor_pago AS REAL) AS amount_closed,
       CASE r.estado WHEN '2' THEN 'closed' WHEN '1' THEN 'pending' ELSE r.estado END AS status,
       date(substr(r.data_geracao,1,4)||'-'||substr(r.data_geracao,5,2)||'-'||substr(r.data_geracao,7,2)) AS generated_on,
       CASE WHEN r.data_pagamento > '19000101' THEN date(substr(r.data_pagamento,1,4)||'-'||substr(r.data_pagamento,5,2)||'-'||substr(r.data_pagamento,7,2)) END AS closed_on
FROM mov_refMB r WHERE r.doc_numero <> '';
