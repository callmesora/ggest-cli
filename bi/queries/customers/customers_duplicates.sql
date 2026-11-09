-- name: customers_duplicates
-- description: Possible duplicate customer records: customer codes sharing the same NIF (kind = nif) or the same normalised name (kind = name). same_name = 1 is usually a real duplicate to merge; 0 with a public NIF usually means departments of one body. Shows sales and repairs per group
-- params: kind=nif, min_codes=2, limit=100
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
k AS (
  SELECT seg.*, CASE WHEN :kind = 'name' THEN lower(trim(replace(replace(replace(name, '.', ''), ',', ''), '  ', ' ')))
                     ELSE CASE WHEN length(nf) = 9 AND nf GLOB '[0-9]*' AND nf <> '999999990' THEN nf END END AS dkey
  FROM seg WHERE segment <> 'consumidor_final'),
s AS (SELECT customer_code, SUM(net) AS net, MAX(doc_date) AS last_purchase FROM sales_facts GROUP BY 1),
r AS (SELECT customer_code, COUNT(*) AS repairs FROM repairs GROUP BY 1)
SELECT k.dkey AS duplicate_key, COUNT(*) AS codes, group_concat(k.customer_code || '=' || k.name, ' | ') AS records,
       COUNT(DISTINCT lower(trim(k.name))) = 1 AS same_name, MAX(k.segment) AS segment,
       COUNT(DISTINCT k.nf) AS distinct_nifs, SUM(s.customer_code IS NOT NULL) AS codes_with_sales,
       ROUND(SUM(s.net), 2) AS net_sales, MAX(s.last_purchase) AS last_purchase, COALESCE(SUM(r.repairs), 0) AS repairs
FROM k LEFT JOIN s USING (customer_code) LEFT JOIN r USING (customer_code)
WHERE k.dkey IS NOT NULL AND k.dkey <> ''
GROUP BY k.dkey HAVING COUNT(*) >= :min_codes
ORDER BY codes_with_sales DESC, net_sales DESC LIMIT :limit
