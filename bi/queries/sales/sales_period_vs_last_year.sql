-- name: sales_period_vs_last_year
-- description: Headline sales of a period vs the same period one year earlier (dates shifted -1 year): net sales, gross margin, margin %, invoices, credit notes, distinct customers, average and median invoice, sales by line kind (product / service / fee), sales of big documents (>= big_deal_net) and sales without them. One row per metric: metric, period, previous, difference, change %. Default: this year to date vs last year to the same day. Net of VAT, credit notes negative, cancelled/internal/vehicle sales excluded (sales_facts).
-- params: start=year_start, end=today, big_deal_net=5000
WITH p AS (SELECT 'cur' AS per, :start AS s, :end AS e UNION ALL SELECT 'prev', date(:start, '-1 year'), date(:end, '-1 year')),
f AS (SELECT p.per, f.* FROM p JOIN sales_facts f ON f.doc_date BETWEEN p.s AND p.e),
docs AS (SELECT per, doc_id, MAX(doc_class) AS doc_class, SUM(net) AS net FROM f GROUP BY per, doc_id),
med AS (SELECT per, net, ROW_NUMBER() OVER (PARTITION BY per ORDER BY net) AS rn, COUNT(*) OVER (PARTITION BY per) AS cnt
        FROM docs WHERE doc_class = 'invoice'),
m AS (
  SELECT per, 1 AS ord, 'net_sales' AS metric, SUM(net) AS v FROM f GROUP BY per
  UNION ALL SELECT per, 2, 'gross_margin', SUM(margin) FROM f GROUP BY per
  UNION ALL SELECT per, 3, 'margin_pct', 100.0 * SUM(margin) / NULLIF(SUM(net), 0) FROM f GROUP BY per
  UNION ALL SELECT per, 4, 'invoices', SUM(doc_class = 'invoice') FROM docs GROUP BY per
  UNION ALL SELECT per, 5, 'credit_notes', SUM(doc_class = 'credit_note') FROM docs GROUP BY per
  UNION ALL SELECT per, 6, 'customers', COUNT(DISTINCT customer_code) FROM f GROUP BY per
  UNION ALL SELECT per, 7, 'avg_invoice', AVG(net) FROM docs WHERE doc_class = 'invoice' GROUP BY per
  UNION ALL SELECT per, 8, 'median_invoice', MIN(net) FROM med WHERE rn = (cnt + 1) / 2 GROUP BY per
  UNION ALL SELECT per, 9, 'sales_products', SUM(net) FROM f WHERE line_kind = 'product' GROUP BY per
  UNION ALL SELECT per, 10, 'sales_services', SUM(net) FROM f WHERE line_kind = 'service' GROUP BY per
  UNION ALL SELECT per, 11, 'sales_fees', SUM(net) FROM f WHERE line_kind = 'fee' GROUP BY per
  UNION ALL SELECT per, 12, 'big_docs_count', SUM(net >= :big_deal_net) FROM docs GROUP BY per
  UNION ALL SELECT per, 13, 'big_docs_sales', SUM(CASE WHEN net >= :big_deal_net THEN net ELSE 0 END) FROM docs GROUP BY per
  UNION ALL SELECT per, 14, 'sales_without_big_docs', SUM(CASE WHEN net < :big_deal_net THEN net ELSE 0 END) FROM docs GROUP BY per)
SELECT metric, ROUND(MAX(CASE WHEN per = 'cur' THEN v END), 2) AS period, ROUND(MAX(CASE WHEN per = 'prev' THEN v END), 2) AS previous,
       ROUND(MAX(CASE WHEN per = 'cur' THEN v END) - MAX(CASE WHEN per = 'prev' THEN v END), 2) AS difference,
       CASE WHEN metric <> 'margin_pct' THEN ROUND(100.0 * (MAX(CASE WHEN per = 'cur' THEN v END) - MAX(CASE WHEN per = 'prev' THEN v END))
            / NULLIF(abs(MAX(CASE WHEN per = 'prev' THEN v END)), 0), 1) END AS change_pct
FROM m GROUP BY ord, metric ORDER BY ord
LIMIT 20
