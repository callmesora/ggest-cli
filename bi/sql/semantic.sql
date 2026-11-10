-- Inforbyte business layer over the raw gGest (HFSQL) tables.
-- Raw tables keep every value as TEXT exactly as exported; these views give clean names, real numbers
-- and ISO dates, and apply the business rules once:
--   * cancelled documents (estado_doc = 1) are excluded from sales figures
--   * credit notes count negative (sign = -1)
--   * internal consumption / sponsorship documents are flagged (is_internal) so they can be left out
--   * amounts are NET of VAT unless the column name says gross / vat
-- Recreate with: py -m bi build-views   (idempotent)

CREATE INDEX IF NOT EXISTS ix_lin_vendas_doc ON lin_vendas(Codigo, serie, numero);
CREATE INDEX IF NOT EXISTS ix_artigos_codigo ON Artigos(Codigo);
CREATE INDEX IF NOT EXISTS ix_clientes_codigo ON Clientes(Codigo);
CREATE INDEX IF NOT EXISTS ix_cab_assistec_ent ON Cab_Assistec(entidade_codigo);
CREATE INDEX IF NOT EXISTS ix_intervencao_key ON assTec_intervencao_tecnica(codigo, serie, numero, ano);

DROP VIEW IF EXISTS doc_types;
CREATE VIEW doc_types AS
SELECT codigo AS doc_type, descricao AS description, tipo AS module, invoicetype AS fiscal_type,
       CASE WHEN invoicetype IN ('FT','FR','FS') THEN 'invoice'
            WHEN invoicetype = 'NC' THEN 'credit_note'
            ELSE 'other' END AS doc_class,
       CASE WHEN invoicetype = 'NC' THEN -1 WHEN invoicetype IN ('FT','FR','FS') THEN 1 ELSE 0 END AS sign,
       -- internal (not trading) document types: listed in the config, or described as internal consumption /
       -- sponsorship (patterns in the config; see bi/config.default.json)
       CASE WHEN codigo IN (SELECT value FROM _bi_config WHERE key = 'internal_doc_types')
              OR EXISTS (SELECT 1 FROM _bi_config c WHERE c.key = 'internal_doc_name_like' AND lower(descricao) LIKE c.value)
            THEN 1 ELSE 0 END AS is_internal
FROM Documentos;

-- One row per sales document (invoice / credit note) ---------------------------------------------
DROP VIEW IF EXISTS sales_docs;
CREATE VIEW sales_docs AS
SELECT v.Codigo || ' ' || v.serie || '/' || v.numero AS doc_id,
       v.Codigo AS doc_type, dt.description AS doc_type_name, dt.doc_class, dt.sign,
       CASE WHEN dt.is_internal = 1
              OR EXISTS (SELECT 1 FROM _bi_config c WHERE c.key = 'excluded_series_prefixes' AND v.serie LIKE c.value || '%')
            THEN 1 ELSE 0 END AS is_internal,  -- excluded series from the config (e.g. sale of a company vehicle)
       v.serie AS series, CAST(v.numero AS INTEGER) AS number,
       date(substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) AS doc_date,
       CAST(substr(v.data_doc,1,4) AS INTEGER) AS year,
       substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2) AS month,
       substr(v.data_doc,1,4)||'-Q'||((CAST(substr(v.data_doc,5,2) AS INTEGER)+2)/3) AS quarter,
       CAST(strftime('%w', substr(v.data_doc,1,4)||'-'||substr(v.data_doc,5,2)||'-'||substr(v.data_doc,7,2)) AS INTEGER) AS weekday,
       CAST(substr(printf('%06d', CAST(v.hora_doc AS INTEGER)),1,2) AS INTEGER) AS hour,
       v.entidade_codigo AS customer_code, trim(v.entidade_descricao) AS customer_name,
       trim(v.entidade_contribuinte) AS customer_nif,
       CASE WHEN v.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled, NULLIF(trim(v.motivo_anulacao),'') AS cancel_reason,
       dt.sign * (CAST(v.total_documento AS REAL) - CAST(v.Total_iva AS REAL)) AS net,
       dt.sign * CAST(v.Total_iva AS REAL) AS vat,
       dt.sign * CAST(v.total_documento AS REAL) AS gross,
       dt.sign * CAST(v.Total_mercadoria AS REAL) AS goods_net,
       dt.sign * CAST(v.Total_servicos AS REAL) AS services_net,
       CAST(v.numero_itens AS INTEGER) AS item_count,
       v.posto AS terminal, v.inserido_util AS created_by_user,
       v.cx_sessao AS cash_session
