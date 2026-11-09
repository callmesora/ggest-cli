-- name: sales_discounted_lines
-- description: Sales lines sold well below the item's current catalogue price (unit_price_net at least min_discount_pct under items.price_net) or below cost, in a period: who got the price, which item, how much was given away. Columns: doc_id, doc_date, customer, item, qty, unit price sold, catalogue price now, discount % vs catalogue, unit cost, line margin %, created_by_user (gGest user id of the document), flag ('below_cost' / 'discount'); totals over ALL matching lines (not only the rows shown): total_lines, total_below_catalogue (€ under catalogue price), total_negative_margin. Caveat: the catalogue price is today's, prices may have changed since the sale; bundle components at price 0 and ZZ excluded. Explicit discounts (desc columns) are rare (see sales_discounts_by_year): price cuts are typed into the unit price.
-- params: start=year_start, end=today, min_discount_pct=20, min_net=50, limit=100
SELECT f.doc_id, f.doc_date, f.customer_code, f.customer_name, f.item_code, f.item_description, f.qty,
       ROUND(f.unit_price_net, 2) AS unit_price_net, ROUND(i.price_net, 2) AS catalogue_price_net,
       ROUND(100.0 * (i.price_net - f.unit_price_net) / i.price_net, 1) AS discount_vs_catalogue_pct,
       ROUND(f.unit_cost, 2) AS unit_cost, ROUND(f.net, 2) AS net, ROUND(100.0 * f.margin / f.net, 1) AS margin_pct,
       (SELECT v.inserido_util FROM cab_vendas v WHERE v.Codigo = f.doc_type
          AND v.Codigo || ' ' || v.serie || '/' || v.numero = f.doc_id) AS created_by_user,
       CASE WHEN f.margin < 0 THEN 'below_cost' ELSE 'discount' END AS flag,
       COUNT(*) OVER () AS total_lines, ROUND(SUM((i.price_net - f.unit_price_net) * f.qty) OVER (), 2) AS total_below_catalogue,
       ROUND(SUM(CASE WHEN f.margin < 0 THEN f.margin ELSE 0 END) OVER (), 2) AS total_negative_margin
FROM sales_facts f
JOIN items i ON i.item_code = f.item_code
WHERE f.doc_date BETWEEN :start AND :end AND f.doc_class = 'invoice' AND f.line_kind = 'product'
  AND f.net >= :min_net AND f.line_role = 'normal' AND upper(f.item_code) <> 'ZZ' AND i.price_net > 0
  AND (f.unit_price_net <= i.price_net * (1 - :min_discount_pct / 100.0) OR f.margin < 0)
ORDER BY (i.price_net - f.unit_price_net) * f.qty DESC
LIMIT :limit
