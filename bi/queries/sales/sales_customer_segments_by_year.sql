-- name: sales_customer_segments_by_year
-- description: Net sales, margin, documents, customers and average ticket per year by customer segment derived from the NIF on the document (6 = public administration, 5/9 = companies and institutions, 1-4 = private individuals, none/999999990 = anonymous). Approximate: some public bodies (hospitals EPE, municipalities, vocational schools) have NIF 5.
-- params: start_year=2017, end_year=2026
SELECT f.year, CASE WHEN d.customer_nif IS NULL OR d.customer_nif = '' OR d.customer_nif = '999999990' THEN 'Consumidor final (sem NIF)'
         WHEN substr(d.customer_nif,1,1) = '6' THEN 'Administracao publica (NIF 6)'
         WHEN substr(d.customer_nif,1,1) IN ('5','9') THEN 'Empresas e instituicoes (NIF 5/9)'
         WHEN substr(d.customer_nif,1,1) IN ('1','2','3','4') THEN 'Particulares (NIF 1-4)'
         ELSE 'Outros / estrangeiros' END AS segment,
       ROUND(SUM(f.net), 2) AS net_sales, ROUND(SUM(f.margin), 2) AS gross_margin,
       ROUND(100.0 * SUM(f.margin) / NULLIF(SUM(f.net), 0), 1) AS margin_pct,
       COUNT(DISTINCT f.doc_id) AS documents, COUNT(DISTINCT f.customer_code) AS customers,
       ROUND(SUM(f.net) / COUNT(DISTINCT f.doc_id), 2) AS avg_ticket
FROM sales_facts f JOIN sales_docs d ON d.doc_id = f.doc_id
WHERE f.year BETWEEN :start_year AND :end_year
GROUP BY f.year, segment ORDER BY f.year, net_sales DESC
