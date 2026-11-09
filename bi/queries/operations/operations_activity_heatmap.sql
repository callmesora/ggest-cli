-- name: operations_activity_heatmap
-- description: When the shop works in gGest (whole team, aggregated): documents created per weekday (0=Sunday .. 6=Saturday) and hour band in a period, plus total gGest activity-log events per weekday. Columns: weekday, weekday_name, before_9, h09, h10 ... h19, after_20, documents, log_events. Use to plan opening hours, staffing and quiet time for admin work.
-- params: start=last_year_start, end=today
WITH d AS (SELECT weekday, hour FROM documents_created WHERE is_migrated = 0 AND date(created_at) BETWEEN :start AND :end),
l AS (SELECT weekday, COUNT(*) AS n FROM activity_log WHERE event_date BETWEEN :start AND :end GROUP BY weekday)
SELECT d.weekday,
       CASE d.weekday WHEN 0 THEN 'domingo' WHEN 1 THEN 'segunda' WHEN 2 THEN 'terça' WHEN 3 THEN 'quarta' WHEN 4 THEN 'quinta' WHEN 5 THEN 'sexta' ELSE 'sábado' END AS weekday_name,
       SUM(hour < 9) AS before_9, SUM(hour = 9) AS h09, SUM(hour = 10) AS h10, SUM(hour = 11) AS h11, SUM(hour = 12) AS h12,
       SUM(hour = 13) AS h13, SUM(hour = 14) AS h14, SUM(hour = 15) AS h15, SUM(hour = 16) AS h16, SUM(hour = 17) AS h17,
       SUM(hour = 18) AS h18, SUM(hour = 19) AS h19, SUM(hour >= 20) AS after_20,
       COUNT(*) AS documents, MAX(l.n) AS log_events
FROM d LEFT JOIN l ON l.weekday = d.weekday
GROUP BY d.weekday
ORDER BY CASE d.weekday WHEN 0 THEN 7 ELSE d.weekday END