FROM cab_vendas v JOIN doc_types dt ON dt.doc_type = v.Codigo
WHERE dt.module = 'VND' AND v.data_doc <> '';

-- One row per sales line, with cost and margin ------------------------------------------------------
-- unit_cost = average cost at sale time (pmc); when missing, the item's last purchase net price;
-- cost_source says which was used ('pmc', 'last_purchase', 'in_bundle', 'in_components', 'unknown', ...).
DROP VIEW IF EXISTS sales_lines;
DROP VIEW IF EXISTS sales_lines_base;
CREATE VIEW sales_lines_base AS
SELECT CAST(l.pmc AS REAL) AS raw_pmc, l.movstock AS raw_movstock, a.tipo AS item_kind,
       COALESCE(CAST(a.ultc_doc_precoliq AS REAL), 0) AS item_last_cost, l.Componente_artigo AS component_flag,
       d.doc_id, d.doc_type, d.doc_class, d.sign, d.is_internal, d.is_cancelled,
       d.doc_date, d.year, d.month, d.quarter, d.customer_code, d.customer_name,
       CAST(l.linha AS INTEGER) AS line_no,
       NULLIF(trim(l.Artigo),'') AS item_code, trim(l.descricao) AS item_description,
       CASE l.tipo_artigo WHEN 'A' THEN 'product' WHEN 'E' THEN 'service' WHEN 'F' THEN 'fee'
            ELSE 'text' END AS line_kind,
       a.grupo AS group_code, g.descricao AS group_name,
       a.familia AS family_code, f.descricao AS family_name,
       a.Marca AS brand_code, m.Descricao AS brand_name,
       d.sign * CAST(l.quantidade AS REAL) AS qty,
       CAST(l.preco AS REAL) AS unit_price_net,
       d.sign * CAST(l.Total AS REAL) AS net,
       -- PC bundles ("Computador ... composto por") appear in two shapes; count their cost exactly once:
       --  * parent (Componente_artigo = 8) carrying the TOTAL line cost in pmc -> unit cost = pmc / qty, and the
       --    price-0 component lines of that document cost nothing ('in_bundle');
       --  * parent priced with no cost and no stock movement, components at price 0 carrying their real pmc
       --    (typical before 2021) -> the parent costs nothing ('in_components'), the components keep their pmc.
       -- Generic codes (ZZ, *diverso*) never borrow a catalogue cost.
       CASE WHEN bf.costed_bundle = 1 AND l.tipo_artigo = 'A' AND CAST(l.Total AS REAL) = 0 AND l.Componente_artigo <> '8' THEN 0
            WHEN bf.costed_bundle = 0 AND bf.zp_costed = 1 AND l.tipo_artigo = 'A' AND CAST(l.Total AS REAL) <> 0
                 AND CAST(l.pmc AS REAL) = 0 AND l.movstock = '0' THEN 0
            WHEN l.Componente_artigo = '8' AND CAST(l.pmc AS REAL) > 0 AND CAST(l.quantidade AS REAL) <> 0
                 THEN CAST(l.pmc AS REAL) / abs(CAST(l.quantidade AS REAL))
            WHEN CAST(l.pmc AS REAL) > 0 THEN CAST(l.pmc AS REAL)
            WHEN l.tipo_artigo = 'A' AND CAST(l.Total AS REAL) <> 0 AND upper(l.Artigo) <> 'ZZ'
                 AND lower(l.Artigo) NOT LIKE '%diverso%' AND CAST(a.ultc_doc_precoliq AS REAL) > 0
                 AND CAST(a.ultc_doc_precoliq AS REAL) <= 2 * abs(CAST(l.preco AS REAL))
                 THEN CAST(a.ultc_doc_precoliq AS REAL)
            ELSE 0 END AS unit_cost,
       CASE WHEN bf.costed_bundle = 1 AND l.tipo_artigo = 'A' AND CAST(l.Total AS REAL) = 0 AND l.Componente_artigo <> '8' THEN 'in_bundle'
            WHEN bf.costed_bundle = 0 AND bf.zp_costed = 1 AND l.tipo_artigo = 'A' AND CAST(l.Total AS REAL) <> 0
                 AND CAST(l.pmc AS REAL) = 0 AND l.movstock = '0' THEN 'in_components'
            WHEN CAST(l.pmc AS REAL) > 0 THEN 'pmc'
            WHEN l.tipo_artigo = 'A' AND CAST(l.Total AS REAL) = 0 THEN 'zero_price_line'
            WHEN l.tipo_artigo = 'A' AND upper(l.Artigo) <> 'ZZ' AND lower(l.Artigo) NOT LIKE '%diverso%'
                 AND CAST(a.ultc_doc_precoliq AS REAL) > 0
                 AND CAST(a.ultc_doc_precoliq AS REAL) <= 2 * abs(CAST(l.preco AS REAL)) THEN 'last_purchase'
            WHEN l.tipo_artigo = 'A' THEN 'unknown'
            ELSE 'not_applicable' END AS cost_source,
       CASE WHEN l.Componente_artigo = '8' THEN 'bundle'
            WHEN l.Componente_artigo IN ('1','2') AND CAST(l.Total AS REAL) = 0 THEN 'bundle_component'
            ELSE 'normal' END AS line_role,
       NULLIF(l.origem_codigo,'') AS origin_doc_type,
       CASE WHEN l.origem_codigo <> '' THEN l.origem_codigo||' '||l.origem_serie||'/'||l.origem_numero END AS origin_doc_id
