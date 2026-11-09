-- name: sales_business_lines
-- description: Revenue and gross margin per business line (gGest software, update contracts, services, hosting, computers, consumables...) for a period, with share of sales and of margin. Services show 100% margin (labour cost not recorded).
-- params: start=last_year_start, end=last_year_end
WITH f AS (SELECT f.*, CASE
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
         ELSE 'Outros' END AS business_line FROM sales_facts f WHERE f.doc_date BETWEEN :start AND :end)
SELECT business_line,
       ROUND(SUM(net), 2) AS net_sales,
       ROUND(SUM(margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(margin) / NULLIF(SUM(net), 0), 1) AS margin_pct,
       ROUND(100.0 * SUM(net) / (SELECT SUM(net) FROM f), 1) AS share_of_sales_pct,
       ROUND(100.0 * SUM(margin) / (SELECT SUM(margin) FROM f), 1) AS share_of_margin_pct,
       COUNT(DISTINCT doc_id) AS documents,
       COUNT(DISTINCT customer_code) AS customers
FROM f GROUP BY business_line ORDER BY gross_margin DESC
