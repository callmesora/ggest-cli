-- name: finance_efatura_unmatched
-- description: Supplier invoices that the tax authority's e-fatura portal knows about (documents imported into gGest from e-fatura: cab_efatura, issuer NIF, number, date, totals) but that have no matching document in gGest purchases or 'outros credores' (same issuer NIF, same total within 0.02, date within max_days). Candidates for invoices not yet registered (missing costs / deductible VAT) or registered with another total. Only covers the periods that were imported from e-fatura (imports are occasional): see imported_periods.
-- params: start=2017-01-01, end=today, max_days=45, limit=100
WITH e AS (
  SELECT trim(nifEmitente) AS nif, trim(nomeEmitente) AS issuer, trim(tipoDocumento) AS doc_type, trim(numerodocumento) AS doc_number,
         date(substr(dataEmissaoDocumento,1,4)||'-'||substr(dataEmissaoDocumento,5,2)||'-'||substr(dataEmissaoDocumento,7,2)) AS doc_date,
         CAST(valorTotal AS REAL) AS total, CAST(valorTotalBaseTributavel AS REAL) AS base, CAST(valorTotalIva AS REAL) AS vat
  FROM cab_efatura),
g AS MATERIALIZED (
  SELECT upper(replace(replace(trim(c.entidade_contribuinte),' ',''),'PT','')) AS nif,
         date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS d, CAST(c.total_documento AS REAL) AS tot
  FROM cab_compras c WHERE c.estado_doc <> '1'
  UNION ALL
  SELECT upper(replace(replace(trim(c.entidade_contribuinte),' ',''),'PT','')),
         date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)), CAST(c.total_documento AS REAL)
  FROM Cab_DirCC_Cre c WHERE c.estado_doc <> '1' AND c.Codigo IN ('FTOC','FROC','NCOC')),
per AS (SELECT GROUP_CONCAT(m, ', ') AS imported_periods FROM (SELECT DISTINCT substr(doc_date,1,7) AS m FROM e ORDER BY m))
SELECT e.doc_date, e.issuer, e.nif, e.doc_type, e.doc_number, ROUND(e.total,2) AS total, ROUND(e.base,2) AS base, ROUND(e.vat,2) AS vat,
       (SELECT COUNT(*) FROM g WHERE g.nif = e.nif) AS docs_from_issuer_in_ggest,
       per.imported_periods
FROM e CROSS JOIN per
WHERE e.doc_date BETWEEN :start AND :end
  AND NOT EXISTS (SELECT 1 FROM g WHERE g.nif = e.nif AND abs(g.tot - e.total) < 0.02
                  AND abs(julianday(g.d) - julianday(e.doc_date)) <= :max_days)
ORDER BY e.doc_date
LIMIT :limit
