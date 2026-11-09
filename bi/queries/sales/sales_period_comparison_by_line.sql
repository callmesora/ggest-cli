-- name: sales_period_comparison_by_line
-- description: Compare two periods (e.g. this year to date vs same period last year) per business line: net sales and margin in A and B, difference and % change, plus a TOTAL row. Default: 2025-01-01..2025-11-07 (A) vs 2026-01-01..2026-11-07 (B).
-- params: a_start=2025-01-01, a_end=2025-11-07, b_start=2026-01-01, b_end=2026-11-07
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
         ELSE 'Outros' END AS business_line FROM sales_facts f
           WHERE f.doc_date BETWEEN :a_start AND :a_end OR f.doc_date BETWEEN :b_start AND :b_end),
g AS (SELECT business_line,
             SUM(CASE WHEN doc_date BETWEEN :a_start AND :a_end THEN net ELSE 0 END) AS net_a,
             SUM(CASE WHEN doc_date BETWEEN :b_start AND :b_end THEN net ELSE 0 END) AS net_b,
             SUM(CASE WHEN doc_date BETWEEN :a_start AND :a_end THEN margin ELSE 0 END) AS margin_a,
             SUM(CASE WHEN doc_date BETWEEN :b_start AND :b_end THEN margin ELSE 0 END) AS margin_b
      FROM f GROUP BY business_line),
u AS (
  SELECT business_line, net_a, net_b, margin_a, margin_b, 0 AS is_total FROM g
  UNION ALL
  SELECT 'TOTAL', SUM(net_a), SUM(net_b), SUM(margin_a), SUM(margin_b), 1 FROM g)
SELECT business_line, ROUND(net_a, 2) AS net_a, ROUND(net_b, 2) AS net_b, ROUND(net_b - net_a, 2) AS net_diff,
       ROUND(100.0 * (net_b - net_a) / NULLIF(net_a, 0), 1) AS net_change_pct,
       ROUND(margin_a, 2) AS margin_a, ROUND(margin_b, 2) AS margin_b, ROUND(margin_b - margin_a, 2) AS margin_diff
FROM u ORDER BY is_total, net_b - net_a
