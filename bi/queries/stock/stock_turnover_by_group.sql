-- name: stock_turnover_by_group
-- description: Stock turnover per catalogue group: current stock at cost vs cost of goods sold in the last 12 months (sales_facts product lines). Columns: group_name, items_in_stock, stock_value, cogs_12m, sales_net_12m, turnover (cogs / stock), days_of_stock (stock / daily cogs; blank = no sales), stock_share_pct, cogs_share_pct. Groups holding a bigger share of stock than of sales are over-stocked.
-- params: as_of=today
WITH st AS (SELECT group_name, COUNT(*) AS items, SUM(stock_value) AS stock_value FROM stock_items WHERE kind = 'product' AND qty_on_hand > 0 GROUP BY group_name),
cg AS (SELECT COALESCE(group_name,'(sem grupo)') AS group_name, SUM(cost) AS cogs, SUM(net) AS sales_net FROM sales_facts
       WHERE line_kind = 'product' AND doc_date > date(:as_of,'-12 months') AND doc_date <= :as_of GROUP BY 1),
g AS (SELECT group_name FROM st UNION SELECT group_name FROM cg)
SELECT g.group_name, st.items AS items_in_stock, ROUND(st.stock_value,0) AS stock_value, ROUND(cg.cogs,0) AS cogs_12m, ROUND(cg.sales_net,0) AS sales_net_12m,
       ROUND(cg.cogs / NULLIF(st.stock_value,0),1) AS turnover,
       ROUND(st.stock_value / NULLIF(cg.cogs / 365.0,0),0) AS days_of_stock,
       ROUND(100.0 * st.stock_value / (SELECT SUM(stock_value) FROM st),1) AS stock_share_pct,
       ROUND(100.0 * cg.cogs / (SELECT SUM(cogs) FROM cg),1) AS cogs_share_pct
FROM g LEFT JOIN st ON st.group_name = g.group_name LEFT JOIN cg ON cg.group_name = g.group_name
ORDER BY st.stock_value DESC
