-- name: finance_vat_by_year
-- description: Indicative VAT position per year: VAT charged on sales documents (sales_docs, not cancelled, incl. internal docs; credit notes negative) minus VAT on supplier invoices and on overhead invoices (payable_docs: cab_compras / Cab_DirCC_Cre; amounts typed by mistake in the VAT box of a 0% slot are not counted as VAT). Positive = VAT to pay to the State. Sales are taxed at the Azores rate (18% -> 16% from mid-2021) while most purchases come from the mainland at 23%, so the net is small. Not a tax return: excludes reverse-charge self-assessment and adjustments.
-- params: start_year=2017, end_year=this_year
WITH s AS (SELECT year, SUM(vat) AS vat_sales, SUM(net) AS net_sales FROM sales_docs
           WHERE is_cancelled = 0 AND doc_class IN ('invoice','credit_note') GROUP BY year),
p AS (SELECT year, SUM(vat) AS vat_purchases, SUM(net) AS net_purchases
      FROM payable_docs WHERE party_type = 'supplier' GROUP BY year),
o AS (SELECT year, SUM(vat) AS vat_overheads
      FROM payable_docs WHERE party_type = 'creditor' AND doc_type IN ('FTOC','FROC','NCOC') GROUP BY year)
SELECT s.year, ROUND(s.vat_sales,0) AS vat_collected, ROUND(100.0 * s.vat_sales / s.net_sales,2) AS avg_sales_rate_pct,
       ROUND(p.vat_purchases,0) AS vat_on_purchases, ROUND(100.0 * p.vat_purchases / p.net_purchases,2) AS avg_purchase_rate_pct,
       ROUND(o.vat_overheads,0) AS vat_on_overheads,
       ROUND(s.vat_sales - COALESCE(p.vat_purchases,0) - COALESCE(o.vat_overheads,0),0) AS net_vat_position
FROM s LEFT JOIN p ON p.year = s.year LEFT JOIN o ON o.year = s.year
WHERE s.year BETWEEN :start_year AND :end_year ORDER BY s.year
