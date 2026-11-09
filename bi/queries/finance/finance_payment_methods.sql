-- name: finance_payment_methods
-- description: Money received by payment method per year or month (granularity=year|month) from the till (Lin_caixa joined to cab_caixa, available from 2022): invoice-receipts paid at the counter (FR) + receipts of credit invoices (R) minus refunds (NCP). Methods: NUM cash, MB Multibanco card, TRB bank transfer, if/eas MB payment references (Ifthenpay/EasyPay), mbway, CHQB cheque, mypos.
-- params: granularity=year, start=2022-01-01, end=2026-12-31
WITH m AS (
  SELECT CASE WHEN :granularity = 'month' THEN substr(c.data,1,4)||'-'||substr(c.data,5,2) ELSE substr(c.data,1,4) END AS period,
         date(substr(c.data,1,4)||'-'||substr(c.data,5,2)||'-'||substr(c.data,7,2)) AS d,
         CASE WHEN l.forma_pagamento = 'NUM' THEN 'cash' WHEN l.forma_pagamento IN ('MB','mypos') THEN 'card'
              WHEN l.forma_pagamento = 'TRB' THEN 'transfer' WHEN l.forma_pagamento IN ('if','eas') THEN 'mb_reference'
              WHEN l.forma_pagamento = 'mbway' THEN 'mbway' WHEN l.forma_pagamento = 'CHQB' THEN 'cheque' ELSE 'other' END AS method,
         CASE WHEN l.Codigo = 'NCP' THEN -1 ELSE 1 END * CAST(l.valor AS REAL) AS amount, l.Codigo AS doc_type
  FROM Lin_caixa l
  JOIN cab_caixa c ON c.codigo = l.Codigo AND c.numero = l.numero AND c.serie = l.serie AND c.ano = l.ano
  WHERE l.Codigo IN ('FR','R','NCP'))
SELECT period, ROUND(SUM(amount),0) AS total_received,
       ROUND(SUM(CASE WHEN method='cash' THEN amount ELSE 0 END),0) AS cash,
       ROUND(SUM(CASE WHEN method='card' THEN amount ELSE 0 END),0) AS card,
       ROUND(SUM(CASE WHEN method='transfer' THEN amount ELSE 0 END),0) AS transfer,
       ROUND(SUM(CASE WHEN method='mb_reference' THEN amount ELSE 0 END),0) AS mb_reference,
       ROUND(SUM(CASE WHEN method='mbway' THEN amount ELSE 0 END),0) AS mbway,
       ROUND(SUM(CASE WHEN method IN ('cheque','other') THEN amount ELSE 0 END),0) AS cheque_other,
       ROUND(100.0*SUM(CASE WHEN method='cash' THEN amount ELSE 0 END)/SUM(amount),1) AS cash_pct,
       ROUND(100.0*SUM(CASE WHEN method='card' THEN amount ELSE 0 END)/SUM(amount),1) AS card_pct,
       ROUND(100.0*SUM(CASE WHEN method='transfer' THEN amount ELSE 0 END)/SUM(amount),1) AS transfer_pct,
       ROUND(100.0*SUM(CASE WHEN method='mb_reference' THEN amount ELSE 0 END)/SUM(amount),1) AS mb_reference_pct,
       ROUND(SUM(CASE WHEN doc_type='FR' THEN amount ELSE 0 END),0) AS counter_sales_fr,
       ROUND(SUM(CASE WHEN doc_type='R' THEN amount ELSE 0 END),0) AS receipts_r
FROM m WHERE d BETWEEN :start AND :end
GROUP BY period ORDER BY period
