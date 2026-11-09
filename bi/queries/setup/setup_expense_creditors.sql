-- name: setup_expense_creditors
-- description: For configuring expense_rules in ggest.json: every creditor ('outros credores', Cab_DirCC_Cre invoices) with code, name, documents, gross total, years active, a sample document text and the category the current rules give it. Sort by total to classify the biggest ones first; creditors in the default category have no rule yet.
-- params: start_year=years_ago_3, limit=150
WITH e AS (
  SELECT d.entidade_codigo AS code, lower(trim(d.entidade_descricao)) AS name, lower(COALESCE(d.descritivo, '')) AS txt,
         CASE WHEN d.Codigo = 'NCOC' THEN -1 ELSE 1 END * CAST(d.total_documento AS REAL) AS gross,
         CAST(substr(d.data_doc, 1, 4) AS INTEGER) AS year
  FROM Cab_DirCC_Cre d
  WHERE d.Codigo IN ('FTOC','FROC','NCOC') AND d.estado_doc <> '1' AND d.data_doc <> ''
    AND CAST(substr(d.data_doc, 1, 4) AS INTEGER) >= :start_year),
c AS (
  SELECT e.*, COALESCE((SELECT r.category FROM _bi_expense_rules r
                        WHERE (r.code IS NULL OR r.code = e.code) AND (r.name_like IS NULL OR e.name LIKE r.name_like)
                          AND (r.text_like IS NULL OR e.txt LIKE r.text_like) ORDER BY r.priority LIMIT 1),
                       (SELECT value FROM _bi_config WHERE key = 'default_expense_category')) AS category
  FROM e)
SELECT code, MAX(name) AS creditor, COUNT(*) AS documents, ROUND(SUM(gross), 0) AS gross_total,
       MIN(year) || '-' || MAX(year) AS years, substr(MAX(txt), 1, 60) AS sample_text,
       GROUP_CONCAT(DISTINCT category) AS current_category
FROM c GROUP BY code ORDER BY gross_total DESC LIMIT :limit
