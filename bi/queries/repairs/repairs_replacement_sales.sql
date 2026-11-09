-- name: repairs_replacement_sales
-- description: Do repairs lead to new-equipment sales? Per year (grain=year) or overall (grain=total): repairs of identified (non walk-in) customers, how many were followed by an equipment purchase (group COMPUTADORES or TABLET, unit net >= min_unit_net) by the same customer within window_days after opening, the same measured in the window BEFORE opening (baseline), and the subset whose diagnosis says the repair is uneconomical ('nao compensa reparar' / 'economicamente') - i.e. replacement leads - and how many of those bought from the shop. Sales data starts 2017-02, so use start >= 2017-04-01. equipment_net_after_repair can count the same purchase twice when a customer had several repairs inside the window.
-- params: start=2017-04-01, end=today, window_days=60, min_unit_net=150, grain=year
WITH r AS (
  SELECT c._row AS rid, c.entidade_codigo AS customer_code,
         date(substr(c.data_doc,1,4)||'-'||substr(c.data_doc,5,2)||'-'||substr(c.data_doc,7,2)) AS opened_on,
         CASE WHEN :grain = 'total' THEN 'total' ELSE substr(c.data_doc, 1, 4) END AS period,
         lower(c.tipo_equipamento) AS eq, lower(COALESCE(i.avaria_encontrada, '')) AS d
  FROM Cab_Assistec c
  LEFT JOIN assTec_intervencao_tecnica i ON i.codigo = c.Codigo AND i.serie = c.serie AND i.numero = c.numero AND i.ano = c.ano
  JOIN customers cu ON cu.customer_code = c.entidade_codigo AND cu.is_walk_in = 0
  WHERE c.data_doc <> '' AND c.data_doc BETWEEN replace(:start, '-', '') AND replace(:end, '-', '') || '99'),
eq AS MATERIALIZED (
  SELECT customer_code, doc_date, net FROM sales_facts
  WHERE line_kind = 'product' AND qty > 0 AND unit_price_net >= :min_unit_net
    AND (group_name = 'COMPUTADORES' OR family_name = 'TABLET')),
x AS (
  SELECT r.rid, r.period, r.eq,
         (r.d LIKE '%economicamente%' OR r.d LIKE '%n_o compensa%' OR r.d LIKE '%nao compensa%' OR r.d LIKE '%n_o justifica%') AS uneconomical,
         SUM(CASE WHEN eq.doc_date > r.opened_on AND eq.doc_date <= date(r.opened_on, '+' || :window_days || ' day') THEN eq.net END) AS bought_after_net,
         MAX(CASE WHEN eq.doc_date < r.opened_on AND eq.doc_date >= date(r.opened_on, '-' || :window_days || ' day') THEN 1 ELSE 0 END) AS bought_before
  FROM r LEFT JOIN eq ON eq.customer_code = r.customer_code
  GROUP BY r.rid)
SELECT period, COUNT(*) AS repairs,
       SUM(bought_after_net IS NOT NULL) AS followed_by_equipment_sale,
       ROUND(100.0 * SUM(bought_after_net IS NOT NULL) / COUNT(*), 1) AS conversion_pct,
       ROUND(SUM(bought_after_net), 2) AS equipment_net_after_repair,
       ROUND(100.0 * SUM(bought_before) / COUNT(*), 1) AS baseline_bought_before_pct,
       SUM(uneconomical) AS uneconomical_repairs,
       SUM(uneconomical AND bought_after_net IS NOT NULL) AS uneconomical_bought_here,
       ROUND(100.0 * SUM(uneconomical AND bought_after_net IS NOT NULL) / NULLIF(SUM(uneconomical), 0), 1) AS uneconomical_conversion_pct
FROM x GROUP BY period ORDER BY period
