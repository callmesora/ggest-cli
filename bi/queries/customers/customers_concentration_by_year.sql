-- name: customers_concentration_by_year
-- description: Customer concentration per year (walk-in excluded, legal entity = NIF): active customers, net sales, average per customer, share of top 1/10/20/50 and how many customers make 50% and 80% of sales
-- params: start_year=2017, end_year=2026
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
ent AS (
  SELECT seg.*, CASE WHEN length(nf) = 9 AND nf GLOB '[0-9]*' AND nf <> '999999990' THEN 'NIF ' || nf
                     ELSE 'COD ' || customer_code END AS entity_key
  FROM seg),
y AS (
  SELECT f.year, e.entity_key, SUM(f.net) AS net
  FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code
  WHERE f.year BETWEEN :start_year AND :end_year AND e.segment <> 'consumidor_final'
  GROUP BY 1, 2 HAVING SUM(f.net) > 0),
rk AS (
  SELECT year, entity_key, net,
         ROW_NUMBER() OVER (PARTITION BY year ORDER BY net DESC) AS rn,
         SUM(net) OVER (PARTITION BY year ORDER BY net DESC ROWS UNBOUNDED PRECEDING) AS cum,
         SUM(net) OVER (PARTITION BY year) AS tot
  FROM y)
SELECT year, COUNT(*) AS customers, ROUND(MAX(tot), 2) AS net_sales,
       ROUND(MAX(tot) / COUNT(*), 2) AS avg_per_customer,
       ROUND(100.0 * SUM(CASE WHEN rn = 1 THEN net END) / MAX(tot), 1) AS top1_pct,
       ROUND(100.0 * SUM(CASE WHEN rn <= 10 THEN net END) / MAX(tot), 1) AS top10_pct,
       ROUND(100.0 * SUM(CASE WHEN rn <= 20 THEN net END) / MAX(tot), 1) AS top20_pct,
       ROUND(100.0 * SUM(CASE WHEN rn <= 50 THEN net END) / MAX(tot), 1) AS top50_pct,
       MIN(CASE WHEN cum >= 0.5 * tot THEN rn END) AS customers_for_50pct,
       MIN(CASE WHEN cum >= 0.8 * tot THEN rn END) AS customers_for_80pct
FROM rk GROUP BY year ORDER BY year
