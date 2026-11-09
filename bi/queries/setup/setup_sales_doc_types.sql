-- name: setup_sales_doc_types
-- description: For configuring a new database (ggest.json): every sales document type used, with its gGest description, fiscal type (FT/FR/FS/NC), documents, net total and whether it currently counts as internal (excluded from sales). Company-created types for internal consumption, sponsorship or asset sales belong in internal_doc_types.
-- params: limit=100
SELECT d.doc_type, t.description, t.fiscal_type, t.doc_class, COUNT(*) AS documents,
       ROUND(SUM(d.net), 0) AS net_total, MIN(d.doc_date) AS first_date, MAX(d.doc_date) AS last_date,
       MAX(d.is_internal) AS counted_as_internal
FROM sales_docs d LEFT JOIN doc_types t ON t.doc_type = d.doc_type
GROUP BY d.doc_type ORDER BY documents DESC LIMIT :limit
