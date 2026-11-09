-- name: repairs_seasonality
-- description: When do repairs come in? by = month (average orders per calendar month over the full years in the range, and % of the yearly total), weekday (orders and % by day of week, 0 = Sunday) or day_of_month. Based on the opening date of the repair order (repairs view). Use full years (default from 2008 to last year) to avoid partial-year bias.
-- params: start_year=2008, end_year=last_year, by=month
WITH r AS (
  SELECT year, CASE :by WHEN 'weekday' THEN CAST(strftime('%w', opened_on) AS INTEGER)
                        WHEN 'day_of_month' THEN CAST(strftime('%d', opened_on) AS INTEGER)
                        ELSE CAST(strftime('%m', opened_on) AS INTEGER) END AS k
  FROM (SELECT CAST(substr(data_doc,1,4) AS INTEGER) AS year,
               substr(data_doc,1,4)||'-'||substr(data_doc,5,2)||'-'||substr(data_doc,7,2) AS opened_on
        FROM Cab_Assistec WHERE data_doc <> '') x
  WHERE year BETWEEN :start_year AND :end_year)
SELECT :by AS dimension, k AS key,
       CASE WHEN :by = 'weekday' THEN substr('domsegterquaquisexsab', k * 3 + 1, 3) END AS weekday_name,
       COUNT(*) AS orders,
       ROUND(1.0 * COUNT(*) / (SELECT COUNT(DISTINCT year) FROM r), 1) AS avg_per_year,
       ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM r), 1) AS pct
FROM r GROUP BY k ORDER BY k
