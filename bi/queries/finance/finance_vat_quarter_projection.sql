-- name: finance_vat_quarter_projection
-- description: Projection of the current VAT quarter (the quarter containing as_of): output VAT (sales), input VAT (supplier purchases + overheads) and net (positive = to pay) quarter-to-date, then two full-quarter estimates: linear (quarter-to-date scaled by calendar days) and seasonal (output and input each = quarter-to-date x the full / to-date ratio of the same quarter last year; net = output - input; volatile early in a quarter), next to last year's same quarter actual. Indicative: the same rules as finance_vat_by_period (no reverse-charge self-assessment; costs not yet registered are missing, so input VAT is usually under-projected early in the quarter). Pass a past date to check a closed quarter.
-- params: as_of=today
WITH q AS (
  SELECT date(:as_of, 'start of month', '-' || ((CAST(strftime('%m', :as_of) AS INTEGER) - 1) % 3) || ' months') AS qs),
p AS (
  SELECT qs, date(qs, '+3 months', '-1 day') AS qe, :as_of AS cut,
         date(qs, '-12 months') AS ly_qs, date(qs, '-9 months', '-1 day') AS ly_qe, date(:as_of, '-12 months') AS ly_cut
  FROM q),
v AS (
  SELECT doc_date, vat AS v_out, 0 AS v_in FROM sales_docs WHERE is_cancelled = 0 AND doc_class IN ('invoice','credit_note')
  UNION ALL
  SELECT doc_date, 0, vat FROM payable_docs WHERE party_type = 'supplier' OR doc_type IN ('FTOC','FROC','NCOC')),
a AS (
  SELECT SUM(CASE WHEN doc_date BETWEEN p.qs AND p.cut THEN v_out END) AS out_qtd,
         SUM(CASE WHEN doc_date BETWEEN p.qs AND p.cut THEN v_in END) AS in_qtd,
         SUM(CASE WHEN doc_date BETWEEN p.ly_qs AND p.ly_cut THEN v_out END) AS out_ly_qtd,
         SUM(CASE WHEN doc_date BETWEEN p.ly_qs AND p.ly_cut THEN v_in END) AS in_ly_qtd,
         SUM(CASE WHEN doc_date BETWEEN p.ly_qs AND p.ly_qe THEN v_out END) AS out_ly,
         SUM(CASE WHEN doc_date BETWEEN p.ly_qs AND p.ly_qe THEN v_in END) AS in_ly,
         julianday(MIN(p.cut, p.qe)) - julianday(p.qs) + 1 AS days_done, julianday(p.qe) - julianday(p.qs) + 1 AS days_total,
         MAX(p.qs) AS qs, MAX(p.qe) AS qe
  FROM p CROSS JOIN v WHERE v.doc_date BETWEEN p.ly_qs AND p.qe GROUP BY p.qs),
b AS (SELECT a.*, CASE WHEN out_ly_qtd <> 0 THEN out_qtd * out_ly / out_ly_qtd END AS out_seas,
                  CASE WHEN in_ly_qtd <> 0 THEN in_qtd * in_ly / in_ly_qtd END AS in_seas FROM a)
SELECT x.line, x.qs AS quarter_start, x.qe AS quarter_end, CAST(x.days_done AS INTEGER) AS days_elapsed, CAST(x.days_total AS INTEGER) AS days_in_quarter,
       ROUND(x.qtd,0) AS quarter_to_date, ROUND(x.qtd * x.days_total / x.days_done,0) AS projection_linear,
       ROUND(x.seas,0) AS projection_seasonal, ROUND(x.ly,0) AS same_quarter_last_year
FROM (
  SELECT 1 AS o, 'vat_output_sales' AS line, out_qtd AS qtd, out_seas AS seas, out_ly AS ly, days_done, days_total, qs, qe FROM b
  UNION ALL SELECT 2, 'vat_input_purchases_overheads', in_qtd, in_seas, in_ly, days_done, days_total, qs, qe FROM b
  UNION ALL SELECT 3, 'vat_net_to_pay', out_qtd - in_qtd, out_seas - in_seas, out_ly - in_ly, days_done, days_total, qs, qe FROM b) x
ORDER BY x.o
