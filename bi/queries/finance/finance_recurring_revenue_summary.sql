-- name: finance_recurring_revenue_summary
-- description: Recurring-contract (avenças) portfolio summary by item (hosting, domain, DNS, licence...): active contracts and customers, contracted annual value and monthly recurring revenue (MRR = annual / 12, net of VAT), contracts to bill now (next billing date passed or never billed), inactive (cancelled) contracts, and what was actually invoiced for those items in the last 12 months (sales_facts) as a check. Last row TOTAL. For all recurring revenue streams (incl. software update contracts not managed as avenças) see sales_recurring_revenue_by_year.
-- params: as_of=today
WITH c AS (SELECT COALESCE(item_code,'(none)') AS item_code, * FROM recurring_contracts),
b AS (SELECT upper(item_code) AS item_code, SUM(net) AS billed FROM sales_facts
      WHERE doc_date > date(:as_of,'-12 months') AND doc_date <= :as_of
        AND upper(item_code) IN (SELECT item_code FROM recurring_contracts) GROUP BY 1),
g AS (
  SELECT c.item_code, SUM(is_active) AS active_contracts, COUNT(DISTINCT CASE WHEN is_active = 1 THEN customer_code END) AS customers,
         SUM(CASE WHEN is_active = 1 THEN annual_value ELSE 0 END) AS annual_value,
         SUM(CASE WHEN is_active = 1 AND (last_billed IS NULL OR next_billing <= :as_of) THEN 1 ELSE 0 END) AS to_bill_now,
         SUM(1 - is_active) AS inactive_contracts
  FROM c GROUP BY c.item_code)
SELECT * FROM (
  SELECT g.item_code, g.active_contracts, g.customers, ROUND(g.annual_value,2) AS annual_value, ROUND(g.annual_value/12.0,2) AS mrr,
         g.to_bill_now, g.inactive_contracts, ROUND(b.billed,2) AS billed_last_12m
  FROM g LEFT JOIN b ON b.item_code = g.item_code
  UNION ALL
  SELECT 'TOTAL', SUM(active_contracts), (SELECT COUNT(DISTINCT customer_code) FROM recurring_contracts WHERE is_active = 1),
         ROUND(SUM(annual_value),2), ROUND(SUM(annual_value)/12.0,2), SUM(to_bill_now), SUM(inactive_contracts),
         (SELECT ROUND(SUM(billed),2) FROM b)
  FROM g)
ORDER BY item_code = 'TOTAL', annual_value DESC
