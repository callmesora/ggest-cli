-- name: finance_month_close
-- description: Month-close pack (fecho do mês): one row per KPI for the month of as_of vs the previous month and the same month last year, with changes. KPIs: net sales, gross margin and %, invoices, purchases (net), overheads by P&L line (staff, rents, other running costs; from expense_docs, config-driven categories), indicative operating result (margin - overheads), investments (not deducted), VAT output / input / net, money in / money out (receipts + counter sales vs supplier and creditor payments), and balances at the end of each period: customer receivables, of which overdue > 90 days, and payables (suppliers + creditors). Changes: vs_prev / vs_last_year are relative % for amounts and percentage points (change_unit = 'pp') for gross_margin_pct. Balances (receivables_end, payables_end) are taken AT the end of each period (at as_of for the current one), so receivables_end for a closed month differs from finance_receivables_aging / finance_receivables_open, which show the balance at the data date (they match when as_of = today). If as_of is not a month end, the three periods are cut at the same day of the month (month-to-date, like-for-like); pass the last day of a month (e.g. 2026-10-31) for a closed month.
-- params: as_of=today
WITH base AS (
  SELECT :as_of AS b0, date(:as_of,'start of month') AS a0,
         CASE WHEN date(:as_of,'+1 day') = date(:as_of,'start of month','+1 month') THEN 1 ELSE 0 END AS is_month_end,
         CAST(strftime('%d', :as_of) AS INTEGER) AS dd),
p AS (
  SELECT 'cur' AS per, a0 AS a, b0 AS b FROM base
  UNION ALL
  SELECT 'prev', date(a0,'-1 month'),
         CASE WHEN is_month_end = 1 THEN date(a0,'-1 day') ELSE MIN(date(a0,'-1 month','+' || (dd-1) || ' days'), date(a0,'-1 day')) END FROM base
  UNION ALL
  SELECT 'ly', date(a0,'-12 months'),
         CASE WHEN is_month_end = 1 THEN date(a0,'-11 months','-1 day') ELSE MIN(date(a0,'-12 months','+' || (dd-1) || ' days'), date(a0,'-11 months','-1 day')) END FROM base),
rd AS MATERIALIZED (SELECT doc_id, doc_date, due_date, gross, sign FROM receivable_docs),
pd AS MATERIALIZED (SELECT doc_key, doc_date, gross, sign FROM payable_docs WHERE doc_type IN (SELECT codigo FROM Documentos WHERE mov_cc IN ('2','3'))),
al AS MATERIALIZED (SELECT settled_doc_id, settled_doc_key, payment_date, amount FROM payment_allocations),
ra AS MATERIALIZED (SELECT al.payment_date, rd.doc_date, rd.due_date, rd.sign * al.amount AS amt FROM al JOIN rd ON rd.doc_id = al.settled_doc_id),
pa AS MATERIALIZED (SELECT al.payment_date, pd.sign * al.amount AS amt FROM al JOIN pd ON pd.doc_key = al.settled_doc_key),
sf AS (SELECT p.per, SUM(f.net) AS net, SUM(f.margin) AS margin, COUNT(DISTINCT CASE WHEN f.doc_class = 'invoice' THEN f.doc_id END) AS inv
       FROM p JOIN sales_facts f ON f.doc_date BETWEEN p.a AND p.b GROUP BY p.per),
ex AS MATERIALIZED (SELECT doc_date, pnl_line, net FROM expense_docs WHERE doc_date >= (SELECT MIN(a) FROM p)),
ed AS (SELECT p.per, SUM(CASE WHEN pnl_line = 'staff' THEN net ELSE 0 END) AS staff, SUM(CASE WHEN pnl_line = 'rent' THEN net ELSE 0 END) AS rent,
              SUM(CASE WHEN pnl_line = 'opex' THEN net ELSE 0 END) AS opex, SUM(CASE WHEN pnl_line = 'investment' THEN net ELSE 0 END) AS inv
       FROM p JOIN ex ON ex.doc_date BETWEEN p.a AND p.b GROUP BY p.per),
vl AS (SELECT p.per, SUM(CASE WHEN x.side = 'sales' THEN x.vat ELSE 0 END) AS v_out, SUM(CASE WHEN x.side <> 'sales' THEN x.vat ELSE 0 END) AS v_in
       FROM p JOIN (SELECT 'sales' AS side, doc_date, vat FROM sales_docs WHERE is_cancelled = 0 AND doc_class IN ('invoice','credit_note')
                    UNION ALL SELECT 'input', doc_date, vat FROM payable_docs WHERE party_type = 'supplier' OR doc_type IN ('FTOC','FROC','NCOC')) x
         ON x.doc_date BETWEEN p.a AND p.b GROUP BY p.per),