FROM lin_vendas l
JOIN sales_docs d ON d.doc_type = l.Codigo AND d.series = l.serie AND d.number = CAST(l.numero AS INTEGER)
JOIN (SELECT Codigo, serie, numero,
             MAX(Componente_artigo = '8' AND CAST(pmc AS REAL) > 0) AS costed_bundle,
             MAX(tipo_artigo = 'A' AND CAST(Total AS REAL) = 0 AND CAST(pmc AS REAL) > 0) AS zp_costed
      FROM lin_vendas GROUP BY Codigo, serie, numero) bf
  ON bf.Codigo = l.Codigo AND bf.serie = l.serie AND bf.numero = l.numero
LEFT JOIN Artigos a ON a.Codigo = l.Artigo
LEFT JOIN Grupos g ON g.Codigo = a.grupo
LEFT JOIN Familias f ON f.Codigo = a.familia AND f.grupo = a.grupo
LEFT JOIN Marcas m ON m.Codigo = a.Marca;

-- Service work typed as a product line (e.g. "consultadoria", "implementação da rede" on the generic item, or a
-- service item sold with line type A) counts as a service: line_kind 'service', no cost (labour is an overhead).
-- kind_rule says why: 'service_item' (catalogue item is a service: Artigos.tipo E/H, a group in
-- service_group_names, or a code in service_item_codes) or 'service_text' (no recorded cost, no stock movement,
-- description matches service_description_like). Codes in product_item_codes are never reclassified.
-- All lists come from ggest.json (defaults in bi/config.default.json).
DROP VIEW IF EXISTS sales_lines;
CREATE VIEW sales_lines AS
WITH k AS (
  SELECT b.*,
         CASE WHEN b.line_kind <> 'product' OR b.component_flag = '8' OR b.line_role = 'bundle_component'
                   OR b.cost_source IN ('in_bundle', 'in_components')
                   OR b.item_code IN (SELECT value FROM _bi_config WHERE key = 'product_item_codes') THEN NULL
              WHEN b.item_kind IN ('E','H')
                   OR b.item_code IN (SELECT value FROM _bi_config WHERE key = 'service_item_codes')
                   OR upper(b.group_name) IN (SELECT upper(value) FROM _bi_config WHERE key = 'service_group_names')
                   THEN 'service_item'
              WHEN b.raw_pmc = 0 AND b.raw_movstock = '0'
                   AND (upper(b.item_code) = 'ZZ' OR lower(b.item_code) LIKE '%diverso%' OR b.item_last_cost = 0)
                   AND EXISTS (SELECT 1 FROM _bi_config c WHERE c.key = 'service_description_like'
                               AND lower(b.item_description) LIKE c.value)
                   THEN 'service_text'
         END AS kind_rule
  FROM sales_lines_base b)
