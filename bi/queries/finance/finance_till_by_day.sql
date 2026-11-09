-- name: finance_till_by_day
-- description: Till (caixa) movements per day by payment method (till_movements; the till module is only used from its adoption year): cash, card, transfer, Multibanco reference, MB Way, cheque, offsets; money in from counter sales and receipts, money out from refunds and cash withdrawals; cash_net = what should change in the cash drawer. Default = the last day in the data; pass start/end for a range (e.g. a week or month).
-- params: start=today, end=today
SELECT move_date, COUNT(DISTINCT cash_session) AS sessions, COUNT(DISTINCT doc_id) AS documents,
       ROUND(SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END),2) AS money_in,
       ROUND(SUM(CASE WHEN amount < 0 THEN amount ELSE 0 END),2) AS money_out,
       ROUND(SUM(CASE WHEN method_group = 'cash' THEN amount ELSE 0 END),2) AS cash_net,
       ROUND(SUM(CASE WHEN method_group = 'card' THEN amount ELSE 0 END),2) AS card,
       ROUND(SUM(CASE WHEN method_group = 'transfer' THEN amount ELSE 0 END),2) AS transfer,
       ROUND(SUM(CASE WHEN method_group = 'mb_reference' THEN amount ELSE 0 END),2) AS mb_reference,
       ROUND(SUM(CASE WHEN method_group = 'mbway' THEN amount ELSE 0 END),2) AS mbway,
       ROUND(SUM(CASE WHEN method_group NOT IN ('cash','card','transfer','mb_reference','mbway') THEN amount ELSE 0 END),2) AS other,
       ROUND(SUM(CASE WHEN doc_type IN ('FR','FS') THEN amount ELSE 0 END),2) AS counter_sales,
       ROUND(SUM(CASE WHEN doc_type IN ('R','RECPT','ACERT') THEN amount ELSE 0 END),2) AS receipts
FROM till_movements
WHERE move_date BETWEEN :start AND :end
GROUP BY move_date ORDER BY move_date
