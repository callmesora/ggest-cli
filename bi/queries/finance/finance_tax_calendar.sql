-- name: finance_tax_calendar
-- description: Obligations calendar from gGest (tax_obligations: SAF-T submission, VAT return, social security, payroll, withholding tax, monthly maps for the accountant, recurring invoices to issue...). Default mode=next: one row per obligation with its NEXT due date (status upcoming / due_today), plus its last due date in the past days_back days when it is not marked done in gGest (status past_due_not_marked_done; 'done' comes from expediente_obrigacoes_geradas, which many companies don't maintain, so treat that status as 'to confirm'). mode=all lists every occurrence between as_of - days_back and as_of + days_ahead. Columns: status, due_date, days_left (negative = passed), alert_from, description, note. Pair with finance_vat_by_period (VAT of the last period) and finance_vat_quarter_projection (current quarter estimate).
-- params: as_of=today, mode=next, days_ahead=45, days_back=15
WITH RECURSIVE mo(k) AS (SELECT -2 UNION ALL SELECT k + 1 FROM mo WHERE k < 13),
cal AS (
  SELECT t.*, date(:as_of, 'start of month', mo.k || ' months') AS month_start
  FROM tax_obligations t CROSS JOIN mo
  WHERE t.month = CAST(strftime('%m', date(:as_of, 'start of month', mo.k || ' months')) AS INTEGER)),
d AS (
  SELECT cal.*, MIN(date(month_start, '+' || (due_day - 1) || ' days'), date(month_start, '+1 month', '-1 day')) AS due_date
  FROM cal),
g AS (
  SELECT d.*,
         EXISTS (SELECT 1 FROM expediente_obrigacoes_geradas x
                 WHERE x.Obrigacao = d.obligation_code AND x.Estado = '1'
                   AND CAST(x.Ano AS INTEGER) = CAST(strftime('%Y', d.month_start) AS INTEGER)
                   AND CAST(x.Mes AS INTEGER) = CAST(strftime('%m', d.month_start) AS INTEGER)) AS is_done,
         ROW_NUMBER() OVER (PARTITION BY obligation_code, due_date >= :as_of
                            ORDER BY CASE WHEN due_date >= :as_of THEN due_date END, due_date DESC) AS rn
  FROM d),
s AS (
  SELECT g.*, CASE WHEN due_date > :as_of THEN 'upcoming' WHEN due_date = :as_of THEN 'due_today'
                   WHEN is_done THEN 'done' ELSE 'past_due_not_marked_done' END AS status
  FROM g)
SELECT status, due_date, CAST(julianday(due_date) - julianday(:as_of) AS INTEGER) AS days_left,
       date(due_date, '-' || COALESCE(alert_days,0) || ' days') AS alert_from,
       obligation_code, description, note
FROM s
WHERE (:mode = 'all' AND due_date BETWEEN date(:as_of, '-' || :days_back || ' days') AND date(:as_of, '+' || :days_ahead || ' days'))
   OR (:mode <> 'all' AND rn = 1 AND (
         (due_date >= :as_of AND due_date <= date(:as_of, '+' || :days_ahead || ' days'))
         OR (due_date < :as_of AND due_date >= date(:as_of, '-' || :days_back || ' days') AND NOT is_done)))
ORDER BY CASE status WHEN 'past_due_not_marked_done' THEN 0 WHEN 'due_today' THEN 1 ELSE 2 END, due_date, obligation_code
