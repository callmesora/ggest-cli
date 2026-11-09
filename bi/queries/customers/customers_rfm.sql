-- name: customers_rfm
-- description: RFM segmentation of customers at legal-entity level (NIF merges duplicate records; walk-in excluded) over the last `years` years: recency days, invoices, net, margin, R/F/M quintile scores (5 = best) and label (1 Campeoes, 2 Leais, 3 Novos/recentes, 4 Nao pode perder, 5 Em risco, 6 Precisa de atencao, 7 Hibernados). label = all or a label number like 4
-- params: years=3, label=all, limit=200
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
  SELECT entity_key, segment, codes, name AS main_name FROM (
    SELECT ent.entity_key, ent.segment, ent.name, COUNT(*) OVER (PARTITION BY ent.entity_key) AS codes,
           ROW_NUMBER() OVER (PARTITION BY ent.entity_key ORDER BY COALESCE(cs.net, 0) DESC) AS rn
    FROM ent LEFT JOIN cs USING (customer_code))
  WHERE rn = 1),
base AS (
  SELECT s.entity_key, MAX(f.doc_date) AS last_purchase,
         CAST(julianday((SELECT d FROM asof)) - julianday(MAX(f.doc_date)) AS INTEGER) AS recency_days,
         COUNT(DISTINCT f.doc_id) AS frequency, SUM(f.net) AS monetary, SUM(f.margin) AS margin
  FROM sales_facts f JOIN ent s ON s.customer_code = f.customer_code
  WHERE s.segment <> 'consumidor_final'
    AND f.doc_date >= date((SELECT d FROM asof), '-' || :years || ' years')
  GROUP BY 1 HAVING SUM(f.net) > 0),
sc AS (
  SELECT base.*, 6 - NTILE(5) OVER (ORDER BY recency_days) AS r,
         NTILE(5) OVER (ORDER BY frequency) AS f, NTILE(5) OVER (ORDER BY monetary) AS m
  FROM base),
lab AS (
  SELECT sc.*, CASE
    WHEN r >= 4 AND f >= 4 AND m >= 4 THEN '1 Campeoes'
    WHEN r >= 3 AND f >= 3 AND m >= 3 THEN '2 Leais'
    WHEN r >= 4 AND f <= 2 THEN '3 Novos/recentes'
    WHEN r <= 2 AND f >= 4 AND m >= 4 THEN '4 Nao pode perder'
    WHEN r <= 2 AND (f >= 3 OR m >= 3) THEN '5 Em risco'
    WHEN r = 3 THEN '6 Precisa de atencao'
    ELSE '7 Hibernados' END AS rfm_label
  FROM sc)
SELECT n.main_name AS customer, n.segment, lab.entity_key, n.codes, rfm_label, r, f, m, r || f || m AS rfm,
       last_purchase, recency_days, frequency AS invoices, ROUND(monetary, 2) AS net_sales, ROUND(margin, 2) AS gross_margin
FROM lab JOIN names n USING (entity_key)
WHERE :label = 'all' OR rfm_label LIKE :label || '%'
ORDER BY rfm_label, monetary DESC LIMIT :limit
