-- name: operations_activity_by_area
-- description: What the team spends gGest time on: activity-log events (log_atividades, from 2020-03) per screen/module area in a period, split by operation (viewed, created, changed, printed, cancelled, deleted), with the number of distinct users and the share of all events. `user` = optional user code to see one person's mix (aggregate counts only). Columns: area, events, share_pct, users, viewed, created, changed, printed, cancelled, deleted.
-- params: start=year_start, end=today, user=, limit=30
SELECT area, COUNT(*) AS events, ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS share_pct, COUNT(DISTINCT user_code) AS users,
       SUM(operation = 'VISUALIZOU') AS viewed, SUM(operation IN ('CRIOU','NOVO')) AS created, SUM(operation IN ('ALTEROU','ALTERAR')) AS changed,
       SUM(operation = 'IMPRIMIU') AS printed, SUM(operation = 'ANULOU') AS cancelled, SUM(operation = 'ELIMINOU') AS deleted
FROM activity_log
WHERE event_date BETWEEN :start AND :end AND (:user = '' OR user_code = CAST(:user AS TEXT))
GROUP BY area
ORDER BY events DESC
LIMIT :limit
