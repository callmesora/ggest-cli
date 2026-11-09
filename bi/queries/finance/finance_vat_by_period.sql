-- name: finance_vat_by_period
-- description: VAT per period (month or quarter, granularity=month|quarter) and rate, from the VAT boxes of each document (vat_lines): sales (VAT charged, output), supplier purchases and overheads (VAT on purchases, input), with taxable base and VAT per rate (0% rows never carry VAT: VAT typed on a 0% slot is corrected in vat_lines, see its data_fix column), then a NET row per period (output - input; positive = to pay, negative = credit to recover). Indicative preparation of the periodic VAT return: exempt/0% lines are listed with their vat_regime (int intra-EU, aut reverse charge, ext/ter exports...); reverse-charge self-assessment on intra-EU purchases is not computed; overheads only exist from the year they started being recorded.
-- params: start=last_year_start, end=today, granularity=quarter
WITH v AS (
  SELECT CASE WHEN :granularity = 'month' THEN month ELSE quarter END AS period, side, vat_rate,
         COALESCE(vat_regime,'') AS vat_regime, base, vat, doc_id
  FROM vat_lines WHERE doc_date BETWEEN :start AND :end),
d AS (
  SELECT period, side, vat_rate, vat_regime, COUNT(DISTINCT doc_id) AS docs, SUM(base) AS base, SUM(vat) AS vat
  FROM v GROUP BY 1,2,3,4),
n AS (
  SELECT period, 'NET (output - input)' AS side, NULL AS vat_rate, '' AS vat_regime, NULL AS docs,
         NULL AS base, SUM(CASE WHEN side = 'sales' THEN vat ELSE -vat END) AS vat
  FROM d GROUP BY period)
SELECT period, side, vat_rate, vat_regime, docs, ROUND(base,2) AS base, ROUND(vat,2) AS vat
FROM (SELECT * FROM d UNION ALL SELECT * FROM n)
ORDER BY period, CASE side WHEN 'sales' THEN 1 WHEN 'purchases' THEN 2 WHEN 'overheads' THEN 3 ELSE 4 END, vat_rate DESC