pu AS (SELECT p.per, SUM(x.net) AS net FROM p JOIN payable_docs x ON x.party_type = 'supplier' AND x.doc_date BETWEEN p.a AND p.b GROUP BY p.per),
cf AS (SELECT p.per, SUM(CASE WHEN x.dir = 'in' THEN x.amt ELSE 0 END) AS cin, SUM(CASE WHEN x.dir = 'out' THEN x.amt ELSE 0 END) AS cout
       FROM p JOIN (SELECT doc_date AS d, direction AS dir, amount AS amt FROM payment_docs
                    UNION ALL SELECT s.doc_date, 'in', s.gross FROM sales_docs s JOIN Documentos t ON t.codigo = s.doc_type
                    WHERE t.mov_cc = '4' AND s.is_cancelled = 0 AND s.is_internal = 0) x ON x.d BETWEEN p.a AND p.b GROUP BY p.per),
bal AS (SELECT p.per,
          (SELECT SUM(gross) FROM rd WHERE doc_date <= p.b) - (SELECT SUM(amt) FROM ra WHERE payment_date <= p.b) AS recv,
          (SELECT SUM(gross) FROM rd WHERE doc_date <= p.b AND due_date < date(p.b,'-90 days'))
          - (SELECT SUM(amt) FROM ra WHERE payment_date <= p.b AND doc_date <= p.b AND due_date < date(p.b,'-90 days')) AS recv90,
          (SELECT SUM(gross) FROM pd WHERE doc_date <= p.b) - (SELECT SUM(amt) FROM pa WHERE payment_date <= p.b) AS pay
        FROM p),
m AS (
  SELECT per, 1 AS ord, 'net_sales' AS kpi, net AS v FROM sf
  UNION ALL SELECT per, 2, 'gross_margin', margin FROM sf
  UNION ALL SELECT per, 3, 'gross_margin_pct', 100.0 * margin / net FROM sf
  UNION ALL SELECT per, 4, 'invoices', inv FROM sf
  UNION ALL SELECT per, 5, 'purchases_net', net FROM pu
  UNION ALL SELECT per, 6, 'overheads_staff', staff FROM ed
  UNION ALL SELECT per, 7, 'overheads_rent', rent FROM ed
  UNION ALL SELECT per, 8, 'overheads_other', opex FROM ed
  UNION ALL SELECT per, 9, 'overheads_total', staff + rent + opex FROM ed
  UNION ALL SELECT per, 11, 'investments_not_deducted', inv FROM ed
  UNION ALL SELECT per, 12, 'vat_output_sales', v_out FROM vl
  UNION ALL SELECT per, 13, 'vat_input_purchases_overheads', v_in FROM vl
  UNION ALL SELECT per, 14, 'vat_net_to_pay', v_out - v_in FROM vl
  UNION ALL SELECT per, 15, 'money_in', cin FROM cf
  UNION ALL SELECT per, 16, 'money_out', cout FROM cf
  UNION ALL SELECT per, 17, 'receivables_end', recv FROM bal
  UNION ALL SELECT per, 18, 'receivables_overdue_90d_end', recv90 FROM bal
  UNION ALL SELECT per, 19, 'payables_end', pay FROM bal),
r AS (SELECT ord, kpi, MAX(CASE WHEN per='cur' THEN v END) AS cur, MAX(CASE WHEN per='prev' THEN v END) AS prev,
             MAX(CASE WHEN per='ly' THEN v END) AS ly FROM m GROUP BY ord, kpi
      UNION ALL
      SELECT 10, 'operating_result_indicative',
             MAX(CASE WHEN per='cur' AND kpi='gross_margin' THEN v END) - MAX(CASE WHEN per='cur' AND kpi='overheads_total' THEN v END),
             MAX(CASE WHEN per='prev' AND kpi='gross_margin' THEN v END) - MAX(CASE WHEN per='prev' AND kpi='overheads_total' THEN v END),
             MAX(CASE WHEN per='ly' AND kpi='gross_margin' THEN v END) - MAX(CASE WHEN per='ly' AND kpi='overheads_total' THEN v END) FROM m)
SELECT r.kpi, (SELECT a || '..' || b FROM p WHERE per='cur') AS period, ROUND(r.cur,1) AS this_month,
       ROUND(r.prev,1) AS previous_month, ROUND(r.ly,1) AS same_month_last_year,
       CASE WHEN r.kpi = 'gross_margin_pct' THEN ROUND(r.cur - r.prev,1) ELSE ROUND(100.0 * (r.cur - r.prev) / NULLIF(abs(r.prev),0),1) END AS vs_prev,
       CASE WHEN r.kpi = 'gross_margin_pct' THEN ROUND(r.cur - r.ly,1) ELSE ROUND(100.0 * (r.cur - r.ly) / NULLIF(abs(r.ly),0),1) END AS vs_last_year,
       CASE WHEN r.kpi = 'gross_margin_pct' THEN 'pp' ELSE '%' END AS change_unit
FROM r ORDER BY r.ord
