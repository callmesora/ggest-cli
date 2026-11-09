-- name: customers_repairs_vs_purchases
-- description: Cross-sell: per customer, repair orders (assistencias) vs purchases. Quadrants: repara_muito_compra_pouco (>= min_repairs repairs and product net < low_net: offer new equipment / maintenance contract); compra_muito_sem_assistencia (product net >= high_net and 0 repairs: offer support/maintenance); equilibrado. quadrant = all | repara_muito_compra_pouco | compra_muito_sem_assistencia | equilibrado
-- params: start=2017-01-01, end=2026-12-31, min_repairs=5, low_net=300, high_net=3000, quadrant=repara_muito_compra_pouco, limit=50
-- Segment rules (same in every customers_* query): consumidor_final = walk-in records; publico = NIF 6xxxxxxxx or
-- gGest group 1 'Entidades Governamentais' or public-body name (camara/municipio/freguesia/escola/secretaria/direcao regional/
-- hospital/universidade/instituto...); associativo = associacoes, clubes, filarmonicas, misericordias, IPSS, lares, fundacoes;
-- empresa = gGest group 2 'Empresas', NIF 5/8/9/71-79 (not 999999990), foreign VAT ids, or Lda/SA/Unipessoal in the name;
-- particular = everything else (NIF 1-3, no NIF, NIF 999999990/'cons final').
WITH c0 AS (
  SELECT customer_code, name, nif, customer_group, is_walk_in,
         ' ' || lower(replace(replace(replace(name,'.',' '),',',' '),'-',' ')) || ' ' AS n,
         upper(replace(replace(COALESCE(nif,''),' ',''),'PT','')) AS nf
  FROM customers),
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
   END AS segment
  FROM c0),
rp AS (
  SELECT customer_code, COUNT(*) AS repairs, MAX(opened_on) AS last_repair,
         group_concat(DISTINCT equipment_type) AS equipment_types
  FROM repairs WHERE opened_on BETWEEN :start AND :end GROUP BY 1),
sl AS (
  SELECT customer_code,
         SUM(CASE WHEN line_kind = 'product' THEN net ELSE 0 END) AS product_net,
         SUM(CASE WHEN line_kind = 'service' THEN net ELSE 0 END) AS service_net,
         SUM(CASE WHEN origin_doc_type = 'OSA' THEN net ELSE 0 END) AS billed_from_repairs_net,
         SUM(net) AS net_sales, SUM(margin) AS gross_margin, MAX(doc_date) AS last_purchase
  FROM sales_facts WHERE doc_date BETWEEN :start AND :end GROUP BY 1),
x AS (
  SELECT seg.customer_code, seg.name AS customer, seg.segment, COALESCE(rp.repairs, 0) AS repairs, rp.equipment_types, rp.last_repair,
         COALESCE(sl.product_net, 0) AS product_net, COALESCE(sl.service_net, 0) AS service_net,
         COALESCE(sl.billed_from_repairs_net, 0) AS billed_from_repairs_net, COALESCE(sl.net_sales, 0) AS net_sales,
         COALESCE(sl.gross_margin, 0) AS gross_margin, sl.last_purchase,
         CASE WHEN COALESCE(rp.repairs, 0) >= :min_repairs AND COALESCE(sl.product_net, 0) < :low_net THEN 'repara_muito_compra_pouco'
              WHEN COALESCE(rp.repairs, 0) = 0 AND COALESCE(sl.product_net, 0) >= :high_net THEN 'compra_muito_sem_assistencia'
              ELSE 'equilibrado' END AS quadrant
  FROM seg LEFT JOIN rp USING (customer_code) LEFT JOIN sl USING (customer_code)
  WHERE seg.segment <> 'consumidor_final' AND (rp.customer_code IS NOT NULL OR sl.customer_code IS NOT NULL))
SELECT customer_code, customer, segment, quadrant, repairs, equipment_types, last_repair,
       ROUND(product_net, 2) AS product_net, ROUND(service_net, 2) AS service_net,
       ROUND(billed_from_repairs_net, 2) AS billed_from_repairs_net, ROUND(net_sales, 2) AS net_sales,
       ROUND(gross_margin, 2) AS gross_margin, last_purchase
FROM x WHERE :quadrant = 'all' OR quadrant = :quadrant
ORDER BY CASE WHEN quadrant = 'compra_muito_sem_assistencia' THEN product_net ELSE repairs END DESC, net_sales DESC
LIMIT :limit
