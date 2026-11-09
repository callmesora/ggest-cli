-- name: customers_segment_lookup
-- description: Customer dimension: one row per customer code with derived segment, island and locality, lifetime net sales, first/last purchase and repairs; filter by segment, island or a name fragment
-- params: segment=all, island=all, name=, limit=200
-- Segment rules and entity_key (NIF) come from view customer_dim (bi/sql/ext/customers.sql, documented in
-- docs/domains/customers.md): publico / empresa / particular / associativo / consumidor_final (walk-in records).
WITH seg AS MATERIALIZED (SELECT customer_code, name, nif, customer_group, is_walk_in, ' ' || name_norm || ' ' AS n,
                    COALESCE(nif_clean, '') AS nf, segment, entity_key FROM customer_dim), cp AS (SELECT substr(Codigo,1,8) AS code, MIN(trim(substr(Codigo,10))) AS loc FROM codpostal GROUP BY 1),
g0 AS (
  SELECT c.customer_code,
         trim(COALESCE(c.postal_code,'')) AS pc,
         ' ' || lower(COALESCE(c.postal_code,'') || ' ' || COALESCE(c.address,'') || ' ' || COALESCE(c.address2,'')) || ' ' AS t
  FROM customers c),
g1 AS (
  SELECT g0.*,
         CASE WHEN substr(pc,1,4) GLOB '[1-9][0-9][0-9][0-9]' THEN CAST(substr(pc,1,4) AS INTEGER) END AS p4,
         CASE WHEN substr(pc,1,4) GLOB '[1-9][0-9][0-9][0-9]' AND substr(pc,6,3) GLOB '[0-9][0-9][0-9]' THEN substr(pc,1,4)||'-'||substr(pc,6,3)
              WHEN substr(pc,1,7) GLOB '[1-9][0-9][0-9][0-9][0-9][0-9][0-9]' THEN substr(pc,1,4)||'-'||substr(pc,5,3) END AS p7
  FROM g0),
geo AS (
  SELECT g1.customer_code, g1.p4, g1.p7,
   CASE
    WHEN p4 BETWEEN 9900 AND 9904 OR (p4 IS NULL AND (t LIKE '% horta %' OR t LIKE '%faial%' OR t LIKE '%flamengos%'
      OR t LIKE '%feteira%' OR t LIKE '%castelo branco%' OR t LIKE '%cedros%' OR t LIKE '%almoxarife%' OR t LIKE '%pedro miguel%'
      OR t LIKE '%capelo%' OR t LIKE '%salão%' OR t LIKE '%ribeirinha%' OR t LIKE '%praia do norte%')) THEN 'Faial'
    WHEN p4 BETWEEN 9930 AND 9950 OR (p4 IS NULL AND (t LIKE '%pico%' OR t LIKE '%madalena%')) THEN 'Pico'
    WHEN p4 BETWEEN 9800 AND 9875 THEN 'São Jorge'
    WHEN p4 = 9880 THEN 'Graciosa'
    WHEN p4 BETWEEN 9700 AND 9760 THEN 'Terceira'
    WHEN p4 = 9580 THEN 'Santa Maria'
    WHEN p4 BETWEEN 9500 AND 9699 THEN 'São Miguel'
    WHEN p4 BETWEEN 9960 AND 9970 THEN 'Flores'
    WHEN p4 = 9980 THEN 'Corvo'
    WHEN p4 BETWEEN 9000 AND 9399 THEN 'Madeira'
    WHEN p4 BETWEEN 1000 AND 8999 THEN 'Continente'
    WHEN pc = '' AND trim(t) = '' THEN 'Sem morada'
    ELSE 'Outro/estrangeiro'
   END AS island,
   COALESCE(
    CASE WHEN p4 = 9950 OR (p4 IS NULL AND t LIKE '%madalena%' AND t LIKE '%pico%') THEN 'Madalena (Pico)'
         WHEN p4 = 9940 OR (p4 IS NULL AND (t LIKE '%são roque%' OR t LIKE '%sao roque%')) THEN 'São Roque do Pico'
         WHEN p4 BETWEEN 9930 AND 9934 OR (p4 IS NULL AND t LIKE '%lajes do pico%') THEN 'Lajes do Pico' END,
    CASE WHEN p4 BETWEEN 9900 AND 9904 OR p4 IS NULL THEN
     CASE
      WHEN t LIKE '%flamengos%' THEN 'Flamengos'
      WHEN t LIKE '%feteira%' THEN 'Feteira'
      WHEN t LIKE '%castelo branco%' THEN 'Castelo Branco'
      WHEN t LIKE '%cedros%' THEN 'Cedros'
      WHEN t LIKE '%almoxarife%' THEN 'Praia do Almoxarife'
      WHEN t LIKE '%pedro miguel%' THEN 'Pedro Miguel'
      WHEN t LIKE '%praia do norte%' THEN 'Praia do Norte'
      WHEN t LIKE '%capelo%' THEN 'Capelo'
      WHEN t LIKE '%ribeirinha%' AND (p4 IS NULL OR p4 BETWEEN 9900 AND 9904) THEN 'Ribeirinha'
      WHEN t LIKE '%salão%' OR t LIKE '%salao%' THEN 'Salão'
     END END,
    CASE (SELECT loc FROM cp WHERE cp.code = g1.p7)
      WHEN 'HORTA' THEN 'Horta (cidade)' WHEN 'FLAMENGOS' THEN 'Flamengos' WHEN 'FETEIRA HRT' THEN 'Feteira'
      WHEN 'CASTELO BRANCO HRT' THEN 'Castelo Branco' WHEN 'CEDROS HRT' THEN 'Cedros' WHEN 'PRAIA DO ALMOXARIFE' THEN 'Praia do Almoxarife'
      WHEN 'PEDRO MIGUEL' THEN 'Pedro Miguel' WHEN 'PRAIA DO NORTE' THEN 'Praia do Norte' WHEN 'CAPELO' THEN 'Capelo'
      WHEN 'RIBEIRINHA HRT' THEN 'Ribeirinha' WHEN 'SALÃO' THEN 'Salão'
      ELSE (SELECT loc FROM cp WHERE cp.code = g1.p7) END,
    CASE WHEN p4 BETWEEN 9900 AND 9904 OR (p4 IS NULL AND (t LIKE '% horta %' OR t LIKE '%faial%')) THEN 'Faial (freguesia n/d)'
    END) AS locality
  FROM g1),
f AS (SELECT customer_code, SUM(net) AS net, MIN(doc_date) AS first_purchase, MAX(doc_date) AS last_purchase FROM sales_facts GROUP BY 1),
r AS (SELECT customer_code, COUNT(*) AS repairs, MAX(opened_on) AS last_repair FROM repairs GROUP BY 1)
SELECT seg.customer_code, seg.name, seg.nif, seg.segment, geo.island, geo.locality, c.opened_on, c.is_inactive,
       ROUND(COALESCE(f.net, 0), 2) AS net_sales, f.first_purchase, f.last_purchase, COALESCE(r.repairs, 0) AS repairs, r.last_repair
FROM seg JOIN customers c USING (customer_code) LEFT JOIN geo USING (customer_code)
LEFT JOIN f USING (customer_code) LEFT JOIN r USING (customer_code)
WHERE (:segment = 'all' OR seg.segment = :segment) AND (:island = 'all' OR geo.island = :island)
  AND (:name = '' OR lower(seg.name) LIKE '%' || lower(:name) || '%')
ORDER BY net_sales DESC LIMIT :limit