SELECT doc_id, doc_type, doc_class, sign, is_internal, is_cancelled, doc_date, year, month, quarter,
       customer_code, customer_name, line_no, item_code, item_description,
       CASE WHEN kind_rule IS NOT NULL THEN 'service' ELSE line_kind END AS line_kind,
       group_code, group_name, family_code, family_name, brand_code, brand_name, qty, unit_price_net, net,
       CASE WHEN kind_rule IS NOT NULL THEN 0 ELSE unit_cost END AS unit_cost,
       CASE WHEN kind_rule IS NOT NULL THEN 'not_applicable' ELSE cost_source END AS cost_source,
       line_role, origin_doc_type, origin_doc_id, kind_rule
FROM k;

-- Cost-to-sales ratio of products whose cost is known, per family and overall: used to ESTIMATE the cost
-- of product lines without one (cost_source 'unknown' -> 'estimated').
-- (materialised as tables for speed; rebuilt by `py -m bi build-views`)
DROP TABLE IF EXISTS product_cost_ratios;
CREATE TABLE product_cost_ratios AS
SELECT group_code, family_code, SUM(qty * unit_cost) / SUM(net) AS cost_ratio, SUM(net) AS basis_net
FROM sales_lines
WHERE line_kind = 'product' AND cost_source IN ('pmc','last_purchase') AND is_cancelled = 0 AND net > 0
GROUP BY group_code, family_code HAVING SUM(net) >= 2000
UNION ALL
SELECT NULL, NULL, SUM(qty * unit_cost) / SUM(net), SUM(net)
FROM sales_lines
WHERE line_kind = 'product' AND cost_source IN ('pmc','last_purchase') AND is_cancelled = 0 AND net > 0;

-- Lines that count as real business (not cancelled, not internal), with cost and margin computed.
-- cost_source 'estimated' = product without a recorded cost, costed at its family's (else overall) ratio.
-- Labour/services have no cost per line (wages are overheads in Cab_DirCC_Cre), so their gross margin is 100%.
DROP TABLE IF EXISTS sales_facts;
CREATE TABLE sales_facts AS
SELECT l.doc_id, l.doc_type, l.doc_class, l.sign, l.is_internal, l.is_cancelled, l.doc_date, l.year, l.month, l.quarter,
       l.customer_code, l.customer_name, l.line_no, l.item_code, l.item_description, l.line_kind,
       l.group_code, l.group_name, l.family_code, l.family_name, l.brand_code, l.brand_name,
       l.qty, l.unit_price_net, l.net,
       CASE WHEN l.cost_source = 'unknown' THEN l.net * COALESCE(fr.cost_ratio, gr.cost_ratio) ELSE l.qty * l.unit_cost END AS cost,
       l.net - CASE WHEN l.cost_source = 'unknown' THEN l.net * COALESCE(fr.cost_ratio, gr.cost_ratio) ELSE l.qty * l.unit_cost END AS margin,
       l.unit_cost, CASE WHEN l.cost_source = 'unknown' THEN 'estimated' ELSE l.cost_source END AS cost_source,
       l.line_role, l.origin_doc_type, l.origin_doc_id, l.kind_rule
FROM sales_lines l
LEFT JOIN product_cost_ratios fr ON fr.family_code = l.family_code AND fr.group_code = l.group_code
LEFT JOIN product_cost_ratios gr ON gr.family_code IS NULL AND gr.group_code IS NULL
WHERE l.is_cancelled = 0 AND l.is_internal = 0 AND l.doc_class IN ('invoice','credit_note') AND l.line_kind <> 'text';
-- invoice series and its business-unit group (series_groups in ggest.json; others = default_series_group)
ALTER TABLE sales_facts ADD COLUMN series TEXT;
ALTER TABLE sales_facts ADD COLUMN series_group TEXT;
UPDATE sales_facts SET series = substr(doc_id, instr(doc_id, ' ') + 1,
                                       instr(substr(doc_id, instr(doc_id, ' ') + 1), '/') - 1);
DROP TABLE IF EXISTS _series_map;
CREATE TEMP TABLE _series_map AS
SELECT s.series, COALESCE((SELECT g.series_group FROM _bi_series_groups g WHERE s.series LIKE g.series_prefix || '%'
                           ORDER BY g.priority LIMIT 1),
                          (SELECT value FROM _bi_config WHERE key = 'default_series_group'), 'Main') AS series_group
