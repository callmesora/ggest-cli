-- name: customers_winback
-- description: Win-back list at legal-entity level (NIF; records/departments sharing a NIF are merged so renamed public bodies are not false churn): entities with lifetime net >= min_net and no purchase in the last inactive_days days (as of the last sale date), with segment, codes, best year, last purchase, last repair (repaired_after_last_purchase = 1 means still in touch) and net per active year
-- params: min_net=1000, inactive_days=540, segment=all, limit=50
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
asof AS (SELECT MAX(doc_date) AS d FROM sales_facts),
cs AS (SELECT customer_code, SUM(net) AS net FROM sales_facts GROUP BY 1),
names AS (
  SELECT entity_key, segment, codes, customer_codes, name AS main_name FROM (
    SELECT ent.entity_key, ent.segment, ent.name, COUNT(*) OVER (PARTITION BY ent.entity_key) AS codes,
           group_concat(ent.customer_code, ',') OVER (PARTITION BY ent.entity_key) AS customer_codes,
           ROW_NUMBER() OVER (PARTITION BY ent.entity_key ORDER BY COALESCE(cs.net, 0) DESC) AS rn
    FROM ent LEFT JOIN cs USING (customer_code))
  WHERE rn = 1),
s AS (
  SELECT e.entity_key, SUM(f.net) AS net_sales, SUM(f.margin) AS gross_margin, COUNT(DISTINCT f.doc_id) AS invoices,
         COUNT(DISTINCT f.year) AS active_years, MIN(f.doc_date) AS first_purchase, MAX(f.doc_date) AS last_purchase
  FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code
  WHERE e.segment <> 'consumidor_final' GROUP BY 1),
best AS (
  SELECT entity_key, year AS best_year, net AS best_year_net FROM (
    SELECT e.entity_key, f.year, SUM(f.net) AS net,
           ROW_NUMBER() OVER (PARTITION BY e.entity_key ORDER BY SUM(f.net) DESC) AS rn
    FROM sales_facts f JOIN ent e ON e.customer_code = f.customer_code GROUP BY 1, 2) WHERE rn = 1),
r AS (SELECT e.entity_key, COUNT(*) AS repairs, MAX(rp.opened_on) AS last_repair
      FROM repairs rp JOIN ent e ON e.customer_code = rp.customer_code GROUP BY 1)
SELECT n.main_name AS customer, n.segment, s.entity_key, n.codes, n.customer_codes,
       ROUND(s.net_sales, 2) AS net_sales, ROUND(s.gross_margin, 2) AS gross_margin, s.invoices, s.active_years,
       ROUND(s.net_sales / s.active_years, 2) AS net_per_active_year, best.best_year, ROUND(best.best_year_net, 2) AS best_year_net,
       s.first_purchase, s.last_purchase,
       CAST(julianday((SELECT d FROM asof)) - julianday(s.last_purchase) AS INTEGER) AS days_since_purchase,
       COALESCE(r.repairs, 0) AS repairs, r.last_repair,
       CASE WHEN r.last_repair > s.last_purchase THEN 1 ELSE 0 END AS repaired_after_last_purchase
FROM s JOIN names n USING (entity_key) LEFT JOIN best USING (entity_key) LEFT JOIN r USING (entity_key)
WHERE s.net_sales >= :min_net
  AND julianday((SELECT d FROM asof)) - julianday(s.last_purchase) >= :inactive_days
  AND (:segment = 'all' OR n.segment = :segment)
ORDER BY s.net_sales DESC LIMIT :limit
