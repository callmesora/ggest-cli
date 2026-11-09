-- name: finance_customer_supplier_offsets
-- description: Entities that are both customers and suppliers/creditors (same NIF in Clientes and Fornecedores/Credores), with what they owe us now (open receivables, gross), what we owe them now (open payables), what we sold to them and bought from them in the last 12 months (gross). Candidates for an offset (encontro de contas) and for reviewing related-party deals. Only rows with some open balance or activity in the window.
-- params: as_of=today, limit=50
WITH nf AS (
  SELECT customer_code, name, upper(replace(replace(COALESCE(nif,''),' ',''),'PT','')) AS nif FROM customers),
cust AS (SELECT * FROM nf WHERE length(nif) = 9 AND nif NOT IN ('999999990')),
part AS (
  SELECT 'supplier' AS t, Codigo AS code, upper(replace(replace(COALESCE(contribuinte,''),' ',''),'PT','')) AS nif FROM Fornecedores
  UNION ALL SELECT 'creditor', Codigo, upper(replace(replace(COALESCE(contribuinte,''),' ',''),'PT','')) FROM Credores),
pd AS (SELECT party_type, party_code, SUM(CASE WHEN is_open = 1 THEN open_amount ELSE 0 END) AS we_owe,
              SUM(CASE WHEN doc_date > date(:as_of,'-12 months') AND doc_date <= :as_of THEN gross ELSE 0 END) AS bought_12m
       FROM payable_docs GROUP BY 1,2),
pp AS (SELECT p.nif, GROUP_CONCAT(DISTINCT p.t) AS roles, SUM(pd.we_owe) AS we_owe, SUM(pd.bought_12m) AS bought_12m
       FROM part p JOIN pd ON pd.party_type = p.t AND pd.party_code = p.code WHERE length(p.nif) = 9 GROUP BY p.nif),
rc AS (SELECT customer_code, SUM(CASE WHEN is_open = 1 THEN open_amount ELSE 0 END) AS they_owe FROM receivable_docs GROUP BY 1),
sl AS (SELECT customer_code, SUM(gross) AS sold_12m FROM sales_docs
       WHERE is_cancelled = 0 AND doc_date > date(:as_of,'-12 months') AND doc_date <= :as_of GROUP BY 1)
SELECT c.customer_code, c.name AS customer_name, pp.roles AS also_our, ROUND(COALESCE(SUM(rc.they_owe),0),2) AS they_owe_us,
       ROUND(pp.we_owe,2) AS we_owe_them, ROUND(COALESCE(SUM(sl.sold_12m),0),2) AS sold_to_them_12m, ROUND(pp.bought_12m,2) AS bought_from_them_12m
FROM cust c JOIN pp ON pp.nif = c.nif
LEFT JOIN rc ON rc.customer_code = c.customer_code
LEFT JOIN sl ON sl.customer_code = c.customer_code
GROUP BY c.nif
HAVING abs(they_owe_us) > 0.5 OR abs(we_owe_them) > 0.5 OR sold_to_them_12m > 0 OR bought_from_them_12m > 0
ORDER BY they_owe_us DESC, bought_from_them_12m DESC
LIMIT :limit
