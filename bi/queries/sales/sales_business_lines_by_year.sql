-- name: sales_business_lines_by_year
-- description: Net sales and gross margin per business line per year (long format: year x business_line), for trend / stacked charts. Current year is partial.
-- params: start_year=2017, end_year=2026
SELECT f.year, CASE
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
         ELSE 'Outros' END AS business_line,
       ROUND(SUM(f.net), 2) AS net_sales,
       ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       COUNT(DISTINCT f.customer_code) AS customers
FROM sales_facts f
WHERE f.year BETWEEN :start_year AND :end_year
GROUP BY f.year, business_line ORDER BY f.year, net_sales DESC