FROM (SELECT DISTINCT series FROM sales_facts) s;
UPDATE sales_facts SET series_group = (SELECT m.series_group FROM _series_map m WHERE m.series = sales_facts.series);
DROP TABLE _series_map;
CREATE INDEX sales_facts_date ON sales_facts(doc_date);
CREATE INDEX sales_facts_customer ON sales_facts(customer_code);
CREATE INDEX sales_facts_item ON sales_facts(item_code);
CREATE INDEX sales_facts_origin ON sales_facts(origin_doc_id);

-- Customers ----------------------------------------------------------------------------------------
DROP VIEW IF EXISTS customers;
CREATE VIEW customers AS
SELECT c.Codigo AS customer_code, trim(c.descricao) AS name, NULLIF(c.descricao2,'') AS name2,
       c.morada AS address, NULLIF(c.morada2,'') AS address2, c.codpostal AS postal_code,
       NULLIF(trim(c.contribuinte),'') AS nif, NULLIF(c.mail1,'') AS email,
       COALESCE(NULLIF(c.telemovel1,''), NULLIF(c.telefone1,'')) AS phone,
       c.grupo AS customer_group,
       date(substr(c.data_abertura,1,4)||'-'||substr(c.data_abertura,5,2)||'-'||substr(c.data_abertura,7,2)) AS opened_on,
       CASE WHEN c.inactivo = '1' THEN 1 ELSE 0 END AS is_inactive,
       CASE WHEN lower(c.descricao) LIKE '%consumidor final%' OR lower(c.descricao) LIKE '%cliente diverso%'
                 OR lower(c.descricao) LIKE '%diversos%' THEN 1 ELSE 0 END AS is_walk_in
FROM Clientes c;

-- Items (catalogue) --------------------------------------------------------------------------------
DROP VIEW IF EXISTS items;
CREATE VIEW items AS
SELECT a.Codigo AS item_code, trim(a.descricao) AS description,
       CASE a.tipo WHEN 'A' THEN 'product' WHEN 'E' THEN 'service' WHEN 'F' THEN 'fee' ELSE a.tipo END AS kind,
       a.grupo AS group_code, g.descricao AS group_name, a.familia AS family_code, f.descricao AS family_name,
       a.Marca AS brand_code, m.Descricao AS brand_name, NULLIF(a.barras,'') AS barcode,
       CAST(a.pvp1 AS REAL) AS price_net, CAST(a.pvpiva1 AS REAL) AS price_gross,
       CAST(a.ultc_doc_precoliq AS REAL) AS last_purchase_price,
       a.ultc_doc_entdescr AS last_supplier, a.ultc_doc_data AS last_purchase_date,
       a.ultv_doc_data AS last_sale_date, CAST(a.stock_real AS REAL) AS stock_qty,
       a.for_principal AS main_supplier_code
FROM Artigos a
LEFT JOIN Grupos g ON g.Codigo = a.grupo
LEFT JOIN Familias f ON f.Codigo = a.familia AND f.grupo = a.grupo
LEFT JOIN Marcas m ON m.Codigo = a.Marca;

-- Repairs / technical assistance (assistências) -----------------------------------------------------
DROP VIEW IF EXISTS repairs;
CREATE VIEW repairs AS
SELECT r.Codigo || ' ' || r.serie || '/' || r.numero AS repair_id,  -- not unique for series 'VAZIA' (2008/2009): use with year
       r.serie AS series, CAST(r.numero AS INTEGER) AS number, r.ano AS series_year,
       date(substr(r.data_doc,1,4)||'-'||substr(r.data_doc,5,2)||'-'||substr(r.data_doc,7,2)) AS opened_on,
       CAST(substr(r.data_doc,1,4) AS INTEGER) AS year,
       substr(r.data_doc,1,4)||'-'||substr(r.data_doc,5,2) AS month,
       CASE WHEN r.DataHora_Fecho > '19000000' THEN
            datetime(substr(r.DataHora_Fecho,1,4)||'-'||substr(r.DataHora_Fecho,5,2)||'-'||substr(r.DataHora_Fecho,7,2)||' '||
                     substr(r.DataHora_Fecho,9,2)||':'||substr(r.DataHora_Fecho,11,2)) END AS closed_at,
       upper(r.Estado_Codigo) AS status_code, s.descricao AS status,
       r.entidade_codigo AS customer_code, trim(r.entidade_descricao) AS customer_name,
       lower(r.tipo_equipamento) AS equipment_type_code, te.descricao AS equipment_type,
       r.Artigo AS equipment_item, r.artigo_descricao AS equipment_description,
       r.Marca AS brand_code, m.Descricao AS brand_name, NULLIF(r.Modelo,'') AS model,
       NULLIF(r.Numero_Serie,'') AS serial_number,
       r.Avaria_Descrita AS reported_fault, NULLIF(r.Acessorios,'') AS accessories,
       r.Tecnico AS received_by_code,            -- who opened/received the order (not who repaired)
       NULLIF(it.tecnico,'0') AS repair_technician_code, -- who did the repair (assTec_tecnicos)
       NULLIF(trim(it.avaria_encontrada),'') AS diagnosis, NULLIF(trim(it.reparacao_efetuada),'') AS work_done,
       r.inserido_util AS created_by_user,
       CAST(r.total_documento AS REAL) AS quoted_gross,
       CAST(r.total_documento AS REAL) - CAST(r.Total_iva AS REAL) AS quoted_net
