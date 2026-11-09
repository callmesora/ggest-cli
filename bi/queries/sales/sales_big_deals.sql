-- name: sales_big_deals
-- description: Largest sales documents (net >= min_net) in a period with customer, segment (from NIF), main business line and margin: public tenders vs company projects vs retail.
-- params: start=2017-01-01, end=2026-12-31, min_net=3000, limit=50
WITH l AS (SELECT f.doc_id, CASE
         WHEN upper(f.item_code) = 'ZZ' THEN 'ZZ - artigo generico (texto livre)'
         WHEN f.family_name = 'GOLFINHO SOFTWARE' AND f.item_code LIKE 'ACTPER%' THEN 'gGest - contratos anuais de actualizacao'
         WHEN f.family_name = 'GOLFINHO SOFTWARE' AND (lower(f.item_description) LIKE '%anual%' OR lower(f.item_description) LIKE '%cloud%'
              OR lower(f.item_description) LIKE '%mensal%') THEN 'gGest - subscricoes anuais/cloud'
         WHEN f.family_name = 'GOLFINHO SOFTWARE' THEN 'gGest - licencas e modulos'
         WHEN f.item_code = 'F/A' THEN 'Servico fecho/abertura de ano'
         WHEN f.group_name = 'INTERNET E CLOUD' THEN 'Alojamento e dominios'
         WHEN f.group_name = 'SOFTWARE' THEN 'Outro software (Office, antivirus, Windows)'
         WHEN f.group_name = 'SERVIÇOS' OR f.line_kind = 'service' THEN 'Assistencia tecnica e servicos'
         WHEN f.group_name = 'PORTES' OR f.line_kind = 'fee' THEN 'Portes'
         WHEN f.group_name IN ('COMPUTADORES','TABLET') THEN 'Computadores e tablets'
         WHEN f.group_name = 'CONSUMÍVEIS' THEN 'Consumiveis'
         WHEN f.group_name IN ('COMPONENTES','SPARES','ARMAZENAMENTO DE DADOS') THEN 'Componentes, pecas e armazenamento'
         WHEN f.group_name IN ('MONITORES','PERIFERICOS','IMPRESSORAS  SCANNERS','ACESSÓRIOS','CABOS','ADAPTADORES',
              'ALIMENTAÇÃO / ENERGIA','VIDEOPROJETORES','TV') THEN 'Perifericos, monitores e impressoras'
         WHEN f.group_name IN ('REDES','VIDEOVIGILÂNCIA','POS','Automação/Smart Home','Video Conferencia','TELEFONES') THEN 'Redes, POS e videovigilancia'
         WHEN f.group_name = 'TELEMOVEIS E SMARTWATCH' THEN 'Telemoveis'
         WHEN f.group_name = 'Viatura' THEN 'Venda de viaturas (nao operacional)'
         ELSE 'Outros' END AS business_line, SUM(f.net) AS net FROM sales_facts f
           WHERE f.doc_date BETWEEN :start AND :end GROUP BY f.doc_id, business_line),
top_line AS (SELECT doc_id, business_line FROM
             (SELECT doc_id, business_line, ROW_NUMBER() OVER (PARTITION BY doc_id ORDER BY net DESC) AS rn FROM l) WHERE rn = 1),
docs AS (SELECT f.doc_id, MIN(f.doc_date) AS doc_date, MAX(f.customer_code) AS customer_code, MAX(f.customer_name) AS customer_name,
                SUM(f.net) AS net, SUM(f.margin) AS margin
         FROM sales_facts f WHERE f.doc_date BETWEEN :start AND :end GROUP BY f.doc_id HAVING SUM(f.net) >= :min_net)
SELECT x.doc_id, x.doc_date, x.customer_code, x.customer_name, CASE WHEN d.customer_nif IS NULL OR d.customer_nif = '' OR d.customer_nif = '999999990' THEN 'Consumidor final (sem NIF)'
         WHEN substr(d.customer_nif,1,1) = '6' THEN 'Administracao publica (NIF 6)'
         WHEN substr(d.customer_nif,1,1) IN ('5','9') THEN 'Empresas e instituicoes (NIF 5/9)'
         WHEN substr(d.customer_nif,1,1) IN ('1','2','3','4') THEN 'Particulares (NIF 1-4)'
         ELSE 'Outros / estrangeiros' END AS segment,
       t.business_line AS main_business_line, ROUND(x.net, 2) AS net, ROUND(x.margin, 2) AS gross_margin,
       ROUND(100.0 * x.margin / NULLIF(x.net, 0), 1) AS margin_pct
FROM docs x JOIN sales_docs d ON d.doc_id = x.doc_id LEFT JOIN top_line t ON t.doc_id = x.doc_id
ORDER BY x.net DESC LIMIT :limit