FROM Cab_Assistec r
LEFT JOIN assTec_intervencao_tecnica it ON it.codigo = r.Codigo AND it.serie = r.serie AND it.numero = r.numero AND it.ano = r.ano
LEFT JOIN assTec_estados s ON upper(s.codigo) = upper(r.Estado_Codigo)
LEFT JOIN assTec_tipos_equipamentos te ON lower(te.codigo) = lower(r.tipo_equipamento)
LEFT JOIN Marcas m ON m.Codigo = r.Marca
WHERE r.data_doc <> '';

-- Repair lines (parts / labour recorded on the repair order) ------------------------------------
DROP VIEW IF EXISTS repair_lines;
CREATE VIEW repair_lines AS
SELECT l.Codigo || ' ' || l.serie || '/' || l.numero AS repair_id,
       CAST(substr(l.data_doc,1,4) AS INTEGER) AS year,
       NULLIF(l.Artigo,'') AS item_code, l.descricao AS description,
       CASE WHEN upper(trim(l.Artigo)) = 'ASSISTENCIA' OR a.tipo = 'E' THEN 'service'
            ELSE CASE l.tipo_artigo WHEN 'A' THEN 'product' WHEN 'E' THEN 'service' WHEN 'F' THEN 'fee' ELSE 'text' END END AS line_kind,
       CAST(l.quantidade AS REAL) AS qty, CAST(l.Total AS REAL) AS net
FROM Lin_Assistec l LEFT JOIN Artigos a ON a.Codigo = l.Artigo;

-- Purchases (supplier invoices) ------------------------------------------------------------------
DROP VIEW IF EXISTS purchase_docs;
CREATE VIEW purchase_docs AS
SELECT c.Codigo || ' ' || c.serie || '/' || c.numero AS doc_id, c.Codigo AS doc_type, dt.description AS doc_type_name,
       date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS doc_date,
       CAST(substr(c.data_doc,1,4) AS INTEGER) AS year, substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2) AS month,
       c.entidade_codigo AS supplier_code, trim(c.entidade_descricao) AS supplier_name,
       CASE WHEN c.estado_doc = '1' THEN 1 ELSE 0 END AS is_cancelled,
       CASE WHEN c.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END
         * (CAST(c.total_documento AS REAL) - CAST(c.Total_iva AS REAL)) AS net,
       CASE WHEN c.Codigo IN ('DEVNC','VNC','VNCP','NCADI') THEN -1 ELSE 1 END * CAST(c.total_documento AS REAL) AS gross
FROM cab_compras c LEFT JOIN doc_types dt ON dt.doc_type = c.Codigo
WHERE c.data_doc <> '';

DROP VIEW IF EXISTS suppliers;
CREATE VIEW suppliers AS
SELECT Codigo AS supplier_code, trim(descricao) AS name, NULLIF(trim(contribuinte),'') AS nif
FROM Fornecedores;

-- speeds up quote/order -> invoice links (bi/sql/ext/sales.sql)
CREATE INDEX IF NOT EXISTS ix_lin_vendas_origem ON lin_vendas(origem_codigo);
CREATE INDEX IF NOT EXISTS ix_lin_mov_series_serial ON lin_mov_series(Serie_Artigo);
